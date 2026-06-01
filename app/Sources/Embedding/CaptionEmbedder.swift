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
    ///
    /// Behavior is intentionally unchanged: it averages the per-caption
    /// encoder outputs (NOT the L2-normalized per-caption vectors — the
    /// normalization is applied once, to the mean), so this remains
    /// bit-for-bit equivalent to the onboarding compile path that builds
    /// `policy.bin`. It delegates the raw encode to ``encodeEach(captions:)``
    /// so the per-caption building block has a single source of truth.
    func embed(captions: [String]) throws -> [Float] {
        let dim = TextEncoder.embedDim
        let perCaption = try encodeEach(captions: captions)
        var sum = [Float](repeating: 0, count: dim)
        for emb in perCaption {
            for i in 0..<dim { sum[i] += emb[i] }
        }
        let n = Float(captions.count)
        for i in 0..<dim { sum[i] /= n }
        normalizeL2(&sum)
        return sum
    }

    /// Embed each caption individually and return its L2-normalized vector —
    /// one 768-dim point per caption, in the SAME unit-sphere space images are
    /// embedded into. Unlike ``embed(captions:)`` (which averages then
    /// normalizes once), this normalizes each caption so every returned vector
    /// is a comparable cosine point.
    ///
    /// Used by the calibrator's caption-anchored fallback: when no positive
    /// sample images can be fetched for a category (e.g. an explicit category
    /// the moderated calibration source refuses to serve), these per-caption
    /// points stand in for a fetched positive image corpus — entirely
    /// on-device, no images, no network.
    func embedEach(captions: [String]) throws -> [[Float]] {
        try encodeEach(captions: captions).map { emb in
            var v = emb
            normalizeL2(&v)
            return v
        }
    }

    /// Tokenize + text-encode each caption. Returns the raw (un-normalized)
    /// encoder outputs; the SigLIP-2 text tower already L2-normalizes its
    /// output internally (see `TextEncoder.encode`), but callers that need a
    /// strict unit vector should normalize again (``embedEach`` does). Shared
    /// building block for ``embed`` and ``embedEach`` so tokenize→encode lives
    /// in exactly one place.
    private func encodeEach(captions: [String]) throws -> [[Float]] {
        let dim = TextEncoder.embedDim
        var out: [[Float]] = []
        out.reserveCapacity(captions.count)
        for caption in captions {
            let ids = tokenizer.encode(caption)
            let emb = try encoder.encode(inputIds: ids)
            precondition(emb.count == dim, "expected embedding dim \(dim), got \(emb.count)")
            out.append(emb)
        }
        return out
    }

    private func normalizeL2(_ v: inout [Float]) {
        var sq: Float = 0
        for x in v { sq += x * x }
        let norm = sq.squareRoot() + 1e-12
        for i in 0..<v.count { v[i] /= norm }
    }
}
