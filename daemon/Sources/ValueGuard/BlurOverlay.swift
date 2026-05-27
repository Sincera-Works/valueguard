import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Full-screen frosted-glass overlay shown when a `blur` action fires.
///
/// Not wired in yet — `ValueGuardDaemon` calls `BlurOverlay.shared.show(...)`
/// when a blur category trips. The current implementation is a no-op stub;
/// the real overlay needs an AppKit-hosted NSWindow at .screenSaver level,
/// which requires the CLI to host an NSApplication run loop.
///
/// Phase: do not enable until log-only calibration has produced acceptable
/// false-positive numbers. A blur that fires on a false positive during
/// a presentation is the kind of incident that ends the product.
public final class BlurOverlay: @unchecked Sendable {
    public static let shared = BlurOverlay()

    private init() {}

    public func show(reason: String) async {
        FileHandle.standardError.write(Data(
            "blur: would show overlay (category=\(reason)) — stub, not enabled in v0.1\n".utf8
        ))
    }

    public func dismiss() async {
        // TODO: dismiss overlay
    }
}
