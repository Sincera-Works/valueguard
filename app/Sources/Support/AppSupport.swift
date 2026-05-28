import Foundation

enum AppSupport {
    static var rootURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ValueGuard", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support
    }

    static var modelsURL: URL {
        let dir = rootURL.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var valuesURL: URL { rootURL.appendingPathComponent("values.md") }
    static var policyJSONURL: URL { rootURL.appendingPathComponent("policy.json") }
    static var policyBinURL: URL { rootURL.appendingPathComponent("policy.bin") }
    static var auditLogURL: URL { rootURL.appendingPathComponent("audit.log") }
    static var scoresLogURL: URL { rootURL.appendingPathComponent("scores.log") }
    static var textEncoderURL: URL { modelsURL.appendingPathComponent("SigLIP2Text.mlpackage") }
}
