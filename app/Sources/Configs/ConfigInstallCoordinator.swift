import Foundation
import Darwin
import ValueGuardMarketplace

/// Owns the install / verify / activate / uninstall lifecycle for marketplace
/// config bundles, bridging the offline `ValueGuardMarketplace` library to the
/// app's flat-file daemon.
///
/// ## Why a coordinator (and not direct library calls in the view)
/// Two flows funnel through here — the **Configs settings tab** (a ref typed by
/// the user) and the **`vgconfig://` URL open** (a ref handed in by the web
/// directory, i.e. attacker-influenceable). Both must run the *same* gated
/// path: resolve → download (content-address checked by `RegistryClient`) →
/// full offline `BundleVerifier` → **explicit user confirmation** → install →
/// optional activate. Centralizing that path in one `@MainActor` object means
/// the URL-open path can never skip the confirmation the settings path also
/// shows, and the view stays a thin renderer of ``state``.
///
/// ## The copy-on-activate bridge
/// The daemon reads a single flat file, ``AppSupport/policyBinURL``
/// (`~/Library/Application Support/ValueGuard/policy.bin`). The marketplace
/// installs each version under `configs/<author>/<slug>/<version>/policy.bin`
/// and flips a `configs/active` symlink. Those two worlds are joined in
/// ``activate(author:slug:)``: after `Installer.activate` updates the lockfile
/// + symlink, we **atomically copy** the activated version's `policy.bin` over
/// the flat file and call the injected restart closure. The daemon's existing
/// flat-file load path then picks it up with no daemon changes.
///
/// ## Testability / isolation
/// The coordinator never imports `DaemonHost`; the daemon restart is injected as
/// a `() -> Void` closure. It is `@MainActor` to match the app's UI isolation
/// (the marketplace library's calls are synchronous and run on a detached task
/// only for the network-bearing resolve/download step, then hop back).
@MainActor
final class ConfigInstallCoordinator: ObservableObject {
    /// The information surfaced to the confirmation sheet after a successful
    /// resolve + offline verify, *before* anything is installed. Everything the
    /// user needs to make a trust decision lives here.
    struct ConfirmationInfo: Identifiable {
        var id: String { ref }
        /// The canonical `author/slug@version` reference being offered.
        let ref: String
        /// The registry base URL the bundle was fetched from, surfaced in the
        /// sheet so the user can see *where* it came from — a link to
        /// `evil.example.com` must not look identical to the canonical registry.
        let registryBase: String
        /// Author handle (`manifest.author.handle`).
        let author: String
        /// Author display name, if the manifest carries one.
        let authorDisplayName: String?
        /// Full lowercase-hex SHA-256 of the author's raw Ed25519 public key.
        /// Display truncates (see ``fingerprintShort``); storage is full.
        let fingerprint: String
        /// The concrete resolved version.
        let version: String
        /// Per-category {id, action, short description} for the action preview.
        let categories: [Category]
        /// Whether every offline `BundleVerifier` check passed. Only a passing
        /// verify ever reaches the sheet, but we surface it so the UI can render
        /// the "verified" badge from data rather than implication.
        let verifyPassed: Bool
        /// The downloaded + sha-checked bundle on disk, retained so
        /// ``confirmInstall()`` can install the *exact* bytes that were verified
        /// (never a re-download that could differ).
        let bundleTempURL: URL

        /// First 16 hex chars of the fingerprint — the short TOFU form shown in
        /// the confirm sheet and the installed list. Storage stays full.
        var fingerprintShort: String {
            String(fingerprint.prefix(16))
        }

        /// One category's action summary for the confirm sheet.
        struct Category: Identifiable {
            var id: String { categoryID }
            let categoryID: String
            let action: String
            let shortDescription: String?
        }
    }

    /// The UI-facing lifecycle state. The Configs view renders purely off this.
    enum State: Equatable {
        /// Nothing in flight.
        case idle
        /// Resolving + downloading + verifying a ref (network-bearing).
        case resolving
        /// Verify passed; waiting for the user to confirm or cancel the install.
        case awaitingConfirmation(ConfirmationInfo)
        /// `Installer.install` is running over the confirmed bundle.
        case installing
        /// The most recent install succeeded; carries the installed ref.
        case installed(ref: String)
        /// Any step failed; carries a human-readable message for the UI.
        case failed(message: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.resolving, .resolving), (.installing, .installing):
                return true
            case let (.awaitingConfirmation(a), .awaitingConfirmation(b)):
                return a.ref == b.ref && a.bundleTempURL == b.bundleTempURL
            case let (.installed(a), .installed(b)):
                return a == b
            case let (.failed(a), .failed(b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// The current lifecycle state, observed by the Configs view.
    @Published private(set) var state: State = .idle

    /// The installed configs, newest list refreshed via ``refresh()``. Drives
    /// the Configs tab's list.
    @Published private(set) var installedConfigs: [InstalledConfig] = []

    /// Injected daemon-restart closure (reuses `SettingsWindow.onRestartDaemon`).
    /// Called after a copy-on-activate so the running daemon reloads the swapped
    /// flat `policy.bin`. Kept as a closure so the coordinator never imports
    /// `DaemonHost` and stays unit-testable.
    private let onRestartDaemon: () -> Void

    /// The destination flat policy the daemon reads. Defaulted to
    /// ``AppSupport/policyBinURL`` but injectable for tests.
    private let flatPolicyURL: URL

    /// Build a coordinator.
    ///
    /// - Parameters:
    ///   - onRestartDaemon: invoked after a successful copy-on-activate so the
    ///     daemon reloads the new flat `policy.bin`.
    ///   - flatPolicyURL: the flat file the daemon reads; defaults to
    ///     ``AppSupport/policyBinURL``.
    init(
        onRestartDaemon: @escaping () -> Void,
        flatPolicyURL: URL = AppSupport.policyBinURL
    ) {
        self.onRestartDaemon = onRestartDaemon
        self.flatPolicyURL = flatPolicyURL
    }

    // MARK: - Resolve for confirmation

    /// Resolve `ref` against `registry`, download the bundle (content-address
    /// checked by `RegistryClient`), run the full offline `BundleVerifier`, and
    /// move to ``State/awaitingConfirmation(_:)`` — **without installing**.
    ///
    /// This is the single entry point for both the settings field and the
    /// `vgconfig://` URL open. Nothing is written to the install tree here; the
    /// downloaded bundle sits in a temp file referenced by the surfaced
    /// ``ConfirmationInfo`` until the user explicitly confirms.
    ///
    /// - Parameters:
    ///   - registry: the registry base URL string (defaults to the live
    ///     registry at the call sites; passed through verbatim).
    ///   - ref: an `author/slug[@version]` reference (may arrive URL-encoded
    ///     from a `vgconfig://` open — decode before calling).
    func resolveForConfirmation(registry: String, ref: String) async {
        // Reentrancy guard: `application(_:open:)` can deliver multiple
        // `vgconfig://` URLs in one delegate call, and each `await` below is a
        // suspension point. Only start a resolve from a clean state — otherwise a
        // second call would overwrite an `.awaitingConfirmation` (orphaning its
        // downloaded temp bundle) or stomp an in-flight resolve. A second link is
        // simply dropped; the user re-clicks after dealing with the first.
        guard case .idle = state else {
            NSLog("ValueGuard: ignoring install request for '\(ref)' — another is in progress")
            return
        }
        state = .resolving

        guard let parsed = Self.parseRef(ref) else {
            state = .failed(message: "Couldn't parse config reference '\(ref)'. Expected author/slug[@version].")
            return
        }
        // SECURITY: the registry base arrives from an attacker-influenceable
        // `vgconfig://` link. `RegistryClient` supports `file://` for offline
        // tests, so an unvalidated base would let a webpage point the app at
        // `file:///…` and read arbitrary local files the user can read — *before*
        // any verification runs. Only allow https (and http for localhost dev).
        guard let baseURL = URL(string: registry), Self.isAllowedRegistryScheme(baseURL) else {
            state = .failed(message: "Refusing registry '\(registry)': only https registries are allowed.")
            return
        }

        // The resolve + download is network-bearing and the marketplace API is
        // synchronous (it bridges URLSession over a semaphore internally), so run
        // it off the main actor to keep the UI responsive, then hop back to
        // publish state.
        let result: Result<ConfirmationInfo, Error> = await Task.detached(priority: .userInitiated) {
            let client = RegistryClient(baseURL: baseURL)
            let (bundleURL, resolved) = try client.resolveAndDownload(
                author: parsed.author,
                slug: parsed.slug,
                version: parsed.version
            )
            // From here a downloaded temp bundle exists. Any throw (a failing
            // verify, an identity mismatch, …) must not leak it; only the success
            // path that hands the URL to `ConfirmationInfo` clears this flag.
            var keepBundle = false
            defer { if !keepBundle { try? FileManager.default.removeItem(at: bundleURL) } }

            // SECURITY: the resolved author/slug come from the registry's own
            // index.json (attacker-controlled). Assert they match what the link
            // asked for, so a malicious registry can't serve `evil/policy` while
            // claiming to be `trusted/policy` in the confirm sheet.
            guard resolved.config.author == parsed.author,
                  resolved.config.slug == parsed.slug else {
                throw VGError.crossCheck(
                    "registry returned \(resolved.config.author)/\(resolved.config.slug) "
                    + "for requested \(parsed.author)/\(parsed.slug)")
            }

            // Full offline verify over the downloaded bytes — signature,
            // cross-checks, manifest digest — independent of the index sha
            // `RegistryClient` already enforced. The extracted temp dir is not
            // needed here (install re-extracts), so remove it.
            let (report, extractedDir) = try BundleVerifier.verify(bundleAt: bundleURL)
            try? FileManager.default.removeItem(at: extractedDir)

            // A verify failure must never reach an "installable" confirm sheet:
            // surface it as an error with the failing check details.
            guard report.allPassed else {
                let failed = report.checks
                    .filter { !$0.ok }
                    .map { check in
                        check.detail.map { "\(check.label): \($0)" } ?? check.label
                    }
                    .joined(separator: "; ")
                throw VGError.signatureInvalid("verification failed: \(failed)")
            }

            let manifest = report.manifest
            let resolvedRef = "\(resolved.config.author)/\(resolved.config.slug)@\(resolved.version.version)"
            let categories = manifest.categories.map { entry in
                ConfirmationInfo.Category(
                    categoryID: entry.id,
                    action: entry.action,
                    shortDescription: entry.shortDescription
                )
            }
            // The bundle is handed to the confirm sheet — retain it past the defer.
            keepBundle = true
            return ConfirmationInfo(
                ref: resolvedRef,
                registryBase: registry,
                author: manifest.author.handle,
                authorDisplayName: manifest.author.displayName,
                fingerprint: report.authorFingerprint,
                version: manifest.version,
                categories: categories,
                verifyPassed: report.allPassed,
                bundleTempURL: bundleURL
            )
        }.result

        switch result {
        case .success(let info):
            state = .awaitingConfirmation(info)
        case .failure(let error):
            state = .failed(message: Self.message(for: error))
        }
    }

    // MARK: - Confirm install

    /// Install the bundle the user confirmed in the sheet.
    ///
    /// Only valid in ``State/awaitingConfirmation(_:)``; installs the exact
    /// downloaded bytes (`bundleTempURL`) — `Installer.install` re-runs the full
    /// verify + TOFU pipeline internally, so this never trusts the earlier
    /// resolve. On success the installed list is refreshed and state moves to
    /// ``State/installed(ref:)``; the caller may then offer activation.
    func confirmInstall() async {
        guard case .awaitingConfirmation(let info) = state else { return }
        state = .installing

        let bundleURL = info.bundleTempURL
        let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let layout = try InstallLayout()
                let installer = Installer(layout: layout)
                try installer.install(bundleAt: bundleURL)
                return ()
            } catch {
                throw error
            }
        }.result

        // The downloaded temp bundle is consumed either way (install moves the
        // extraction, not this file); remove it so temp doesn't accumulate.
        try? FileManager.default.removeItem(at: bundleURL)

        switch result {
        case .success:
            refresh()
            state = .installed(ref: info.ref)
        case .failure(let error):
            state = .failed(message: Self.message(for: error))
        }
    }

    /// Discard a pending confirmation without installing: drop the downloaded
    /// temp bundle and return to ``State/idle``.
    func cancelConfirmation() {
        if case .awaitingConfirmation(let info) = state {
            try? FileManager.default.removeItem(at: info.bundleTempURL)
        }
        state = .idle
    }

    /// Reset a terminal state (installed / failed) back to idle so the UI can
    /// dismiss banners and start a fresh resolve.
    func resetState() {
        state = .idle
    }

    // MARK: - List

    /// Refresh ``installedConfigs`` from `Installer.list()` (the lockfile is the
    /// source of truth). Failures leave the prior list in place and surface as a
    /// ``State/failed(message:)`` only when nothing was previously loaded, so a
    /// transient read error doesn't blank an otherwise-usable list.
    func refresh() {
        do {
            let layout = try InstallLayout()
            installedConfigs = try Installer(layout: layout).list()
        } catch {
            if installedConfigs.isEmpty {
                // First load failed — surface it; otherwise keep the stale list.
                NSLog("ValueGuard: could not list installed configs: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Activate (copy-on-activate bridge)

    /// Activate `author/slug` and bridge it to the daemon's flat policy file.
    ///
    /// 1. `Installer.activate` updates the lockfile `active` field + flips the
    ///    `configs/active` symlink atomically.
    /// 2. The activated version's `configs/<author>/<slug>/<version>/policy.bin`
    ///    is **atomically copied** over the flat ``AppSupport/policyBinURL`` the
    ///    daemon reads (write to a sibling temp, then `replaceItem`).
    /// 3. The injected ``onRestartDaemon`` closure restarts the daemon so it
    ///    reloads the new flat policy.
    ///
    /// - Throws: ``VGError`` if the config isn't installed, the version dir /
    ///   `policy.bin` is missing, or the atomic copy fails. The throw propagates
    ///   to the view (which surfaces it) *before* any restart, so a failed copy
    ///   never restarts the daemon onto a stale/half-written policy.
    func activate(author: String, slug: String) async throws {
        let restart = onRestartDaemon
        let dest = flatPolicyURL

        do {
            try await Task.detached(priority: .userInitiated) {
                let layout = try InstallLayout()
                let installer = Installer(layout: layout)

                // Update lockfile + symlink first; this also validates the
                // version dir exists (throws VGError.io if pruned out from under
                // us).
                try installer.activate(author: author, slug: slug)

                // Resolve the just-activated version's policy.bin from the layout.
                let lockedVersion = try Self.installedVersion(
                    installer: installer,
                    author: author,
                    slug: slug
                )
                let sourcePolicy = layout
                    .versionDir(author: author, slug: slug, version: lockedVersion)
                    .appendingPathComponent("policy.bin", isDirectory: false)

                guard FileManager.default.fileExists(atPath: sourcePolicy.path) else {
                    throw VGError.io(
                        "activated config is missing policy.bin at \(sourcePolicy.path)")
                }

                // Copy-on-activate: stage to a sibling temp then atomically
                // replace the daemon's flat file so it is never half-written.
                try Self.atomicCopy(from: sourcePolicy, to: dest)
            }.value
        } catch {
            // Surface to the banner AND rethrow so the caller can react.
            state = .failed(message: Self.message(for: error))
            throw error
        }

        // Restart on the main actor (the daemon host is MainActor-isolated).
        restart()
        refresh()
    }

    // MARK: - Uninstall

    /// Uninstall `author/slug` and refresh the list.
    ///
    /// Per the design, the flat `policy.bin` the daemon is currently running is
    /// **left untouched** even if it came from the config being removed: pulling
    /// the daemon's policy out from under it mid-run would stop filtering
    /// silently. The marketplace tree + lockfile entry are removed (so we stop
    /// *offering* it), but the running daemon keeps its loaded flat policy until
    /// the user activates a different config or recompiles.
    ///
    /// - Throws: ``VGError`` if the config isn't installed or the filesystem
    ///   removal fails.
    func uninstall(author: String, slug: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let layout = try InstallLayout()
            try Installer(layout: layout).uninstall(author: author, slug: slug)
        }.value
        refresh()
    }

    // MARK: - Helpers

    /// Parse an `author/slug[@version]` reference. Tolerates surrounding
    /// whitespace and a single optional `@version` suffix. Returns `nil` for any
    /// shape that isn't exactly one `author/slug` (with an optional version).
    static func parseRef(_ raw: String) -> (author: String, slug: String, version: String?)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Split off an optional @version first so a version like "1.0.0" (which
        // contains no slash) can't be mistaken for a path component.
        let refPart: Substring
        let version: String?
        if let at = trimmed.firstIndex(of: "@") {
            refPart = trimmed[trimmed.startIndex..<at]
            let v = String(trimmed[trimmed.index(after: at)...])
            version = v.isEmpty ? nil : v
        } else {
            refPart = Substring(trimmed)
            version = nil
        }

        let parts = refPart.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            return nil
        }
        return (author: parts[0], slug: parts[1], version: version)
    }

    /// Whether a registry base URL is allowed for a (possibly attacker-supplied)
    /// install request. Only `https` is permitted in general; `http` is allowed
    /// solely for loopback dev (`localhost` / `127.0.0.1` / `::1`). Critically
    /// this rejects `file://`, which `RegistryClient` otherwise supports and which
    /// would let a crafted `vgconfig://` link read arbitrary local files.
    static func isAllowedRegistryScheme(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return true
        case "http":
            let host = url.host?.lowercased()
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        default:
            return false
        }
    }

    /// Look up the on-disk installed version of `author/slug` from the lockfile
    /// (via `Installer.list()`), so copy-on-activate copies the exact version
    /// the activate just pointed at.
    ///
    /// `nonisolated` because it is pure (no actor state) and runs inside the
    /// detached activate task.
    private nonisolated static func installedVersion(
        installer: Installer,
        author: String,
        slug: String
    ) throws -> String {
        let configs = try installer.list()
        guard let match = configs.first(where: { $0.author == author && $0.slug == slug }) else {
            throw VGError.notInstalled("\(author)/\(slug)")
        }
        return match.version
    }

    /// Atomically replace `dest` with the contents of `src`.
    ///
    /// We stage to a sibling temp in the destination directory (same volume) then
    /// `rename(2)` it over `dest`. POSIX `rename` atomically replaces the target
    /// whether or not it already exists — so there is no `fileExists`→move TOCTOU
    /// window (a concurrently-created flat file can't make this fail), and no
    /// first-activation special case. This is the same atomic-swap primitive the
    /// marketplace library uses for the `configs/active` symlink. The daemon's
    /// flat `policy.bin` is never observed truncated or half-written.
    private nonisolated static func atomicCopy(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        let destDir = dest.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            throw VGError.io("could not create \(destDir.path): \(error.localizedDescription)")
        }

        let staging = destDir.appendingPathComponent(
            ".policy.bin.activate.\(UUID().uuidString)", isDirectory: false)
        do {
            // Copy the bytes to the sibling temp first.
            if fm.fileExists(atPath: staging.path) {
                try fm.removeItem(at: staging)
            }
            try fm.copyItem(at: src, to: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw VGError.io("could not stage policy.bin: \(error.localizedDescription)")
        }

        // Atomic, existence-agnostic replace via rename(2). FileManager has no
        // atomic move-with-overwrite, so drop to Darwin.
        let result = staging.withUnsafeFileSystemRepresentation { oldPtr -> Int32 in
            guard let oldPtr else { return -1 }
            return dest.withUnsafeFileSystemRepresentation { newPtr -> Int32 in
                guard let newPtr else { return -1 }
                return rename(oldPtr, newPtr)
            }
        }
        guard result == 0 else {
            let err = String(cString: strerror(errno))
            try? fm.removeItem(at: staging)
            throw VGError.io("could not install policy.bin at \(dest.path): \(err)")
        }
    }

    /// Map any thrown error to a user-facing string, preferring a `VGError`'s
    /// already-prefixed `errorDescription`.
    private static func message(for error: Error) -> String {
        if let vg = error as? VGError, let message = vg.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}
