import AppKit

@MainActor
final class MenubarController: NSObject {
    private let statusItem: NSStatusItem
    private let host: DaemonHost
    private let openOnboarding: () -> Void
    private let openSettings: () -> Void
    private let onEmergencyDismiss: () -> Void
    /// Triggers a user-initiated Sparkle update check (standard UI). Injected so
    /// the menubar stays decoupled from the updater; see `UpdaterController`.
    private let checkForUpdates: () -> Void
    private var pauseItem: NSMenuItem?
    /// Disabled menu item that surfaces *why* filtering isn't running. Hidden
    /// unless the daemon is in a `.failed` state (or we're mid-relaunch).
    private var failureItem: NSMenuItem?
    private var privacySettingsItem: NSMenuItem?
    private var failureSeparatorItem: NSMenuItem?

    init(
        host: DaemonHost,
        openOnboarding: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        onEmergencyDismiss: @escaping () -> Void,
        checkForUpdates: @escaping () -> Void
    ) {
        self.host = host
        self.openOnboarding = openOnboarding
        self.openSettings = openSettings
        self.onEmergencyDismiss = onEmergencyDismiss
        self.checkForUpdates = checkForUpdates
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        apply(status: host.status)
    }

    func apply(status: DaemonHost.Status) {
        guard let button = statusItem.button else { return }
        let (symbol, accessibility): (String, String)
        switch status {
        case .stopped:
            symbol = "xmark.shield.fill"
            accessibility = "ValueGuard — stopped"
        case .failed:
            symbol = "exclamationmark.shield.fill"
            accessibility = "ValueGuard — error (filtering not running)"
        case .starting:
            symbol = "clock.shield.fill"
            accessibility = "ValueGuard — preparing model…"
        case .running:
            symbol = "checkmark.shield.fill"
            accessibility = "ValueGuard — running"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        image?.isTemplate = true
        button.image = image
        button.toolTip = accessibility
        pauseItem?.title = host.isRunning ? "Pause" : "Resume"
        updateFailureItem(status: status)
    }

    /// Briefly tells the user the app is relaunching to pick up a freshly-granted
    /// Screen Recording permission (the capture API only honors it for a new
    /// process launch). The relaunched instance starts filtering normally.
    func showRelaunchNotice() {
        statusItem.button?.toolTip = "Restarting to activate Screen Recording…"
        failureItem?.title = "Restarting to activate Screen Recording…"
        failureItem?.isHidden = false
        failureSeparatorItem?.isHidden = false
    }

    private func buildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "ValueGuard", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Failure reason + remediation. Hidden until the daemon reports .failed
        // (or we're mid-relaunch); see updateFailureItem(status:).
        let failure = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        failure.isEnabled = false
        failure.isHidden = true
        failureItem = failure
        menu.addItem(failure)

        let privacy = NSMenuItem(title: "Open Privacy Settings…", action: #selector(openPrivacySettings), keyEquivalent: "")
        privacy.target = self
        privacy.isHidden = true
        privacySettingsItem = privacy
        menu.addItem(privacy)

        let failureSeparator = NSMenuItem.separator()
        failureSeparator.isHidden = true
        failureSeparatorItem = failureSeparator
        menu.addItem(failureSeparator)

        let pause = NSMenuItem(title: host.isRunning ? "Pause" : "Resume", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pauseItem = pause
        menu.addItem(pause)

        // Mirrors the system-wide EmergencyHotkey; the key equivalent here is
        // for discoverability (the Carbon hotkey is what fires when another
        // app is frontmost).
        let dismiss = NSMenuItem(title: "Dismiss blur now", action: #selector(emergencyDismiss), keyEquivalent: "d")
        dismiss.keyEquivalentModifierMask = [.control, .option, .command]
        dismiss.target = self
        menu.addItem(dismiss)

        let openLog = NSMenuItem(title: "Open audit log (flags)", action: #selector(openAuditLog), keyEquivalent: "")
        openLog.target = self
        menu.addItem(openLog)

        let openScores = NSMenuItem(title: "Open scores log (per-frame)", action: #selector(openScoresLog), keyEquivalent: "")
        openScores.target = self
        menu.addItem(openScores)

        let editValues = NSMenuItem(title: "Edit values…", action: #selector(reopenOnboarding), keyEquivalent: "")
        editValues.target = self
        menu.addItem(editValues)

        // Sits in the Settings/Quit region. Routes to the injected Sparkle
        // closure (see UpdaterController); target = self so the @objc action
        // resolves on this controller rather than the (absent) responder chain.
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesAction), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(presentSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ValueGuard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Shows or hides the failure reason + "Open Privacy Settings…" affordances
    /// based on the daemon state. A failed start is the only place a fresh tester
    /// can end up silently not filtering, so we make the reason visible here.
    private func updateFailureItem(status: DaemonHost.Status) {
        guard let failureItem, let privacySettingsItem, let failureSeparatorItem else { return }
        if case .failed(let reason) = status {
            failureItem.title = "Not filtering: \(reason)"
            failureItem.isHidden = false
            privacySettingsItem.isHidden = false
            failureSeparatorItem.isHidden = false
        } else {
            failureItem.isHidden = true
            privacySettingsItem.isHidden = true
            failureSeparatorItem.isHidden = true
        }
    }

    @objc private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func togglePause() {
        if host.isRunning {
            host.stop()
        } else {
            host.start()
        }
        apply(status: host.status)
    }

    @objc private func emergencyDismiss() {
        onEmergencyDismiss()
    }

    @objc private func openAuditLog() {
        revealOrCreate(AppSupport.auditLogURL)
    }

    @objc private func openScoresLog() {
        revealOrCreate(AppSupport.scoresLogURL)
    }

    private func revealOrCreate(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func reopenOnboarding() {
        openOnboarding()
    }

    @objc private func presentSettings() {
        openSettings()
    }

    @objc private func checkForUpdatesAction() {
        checkForUpdates()
    }
}
