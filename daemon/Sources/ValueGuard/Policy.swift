import Foundation

public enum PolicyAction: UInt8, Sendable {
    case log = 0
    case blur = 1
    case block = 2
}

public struct PolicyCategory: Sendable {
    public let id: String
    public let threshold: Float
    public let action: PolicyAction
    /// L2-normalized "unsafe" caption-ensemble embedding.
    public let positiveEmbedding: [Float]
    /// L2-normalized "safe" caption-ensemble embedding.
    public let negativeEmbedding: [Float]
}

public struct PolicyFlag: Sendable {
    public let category: PolicyCategory
    public let positiveScore: Float
    public let negativeScore: Float
    public let timestamp: Date
}

enum PolicyError: Error {
    case fileTooShort
    case badMagic
    case unsupportedVersion(UInt32)
    case mismatchedDim(expected: Int, got: Int)
    case truncatedCategory
    case invalidAction(UInt8)
    case invalidUTF8
}

public struct Policy: Sendable {
    public let embedDim: Int
    public let categories: [PolicyCategory]

    public init(loadingFrom url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count >= 20 else { throw PolicyError.fileTooShort }

        let (dim, categories) = try data.withUnsafeBytes { raw -> (Int, [PolicyCategory]) in
            let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let magic = Data(bytes: base, count: 4)
            guard magic == Data([0x56, 0x47, 0x50, 0x31]) else { throw PolicyError.badMagic }

            // id_utf8 is variable-length, so every field after it can be misaligned.
            // Use loadUnaligned for scalars and memcpy for the float arrays.
            let version = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
            guard version == 1 else { throw PolicyError.unsupportedVersion(version) }

            let nCategories = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            let dim = Int(raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
            // reserved uint32 at offset 16

            var offset = 20
            var categories: [PolicyCategory] = []
            categories.reserveCapacity(nCategories)

            for _ in 0..<nCategories {
                guard offset + 4 <= data.count else { throw PolicyError.truncatedCategory }
                let idLen = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                offset += 4

                guard offset + idLen <= data.count else { throw PolicyError.truncatedCategory }
                let idData = Data(bytes: base.advanced(by: offset), count: idLen)
                guard let id = String(data: idData, encoding: .utf8) else { throw PolicyError.invalidUTF8 }
                offset += idLen

                guard offset + 8 <= data.count else { throw PolicyError.truncatedCategory }
                let threshold = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                offset += 4
                let actionByte = raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
                guard let action = PolicyAction(rawValue: actionByte) else {
                    throw PolicyError.invalidAction(actionByte)
                }
                offset += 4 // includes 3 bytes padding

                let vecBytes = dim * MemoryLayout<Float>.size
                guard offset + 2 * vecBytes <= data.count else { throw PolicyError.truncatedCategory }

                var pos = [Float](repeating: 0, count: dim)
                pos.withUnsafeMutableBytes { dst in
                    _ = memcpy(dst.baseAddress!, base.advanced(by: offset), vecBytes)
                }
                offset += vecBytes

                var neg = [Float](repeating: 0, count: dim)
                neg.withUnsafeMutableBytes { dst in
                    _ = memcpy(dst.baseAddress!, base.advanced(by: offset), vecBytes)
                }
                offset += vecBytes

                categories.append(PolicyCategory(
                    id: id,
                    threshold: threshold,
                    action: action,
                    positiveEmbedding: pos,
                    negativeEmbedding: neg
                ))
            }

            return (dim, categories)
        }

        self.embedDim = dim
        self.categories = categories
    }

    /// SigLIP-2 inference temperature. Equal to `exp(logit_scale)` where
    /// `logit_scale = 4.7265` is the learned scalar in `google/siglip2-base-patch16-256`.
    /// Without this scale, raw cosine sims (~0.05 to 0.30 typical) feed a softmax
    /// that produces P-values squeezed into [0.45, 0.55] — abstract thresholds
    /// like 0.55 become useless. With it, P-values spread to [0.05, 0.95] and
    /// threshold semantics match what humans (and LLMs writing policies) expect.
    ///
    /// If you swap to a different SigLIP-2 variant, update this. The bias term
    /// (`logit_bias = -16.77`) cancels for softmax-over-pair and is not needed.
    private static let siglip2BaseTemperature: Float = 112.9012

    /// Score an image embedding against every category and return the categories that fire.
    /// Uses softmax-over-pair with the learned temperature:
    ///   P(unsafe) = exp(T · pos·x) / (exp(T · pos·x) + exp(T · neg·x))
    public func evaluate(embedding: [Float]) -> [PolicyFlag] {
        precondition(embedding.count == embedDim, "embedding dim mismatch")
        let T = Self.siglip2BaseTemperature
        var flags: [PolicyFlag] = []
        let now = Date()
        for cat in categories {
            let pos = dot(cat.positiveEmbedding, embedding)
            let neg = dot(cat.negativeEmbedding, embedding)
            let logitPos = pos * T
            let logitNeg = neg * T
            let maxv = max(logitPos, logitNeg)
            let ep = expf(logitPos - maxv)
            let en = expf(logitNeg - maxv)
            let pUnsafe = ep / (ep + en)
            if pUnsafe >= cat.threshold {
                flags.append(PolicyFlag(
                    category: cat,
                    positiveScore: pos,
                    negativeScore: neg,
                    timestamp: now
                ))
            }
        }
        return flags
    }
}

@inline(__always)
private func dot(_ a: [Float], _ b: [Float]) -> Float {
    var sum: Float = 0
    let n = a.count
    a.withUnsafeBufferPointer { ap in
        b.withUnsafeBufferPointer { bp in
            for i in 0..<n {
                sum += ap[i] * bp[i]
            }
        }
    }
    return sum
}
