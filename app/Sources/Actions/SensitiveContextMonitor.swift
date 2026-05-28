import AppKit

/// Detects "sensitive" desktop contexts — an active video call, screen
/// share, or slideshow — during which ValueGuard must not pop a blur,
/// notification, or block onto the screen. Two reasons:
///   1. A blur overlay shown while you're screen-sharing is visible to
///      everyone on the call.
///   2. A live call or presentation is exactly when an unexpected
///      full-window blur is most disruptive.
///
/// Detection is heuristic and intentionally biased toward "sensitive"
/// (we'd rather pause filtering one moment too long than fire a blur onto
/// a shared screen). Two signals:
///   - A known conferencing / recording app (Zoom, Teams, Webex, Google Meet
///     desktop, OBS, QuickTime) is frontmost, OR is running with a visible
///     normal-layer window. The window check catches an active call/share the
///     user has clicked away from (sharing a browser while the call window
///     sits in the background) — precisely when a blur must not fire onto the
///     share. An app idling only in the menubar does not count.
///   - Keynote or PowerPoint owns an on-screen window that covers a whole
///     display — a live presentation OR full-screen editing. We deliberately
///     treat both as sensitive; over-pausing is the safe direction.
///
/// Known limitation: browser-tab calls (Google Meet / Teams in a tab) are NOT
/// detected — a browser bundle ID is far too broad to treat as sensitive. The
/// bundle-ID lists below are the single place to tune native-app coverage.
@MainActor
final class SensitiveContextMonitor {
    /// Bundle IDs that mean "sensitive" whenever they are frontmost.
    private static let frontmostSensitiveBundleIDs: Set<String> = [
        "us.zoom.xos",                 // Zoom
        "com.microsoft.teams",         // Teams (classic)
        "com.microsoft.teams2",        // Teams (new)
        "com.cisco.webexmeetingsapp",  // Webex Meetings
        "com.webex.meetingmanager",    // Webex (older)
        "com.google.meet",             // Google Meet desktop (PWA)
        "com.obsproject.obs-studio",   // OBS Studio
        "com.apple.QuickTimePlayerX",  // QuickTime (screen recording)
    ]

    /// Bundle IDs whose full-screen window indicates an active slideshow.
    private static let slideshowBundleIDs: Set<String> = [
        "com.apple.iWork.Keynote",
        "com.microsoft.Powerpoint",
    ]

    /// Fired on every change of the sensitive state (true = now sensitive).
    var onChange: ((Bool) -> Void)?

    private(set) var isSensitive = false
    private let enabled: () -> Bool
    private var timer: Timer?
    private var workspaceObserver: NSObjectProtocol?

    init(enabled: @escaping () -> Bool) {
        self.enabled = enabled
    }

    func start() {
        guard timer == nil else { return }
        // Re-evaluate when the frontmost app changes (catches a call coming
        // to the foreground)…
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        // …and on a 2 s poll (catches slideshow start/stop, which fires no
        // app-activation notification).
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if isSensitive {
            isSensitive = false
            onChange?(false)
        }
    }

    private func evaluate() {
        _ = isSensitiveNow()
    }

    /// Live re-evaluation of the sensitive state: updates `isSensitive` and
    /// fires `onChange` if it changed, then returns the current value. Safe to
    /// call on demand — e.g. right before a blur would fire — to avoid waiting
    /// for the next poll tick (closes the up-to-poll-interval staleness gap).
    func isSensitiveNow() -> Bool {
        let now = enabled() && detectSensitive()
        if now != isSensitive {
            isSensitive = now
            onChange?(now)
        }
        return now
    }

    private func detectSensitive() -> Bool {
        if conferencingActive() { return true }
        return slideshowActive()
    }

    /// A conferencing/recording app counts as sensitive when it is frontmost OR
    /// owns a visible, normal-layer window. The window check catches an active
    /// call/share whose window the user has clicked away from — e.g. sharing a
    /// browser while the Zoom call window sits in the background, exactly when
    /// a blur must not be allowed onto the share. An app living only in the
    /// menubar (no on-screen window) does NOT count, so filtering isn't paused
    /// all day merely because a conferencing app is running.
    private func conferencingActive() -> Bool {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           Self.frontmostSensitiveBundleIDs.contains(front) {
            return true
        }
        let pids = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier.map(Self.frontmostSensitiveBundleIDs.contains) ?? false }
                .map { $0.processIdentifier }
        )
        guard !pids.isEmpty else { return false }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for entry in list {
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            guard pids.contains(pid) else { continue }
            // Normal-layer windows only — skip menubar items / status windows.
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect) else { continue }
            // A real meeting/share window is sizable; ignore tiny helper windows.
            if rect.width >= 200, rect.height >= 200 { return true }
        }
        return false
    }

    /// True when a slideshow app owns an on-screen window whose bounds match a
    /// whole display — a live presentation OR full-screen editing. Both are
    /// treated as sensitive; over-pausing is the safe direction here.
    private func slideshowActive() -> Bool {
        let slideshowPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier.map(Self.slideshowBundleIDs.contains) ?? false }
                .map { $0.processIdentifier }
        )
        guard !slideshowPIDs.isEmpty else { return false }

        let screenSizes = NSScreen.screens.map { $0.frame.size }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for entry in list {
            let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            guard slideshowPIDs.contains(pid) else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] else { continue }
            var rect = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDict as CFDictionary, &rect) else { continue }
            // Match within a few px to any whole screen → it's a slideshow.
            if screenSizes.contains(where: { abs($0.width - rect.width) < 4 && abs($0.height - rect.height) < 4 }) {
                return true
            }
        }
        return false
    }
}
