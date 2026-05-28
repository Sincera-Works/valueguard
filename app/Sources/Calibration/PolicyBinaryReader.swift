import Foundation

/// Read the positive embedding for a category from policy.bin. Used by the
/// calibrator to score downloaded images against the policy's positive pole.
enum PolicyBinaryReader {
    struct CategoryView {
        let id: String
        let threshold: Float
        let action: UInt8
        let positiveVec: [Float]
        let negativeVec: [Float]
    }

    enum ReadError: LocalizedError {
        case fileNotFound(URL)
        case unexpectedHeader
        case categoryNotFound(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let u): return "policy.bin not found: \(u.path)"
            case .unexpectedHeader: return "policy.bin header is not VGP1."
            case .categoryNotFound(let id): return "Category '\(id)' not found in policy.bin."
            }
        }
    }

    static func read(categoryID: String, from url: URL) throws -> CategoryView {
        let data = try Data(contentsOf: url)
        guard data.count >= 20, data[0] == 0x56, data[1] == 0x47, data[2] == 0x50, data[3] == 0x31 else {
            throw ReadError.unexpectedHeader
        }
        let nCategories = data.readLE(UInt32.self, at: 8)
        let embedDim = Int(data.readLE(UInt32.self, at: 12))
        var offset = 20
        for _ in 0..<Int(nCategories) {
            let idLen = Int(data.readLE(UInt32.self, at: offset))
            let id = String(data: data[offset + 4 ..< offset + 4 + idLen], encoding: .utf8) ?? ""
            let baseAfterID = offset + 4 + idLen
            let threshold = data.readLE(Float.self, at: baseAfterID)
            let action = data[baseAfterID + 4]
            let posOff = baseAfterID + 4 + 1 + 3
            let negOff = posOff + embedDim * 4
            if id == categoryID {
                let pos = (0..<embedDim).map { data.readLE(Float.self, at: posOff + $0 * 4) }
                let neg = (0..<embedDim).map { data.readLE(Float.self, at: negOff + $0 * 4) }
                return CategoryView(id: id, threshold: threshold, action: action, positiveVec: pos, negativeVec: neg)
            }
            offset = negOff + embedDim * 4
        }
        throw ReadError.categoryNotFound(categoryID)
    }
}

private extension Data {
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var v: T = 0
        let range = offset ..< offset + MemoryLayout<T>.size
        Swift.withUnsafeMutableBytes(of: &v) { buf in
            buf.copyBytes(from: self[range])
        }
        return T(littleEndian: v)
    }

    func readLE(_ type: Float.Type, at offset: Int) -> Float {
        let bits: UInt32 = readLE(UInt32.self, at: offset)
        return Float(bitPattern: bits)
    }
}
