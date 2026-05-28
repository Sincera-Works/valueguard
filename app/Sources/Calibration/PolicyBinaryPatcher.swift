import Foundation

/// In-place editor for the threshold field of a category in policy.bin.
/// Saves a round-trip through embed_captions.py for threshold-only edits.
enum PolicyBinaryPatcher {
    enum PatchError: LocalizedError {
        case fileNotFound(URL)
        case unexpectedHeader
        case categoryNotFound(String)
        case categoryIndexOutOfRange(Int, Int)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let u): return "policy.bin not found: \(u.path)"
            case .unexpectedHeader: return "policy.bin header is not VGP1 — refusing to patch."
            case .categoryNotFound(let id): return "Category '\(id)' not found in policy.bin."
            case .categoryIndexOutOfRange(let i, let n): return "Category index \(i) out of range (have \(n))."
            }
        }
    }

    /// Update the threshold for the category at the given index. Layout:
    ///   header     20 bytes
    ///   per cat:    4 (id_len) + id_len + 4 (threshold) + 1 (action) + 3 (pad) + 3072 (pos) + 3072 (neg)
    static func writeThreshold(_ newValue: Float, atCategoryIndex index: Int, in url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatchError.fileNotFound(url)
        }
        var data = try Data(contentsOf: url)
        guard data.count >= 20, data[0] == 0x56, data[1] == 0x47, data[2] == 0x50, data[3] == 0x31 else {
            throw PatchError.unexpectedHeader
        }
        let nCategories = data.readLE(UInt32.self, at: 8)
        guard index >= 0 && index < Int(nCategories) else {
            throw PatchError.categoryIndexOutOfRange(index, Int(nCategories))
        }
        let embedDim = data.readLE(UInt32.self, at: 12)
        let perCatExtra = 4 /*id_len*/ + 4 /*threshold*/ + 1 + 3 /*pad*/ + 2 * Int(embedDim) * 4

        var offset = 20
        for _ in 0..<index {
            let idLen = data.readLE(UInt32.self, at: offset)
            offset += perCatExtra + Int(idLen) // includes the id bytes
        }
        // At this point offset = start of category's id_len field.
        let idLen = data.readLE(UInt32.self, at: offset)
        let thresholdOffset = offset + 4 + Int(idLen)
        data.writeLE(newValue, at: thresholdOffset)
        try data.write(to: url, options: .atomic)
    }

    /// Convenience: look up a category by id and patch its threshold.
    static func writeThreshold(_ newValue: Float, forCategoryID id: String, in url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PatchError.fileNotFound(url)
        }
        let data = try Data(contentsOf: url)
        guard data.count >= 20, data[0] == 0x56, data[1] == 0x47, data[2] == 0x50, data[3] == 0x31 else {
            throw PatchError.unexpectedHeader
        }
        let nCategories = data.readLE(UInt32.self, at: 8)
        let embedDim = data.readLE(UInt32.self, at: 12)
        let perCatExtra = 4 + 4 + 1 + 3 + 2 * Int(embedDim) * 4

        var offset = 20
        for i in 0..<Int(nCategories) {
            let idLen = Int(data.readLE(UInt32.self, at: offset))
            let idData = data[offset + 4 ..< offset + 4 + idLen]
            let catID = String(data: Data(idData), encoding: .utf8) ?? ""
            if catID == id {
                try writeThreshold(newValue, atCategoryIndex: i, in: url)
                return
            }
            offset += perCatExtra + idLen
        }
        throw PatchError.categoryNotFound(id)
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

    mutating func writeLE(_ value: Float, at offset: Int) {
        var bits = value.bitPattern.littleEndian
        let range = offset ..< offset + 4
        Swift.withUnsafeBytes(of: &bits) { src in
            self.replaceSubrange(range, with: src)
        }
    }
}
