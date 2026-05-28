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

    struct Result {
        let positiveScores: [Float]
        let negativeScores: [Float]
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

        let posScores = try await scoreCorpus(
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

        return makeResult(
            posScores: posScores,
            negScores: negScores,
            prior: prior,
            costRatio: costRatio,
            conformalAlpha: conformalAlpha
        )
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
