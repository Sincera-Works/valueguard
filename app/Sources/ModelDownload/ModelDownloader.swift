import Foundation
import CryptoKit

enum ModelDownloadError: LocalizedError {
    case badResponse(Int)
    case shaMismatch(expected: String, got: String)
    case extractionFailed(String)
    case configurationPlaceholder

    var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "Server returned HTTP \(code)."
        case .shaMismatch(let expected, let got):
            return "SHA-256 mismatch — refusing to install. Expected \(expected), got \(got)."
        case .extractionFailed(let m):
            return "Tar extraction failed: \(m)"
        case .configurationPlaceholder:
            return "Model URL/SHA256 is still a placeholder. Edit ModelManifest.swift with the real release."
        }
    }
}

@MainActor
final class ModelDownloader: NSObject {
    struct Progress {
        let bytesReceived: Int64
        let bytesExpected: Int64 // -1 if unknown
        var fraction: Double {
            guard bytesExpected > 0 else { return 0 }
            return min(1.0, Double(bytesReceived) / Double(bytesExpected))
        }
    }

    private var progressContinuation: AsyncStream<Progress>.Continuation?

    /// Streams progress while downloading the text encoder. On success, the
    /// `.mlpackage` directory exists at `AppSupport.textEncoderURL`.
    func downloadTextEncoder(onProgress: @escaping (Progress) -> Void) async throws {
        // Refuse to run with a placeholder manifest — guards against accidental shipping.
        guard ModelManifest.textEncoderSHA256.count == 64,
              ModelManifest.textEncoderSHA256.allSatisfy({ "0123456789abcdef".contains($0) })
        else {
            throw ModelDownloadError.configurationPlaceholder
        }

        let url = ModelManifest.textEncoderURL
        var request = URLRequest(url: url)
        request.timeoutInterval = 60

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ModelDownloadError.badResponse(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ModelDownloadError.badResponse(http.statusCode)
        }

        let expected = http.expectedContentLength
        let tempTar = FileManager.default.temporaryDirectory
            .appendingPathComponent("vg-text-encoder-\(UUID().uuidString).tar.gz")
        FileManager.default.createFile(atPath: tempTar.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempTar)
        defer { try? handle.close() }

        var hasher = SHA256()
        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                hasher.update(data: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                onProgress(.init(bytesReceived: received, bytesExpected: expected))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            received += Int64(buffer.count)
            onProgress(.init(bytesReceived: received, bytesExpected: expected))
        }
        try handle.close()

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == ModelManifest.textEncoderSHA256 else {
            try? FileManager.default.removeItem(at: tempTar)
            throw ModelDownloadError.shaMismatch(expected: ModelManifest.textEncoderSHA256, got: hex)
        }

        try extract(tarGz: tempTar, into: AppSupport.modelsURL)
        try? FileManager.default.removeItem(at: tempTar)
    }

    /// Extract a .tar.gz via /usr/bin/tar. Foundation has no tar implementation,
    /// so we shell out — safe here because the archive's SHA256 was verified above.
    private func extract(tarGz: URL, into directory: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xzf", tarGz.path, "-C", directory.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            throw ModelDownloadError.extractionFailed(error.localizedDescription)
        }
        guard proc.terminationStatus == 0 else {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ModelDownloadError.extractionFailed("tar exit \(proc.terminationStatus): \(stderr)")
        }
    }
}
