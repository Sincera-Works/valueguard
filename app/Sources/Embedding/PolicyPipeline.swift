import Foundation

@MainActor
enum PolicyPipeline {
    struct Progress {
        let stage: String
        let current: Int
        let total: Int
    }

    /// Embed every caption in `policy` and write the resulting `policy.bin`.
    /// Calls `onProgress` on the main actor between categories.
    static func compile(
        policy: Policy,
        onProgress: @escaping (Progress) -> Void = { _ in }
    ) async throws -> URL {
        let tokenizer = try PolicyTokenizer()
        let encoder = try TextEncoder()
        let embedder = CaptionEmbedder(tokenizer: tokenizer, encoder: encoder)

        var embeddedCategories: [PolicyBinaryWriter.EmbeddedCategory] = []
        embeddedCategories.reserveCapacity(policy.categories.count)

        let total = policy.categories.count * 2 // pos + neg per category
        var step = 0

        for cat in policy.categories {
            onProgress(.init(stage: "Embedding \(cat.id) positive", current: step, total: total))
            let pos = try await Task.detached(priority: .userInitiated) {
                try await MainActor.run { try embedder.embed(captions: cat.positive_captions) }
            }.value
            step += 1

            onProgress(.init(stage: "Embedding \(cat.id) negative", current: step, total: total))
            let neg = try await Task.detached(priority: .userInitiated) {
                try await MainActor.run { try embedder.embed(captions: cat.negative_captions) }
            }.value
            step += 1

            embeddedCategories.append(.init(
                id: cat.id,
                threshold: Float(cat.threshold),
                action: cat.action,
                positiveVec: pos,
                negativeVec: neg
            ))
        }

        onProgress(.init(stage: "Writing policy.bin", current: total, total: total))
        let url = AppSupport.policyBinURL
        try PolicyBinaryWriter.write(categories: embeddedCategories, to: url)
        return url
    }
}
