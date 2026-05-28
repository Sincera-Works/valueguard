import Foundation
import ValueGuardCore

@MainActor
final class DaemonHost {
    enum Status {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var status: Status = .stopped {
        didSet { onStatusChange?(status) }
    }
    var onStatusChange: ((Status) -> Void)?

    private var runTask: Task<Void, Never>?
    private var daemon: ValueGuardDaemon?

    static var policyURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ValueGuard", isDirectory: true)
        return support.appendingPathComponent("policy.bin")
    }

    var hasPolicy: Bool {
        FileManager.default.fileExists(atPath: Self.policyURL.path)
    }

    private var lastLogOnly: Bool = true
    private var lastSampleRateHz: Double = 1.0
    private var lastWriteScoresLog: Bool = true

    func start(
        logOnly: Bool = true,
        sampleRateHz: Double = 1.0,
        writeScoresLog: Bool = true
    ) {
        guard runTask == nil else { return }
        guard hasPolicy else {
            status = .failed("No policy installed at \(Self.policyURL.path)")
            return
        }
        lastLogOnly = logOnly
        lastSampleRateHz = sampleRateHz
        lastWriteScoresLog = writeScoresLog
        status = .starting
        let policyPath = Self.policyURL.path
        let scoresPath = writeScoresLog ? AppSupport.scoresLogURL.path : nil
        runTask = Task { [weak self] in
            do {
                let daemon = try await ValueGuardDaemon(
                    policyPath: policyPath,
                    sampleRateHz: sampleRateHz,
                    logOnly: logOnly,
                    filter: .allExceptGreenlist,
                    includeWindowInfo: true,
                    scoresLogPath: scoresPath
                )
                await MainActor.run {
                    self?.daemon = daemon
                    self?.status = .running
                }
                try await daemon.run()
            } catch {
                await MainActor.run {
                    self?.status = .failed(error.localizedDescription)
                    self?.runTask = nil
                    self?.daemon = nil
                }
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        daemon = nil
        status = .stopped
    }

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// Stop + restart using the most recent settings (or arguments if provided).
    func restart(logOnly: Bool? = nil, sampleRateHz: Double? = nil, writeScoresLog: Bool? = nil) {
        let lo = logOnly ?? lastLogOnly
        let sr = sampleRateHz ?? lastSampleRateHz
        let ws = writeScoresLog ?? lastWriteScoresLog
        stop()
        start(logOnly: lo, sampleRateHz: sr, writeScoresLog: ws)
    }
}
