import Foundation
import Darwin

import ValueGuardCore

/// A single installed config as reported by ``Installer/list()`` — a flattened
/// view over the lockfile (the source of truth) joined with the resolved
/// `configs/active` symlink to mark which one is active.
public struct InstalledConfig: Sendable {
    /// Author handle (`manifest.author.handle`).
    public let author: String
    /// Config slug (`manifest.config_id`).
    public let slug: String
    /// The exact installed version on disk.
    public let version: String
    /// Whether this config is the currently active one.
    public let active: Bool
    /// SemVer pin expression, or `nil` (P0 never sets a pin — `vg update` is out
    /// of scope — so this is always `nil` for freshly installed configs).
    public let pin: String?
    /// RFC3339 UTC timestamp recorded at install time.
    public let installedAt: String
    /// Bare lowercase hex SHA-256 of the author's raw 32-byte Ed25519 key.
    public let fingerprint: String

    public init(
        author: String,
        slug: String,
        version: String,
        active: Bool,
        pin: String?,
        installedAt: String,
        fingerprint: String
    ) {
        self.author = author
        self.slug = slug
        self.version = version
        self.active = active
        self.pin = pin
        self.installedAt = installedAt
        self.fingerprint = fingerprint
    }
}

/// Performs the on-disk lifecycle operations for installed config bundles
/// against an ``InstallLayout``: `install`, `list`, `activate`, `uninstall`,
/// plus the `current()` helper that resolves the active symlink.
///
/// The lockfile (`configs/lockfile.json`) is the source of truth for "what is
/// installed and why"; the `configs/<author>/<slug>/<version>/` directory tree
/// is the cache. `known_keys.json` is the TOFU author-key cache. `Installer`
/// keeps all three consistent.
///
/// The atomic `activate` swap lives here: it creates a temporary relative
/// symlink in `configs/` and `rename(2)`s it over `configs/active`, so the
/// active path is always a valid symlink with no missing-link window.
public struct Installer {
    /// The install layout this installer operates on.
    public let layout: InstallLayout

    public init(layout: InstallLayout) {
        self.layout = layout
    }

    // MARK: - Install

    /// Verify a `.vgconfig`, TOFU-check its author key, and install it into the
    /// local layout (§5).
    ///
    /// Steps:
    /// 1. Run the full offline verification (`BundleVerifier.verify`). If any
    ///    check fails, the install is refused and the temp extraction is removed.
    /// 2. Derive the install coordinates (`author = manifest.author.handle`,
    ///    `slug = manifest.config_id`, `version = manifest.version`).
    /// 3. Immutability (§2): refuse if the exact `author/slug/version` directory
    ///    already exists on disk (`VGError.alreadyInstalled`).
    /// 4. TOFU (§5/§7): refuse if the author handle is already trusted with a
    ///    *different* key (`VGError.keyChanged`); record the key on first use.
    /// 5. Move the validated extraction into `configs/<author>/<slug>/<version>/`.
    /// 6. Commit bookkeeping: pin the author key in `known_keys.json` first, then
    ///    upsert the `lockfile.json` entry (the TOFU pin must be at least as
    ///    durable as the lockfile entry; §5/§7).
    ///
    /// The on-disk tree and both JSON files are only mutated after every check
    /// (verification, immutability, TOFU) has passed, so a refused install
    /// leaves the layout untouched. If a *post-move* bookkeeping step fails, the
    /// move (and any slug directory this install created) is rolled back so a
    /// failed install is a true no-op on disk — never an orphaned, unremovable
    /// version directory.
    ///
    /// - Returns: the installed `(author, slug, version)` coordinates.
    /// - Throws: `VGError` on verification failure, immutability violation, TOFU
    ///   key change, or any filesystem error.
    @discardableResult
    public func install(bundleAt url: URL) throws -> (author: String, slug: String, version: String) {
        // 1. Verify. On success we own the returned temp `extractedDir`; on any
        //    later failure we must remove it so we never leak the extraction.
        let (report, extractedDir) = try BundleVerifier.verify(bundleAt: url)

        func cleanup() {
            try? FileManager.default.removeItem(at: extractedDir)
        }

        guard report.allPassed else {
            cleanup()
            let failed = report.checks.filter { !$0.ok }.map { check -> String in
                if let detail = check.detail {
                    return "\(check.label): \(detail)"
                }
                return check.label
            }
            throw VGError.signatureInvalid(
                "bundle verification failed: " + failed.joined(separator: "; ")
            )
        }

        let manifest = report.manifest
        let author = manifest.author.handle
        let slug = manifest.configId
        let version = manifest.version

        let versionDir = layout.versionDir(author: author, slug: slug, version: version)

        // 3. Immutability — republishing the same version is an error (§2).
        if FileManager.default.fileExists(atPath: versionDir.path) {
            cleanup()
            throw VGError.alreadyInstalled("\(author)/\(slug)@\(version)")
        }

        // 4. TOFU key check against known_keys.json.
        var knownKeys: KnownKeys
        do {
            knownKeys = try KnownKeys.load(layout.knownKeysURL)
        } catch {
            cleanup()
            throw error
        }
        switch knownKeys.check(handle: author, fingerprint: report.authorFingerprint) {
        case .firstUse, .matches:
            break
        case .changed(let oldFingerprint):
            cleanup()
            throw VGError.keyChanged(
                handle: author,
                oldFingerprint: oldFingerprint,
                newFingerprint: report.authorFingerprint
            )
        }

        // 5. Move the validated extraction into place. Ensure the slug directory
        //    (and the configs root, for the explicit-temp-root test case) exists,
        //    then move the temp extraction to the version directory. Move is
        //    preferred over copy so the operation is a cheap rename within the
        //    same volume when possible; if the temp dir is on a different volume,
        //    FileManager.moveItem falls back to copy+remove.
        //
        //    Track whether *this* install created the slug directory: if so, and
        //    a later bookkeeping step fails, rollback removes the now-empty slug
        //    dir too, leaving the layout exactly as we found it.
        let slugDir = layout.slugDir(author: author, slug: slug)
        let slugDirPreexisted = FileManager.default.fileExists(atPath: slugDir.path)
        do {
            try FileManager.default.createDirectory(
                at: slugDir,
                withIntermediateDirectories: true
            )
        } catch {
            cleanup()
            throw VGError.io("could not create install directory at \(slugDir.path): \(error.localizedDescription)")
        }
        do {
            try FileManager.default.moveItem(at: extractedDir, to: versionDir)
        } catch {
            cleanup()
            throw VGError.io("could not move config into place at \(versionDir.path): \(error.localizedDescription)")
        }

        // From here the on-disk version dir exists but is not yet recorded in
        // either bookkeeping file. If any subsequent step throws (or the process
        // dies mid-write), the version dir would be orphaned: present on disk but
        // absent from the lockfile, so `vg uninstall` — which requires a lockfile
        // entry — could never remove it. To keep a failed install a true no-op on
        // disk, undo the move (and the slug dir if we just created it empty)
        // before rethrowing.
        func rollbackMove() {
            try? FileManager.default.removeItem(at: versionDir)
            // Only remove the slug dir if this install created it and it is now
            // empty (no other versions of this config were already installed).
            if !slugDirPreexisted {
                let contents = (try? FileManager.default.contentsOfDirectory(atPath: slugDir.path)) ?? []
                if contents.isEmpty {
                    try? FileManager.default.removeItem(at: slugDir)
                }
            }
        }

        // 6. Commit bookkeeping. TOFU ordering (§5/§7): the known_keys pin must be
        //    at least as durable as the lockfile entry — an installed-but-unpinned
        //    config would defeat the key-change protection — so the pin is written
        //    and flushed to disk *before* the lockfile entry. Any failure (or a
        //    crash) at the lockfile step then leaves at most a pinned-but-not-yet-
        //    installed key, which is the safe direction; on the lockfile write
        //    failure here we additionally restore the prior known_keys bytes so
        //    the two stay consistent, and roll the moved tree back.
        let now = Installer.rfc3339UTCNow()

        var lockfile: Lockfile
        do {
            lockfile = try Lockfile.load(layout.lockfileURL)
        } catch {
            rollbackMove()
            throw error
        }

        // Snapshot the prior known_keys bytes so a later lockfile failure can
        // restore the pin to exactly its pre-install state (nil = file absent).
        let priorKnownKeysData = try? Data(contentsOf: layout.knownKeysURL)

        // Pin the TOFU key first (durable before the lockfile entry).
        knownKeys.record(
            handle: author,
            publicKeyBase64: manifest.author.publicKey,
            fingerprint: report.authorFingerprint,
            now: now
        )
        do {
            try knownKeys.save(to: layout.knownKeysURL)
        } catch {
            rollbackMove()
            throw error
        }

        func restoreKnownKeys() {
            if let priorKnownKeysData {
                try? priorKnownKeysData.write(to: layout.knownKeysURL, options: [.atomic])
            } else {
                // The file did not exist before this install (first-ever key).
                try? FileManager.default.removeItem(at: layout.knownKeysURL)
            }
        }

        let entry = Lockfile.Entry(
            author: author,
            slug: slug,
            pin: nil,
            installedVersion: version,
            installedAt: now,
            bundleSha256: report.bundleSha256,
            authorKeyFingerprint: report.authorFingerprint
        )
        if let i = lockfile.index(author: author, slug: slug) {
            lockfile.configs[i] = entry
        } else {
            lockfile.configs.append(entry)
        }
        do {
            try lockfile.save(to: layout.lockfileURL)
        } catch {
            restoreKnownKeys()
            rollbackMove()
            throw error
        }

        return (author, slug, version)
    }

    // MARK: - List

    /// List installed configs from the lockfile (the source of truth), marking
    /// the active one by resolving the `configs/active` symlink.
    ///
    /// - Throws: `VGError.io` if the lockfile cannot be read/decoded.
    public func list() throws -> [InstalledConfig] {
        let lockfile = try Lockfile.load(layout.lockfileURL)
        let activeRef = try resolveActiveRef()
        return lockfile.configs.map { entry in
            let isActive = activeRef.map { $0.author == entry.author && $0.slug == entry.slug } ?? false
            return InstalledConfig(
                author: entry.author,
                slug: entry.slug,
                version: entry.installedVersion,
                active: isActive,
                pin: entry.pin,
                installedAt: entry.installedAt,
                fingerprint: entry.authorKeyFingerprint
            )
        }
    }

    // MARK: - Activate

    /// Activate `author/slug` by atomically pointing `configs/active` at its
    /// installed version directory.
    ///
    /// The swap is atomic: a temporary symlink with the relative target
    /// `"<author>/<slug>/<version>"` is created inside `configs/`, then
    /// `rename(2)`'d over `configs/active`. Because `rename(2)` is atomic on the
    /// same filesystem, `configs/active` is always either the old valid symlink
    /// or the new valid symlink — never missing. Re-activating the already-active
    /// config is idempotent (it points the symlink at the same target).
    ///
    /// The lockfile's `active` field is updated to `"author/slug"` to stay in
    /// sync with the symlink.
    ///
    /// - Throws: `VGError.notInstalled` if `author/slug` is not in the lockfile;
    ///   `VGError.io` if the version directory is missing or the symlink swap
    ///   fails.
    public func activate(author: String, slug: String) throws {
        var lockfile = try Lockfile.load(layout.lockfileURL)
        guard let entry = lockfile.entry(author: author, slug: slug) else {
            throw VGError.notInstalled("\(author)/\(slug)")
        }
        let version = entry.installedVersion

        // The target directory must actually exist (the cache could have been
        // pruned out from under the lockfile).
        let versionDir = layout.versionDir(author: author, slug: slug, version: version)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: versionDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw VGError.io("cannot activate: missing installed version directory at \(versionDir.path)")
        }

        let relativeTarget = layout.relativeTarget(author: author, slug: slug, version: version)

        // Create a temp symlink in configs/ pointing at the relative target,
        // then atomically rename it over configs/active.
        let tmpLink = layout.configsDir
            .appendingPathComponent(".active.\(UUID().uuidString)", isDirectory: false)
        // Defensive: clear any stale temp link (UUID collision is effectively
        // impossible, but createSymbolicLink fails if the path exists).
        try? FileManager.default.removeItem(at: tmpLink)
        do {
            try FileManager.default.createSymbolicLink(
                atPath: tmpLink.path,
                withDestinationPath: relativeTarget
            )
        } catch {
            throw VGError.io("could not create temporary active symlink: \(error.localizedDescription)")
        }

        // POSIX rename(2): atomic same-filesystem replace. FileManager has no
        // atomic symlink-replace, so we drop to Darwin.
        let result = tmpLink.withUnsafeFileSystemRepresentation { oldPtr -> Int32 in
            guard let oldPtr else { return -1 }
            return layout.activeSymlink.withUnsafeFileSystemRepresentation { newPtr -> Int32 in
                guard let newPtr else { return -1 }
                return rename(oldPtr, newPtr)
            }
        }
        guard result == 0 else {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tmpLink)
            throw VGError.io("could not atomically swap active symlink: \(err)")
        }

        // Keep the lockfile's active field in sync with the symlink.
        let activeRef = "\(author)/\(slug)"
        if lockfile.active != activeRef {
            lockfile.active = activeRef
            try lockfile.save(to: layout.lockfileURL)
        }
    }

    // MARK: - Uninstall

    /// Uninstall `author/slug`: remove its directory tree, drop its lockfile
    /// entry, and clear `configs/active` (and the lockfile `active` field) if it
    /// pointed at this config.
    ///
    /// - Throws: `VGError.notInstalled` if `author/slug` is not in the lockfile;
    ///   `VGError.io` on a filesystem failure.
    public func uninstall(author: String, slug: String) throws {
        var lockfile = try Lockfile.load(layout.lockfileURL)
        guard lockfile.index(author: author, slug: slug) != nil else {
            throw VGError.notInstalled("\(author)/\(slug)")
        }

        // If this config is active, remove the active symlink first so we never
        // leave a dangling symlink pointing into a removed tree.
        let wasActive = (try resolveActiveRef()).map { $0.author == author && $0.slug == slug } ?? false
        if wasActive {
            try? FileManager.default.removeItem(at: layout.activeSymlink)
        }

        // Remove the slug directory tree (all installed versions of this config).
        let slugDir = layout.slugDir(author: author, slug: slug)
        if FileManager.default.fileExists(atPath: slugDir.path) {
            do {
                try FileManager.default.removeItem(at: slugDir)
            } catch {
                throw VGError.io("could not remove config tree at \(slugDir.path): \(error.localizedDescription)")
            }
        }

        // Drop the lockfile entry and clear active if it named this config.
        if let i = lockfile.index(author: author, slug: slug) {
            lockfile.configs.remove(at: i)
        }
        if lockfile.active == "\(author)/\(slug)" {
            lockfile.active = nil
        }
        try lockfile.save(to: layout.lockfileURL)
    }

    // MARK: - Current

    /// Resolve the currently active config by reading the `configs/active`
    /// symlink target and joining it back to the lockfile entry.
    ///
    /// Returns `nil` if there is no active symlink, the symlink cannot be parsed
    /// into `author/slug/version`, or the lockfile has no matching entry.
    ///
    /// - Throws: `VGError.io` if the lockfile cannot be read/decoded.
    public func current() throws -> InstalledConfig? {
        guard let ref = try resolveActiveRef() else { return nil }
        let lockfile = try Lockfile.load(layout.lockfileURL)
        guard let entry = lockfile.entry(author: ref.author, slug: ref.slug) else { return nil }
        return InstalledConfig(
            author: entry.author,
            slug: entry.slug,
            version: entry.installedVersion,
            active: true,
            pin: entry.pin,
            installedAt: entry.installedAt,
            fingerprint: entry.authorKeyFingerprint
        )
    }

    // MARK: - Private helpers

    /// Read the `configs/active` symlink and parse its relative target
    /// (`"author/slug/version"`) into components. Returns `nil` when the symlink
    /// is absent or malformed (rather than throwing) so callers can treat "no
    /// active config" uniformly.
    private func resolveActiveRef() throws -> (author: String, slug: String, version: String)? {
        let activePath = layout.activeSymlink.path
        // destinationOfSymbolicLink reads the link target without following it;
        // it throws if `active` is not a symlink / does not exist.
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: activePath) else {
            return nil
        }
        // The target is the relative POSIX string "author/slug/version".
        let parts = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else {
            return nil
        }
        return (author: parts[0], slug: parts[1], version: parts[2])
    }

    /// Current time as an RFC3339 UTC timestamp with a `Z` terminator and no
    /// offset (e.g. `2026-05-28T14:02:11Z`) — the form §2/§5 require for
    /// `created_at` / `installed_at`. No fractional seconds.
    private static func rfc3339UTCNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
