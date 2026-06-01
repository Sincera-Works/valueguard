import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var actionOverrides: ActionOverrides
    /// Shared marketplace coordinator (also driven by the `vgconfig://` URL open
    /// in `AppDelegate`); powers the Configs tab.
    @ObservedObject var configCoordinator: ConfigInstallCoordinator
    var onRestartDaemon: () -> Void
    var onReopenOnboarding: () -> Void

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            policyTab.tabItem { Label("Policy", systemImage: "doc.text") }
            ConfigsView(coordinator: configCoordinator)
                .tabItem { Label("Configs", systemImage: "square.and.arrow.down.on.square") }
            ActionsView(overrides: actionOverrides)
                .tabItem { Label("Actions", systemImage: "bolt.shield") }
            CalibrationView(onRestartDaemon: onRestartDaemon)
                .tabItem { Label("Calibration", systemImage: "scope") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 640, minHeight: 480)
        .padding(16)
    }

    private var generalTab: some View {
        Form {
            Toggle("Log-only mode (no blur or block actions)", isOn: $settings.logOnly)
                .help("Recommended for the first week of use. Reviews logged flags before unlocking blur/block.")
            Toggle("Write per-frame scores log (calibration)", isOn: $settings.writeScoresLog)
                .help("scores.log gets one NDJSON line per category per sampled frame. Lets you see what the model thinks of every frame, not just the ones that fire.")
            Toggle("Pause actions during calls, screen shares & slideshows", isOn: $settings.autoPauseInSensitiveContexts)
                .help("When a conferencing app (Zoom, Teams, Webex, Meet desktop, OBS, QuickTime) is frontmost, or Keynote/PowerPoint is presenting full-screen, blur/notify/block are suppressed so they aren't broadcast. Logging continues. Takes effect immediately — no restart needed.")
            Picker("Sample rate", selection: $settings.sampleRateHz) {
                Text("0.5 Hz").tag(0.5)
                Text("1 Hz (default)").tag(1.0)
                Text("2 Hz").tag(2.0)
                Text("5 Hz").tag(5.0)
            }
            .pickerStyle(.menu)
            HStack {
                Spacer()
                Button("Apply (restart daemon)") { onRestartDaemon() }
            }
        }
        .padding()
    }

    private var policyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let policy = loadCurrentPolicy() {
                Text("Active policy")
                    .font(.headline)
                List(policy.categories) { cat in
                    HStack {
                        Text(cat.id).font(.system(.callout, design: .monospaced))
                        Spacer()
                        Text(cat.action.rawValue).font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("τ=\(cat.threshold, format: .number.precision(.fractionLength(2)))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxHeight: 220)
            } else {
                Text("No policy installed yet.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Recompile policy…") { onReopenOnboarding() }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Files").font(.headline)
                Text(AppSupport.policyJSONURL.path)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(AppSupport.policyBinURL.path)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(AppSupport.textEncoderURL.path)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            .padding(.top, 12)
            Spacer()
        }
        .padding()
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "checkmark.shield.fill").font(.system(size: 48)).foregroundStyle(.green)
            Text("ValueGuard").font(.title.bold())
            Text("Version \(appVersion()) (build \(buildNumber()))")
                .foregroundStyle(.secondary)
            Text("Model: google/siglip2-base-patch16-256")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("On-device content filtering. Pixels never leave your Mac.")
                .font(.callout)
            Link("Architecture & threat model", destination: URL(string: "file://\(NSString(string: "~/projects/valueguard/docs/ARCHITECTURE.md").expandingTildeInPath)")!)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
    }

    private func buildNumber() -> String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    private func loadCurrentPolicy() -> Policy? {
        guard let data = try? Data(contentsOf: AppSupport.policyJSONURL) else { return nil }
        return try? JSONDecoder().decode(Policy.self, from: data)
    }
}
