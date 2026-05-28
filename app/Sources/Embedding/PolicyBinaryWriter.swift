import Foundation

/// Writes the `VGP1` binary format defined in
/// model-conversion/embed_captions.py:1-23. Must match byte-for-byte.
enum PolicyBinaryWriter {
    private static let magic: [UInt8] = Array("VGP1".utf8) // 0x56 0x47 0x50 0x31
    private static let version: UInt32 = 1
    private static let embedDim: UInt32 = 768

    static func actionCode(_ a: PolicyAction) -> UInt8 {
        switch a {
        case .log: return 0
        case .blur: return 1
        case .block: return 2
        }
    }

    /// One category's embedded captions, ready to be packed.
    struct EmbeddedCategory {
        let id: String
        let threshold: Float
        let action: PolicyAction
        let positiveVec: [Float] // length 768, L2-normalized
        let negativeVec: [Float] // length 768, L2-normalized
    }

    static func write(categories: [EmbeddedCategory], to url: URL) throws {
        var data = Data()
        data.append(contentsOf: magic)
        data.appendLE(version)
        data.appendLE(UInt32(categories.count))
        data.appendLE(embedDim)
        data.appendLE(UInt32(0)) // reserved

        for cat in categories {
            let idBytes = Array(cat.id.utf8)
            data.appendLE(UInt32(idBytes.count))
            data.append(contentsOf: idBytes)
            data.appendLE(cat.threshold)       // f32
            data.append(actionCode(cat.action)) // u8
            data.append(contentsOf: [0, 0, 0])  // 3 padding bytes
            precondition(cat.positiveVec.count == Int(embedDim))
            precondition(cat.negativeVec.count == Int(embedDim))
            for v in cat.positiveVec { data.appendLE(v) }
            for v in cat.negativeVec { data.appendLE(v) }
        }

        try data.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        var v = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &v) { self.append(contentsOf: $0) }
    }
}
