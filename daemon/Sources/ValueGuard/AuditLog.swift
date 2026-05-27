import Foundation

public actor AuditLog {
    private let logURL: URL
    private let formatter: ISO8601DateFormatter

    public init() throws {
        let supportDir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ValueGuard", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.logURL = supportDir.appendingPathComponent("audit.log")

        self.formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        FileHandle.standardError.write(Data("audit: writing to \(logURL.path)\n".utf8))
    }

    public func record(_ flag: PolicyFlag) throws {
        let line = """
        {"ts":"\(formatter.string(from: flag.timestamp))","category":"\(flag.category.id)","pos":\(flag.positiveScore),"neg":\(flag.negativeScore),"threshold":\(flag.category.threshold),"action":"\(actionName(flag.category.action))"}\n
        """
        if let data = line.data(using: .utf8) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }

    private func actionName(_ a: PolicyAction) -> String {
        switch a {
        case .log: return "log"
        case .blur: return "blur"
        case .block: return "block"
        }
    }
}
