import Foundation
import CryptoKit

enum ModelDownloadError: LocalizedError {
    case network(String)
    case badResponse(Int)
    case shaMismatch(expected: String, got: String)
    case extractionFailed(String)
    case configurationPlaceholder

    var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "Couldn’t download the model — \(detail). Check your internet connection and try again."
        case .badResponse(let code):
            return "The download server returned an unexpected response (HTTP \(code)). Please try again in a moment."
        case .shaMismatch:
            return "The downloaded model didn’t pass its integrity check, so it wasn’t installed. This usually means the download was interrupted. Please try again."
        case .extractionFailed:
            return "The model downloaded but couldn’t be unpacked. Please try again."
        case .configurationPlaceholder:
            // Should be unreachable in shipping builds — the manifest carries a real URL/SHA.
            return "ValueGuard isn’t configured to download the model. Please reinstall the app."
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

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch let urlError as URLError {
            throw ModelDownloadError.network(networkDetail(for: urlError))
        }
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

        do {
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
        } catch let urlError as URLError {
            // Connection dropped mid-download — clean up the partial file and surface a retryable message.
            try? handle.close()
            try? FileManager.default.removeItem(at: tempTar)
            throw ModelDownloadError.network(networkDetail(for: urlError))
        }

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == ModelManifest.textEncoderSHA256 else {
            try? FileManager.default.removeItem(at: tempTar)
            throw ModelDownloadError.shaMismatch(expected: ModelManifest.textEncoderSHA256, got: hex)
        }

        try extract(tarGz: tempTar, into: AppSupport.modelsURL)
        try? FileManager.default.removeItem(at: tempTar)
    }

    /// Map a URLError to a short, plain-language clause for the user-facing message.
    private func networkDetail(for error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet:
            return "this Mac isn’t connected to the internet"
        case .timedOut:
            return "the connection timed out"
        case .networkConnectionLost:
            return "the network connection was lost"
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "the download server couldn’t be reached"
        default:
            return "the connection failed"
        }
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
