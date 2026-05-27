import Foundation

public actor AuditLog {
    private let auditURL: URL
    private let scoresURL: URL?
    private let formatter: ISO8601DateFormatter
    private let includeWindowInfo: Bool

    /// - Parameter scoresLogPath: if set, every per-frame per-category score is
    ///   appended to this file as NDJSON. Used for calibration; off by default
    ///   because the per-frame log can be large (~hundreds of records/sec).
    public init(includeWindowInfo: Bool = false, scoresLogPath: String? = nil) throws {
        let supportDir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ValueGuard", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.auditURL = supportDir.appendingPathComponent("audit.log")
        if let p = scoresLogPath {
            self.scoresURL = URL(fileURLWithPath: p)
            try FileManager.default.createDirectory(
                at: self.scoresURL!.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: self.scoresURL!.path) {
                FileManager.default.createFile(atPath: self.scoresURL!.path, contents: nil)
            }
        } else {
            self.scoresURL = nil
        }
        self.includeWindowInfo = includeWindowInfo

        self.formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if !FileManager.default.fileExists(atPath: auditURL.path) {
            FileManager.default.createFile(atPath: auditURL.path, contents: nil)
        }

        FileHandle.standardError.write(Data("audit: writing to \(auditURL.path)\n".utf8))
        if let s = scoresURL {
            FileHandle.standardError.write(Data("audit: scores log → \(s.path)\n".utf8))
        }
    }

    /// Append a per-frame score record to the scores log (no-op if not enabled).
    /// Written for every category on every classified frame so the calibration
    /// tool sees the full distribution.
    public func recordSample(
        score: CategoryScore,
        window: MonitoredWindow,
        cached: Bool
    ) throws {
        guard let url = scoresURL else { return }
        var fields: [String] = [
            "\"ts\":\"\(formatter.string(from: Date()))\"",
            "\"type\":\"sample\"",
            "\"category\":\"\(score.category.id)\"",
            "\"pos\":\(score.positiveScore)",
            "\"neg\":\(score.negativeScore)",
            "\"threshold\":\(score.category.threshold)",
            "\"firing\":\(score.firing)",
            "\"cached\":\(cached)",
            "\"window_id\":\(window.windowID)",
        ]
        if includeWindowInfo {
            fields.append("\"app\":\"\(jsonEscape(window.appName))\"")
        }
        try writeLine(fields, to: url)
    }

    /// Record a flag — a category that crossed its threshold on this frame.
    public func record(_ score: CategoryScore, window: MonitoredWindow? = nil) throws {
        var fields: [String] = [
            "\"ts\":\"\(formatter.string(from: Date()))\"",
            "\"type\":\"flag\"",
            "\"category\":\"\(score.category.id)\"",
            "\"pos\":\(score.positiveScore)",
            "\"neg\":\(score.negativeScore)",
            "\"threshold\":\(score.category.threshold)",
            "\"action\":\"\(actionName(score.category.action))\"",
        ]
        if let window = window {
            fields.append("\"window_id\":\(window.windowID)")
            if includeWindowInfo {
                fields.append("\"app\":\"\(jsonEscape(window.appName))\"")
            }
        }
        try writeLine(fields, to: auditURL)
    }

    /// Record a hysteresis transition for a window.
    public func recordTransition(
        kind: TransitionKind,
        window: MonitoredWindow,
        categoryID: String? = nil
    ) throws {
        var fields: [String] = [
            "\"ts\":\"\(formatter.string(from: Date()))\"",
            "\"type\":\"\(kind.rawValue)\"",
            "\"window_id\":\(window.windowID)",
        ]
        if includeWindowInfo {
            fields.append("\"app\":\"\(jsonEscape(window.appName))\"")
        }
        if let categoryID = categoryID {
            fields.append("\"category\":\"\(categoryID)\"")
        }
        try writeLine(fields, to: auditURL)
    }

    public func recordDisappeared(windowID: UInt32, appName: String) throws {
        var fields: [String] = [
            "\"ts\":\"\(formatter.string(from: Date()))\"",
            "\"type\":\"disappeared\"",
            "\"window_id\":\(windowID)",
        ]
        if includeWindowInfo {
            fields.append("\"app\":\"\(jsonEscape(appName))\"")
        }
        try writeLine(fields, to: auditURL)
    }

    public enum TransitionKind: String {
        case activated
        case cleared
    }

    private func writeLine(_ fields: [String], to url: URL) throws {
        let line = "{\(fields.joined(separator: ","))}\n"
        if let data = line.data(using: .utf8) {
            let handle = try FileHandle(forWritingTo: url)
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

    private func jsonEscape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }
}
