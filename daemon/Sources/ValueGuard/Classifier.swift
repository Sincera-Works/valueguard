import Foundation
import CoreML
import CoreVideo

enum ClassifierError: Error {
    case modelNotFound
    case unexpectedOutput
    case dimensionMismatch
}

public final class Classifier: @unchecked Sendable {
    private let model: MLModel?
    private let embeddingDim: Int

    public init(embeddingDim: Int) async throws {
        self.embeddingDim = embeddingDim

        // Look for the bundled CoreML package. In SPM-built binaries we won't
        // have a process bundle — fall back to a sibling Resources/ directory.
        let candidates: [URL] = [
            Bundle.main.url(forResource: "SigLIP2Vision", withExtension: "mlpackage"),
            Bundle(for: ClassifierBundleAnchor.self).url(forResource: "SigLIP2Vision", withExtension: "mlpackage"),
            URL(fileURLWithPath: "Resources/SigLIP2Vision.mlpackage", isDirectory: true),
            URL(fileURLWithPath: "../model-conversion/output/SigLIP2Vision.mlpackage", isDirectory: true),
        ].compactMap { $0 }

        if let modelURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            // CoreML refuses to load .mlpackage directly — must be compiled to .mlmodelc first.
            // Cache the compiled model to ~/Library/Caches/ValueGuard/ so repeat startups are
            // instant. Bust the cache if the source .mlpackage is newer than the cached compile.
            let cacheDir = try FileManager.default.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("ValueGuard", isDirectory: true)
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let cachedURL = cacheDir.appendingPathComponent("SigLIP2Vision.mlmodelc", isDirectory: true)

            let needsCompile: Bool
            if let cachedMtime = try? FileManager.default.attributesOfItem(atPath: cachedURL.path)[.modificationDate] as? Date,
               let sourceMtime = try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.modificationDate] as? Date {
                needsCompile = sourceMtime > cachedMtime
            } else {
                needsCompile = true
            }

            let compiledURL: URL
            if needsCompile {
                FileHandle.standardError.write(Data("classifier: compiling \(modelURL.lastPathComponent) (one-time, ~5s)\n".utf8))
                let tempURL = try await MLModel.compileModel(at: modelURL)
                if FileManager.default.fileExists(atPath: cachedURL.path) {
                    try FileManager.default.removeItem(at: cachedURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: cachedURL)
                compiledURL = cachedURL
            } else {
                compiledURL = cachedURL
            }

            let config = MLModelConfiguration()
            config.computeUnits = .all
            self.model = try MLModel(contentsOf: compiledURL, configuration: config)
            FileHandle.standardError.write(Data("classifier: loaded \(modelURL.lastPathComponent)\n".utf8))
        } else {
            self.model = nil
            FileHandle.standardError.write(Data(
                "classifier: SigLIP2Vision.mlpackage not found; running in mock mode (random embeddings)\n".utf8
            ))
        }
    }

    public func embed(_ pixelBuffer: CVPixelBuffer) throws -> [Float] {
        guard let model = model else {
            return mockEmbedding()
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: pixelBuffer)
        ])
        let output = try model.prediction(from: input)
        guard let arr = output.featureValue(for: "embedding")?.multiArrayValue else {
            throw ClassifierError.unexpectedOutput
        }
        guard arr.count == embeddingDim else {
            throw ClassifierError.dimensionMismatch
        }

        var vec = [Float](repeating: 0, count: embeddingDim)
        for i in 0..<embeddingDim {
            vec[i] = arr[i].floatValue
        }
        return vec
    }

    private func mockEmbedding() -> [Float] {
        var vec = [Float](repeating: 0, count: embeddingDim)
        for i in 0..<embeddingDim {
            vec[i] = Float.random(in: -1...1)
        }
        let norm = sqrt(vec.reduce(0) { $0 + $1 * $1 })
        if norm > 0 {
            for i in 0..<embeddingDim {
                vec[i] /= norm
            }
        }
        return vec
    }
}

private final class ClassifierBundleAnchor {}
