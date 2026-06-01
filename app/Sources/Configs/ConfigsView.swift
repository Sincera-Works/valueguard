import SwiftUI
import ValueGuardMarketplace

/// The "Configs" settings tab: browse / install / activate / uninstall
/// marketplace config policies, and the confirmation surface for one-click
/// (`vgconfig://`) installs.
///
/// All state lives in the shared ``ConfigInstallCoordinator`` (also driven by
/// the `vgconfig://` URL open in `AppDelegate`), so this view is a thin renderer:
/// it shows the installed list, an "install from registry" field, and — driven
/// by the coordinator's ``ConfigInstallCoordinator/State`` — the trust
/// confirmation sheet. Because installing via a URL is attacker-influenceable,
/// the sheet *always* shows the author key fingerprint (TOFU), the per-category
/// actions, and the verified state before anything touches the active filter.
struct ConfigsView: View {
    /// The shared coordinator. `@ObservedObject` (not `@StateObject`) because it
    /// is owned by the app delegate and shared with the URL-open path; this view
    /// must observe the same instance, not create its own.
    @ObservedObject var coordinator: ConfigInstallCoordinator

    /// The `author/slug[@version]` ref typed into the install field.
    @State private var refInput: String = ""

    /// The live registry the install field resolves against.
    private let registryBase = RegistryClient.defaultRegistryBase

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            installFromRegistrySection
            Divider()
            installedSection
            Spacer(minLength: 0)
            footer
        }
        .padding()
        .sheet(isPresented: confirmationBinding) {
            if case .awaitingConfirmation(let info) = coordinator.state {
                ConfigConfirmSheet(
                    info: info,
                    onInstall: { Task { await coordinator.confirmInstall() } },
                    onCancel: { coordinator.cancelConfirmation() }
                )
            }
        }
        .onAppear { coordinator.refresh() }
    }

    // MARK: - Install from registry

    private var installFromRegistrySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Install from registry").font(.headline)
            HStack {
                TextField("author/slug[@version]", text: $refInput)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .onSubmit { startInstall() }
                Button("Install") { startInstall() }
                    .disabled(refInput.trimmingCharacters(in: .whitespaces).isEmpty || isBusy)
            }
            statusBanner
        }
    }

    /// Kick off resolve→confirm→install for the typed ref against the default
    /// registry. The sheet appears automatically when the coordinator reaches
    /// `awaitingConfirmation`.
    private func startInstall() {
        let ref = refInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty, !isBusy else { return }
        Task { await coordinator.resolveForConfirmation(registry: registryBase, ref: ref) }
    }

    /// Inline status under the install field: a spinner while resolving /
    /// installing, a success note, or a dismissible error.
    @ViewBuilder
    private var statusBanner: some View {
        switch coordinator.state {
        case .resolving:
            Label("Resolving and verifying…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        case .installing:
            Label("Installing…", systemImage: "square.and.arrow.down")
                .font(.caption).foregroundStyle(.secondary)
        case .installed(let ref):
            HStack {
                Label("Installed \(ref)", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
                Spacer()
                Button("Dismiss") {
                    refInput = ""
                    coordinator.resetState()
                }
                .buttonStyle(.link).font(.caption)
            }
        case .failed(let message):
            HStack(alignment: .top) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled)
                Spacer()
                Button("Dismiss") { coordinator.resetState() }
                    .buttonStyle(.link).font(.caption)
            }
        case .idle, .awaitingConfirmation:
            EmptyView()
        }
    }

    /// Whether a resolve/install is in flight (install button + field disabled).
    private var isBusy: Bool {
        switch coordinator.state {
        case .resolving, .installing, .awaitingConfirmation: return true
        case .idle, .installed, .failed: return false
        }
    }

    // MARK: - Installed list

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Installed configs").font(.headline)
            if coordinator.installedConfigs.isEmpty {
                emptyState
            } else {
                List(coordinator.installedConfigs, id: \.fingerprint) { config in
                    InstalledConfigRow(
                        config: config,
                        onActivate: { activate(config) },
                        onUninstall: { uninstall(config) }
                    )
                }
                .frame(minHeight: 140, maxHeight: 220)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No configs installed yet.").foregroundStyle(.secondary)
            Text("Install one from the registry above, or click “Install” on a config in the web directory.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func activate(_ config: InstalledConfig) {
        // The coordinator surfaces any failure via its `.failed` state (rendered
        // in the status banner); the thrown error is swallowed here.
        Task { try? await coordinator.activate(author: config.author, slug: config.slug) }
    }

    private func uninstall(_ config: InstalledConfig) {
        Task {
            do {
                try await coordinator.uninstall(author: config.author, slug: config.slug)
            } catch {
                NSLog("ValueGuard: uninstall failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Link(
                "Browse the registry",
                destination: URL(string: registryBase)!
            )
            .font(.caption)
            Spacer()
            Text("Installs are verified offline before they can change your filter.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Sheet binding

    /// A `Bool` binding derived from the coordinator state: `true` exactly while
    /// awaiting confirmation. Dismissing the sheet (set `false`) cancels.
    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: {
                if case .awaitingConfirmation = coordinator.state { return true }
                return false
            },
            set: { presented in
                if !presented { coordinator.cancelConfirmation() }
            }
        )
    }
}

// MARK: - Installed row

/// One row in the installed-configs list: identity, version, active marker,
/// short fingerprint, install date, and the Activate / Uninstall actions.
private struct InstalledConfigRow: View {
    let config: InstalledConfig
    let onActivate: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(config.author)/\(config.slug)")
                        .font(.system(.callout, design: .monospaced))
                    Text("v\(config.version)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if config.active {
                        Text("ACTIVE")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule())
                    }
                }
                Text("key \(config.fingerprint.prefix(16))…")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text("installed \(config.installedAt)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Activate", action: onActivate)
                .disabled(config.active)
            Button("Uninstall", action: onUninstall)
                .foregroundStyle(.red)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Confirmation sheet

/// The trust gate for installing a config. Because a `vgconfig://` open is
/// attacker-influenceable, this sheet is the *only* path to install: it shows
/// the resolved ref, the author handle, the author KEY FINGERPRINT (TOFU, short
/// form), the per-category actions, and the offline-verified badge, and only an
/// explicit "Install" proceeds.
private struct ConfigConfirmSheet: View {
    let info: ConfigInstallCoordinator.ConfirmationInfo
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            authorBlock
            categoriesBlock
            Spacer(minLength: 0)
            buttons
        }
        .padding(20)
        .frame(width: 460, height: 460)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Install config?").font(.title2.bold())
                Text(info.ref)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var authorBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Verified (offline) badge — driven by data, not implication.
            HStack(spacing: 6) {
                Image(systemName: info.verifyPassed ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(info.verifyPassed ? .green : .red)
                Text(info.verifyPassed
                     ? "Verified offline — signature, hashes & cross-checks passed"
                     : "Verification failed")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(info.verifyPassed ? .green : .red)
            }
            HStack(spacing: 6) {
                Text("Author").font(.caption).foregroundStyle(.secondary)
                Text(info.authorDisplayName.map { "\($0) (\(info.author))" } ?? info.author)
                    .font(.callout)
            }
            HStack(spacing: 6) {
                Text("Key").font(.caption).foregroundStyle(.secondary)
                Text(info.fingerprintShort)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text("(first 16 hex of the author's signing key — trust on first use)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var categoriesBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("This config will act on \(info.categories.count) categor\(info.categories.count == 1 ? "y" : "ies"):")
                .font(.callout)
            List(info.categories) { cat in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(cat.categoryID)
                            .font(.system(.caption, design: .monospaced))
                        if let desc = cat.shortDescription, !desc.isEmpty {
                            Text(desc).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(cat.action.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(actionColor(cat.action))
                }
            }
            .frame(maxHeight: 160)
        }
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Install", action: onInstall)
                .keyboardShortcut(.defaultAction)
                .disabled(!info.verifyPassed)
        }
    }

    private func actionColor(_ action: String) -> Color {
        switch action.lowercased() {
        case "block": return .red
        case "blur": return .orange
        default: return .secondary
        }
    }
}
