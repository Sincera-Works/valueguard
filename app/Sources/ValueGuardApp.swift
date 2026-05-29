import SwiftUI
import AppKit
import CoreGraphics

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
    private var emergencyHotkey: EmergencyHotkey?

    /// Whether Screen Recording was already granted when *this* process launched.
    /// macOS only honors a freshly-granted Screen Recording permission for a new
    /// process launch, so if the grant flips from false→true during onboarding we
    /// relaunch the app once to pick it up. Because the relaunched instance starts
    /// with this flag set to `true`, the grant can never appear "fresh" twice and
    /// the relaunch cannot loop.
    private var screenRecordingGrantedAtLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        screenRecordingGrantedAtLaunch = CGPreflightScreenCaptureAccess()
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
        let actionDispatcher = ActionDispatcher(
            tailer: auditTailer,
            overrides: actionOverrides,
            autoPauseEnabled: { [weak settings] in settings?.autoPauseInSensitiveContexts ?? true }
        )
        actionDispatcher.start()
        let emergencyHotkey = EmergencyHotkey { [weak actionDispatcher] in
            actionDispatcher?.emergencyDismiss()
        }
        emergencyHotkey.register()
        let menubar = MenubarController(
            host: host,
            openOnboarding: { [weak onboarding] in onboarding?.present() },
            openSettings: { [weak settingsWindow] in settingsWindow?.present() },
            onEmergencyDismiss: { [weak actionDispatcher] in actionDispatcher?.emergencyDismiss() }
        )
        host.onStatusChange = { [weak menubar] status in
            Task { @MainActor in menubar?.apply(status: status) }
        }
        onboarding.onFinish = { [weak self, weak host, weak menubar, weak settings] in
            // onFinish is invoked on the main thread (a UI callback); assert that
            // explicitly so the @MainActor calls below are isolation-clean under
            // Swift 6 / strict concurrency, not just under Swift 5.10.
            MainActor.assumeIsolated {
                guard let host else { return }
                guard host.hasPolicy else {
                    menubar?.apply(status: .stopped)
                    return
                }
                // If Screen Recording was granted *during* this session, the
                // current process won't be honored by the capture API — only a
                // new launch will. Relaunch once (state is already persisted) so
                // filtering actually starts instead of failing into a silent red
                // menubar.
                if self?.shouldRelaunchForScreenRecording() == true {
                    self?.relaunchForScreenRecording(menubar: menubar)
                    return
                }
                let s = settings
                host.start(
                    logOnly: s?.logOnly ?? true,
                    sampleRateHz: s?.sampleRateHz ?? 1.0,
                    writeScoresLog: s?.writeScoresLog ?? true
                )
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
        self.emergencyHotkey = emergencyHotkey
    }

    /// True only when Screen Recording was *not* granted at launch but is now —
    /// i.e. the user just granted it during onboarding. The relaunched instance
    /// sees `screenRecordingGrantedAtLaunch == true`, so this never fires twice.
    @MainActor
    private func shouldRelaunchForScreenRecording() -> Bool {
        !screenRecordingGrantedAtLaunch && CGPreflightScreenCaptureAccess()
    }

    @MainActor
    private func relaunchForScreenRecording(menubar: MenubarController?) {
        menubar?.apply(status: .starting)
        menubar?.showRelaunchNotice()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            Task { @MainActor in
                if let error {
                    // Couldn't relaunch — fall back to starting in-process so the
                    // user isn't left with a dead menubar. Capture may still throw,
                    // which DaemonHost surfaces as .failed with a reason.
                    NSLog("ValueGuard: relaunch for Screen Recording failed: \(error.localizedDescription)")
                    self.daemonHost?.start(
                        logOnly: self.settings?.logOnly ?? true,
                        sampleRateHz: self.settings?.sampleRateHz ?? 1.0,
                        writeScoresLog: self.settings?.writeScoresLog ?? true
                    )
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}
