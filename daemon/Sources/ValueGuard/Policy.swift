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

/// Per-frame, per-category result. Returned for *every* category on every
/// classified frame (not only those that exceed threshold) so calibration
/// tooling sees the full score distribution.
public struct CategoryScore: Sendable {
    public let category: PolicyCategory
    public let positiveScore: Float
    public let negativeScore: Float
    public let firing: Bool
}

/// Back-compat alias. Existing callers can keep referring to PolicyFlag;
/// new code should use CategoryScore.
public typealias PolicyFlag = CategoryScore

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

    /// Score an image embedding against every category. Returns one result per
    /// category regardless of whether it fires — so calibration tooling sees
    /// the full distribution.
    ///
    /// Firing semantics: `pos >= threshold` where both are raw SigLIP-2 cosine
    /// similarity. Earlier versions used a temperature-scaled softmax over the
    /// (pos, neg) pair; that produced near-saturated P-values for any positive
    /// margin and made thresholds uncalibrated against the actual score scale.
    /// Calibration data showed per-category noise floors of 0.01–0.07 raw and
    /// matching SigLIP-2 literature reports true matches at 0.20–0.35, so raw
    /// thresholds in [0.10, 0.25] are both meaningful and tunable.
    public func evaluate(embedding: [Float]) -> [CategoryScore] {
        precondition(embedding.count == embedDim, "embedding dim mismatch")
        var scores: [CategoryScore] = []
        scores.reserveCapacity(categories.count)
        for cat in categories {
            let pos = dot(cat.positiveEmbedding, embedding)
            let neg = dot(cat.negativeEmbedding, embedding)
            scores.append(CategoryScore(
                category: cat,
                positiveScore: pos,
                negativeScore: neg,
                firing: pos >= cat.threshold
            ))
        }
        return scores
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
