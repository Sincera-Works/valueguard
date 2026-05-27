import Foundation
import CoreGraphics

public actor ValueGuardDaemon {
    private let policy: Policy
    private let sampleRateHz: Double
    private let logOnly: Bool
    private let auditLog: AuditLog
    private let classifier: Classifier
    private let capture: ScreenCapture

    public init(policyPath: String, sampleRateHz: Double, logOnly: Bool) async throws {
        let policy = try Policy(loadingFrom: URL(fileURLWithPath: policyPath))
        self.policy = policy
        self.sampleRateHz = sampleRateHz
        self.logOnly = logOnly
        self.auditLog = try AuditLog()
        self.classifier = try await Classifier(embeddingDim: policy.embedDim)
        self.capture = ScreenCapture()
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

        try await capture.requestPermission()
        let interval = 1.0 / sampleRateHz
        let nanosBetween = UInt64(interval * 1_000_000_000)

        while !Task.isCancelled {
            let started = ContinuousClock.now
            do {
                if let pixelBuffer = try await capture.captureFrame() {
                    let embedding = try classifier.embed(pixelBuffer)
                    let flags = policy.evaluate(embedding: embedding)
                    for flag in flags {
                        try await auditLog.record(flag)
                        if !logOnly, flag.category.action != .log {
                            try await dispatchAction(flag)
                        }
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("frame error: \(error)\n".utf8))
            }
            let elapsed = ContinuousClock.now - started
            let elapsedNanos = UInt64(elapsed.components.attoseconds / 1_000_000_000)
                + UInt64(elapsed.components.seconds) * 1_000_000_000
            if elapsedNanos < nanosBetween {
                try? await Task.sleep(nanoseconds: nanosBetween - elapsedNanos)
            }
        }
    }

    private func dispatchAction(_ flag: PolicyFlag) async throws {
        switch flag.category.action {
        case .log:
            return
        case .blur:
            await BlurOverlay.shared.show(reason: flag.category.id)
        case .block:
            FileHandle.standardError.write(Data(
                "valueguard: block action not yet implemented (category=\(flag.category.id))\n".utf8
            ))
        }
    }
}
