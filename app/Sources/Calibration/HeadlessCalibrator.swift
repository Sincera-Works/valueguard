import Foundation
import ValueGuardCore

/// Orchestrates the headless calibration flow for one category.
///
/// Now bilateral: scores both POSITIVE-class images (from the policy's
/// positive captions) AND NEGATIVE-class images (from the policy's negative
/// captions + the user's "I am okay with X" exclusions). The threshold is
/// chosen to maximize the gap between the two distributions, with explicit
/// signaling when they overlap (which means the policy can't discriminate
/// at all and the captions need work).
///
/// All image bytes live in RAM only — fetched, decoded, embedded, and
/// released. Never displayed, never written to disk.
@MainActor
final class HeadlessCalibrator {
    struct Progress {
        let stage: String
        let current: Int
        let total: Int
    }

    enum Separability {
        case clean(gap: Float)        // p05(pos) > p95(neg)
        case overlapping(margin: Float) // p05(pos) ≤ p95(neg)
        case noPositives
        case noNegatives
    }

    /// How the positive-side score distribution was obtained. Drives the UI's
    /// labeling so a successful caption-anchored fit isn't presented as the
    /// old "0 positives" failure.
    enum PositiveSource: Equatable {
        /// Positive sample images were fetched and scored (the normal path).
        case images
        /// No positive images exist in the calibration source, so the
        /// category's `positive_captions` were re-embedded on-device through
        /// the SigLIP-2 text encoder and scored against `posVec`. No images,
        /// no network.
        case captionAnchored
        /// Neither images nor captions yielded any positive scores (e.g. the
        /// category has no positive captions — shouldn't normally happen).
        case none
    }

    struct Result {
        let positiveScores: [Float]
        let negativeScores: [Float]
        let positiveSource: PositiveSource
        let suggestedThreshold: Float
        let separability: Separability
        let p05Pos: Float?
        let p95Neg: Float?
        let p50Pos: Float?
        let p50Neg: Float?
        let posteriorCurve: [(score: Float, posterior: Double)]
        let bayesianThreshold: Float
        let conformalThreshold: Float?
        let empiricalFPR: Double
        let empiricalFNR: Double
        let prior: Double
        let costRatio: Double
        let conformalAlpha: Double
    }

    enum CalibrationError: LocalizedError {
        case noImagesFetched

        var errorDescription: String? {
            switch self {
            case .noImagesFetched: return "No images were fetched. Try a different category or check network."
            }
        }
    }

    /// Strip filler words and quoting from a caption to build a search query.
    /// "a photograph of a pet dog standing on a leash" → "pet dog standing leash"
    static func captionToQuery(_ caption: String) -> String {
        let stop = Set(["a", "an", "the", "of", "on", "in", "with", "to", "for", "by",
                        "photograph", "photo", "image", "picture", "screenshot",
                        "illustration", "drawing", "rendering", "render", "painting",
                        "snapshot", "showing", "close-up", "phone", "digital"])
        let words = caption
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stop.contains($0) }
        return words.joined(separator: " ")
    }

    func calibrate(
        category: PolicyCategory,
        valuesText: String,
        imagesPerQuery: Int = 3,
        prior: Double = 0.5,
        costRatio: Double = 1.0,
        conformalAlpha: Double = 0.05,
        onProgress: @escaping (Progress) -> Void = { _ in }
    ) async throws -> Result {
        let view = try PolicyBinaryReader.read(categoryID: category.id, from: AppSupport.policyBinURL)
        let posVec = view.positiveVec
        let classifier = try await Classifier(embeddingDim: posVec.count)

        // Build the two query sets.
        let positiveQueries = Array(category.positive_captions.prefix(10).map(Self.captionToQuery))
        var negativeQueries = Array(category.negative_captions.prefix(6).map(Self.captionToQuery))
        // Add the user's "okay with X" exclusions — the most boundary-relevant
        // negative tests we can construct.
        let exclusions = ValuesExclusionExtractor.extract(from: valuesText)
        negativeQueries.append(contentsOf: exclusions)

        let imagePosScores = try await scoreCorpus(
            label: "positives",
            queries: positiveQueries,
            classifier: classifier,
            posVec: posVec,
            imagesPerQuery: imagesPerQuery,
            onProgress: onProgress
        )
        let negScores = try await scoreCorpus(
            label: "negatives",
            queries: negativeQueries,
            classifier: classifier,
            posVec: posVec,
            imagesPerQuery: imagesPerQuery,
            onProgress: onProgress
        )

        // Caption-anchored fallback. For EXPLICIT categories the moderated
        // calibration source returns ZERO positive images by design (it never
        // hosts the content), so `imagePosScores` is empty and the Bayesian
        // fit would be meaningless. Rather than fetch positives from an
        // unmoderated source (a hard threat-model line we will not cross), we
        // synthesize the positive distribution entirely on-device: re-embed
        // the author's `positive_captions` through the SigLIP-2 TEXT encoder
        // the app already ships, and score each caption embedding against
        // `posVec` the SAME way images are scored (dot product). Because both
        // the caption embeddings and `posVec` are L2-normalized, this is
        // cosine similarity — on the same scale as the image flow's numbers.
        //
        // Note for future readers: text-vs-text cosine sits HIGHER than
        // image-vs-text cosine, so these anchors land above the negative image
        // cloud. That is intended — they bound the false-positive gap on
        // benign content; recall is anchored to the author's captions. Do NOT
        // rescale them.
        let posScores: [Float]
        let positiveSource: PositiveSource
        if !imagePosScores.isEmpty {
            posScores = imagePosScores
            positiveSource = .images
        } else {
            let anchored = try await captionAnchoredPositives(
                captions: category.positive_captions,
                posVec: posVec,
                onProgress: onProgress
            )
            if anchored.isEmpty {
                // Both image fetch and caption re-embedding came up empty
                // (e.g. the category has no positive captions). Keep the
                // honest "no positives" state.
                posScores = []
                positiveSource = .none
            } else {
                posScores = anchored
                positiveSource = .captionAnchored
            }
        }

        return makeResult(
            posScores: posScores,
            negScores: negScores,
            positiveSource: positiveSource,
            prior: prior,
            costRatio: costRatio,
            conformalAlpha: conformalAlpha
        )
    }

    /// Re-embed the category's positive captions on-device and score each
    /// against `posVec`, producing a synthetic positive-score distribution
    /// when no positive images can be (safely) fetched.
    ///
    /// Each caption is tokenized + run through the bundled SigLIP-2 text
    /// encoder (`SigLIP2Text.mlpackage`) and L2-normalized — one point per
    /// caption, in the same unit-sphere space images are embedded into. The
    /// score is `dot(captionEmb, posVec)`, identical to how `scoreCorpus`
    /// scores a fetched image embedding, so the two corpora live on one scale.
    ///
    /// Construction mirrors `PolicyPipeline.compile`: the tokenizer/encoder are
    /// `@MainActor`-isolated CoreML objects, so the encode runs inside
    /// `MainActor.run` on a detached task. Returns `[]` if there are no
    /// captions to embed.
    private func captionAnchoredPositives(
        captions: [String],
        posVec: [Float],
        onProgress: @escaping (Progress) -> Void
    ) async throws -> [Float] {
        guard !captions.isEmpty else { return [] }
        onProgress(.init(stage: "No positive images available — embedding captions on-device",
                         current: 0, total: captions.count))

        let tokenizer = try PolicyTokenizer()
        let encoder = try TextEncoder()
        let embedder = CaptionEmbedder(tokenizer: tokenizer, encoder: encoder)

        let captionEmbeddings = try await Task.detached(priority: .userInitiated) {
            try await MainActor.run { try embedder.embedEach(captions: captions) }
        }.value

        var scores: [Float] = []
        scores.reserveCapacity(captionEmbeddings.count)
        for (i, emb) in captionEmbeddings.enumerated() {
            onProgress(.init(stage: "Scoring caption anchor", current: i + 1, total: captionEmbeddings.count))
            let score = zip(emb, posVec).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            scores.append(score)
        }
        return scores
    }

    private func scoreCorpus(
        label: String,
        queries: [String],
        classifier: Classifier,
        posVec: [Float],
        imagesPerQuery: Int,
        onProgress: @escaping (Progress) -> Void
    ) async throws -> [Float] {
        var urls: [URL] = []
        for (i, q) in queries.enumerated() {
            onProgress(.init(stage: "Searching \(label): \"\(q)\"", current: i + 1, total: queries.count))
            let found = (try? await WikimediaImageFetcher.searchImages(query: q, limit: imagesPerQuery)) ?? []
            urls.append(contentsOf: found)
        }
        // De-dupe by URL.
        var seen = Set<URL>()
        urls = urls.filter { seen.insert($0).inserted }

        var scores: [Float] = []
        scores.reserveCapacity(urls.count)
        for (i, url) in urls.enumerated() {
            onProgress(.init(stage: "Embedding \(label) image", current: i + 1, total: urls.count))
            do {
                guard let cg = try await WikimediaImageFetcher.downloadImage(url) else { continue }
                let buffer = try PixelBufferBuilder.make(from: cg)
                let emb = try classifier.embed(buffer)
                let score = zip(emb, posVec).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                scores.append(score)
            } catch {
                continue
            }
        }
        return scores
    }

    private func makeResult(
        posScores: [Float],
        negScores: [Float],
        positiveSource: PositiveSource,
        prior: Double,
        costRatio: Double,
        conformalAlpha: Double
    ) -> Result {
        let posSorted = posScores.sorted()
        let negSorted = negScores.sorted()
        let p05Pos = posSorted.isEmpty ? nil : posSorted[max(0, Int(Double(posSorted.count) * 0.05))]
        let p50Pos = posSorted.isEmpty ? nil : posSorted[posSorted.count / 2]
        let p95Neg = negSorted.isEmpty ? nil : negSorted[min(negSorted.count - 1, Int(Double(negSorted.count) * 0.95))]
        let p50Neg = negSorted.isEmpty ? nil : negSorted[negSorted.count / 2]

        // Run the Bayesian + conformal calibrator regardless of separability;
        // it degrades gracefully on small or empty samples.
        let bayes = BayesianCalibrator(
            positiveScores: posScores,
            negativeScores: negScores,
            prior: prior,
            costRatio: costRatio,
            conformalAlpha: conformalAlpha
        )
        let bayesT = bayes.bayesianThreshold()
        let confT = bayes.conformalThreshold()
        let recommended = bayes.recommendedThreshold()
        let curve = bayes.sampledPosterior(steps: 120)

        let separability: Separability
        if posSorted.isEmpty {
            separability = .noPositives
        } else if negSorted.isEmpty {
            separability = .noNegatives
        } else if let p05P = p05Pos, let p95N = p95Neg, p05P > p95N {
            separability = .clean(gap: p05P - p95N)
        } else if let p05P = p05Pos, let p95N = p95Neg {
            separability = .overlapping(margin: p95N - p05P)
        } else {
            separability = .noPositives
        }

        return Result(
            positiveScores: posScores,
            negativeScores: negScores,
            positiveSource: positiveSource,
            suggestedThreshold: recommended,
            separability: separability,
            p05Pos: p05Pos,
            p95Neg: p95Neg,
            p50Pos: p50Pos,
            p50Neg: p50Neg,
            posteriorCurve: curve,
            bayesianThreshold: bayesT,
            conformalThreshold: confT,
            empiricalFPR: bayes.empiricalFPR(at: recommended),
            empiricalFNR: bayes.empiricalFNR(at: recommended),
            prior: prior,
            costRatio: costRatio,
            conformalAlpha: conformalAlpha
        )
    }
}
