import Foundation
import CoreGraphics
import CoreVideo
import AppKit

/// Metadata about a captured window.
///
/// Enumeration and pixel capture both go through the CoreGraphics window-list
/// APIs (`CGWindowListCopyWindowInfo` / `CGWindowListCreateImage`), NOT
/// ScreenCaptureKit. `SCShareableContent.current` was previously used for
/// enumeration, but on macOS 26 it surfaces the Screen Recording permission
/// prompt on *every* call — even when access is already granted — so every
/// daemon (re)start (e.g. the Settings "Apply" restart) re-prompted the user.
/// The CG window-list returns all the metadata we use (owner name, bundle id via
/// PID, bounds, layer, on-screen, window id) without prompting; the pixel grab
/// still requires the Screen Recording grant but does not raise that prompt.
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
        // Non-prompting preflight only. We deliberately never call
        // `SCShareableContent.current` here: on macOS 26 it pops the Screen
        // Recording prompt even when access is already granted, so doing it on
        // every daemon (re)start re-prompted the user. `CGPreflightScreenCaptureAccess()`
        // reports the grant state silently. When not granted, surface a clear
        // message and throw — the app's onboarding owns the actual request flow
        // (`CGRequestScreenCaptureAccess`, which only matters on first launch).
        if CGPreflightScreenCaptureAccess() {
            return
        }
        FileHandle.standardError.write(Data(
            "valueguard: Screen Recording permission required. Grant in System Settings → Privacy & Security → Screen Recording, then re-run.\n".utf8
        ))
        throw NSError(
            domain: "works.sincera.valueguard.capture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Screen Recording permission not granted."]
        )
    }

    /// Enumerate and capture every on-screen window that passes the filter.
    ///
    /// Enumeration uses `CGWindowListCopyWindowInfo` (not ScreenCaptureKit): it
    /// returns the same metadata we need — window number, owner name/PID, bounds,
    /// layer, on-screen flag — WITHOUT triggering the macOS 26 Screen Recording
    /// prompt that `SCShareableContent.current` raises on every call. The
    /// per-window pixel grab still uses `CGWindowListCreateImage`, which requires
    /// the Screen Recording grant (returns a null image when not granted) but does
    /// not itself raise the prompt. Bundle id is resolved from the owner PID via
    /// `NSRunningApplication`.
    public func captureMonitoredWindows(filter: CaptureFilter) async throws -> [CapturedFrame] {
        // On-screen, real windows only; exclude desktop/Dock elements.
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var frames: [CapturedFrame] = []
        for info in infoList {
            // Layer 0 == ordinary application windows (matches the old
            // `windowLayer == 0` guard; filters out menu bar, Dock, overlays).
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            // On-screen guard (the option already filters, but be explicit).
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? true
            guard onScreen else { continue }

            // Bounds → CGRect (CGWindowListCopyWindowInfo gives a bounds dict).
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            guard frame.width > 1, frame.height > 1 else { continue }

            guard let windowNumber = info[kCGWindowNumber as String] as? Int else { continue }

            // App name + bundle id from the owner PID.
            let appName = (info[kCGWindowOwnerName as String] as? String) ?? ""
            let ownerPID = (info[kCGWindowOwnerPID as String] as? pid_t)
            let bundleID = ownerPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            guard filter.shouldMonitor(appName: appName) else { continue }

            let meta = MonitoredWindow(
                windowID: UInt32(windowNumber),
                appName: appName,
                bundleID: bundleID,
                frame: frame
            )

            guard let cgImage = Self.captureWindowImage(windowID: meta.windowID) else {
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
