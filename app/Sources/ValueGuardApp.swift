import SwiftUI
import AppKit
import CoreGraphics
import ValueGuardMarketplace

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
    /// Owns the marketplace install/activate/list lifecycle, shared with the
    /// Configs settings tab and driven directly by `vgconfig://` URL opens.
    private var configCoordinator: ConfigInstallCoordinator?

    /// A `vgconfig://` URL delivered before `applicationDidFinishLaunching`
    /// finished wiring `configCoordinator` (a cold launch *via* the link). It is
    /// stashed here and replayed once setup completes, so a cold-start install
    /// intent is never silently dropped.
    private var pendingConfigURL: URL?

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
        // The daemon-restart closure is shared between Settings (Apply) and the
        // config coordinator's copy-on-activate, so both reload the flat
        // policy.bin the daemon reads.
        let restartDaemon: () -> Void = { [weak host, weak settings] in
            guard let host, let settings else { return }
            host.restart(
                logOnly: settings.logOnly,
                sampleRateHz: settings.sampleRateHz,
                writeScoresLog: settings.writeScoresLog
            )
        }
        let configCoordinator = ConfigInstallCoordinator(onRestartDaemon: restartDaemon)
        let settingsWindow = SettingsWindow(
            settings: settings,
            actionOverrides: actionOverrides,
            configCoordinator: configCoordinator,
            onRestartDaemon: restartDaemon,
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
        self.configCoordinator = configCoordinator

        // Replay a vgconfig:// URL that arrived during a cold launch (before the
        // coordinator existed), so a launch-via-link install isn't dropped.
        if let pending = pendingConfigURL {
            pendingConfigURL = nil
            handleConfigURL(pending)
        }
    }

    // MARK: - vgconfig:// URL handling (one-click install)

    /// Handle `vgconfig://` opens — the web directory's one-click "Install"
    /// button. Format:
    ///
    /// ```
    /// vgconfig://install?registry=<base>&ref=<author>/<slug>[@version]
    /// ```
    ///
    /// `ref` may be URL-encoded (the `/` and `@` are reserved); it is decoded by
    /// `URLComponents`. `registry` is optional and defaults to the live registry
    /// (`RegistryClient.defaultRegistryBase`).
    ///
    /// Installing from a URL is attacker-influenceable, so this NEVER silently
    /// swaps the active filter: it brings the app forward, presents the Settings
    /// window (so the sheet is visible to this `LSUIElement` accessory app), and
    /// routes to the coordinator's resolve→confirm flow, which gates install
    /// behind the explicit confirmation sheet. Malformed URLs are logged and
    /// ignored — never crash.
    func application(_ application: NSApplication, open urls: [URL]) {
        // `NSApplicationDelegate` is main-actor in practice, but the protocol
        // requirement carries no isolation annotation; assert main-actor
        // explicitly so the `@MainActor` routing below is isolation-clean under
        // strict concurrency (mirrors `onboarding.onFinish`).
        MainActor.assumeIsolated {
            for url in urls {
                handleConfigURL(url)
            }
        }
    }

    /// Parse and route a single `vgconfig://` URL. Anything malformed (wrong
    /// scheme/host, missing `ref`) is logged and dropped.
    @MainActor
    private func handleConfigURL(_ url: URL) {
        guard url.scheme?.lowercased() == "vgconfig" else {
            NSLog("ValueGuard: ignoring URL with unexpected scheme: \(url.absoluteString)")
            return
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            NSLog("ValueGuard: could not parse vgconfig URL: \(url.absoluteString)")
            return
        }
        // Accept vgconfig://install?… (host == "install"); tolerate a missing
        // host for robustness as long as a ref is present.
        if let host = components.host, !host.isEmpty, host.lowercased() != "install" {
            NSLog("ValueGuard: ignoring vgconfig URL with unknown action '\(host)'")
            return
        }
        let items = components.queryItems ?? []
        guard let ref = items.first(where: { $0.name == "ref" })?.value, !ref.isEmpty else {
            NSLog("ValueGuard: vgconfig URL missing 'ref': \(url.absoluteString)")
            return
        }
        // queryItems already percent-decodes values, so `ref` is plain text here.
        let registry = items.first(where: { $0.name == "registry" })?.value.flatMap {
            $0.isEmpty ? nil : $0
        } ?? RegistryClient.defaultRegistryBase

        guard let coordinator = configCoordinator else {
            // Cold launch via the link: setup hasn't finished wiring the
            // coordinator yet. Stash the URL; applicationDidFinishLaunching
            // replays it once setup completes, so the intent isn't lost. Only one
            // pending slot — if macOS delivers several at once, keep the first
            // (the coordinator handles one install at a time anyway; the user can
            // re-click the others).
            if pendingConfigURL == nil { pendingConfigURL = url }
            return
        }

        // Bring the app forward and present Settings so the confirmation sheet
        // (presented by the Configs tab) is visible to this accessory app.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.present()
        Task { await coordinator.resolveForConfirmation(registry: registry, ref: ref) }
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
