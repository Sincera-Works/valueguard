import Foundation

/// Tail audit.log and emit decoded flag/transition events on the main actor.
/// Uses DispatchSourceFileSystemObject for kqueue-backed file watch — no
/// polling, fires the moment the daemon's AuditLog actor writes a line.
@MainActor
final class AuditLogTailer {
    struct FlagEvent {
        let timestamp: String
        let category: String
        let positive: Float
        let negative: Float
        let threshold: Float
        let action: String  // policy.bin's baseline action; we usually override
        let windowID: UInt32?
        let app: String?
    }

    struct TransitionEvent {
        enum Kind: String { case activated, cleared, disappeared }
        let timestamp: String
        let kind: Kind
        let category: String?
        let windowID: UInt32?
        let app: String?
    }

    var onFlag: ((FlagEvent) -> Void)?
    var onTransition: ((TransitionEvent) -> Void)?

    private let url: URL
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var carriedOver = ""

    init(url: URL = AppSupport.auditLogURL) {
        self.url = url
    }

    func start() {
        stop()
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        // Seek to end so we only see new entries, not historical ones.
        try? handle.seekToEnd()
        self.handle = handle

        let fd = handle.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.extend, .write], queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.drain() }
        }
        source.setCancelHandler { [weak self] in
            try? self?.handle?.close()
            self?.handle = nil
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func drain() {
        guard let handle else { return }
        let data = (try? handle.readToEnd()) ?? Data()
        guard !data.isEmpty, var text = String(data: data, encoding: .utf8) else { return }
        text = carriedOver + text
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Last element may be a partial line — defer it.
        carriedOver = lines.last ?? ""
        for line in lines.dropLast() {
            if line.isEmpty { continue }
            process(line: line)
        }
    }

    private func process(line: String) {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = obj["type"] as? String ?? ""
        let ts = obj["ts"] as? String ?? ""
        switch type {
        case "flag":
            let event = FlagEvent(
                timestamp: ts,
                category: obj["category"] as? String ?? "?",
                positive: (obj["pos"] as? NSNumber)?.floatValue ?? 0,
                negative: (obj["neg"] as? NSNumber)?.floatValue ?? 0,
                threshold: (obj["threshold"] as? NSNumber)?.floatValue ?? 0,
                action: obj["action"] as? String ?? "log",
                windowID: (obj["window_id"] as? NSNumber)?.uint32Value,
                app: obj["app"] as? String
            )
            onFlag?(event)
        case "activated", "cleared", "disappeared":
            let kind = TransitionEvent.Kind(rawValue: type) ?? .activated
            let event = TransitionEvent(
                timestamp: ts,
                kind: kind,
                category: obj["category"] as? String,
                windowID: (obj["window_id"] as? NSNumber)?.uint32Value,
                app: obj["app"] as? String
            )
            onTransition?(event)
        default:
            break
        }
    }
}
