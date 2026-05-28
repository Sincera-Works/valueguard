import Foundation

@MainActor
final class CaptionEmbedder {
    private let tokenizer: PolicyTokenizer
    private let encoder: TextEncoder

    init(tokenizer: PolicyTokenizer, encoder: TextEncoder) {
        self.tokenizer = tokenizer
        self.encoder = encoder
    }

    /// Embed a list of captions and return their L2-normalized mean. Mirrors
    /// the Python `embed_captions` in model-conversion/embed_captions.py.
    func embed(captions: [String]) throws -> [Float] {
        let dim = TextEncoder.embedDim
        var sum = [Float](repeating: 0, count: dim)
        for caption in captions {
            let ids = tokenizer.encode(caption)
            let emb = try encoder.encode(inputIds: ids)
            precondition(emb.count == dim, "expected embedding dim \(dim), got \(emb.count)")
            for i in 0..<dim { sum[i] += emb[i] }
        }
        let n = Float(captions.count)
        for i in 0..<dim { sum[i] /= n }
        normalizeL2(&sum)
        return sum
    }

    private func normalizeL2(_ v: inout [Float]) {
        var sq: Float = 0
        for x in v { sq += x * x }
        let norm = sq.squareRoot() + 1e-12
        for i in 0..<v.count { v[i] /= norm }
    }
}
