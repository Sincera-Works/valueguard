import Foundation
import CoreGraphics
import CoreVideo
@preconcurrency import ScreenCaptureKit

/// Metadata about a captured window. Holds no SCK references — those are scoped
/// to the capture call itself, because SCWindow references go stale as soon as
/// the parent SCShareableContent is deallocated.
public struct MonitoredWindow: Sendable {
    /// Stable per-session window ID. Survives until the window is closed.
    public let windowID: UInt32
    /// Application name (`SCRunningApplication.applicationName`). May be empty in rare cases.
    public let appName: String
    /// Bundle identifier (`com.apple.Safari` etc). Useful for matching across language locales.
    public let bundleID: String?
    /// Window bounds in screen coordinates. Used by the overlay layer to position the blur.
    public let frame: CGRect
}

/// A captured window: metadata + the pixel buffer at model input size.
/// `@unchecked Sendable` because CVPixelBuffer isn't formally Sendable, but we
/// treat it as immutable after capture.
public struct CapturedFrame: @unchecked Sendable {
    public let window: MonitoredWindow
    public let pixelBuffer: CVPixelBuffer
}

/// Filtering policy applied to the window list before classification.
public struct CaptureFilter: Sendable {
    /// Apps that get classified. If `monitorApps` is empty, every window NOT in `greenlistApps`
    /// is monitored. If non-empty, only windows whose app name matches an entry are monitored.
    /// Matching is case-insensitive substring on `appName`.
    public var monitorApps: [String]
    /// Apps that are never classified, regardless of the monitor list. Match takes precedence.
    public var greenlistApps: [String]

    public init(monitorApps: [String] = [], greenlistApps: [String] = []) {
        self.monitorApps = monitorApps
        self.greenlistApps = greenlistApps
    }

    /// Default monitor list — browsers only, matching the Python reference spec.
    public static let browsersOnly = CaptureFilter(
        monitorApps: [
            "Safari", "Google Chrome", "Firefox", "Chromium",
            "Microsoft Edge", "Brave Browser", "Opera", "Arc"
        ],
        greenlistApps: defaultGreenlist
    )

    /// "All windows except the greenlist" — useful for smoke testing on a terminal.
    public static let allExceptGreenlist = CaptureFilter(
        monitorApps: [],
        greenlistApps: defaultGreenlist
    )

    /// System chrome, terminals, IDEs — never classified.
    public static let defaultGreenlist = [
        "Dock", "Window Server", "Control Center", "NotificationCenter",
        "Spotlight", "SystemUIServer", "loginwindow", "Finder",
        "Terminal", "iTerm2", "Ghostty", "kitty", "Alacritty", "WezTerm",
        "Xcode", "Visual Studio Code", "Cursor", "Sublime Text",
        "Obsidian", "Notes",
    ]

    func shouldMonitor(appName: String) -> Bool {
        let lower = appName.lowercased()
        for green in greenlistApps where !green.isEmpty {
            if lower.contains(green.lowercased()) { return false }
        }
        if monitorApps.isEmpty { return true }
        for monitor in monitorApps where !monitor.isEmpty {
            if lower.contains(monitor.lowercased()) { return true }
        }
        return false
    }
}

public actor ScreenCapture {
    private let captureWidth: Int
    private let captureHeight: Int

    public init(captureSize: Int = 256) {
        self.captureWidth = captureSize
        self.captureHeight = captureSize
    }

    public func requestPermission() async throws {
        // Preflight with the NON-prompting CG check first. `SCShareableContent.current`
        // actively pokes the TCC system and can surface the Screen Recording prompt
        // even when access is already granted — so calling it on every daemon
        // (re)start (e.g. after the Settings "Apply" restart) re-prompts the user
        // each time. When preflight says we already have access, return immediately
        // and never touch SCShareableContent here; the actual capture path
        // exercises it during normal ticks.
        if CGPreflightScreenCaptureAccess() {
            return
        }
        // Not granted: probe via SCShareableContent so a genuine denial throws with
        // a clear message (CGRequestScreenCaptureAccess only matters on first-ever
        // launch; the app's onboarding owns that flow).
        do {
            _ = try await SCShareableContent.current
        } catch {
            FileHandle.standardError.write(Data(
                "valueguard: Screen Recording permission required. Grant in System Settings → Privacy & Security → Screen Recording, then re-run.\n".utf8
            ))
            throw error
        }
    }

    /// Enumerate and capture every on-screen window that passes the filter.
    ///
    /// Uses `SCShareableContent` for enumeration (modern, gives us app names +
    /// bundle IDs) and the deprecated `CGWindowListCreateImage` for the
    /// per-window pixel grab. SCK's `SCContentFilter(desktopIndependentWindow:)`
    /// raises an uncatchable ObjC exception on macOS 26 for ordinary
    /// (non-floating) windows, so it's not usable for our purpose.
    /// `CGWindowListCreateImage` is what the reference Python spec uses too.
    public func captureMonitoredWindows(filter: CaptureFilter) async throws -> [CapturedFrame] {
        let content = try await SCShareableContent.current
        var frames: [CapturedFrame] = []
        for window in content.windows {
            guard window.frame.width > 1, window.frame.height > 1 else { continue }
            guard window.windowLayer == 0 else { continue }
            guard window.isOnScreen else { continue }

            let appName = window.owningApplication?.applicationName ?? ""
            let bundleID = window.owningApplication?.bundleIdentifier
            guard filter.shouldMonitor(appName: appName) else { continue }

            let meta = MonitoredWindow(
                windowID: window.windowID,
                appName: appName,
                bundleID: bundleID,
                frame: window.frame
            )

            guard let cgImage = Self.captureWindowImage(windowID: window.windowID) else {
                FileHandle.standardError.write(Data(
                    "capture skip: window=\(meta.windowID) app=\(meta.appName) reason=null-cgimage\n".utf8
                ))
                continue
            }

            if let pb = Self.pixelBuffer(from: cgImage, targetWidth: captureWidth, targetHeight: captureHeight) {
                frames.append(CapturedFrame(window: meta, pixelBuffer: pb))
            }
        }
        return frames
    }

    @available(macOS, deprecated: 14.0, message: "Intentional: SCK's per-window filter raises uncatchable ObjC exceptions on macOS 26+.")
    private static func captureWindowImage(windowID: UInt32) -> CGImage? {
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(windowID),
            [.boundsIgnoreFraming, .nominalResolution]
        )
    }

    private static func pixelBuffer(from cgImage: CGImage, targetWidth: Int, targetHeight: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth,
            targetHeight,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return buffer
    }
}
