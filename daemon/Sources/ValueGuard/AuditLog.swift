import Foundation

public actor AuditLog {
    private let logURL: URL
    private let formatter: ISO8601DateFormatter
    private let includeWindowInfo: Bool

    public init(includeWindowInfo: Bool = false) throws {
        let supportDir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ValueGuard", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        self.logURL = supportDir.appendingPathComponent("audit.log")
        self.includeWindowInfo = includeWindowInfo

        self.formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        FileHandle.standardError.write(Data("audit: writing to \(logURL.path)\n".utf8))
    }

    /// Record a per-frame classification hit.
    public func record(_ flag: PolicyFlag, window: MonitoredWindow? = nil) throws {
        var fields: [String] = [
            "\"ts\":\"\(formatter.string(from: flag.timestamp))\"",
            "\"type\":\"flag\"",
            "\"category\":\"\(flag.category.id)\"",
            "\"pos\":\(flag.positiveScore)",
            "\"neg\":\(flag.negativeScore)",
            "\"threshold\":\(flag.category.threshold)",
            "\"action\":\"\(actionName(flag.category.action))\"",
        ]
        if let window = window {
            fields.append("\"window_id\":\(window.windowID)")
            if includeWindowInfo {
                fields.append("\"app\":\"\(jsonEscape(window.appName))\"")
            }
        }
        try write(fields)
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
        try write(fields)
    }

    /// Record a window disappearing while its hysteresis was active.
    public func recordDisappeared(windowID: UInt32, appName: String) throws {
        var fields: [String] = [
            "\"ts\":\"\(formatter.string(from: Date()))\"",
            "\"type\":\"disappeared\"",
            "\"window_id\":\(windowID)",
        ]
        if includeWindowInfo {
            fields.append("\"app\":\"\(jsonEscape(appName))\"")
        }
        try write(fields)
    }

    public enum TransitionKind: String {
        case activated
        case cleared
    }

    private func write(_ fields: [String]) throws {
        let line = "{\(fields.joined(separator: ","))}\n"
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
