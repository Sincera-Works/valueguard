import AppKit

@MainActor
final class MenubarController: NSObject {
    private let statusItem: NSStatusItem
    private let host: DaemonHost
    private let openOnboarding: () -> Void
    private let openSettings: () -> Void
    private let onEmergencyDismiss: () -> Void
    private var pauseItem: NSMenuItem?

    init(
        host: DaemonHost,
        openOnboarding: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        onEmergencyDismiss: @escaping () -> Void
    ) {
        self.host = host
        self.openOnboarding = openOnboarding
        self.openSettings = openSettings
        self.onEmergencyDismiss = onEmergencyDismiss
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        apply(status: host.status)
        buildMenu()
    }

    func apply(status: DaemonHost.Status) {
        guard let button = statusItem.button else { return }
        let (symbol, accessibility): (String, String)
        switch status {
        case .stopped, .failed:
            symbol = "xmark.shield.fill"
            accessibility = "ValueGuard — stopped"
        case .starting:
            symbol = "clock.shield.fill"
            accessibility = "ValueGuard — starting"
        case .running:
            symbol = "checkmark.shield.fill"
            accessibility = "ValueGuard — running"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        image?.isTemplate = true
        button.image = image
        pauseItem?.title = host.isRunning ? "Pause" : "Resume"
    }

    private func buildMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "ValueGuard", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

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

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(presentSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ValueGuard", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
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
}
