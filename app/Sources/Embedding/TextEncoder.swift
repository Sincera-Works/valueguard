import Foundation
import CoreML

enum TextEncoderError: LocalizedError {
    case modelMissing(URL)
    case loadFailed(String)
    case unexpectedOutput

    var errorDescription: String? {
        switch self {
        case .modelMissing(let url): return "Text encoder not downloaded yet: \(url.path)"
        case .loadFailed(let m): return "Failed to load text encoder: \(m)"
        case .unexpectedOutput: return "Text encoder returned an unexpected output shape"
        }
    }
}

@MainActor
final class TextEncoder {
    static let embedDim = 768
    static let contextLength = 64

    private let model: MLModel

    init() throws {
        let mlpkg = AppSupport.textEncoderURL
        guard FileManager.default.fileExists(atPath: mlpkg.path) else {
            throw TextEncoderError.modelMissing(mlpkg)
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            // CoreML can load .mlpackage directories directly; compile if needed.
            let compiled = try MLModel.compileModel(at: mlpkg)
            self.model = try MLModel(contentsOf: compiled, configuration: config)
        } catch {
            throw TextEncoderError.loadFailed(error.localizedDescription)
        }
    }

    /// Run one set of input_ids through the text tower. Returns the 768-dim
    /// embedding (the model already applies L2-norm inside, per the
    /// convert_siglip2.py wrapper).
    func encode(inputIds: [Int32]) throws -> [Float] {
        precondition(inputIds.count == Self.contextLength,
                     "input_ids must be padded/truncated to \(Self.contextLength)")
        let arr = try MLMultiArray(shape: [1, NSNumber(value: Self.contextLength)], dataType: .int32)
        for i in 0..<Self.contextLength {
            arr[[0, i] as [NSNumber]] = NSNumber(value: inputIds[i])
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": MLFeatureValue(multiArray: arr)])
        let output = try model.prediction(from: input)
        guard let emb = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw TextEncoderError.unexpectedOutput
        }
        return Self.copyFloats(from: emb)
    }

    private static func copyFloats(from arr: MLMultiArray) -> [Float] {
        let count = arr.count
        var out = [Float](repeating: 0, count: count)
        switch arr.dataType {
        case .float32:
            let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
            for i in 0..<count { out[i] = ptr[i] }
        case .float16:
            // Promote half → single. Read raw bits and convert manually.
            let raw = arr.dataPointer.bindMemory(to: UInt16.self, capacity: count)
            for i in 0..<count { out[i] = Self.halfToFloat(raw[i]) }
        case .double:
            let ptr = arr.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<count { out[i] = Float(ptr[i]) }
        default:
            for i in 0..<count { out[i] = arr[i].floatValue }
        }
        return out
    }

    private static func halfToFloat(_ h: UInt16) -> Float {
        let sign = UInt32(h >> 15) & 0x1
        let exp = UInt32(h >> 10) & 0x1F
        let mant = UInt32(h) & 0x3FF
        var bits: UInt32 = sign << 31
        if exp == 0 {
            if mant != 0 {
                // Subnormal: normalize.
                var m = mant
                var e: UInt32 = 1
                while (m & 0x400) == 0 { m <<= 1; e &+= 1 }
                bits |= ((127 - 15 - e) & 0xFF) << 23
                bits |= (m & 0x3FF) << 13
            }
        } else if exp == 31 {
            bits |= 0xFF << 23
            bits |= mant << 13
        } else {
            bits |= (exp + 127 - 15) << 23
            bits |= mant << 13
        }
        return Float(bitPattern: bits)
    }
}
