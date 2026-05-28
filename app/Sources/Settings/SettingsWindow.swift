import AppKit
import SwiftUI

@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let settings: AppSettings
    private let actionOverrides: ActionOverrides
    private let onRestartDaemon: () -> Void
    private let onReopenOnboarding: () -> Void

    init(
        settings: AppSettings,
        actionOverrides: ActionOverrides,
        onRestartDaemon: @escaping () -> Void,
        onReopenOnboarding: @escaping () -> Void
    ) {
        self.settings = settings
        self.actionOverrides = actionOverrides
        self.onRestartDaemon = onRestartDaemon
        self.onReopenOnboarding = onReopenOnboarding
    }

    func present() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(
            settings: settings,
            actionOverrides: actionOverrides,
            onRestartDaemon: onRestartDaemon,
            onReopenOnboarding: onReopenOnboarding
        )
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "ValueGuard Settings"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
