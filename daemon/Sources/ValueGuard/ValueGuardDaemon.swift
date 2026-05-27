import Foundation
import CoreGraphics
import os

private let log = Logger(subsystem: "works.sincera.valueguard", category: "daemon")

public actor ValueGuardDaemon {
    private let policy: Policy
    private let sampleRateHz: Double
    private let logOnly: Bool
    private let filter: CaptureFilter
    private let auditLog: AuditLog
    private let classifier: Classifier
    private let capture: ScreenCapture

    // Gating + debouncing config
    private let hashGateEnabled: Bool
    private let hashDistanceThreshold: Int
    private let hysteresisRequired: Int
    private let hysteresisSeconds: Double

    /// All per-window mutable state. Lives on the actor; no external
    /// access required so we don't bother making it Sendable.
    private struct WindowState {
        var lastHash: UInt64?
        var lastFlags: [PolicyFlag] = []
        var hysteresis: HysteresisState
    }
    private var windowStates: [UInt32: WindowState] = [:]
    private var overlayProcesses: [UInt32: Process] = [:]

    public init(
        policyPath: String,
        sampleRateHz: Double,
        logOnly: Bool,
        filter: CaptureFilter,
        includeWindowInfo: Bool,
        hashGateEnabled: Bool = true,
        hashDistanceThreshold: Int = 4,
        hysteresisRequired: Int = 3,
        hysteresisSeconds: Double = 10
    ) async throws {
        let policy = try Policy(loadingFrom: URL(fileURLWithPath: policyPath))
        self.policy = policy
        self.sampleRateHz = sampleRateHz
        self.logOnly = logOnly
        self.filter = filter
        self.auditLog = try AuditLog(includeWindowInfo: includeWindowInfo)
        self.classifier = try await Classifier(embeddingDim: policy.embedDim)
        self.capture = ScreenCapture()
        self.hashGateEnabled = hashGateEnabled
        self.hashDistanceThreshold = hashDistanceThreshold
        self.hysteresisRequired = hysteresisRequired
        self.hysteresisSeconds = hysteresisSeconds
    }

    public func run() async throws {
        FileHandle.standardError.write(Data(
            "valueguard: loaded \(policy.categories.count) categor\(policy.categories.count == 1 ? "y" : "ies")\n".utf8
        ))
        for cat in policy.categories {
            FileHandle.standardError.write(Data(
                "  - \(cat.id) (threshold=\(cat.threshold), action=\(cat.action))\n".utf8
            ))
        }
        if logOnly {
            FileHandle.standardError.write(Data("valueguard: log-only mode; no blur/block actions\n".utf8))
        }
        FileHandle.standardError.write(Data(
            "valueguard: monitorApps=\(filter.monitorApps.isEmpty ? "<all-except-greenlist>" : filter.monitorApps.joined(separator: ","))\n".utf8
        ))
        FileHandle.standardError.write(Data(
            "valueguard: hash-gate=\(hashGateEnabled ? "on" : "off") (distance<\(hashDistanceThreshold)); hysteresis=\(hysteresisRequired)-of-\(hysteresisSeconds)s\n".utf8
        ))

        try await capture.requestPermission()
        let interval = 1.0 / sampleRateHz
        let nanosBetween = UInt64(interval * 1_000_000_000)

        while !Task.isCancelled {
            let started = ContinuousClock.now
            do {
                try await tick()
            } catch {
                FileHandle.standardError.write(Data("tick error: \(error)\n".utf8))
            }
            let elapsed = ContinuousClock.now - started
            let elapsedNanos = UInt64(elapsed.components.attoseconds / 1_000_000_000)
                + UInt64(elapsed.components.seconds) * 1_000_000_000
            if elapsedNanos < nanosBetween {
                try? await Task.sleep(nanoseconds: nanosBetween - elapsedNanos)
            }
        }
    }

    private func tick() async throws {
        let frames = try await capture.captureMonitoredWindows(filter: filter)
        let currentWIDs = Set(frames.map { $0.window.windowID })

        for frame in frames {
            let wid = frame.window.windowID
            var state = windowStates[wid] ?? WindowState(
                hysteresis: HysteresisState(required: hysteresisRequired, windowSeconds: hysteresisSeconds)
            )

            // Step 1: hash gate. Skip classification if content hasn't materially changed.
            let hash = differenceHash(frame.pixelBuffer)
            let isStatic: Bool
            if hashGateEnabled, let last = state.lastHash {
                isStatic = hammingDistance(last, hash) < hashDistanceThreshold
            } else {
                isStatic = false
            }
            state.lastHash = hash

            // Step 2: classify (or reuse cached classification if static).
            if !isStatic {
                let embedding = try classifier.embed(frame.pixelBuffer)
                state.lastFlags = policy.evaluate(embedding: embedding)
                for flag in state.lastFlags {
                    try await auditLog.record(flag, window: frame.window)
                }
            }

            // Step 3: feed the (cached-or-fresh) result into hysteresis.
            if let topFlag = state.lastFlags.first {
                let transition = state.hysteresis.recordPositive()
                if case .activated = transition {
                    log.notice("hysteresis ACTIVATED window=\(wid) app=\(frame.window.appName, privacy: .public) category=\(topFlag.category.id, privacy: .public)")
                    try? await auditLog.recordTransition(
                        kind: .activated, window: frame.window, categoryID: topFlag.category.id
                    )
                    if !logOnly, topFlag.category.action != .log {
                        await dispatchAction(topFlag, window: frame.window)
                    }
                }
            } else {
                let transition = state.hysteresis.recordNegative()
                if case .cleared = transition {
                    log.notice("hysteresis CLEARED window=\(wid) app=\(frame.window.appName, privacy: .public)")
                    try? await auditLog.recordTransition(kind: .cleared, window: frame.window)
                    if !logOnly {
                        await dismissAction(window: frame.window)
                    }
                }
            }

            windowStates[wid] = state
        }

        // Clean up state for windows that are no longer visible.
        let goneWIDs = windowStates.keys.filter { !currentWIDs.contains($0) }
        for wid in goneWIDs {
            if windowStates[wid]?.hysteresis.active == true {
                log.notice("hysteresis DISAPPEARED window=\(wid)")
                try? await auditLog.recordDisappeared(windowID: wid, appName: "")
            }
            await terminateOverlay(for: wid)
            windowStates.removeValue(forKey: wid)
        }
    }

    private func dispatchAction(_ flag: PolicyFlag, window: MonitoredWindow) async {
        switch flag.category.action {
        case .log:
            return
        case .blur:
            await showOverlay(for: window, category: flag.category.id)
        case .block:
            log.notice("block would terminate app=\(window.appName, privacy: .public) window=\(window.windowID) category=\(flag.category.id, privacy: .public)")
        }
    }

    private func dismissAction(window: MonitoredWindow) async {
        await terminateOverlay(for: window.windowID)
    }

    /// Launch the blur_overlay binary as a child process positioned over this window.
    private func showOverlay(for window: MonitoredWindow, category: String) async {
        // If we already have an overlay running for this window, leave it.
        if let existing = overlayProcesses[window.windowID], existing.isRunning {
            return
        }
        guard let overlayURL = Self.locateOverlayBinary() else {
            log.error("blur: blur_overlay binary not found near \(CommandLine.arguments[0], privacy: .public)")
            return
        }
        let proc = Process()
        proc.executableURL = overlayURL
        proc.arguments = [
            "show",
            "--x", "\(Int(window.frame.origin.x))",
            "--y", "\(Int(window.frame.origin.y))",
            "--width", "\(Int(window.frame.width))",
            "--height", "\(Int(window.frame.height))",
            "--label", "\(window.appName) — \(category)",
        ]
        do {
            try proc.run()
            overlayProcesses[window.windowID] = proc
            log.notice("blur SHOW window=\(window.windowID) app=\(window.appName, privacy: .public) pid=\(proc.processIdentifier)")
        } catch {
            log.error("blur: failed to launch overlay: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Send SIGTERM to the overlay process associated with this window, if any.
    private func terminateOverlay(for windowID: UInt32) async {
        if let proc = overlayProcesses.removeValue(forKey: windowID) {
            if proc.isRunning {
                proc.terminate()
            }
            log.notice("blur DISMISS window=\(windowID) pid=\(proc.processIdentifier)")
        }
    }

    /// Find the blur_overlay binary next to the daemon binary. We're shipped
    /// inside `.app/Contents/MacOS/` next to it, so a sibling lookup works.
    /// Falls back to the SPM build dir for unbundled `swift run` use.
    private static func locateOverlayBinary() -> URL? {
        let exec = CommandLine.arguments[0]
        let dir = URL(fileURLWithPath: exec).deletingLastPathComponent()
        let candidates = [
            dir.appendingPathComponent("blur_overlay"),
            URL(fileURLWithPath: "\(dir.path)/blur_overlay"),
            URL(fileURLWithPath: ".build/arm64-apple-macosx/debug/blur_overlay"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
