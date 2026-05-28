import SwiftUI
import AppKit

@main
struct ValueGuardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // LSUIElement = true means SwiftUI's Settings scene isn't shown via
        // the menu bar; we present our own NSWindow instead from MenubarController.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menubar: MenubarController?
    private var daemonHost: DaemonHost?
    private var onboarding: OnboardingWindow?
    private var settingsWindow: SettingsWindow?
    private var settings: AppSettings?
    private var actionOverrides: ActionOverrides?
    private var auditTailer: AuditLogTailer?
    private var actionDispatcher: ActionDispatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let host = DaemonHost()
        let settings = AppSettings()
        let actionOverrides = ActionOverrides()
        let onboarding = OnboardingWindow()
        let settingsWindow = SettingsWindow(
            settings: settings,
            actionOverrides: actionOverrides,
            onRestartDaemon: { [weak host, weak settings] in
                guard let host, let settings else { return }
                host.restart(
                    logOnly: settings.logOnly,
                    sampleRateHz: settings.sampleRateHz,
                    writeScoresLog: settings.writeScoresLog
                )
            },
            onReopenOnboarding: { [weak onboarding] in onboarding?.present() }
        )
        let auditTailer = AuditLogTailer()
        let actionDispatcher = ActionDispatcher(tailer: auditTailer, overrides: actionOverrides)
        actionDispatcher.start()
        let menubar = MenubarController(
            host: host,
            openOnboarding: { [weak onboarding] in onboarding?.present() },
            openSettings: { [weak settingsWindow] in settingsWindow?.present() }
        )
        host.onStatusChange = { [weak menubar] status in
            Task { @MainActor in menubar?.apply(status: status) }
        }
        onboarding.onFinish = { [weak host, weak menubar, weak settings] in
            guard let host else { return }
            if host.hasPolicy {
                let s = settings
                host.start(
                    logOnly: s?.logOnly ?? true,
                    sampleRateHz: s?.sampleRateHz ?? 1.0,
                    writeScoresLog: s?.writeScoresLog ?? true
                )
            } else {
                menubar?.apply(status: .stopped)
            }
        }
        if host.hasPolicy {
            host.start(
                logOnly: settings.logOnly,
                sampleRateHz: settings.sampleRateHz,
                writeScoresLog: settings.writeScoresLog
            )
        } else {
            menubar.apply(status: .stopped)
            onboarding.present()
        }
        self.daemonHost = host
        self.menubar = menubar
        self.onboarding = onboarding
        self.settingsWindow = settingsWindow
        self.settings = settings
        self.actionOverrides = actionOverrides
        self.auditTailer = auditTailer
        self.actionDispatcher = actionDispatcher
    }
}
