import Foundation

/// Owns every on-disk path under the local config install tree
/// (`~/Library/Application Support/ValueGuard/configs`).
///
/// The install layout (§5) is:
///
/// ```
/// ~/Library/Application Support/ValueGuard/configs/
///   active                      -> <author>/<slug>/<version>   (relative symlink)
///   lockfile.json
///   known_keys.json
///   <author>/<slug>/<version>/  manifest.json, policy.bin, policy.json,
///                               calibration.json, signatures/, [optionals…]
/// ```
///
/// The app-support root is resolved inline with `FileManager`, replicating the
/// pattern in `AuditLog.swift` (no shared helper exists in the codebase). The
/// resolution + directory-creation lives in the throwing `init()`; the
/// `init(configsDir:)` form takes an explicit root so tests can point the whole
/// layout at a temporary directory without touching the user's real
/// Application Support folder. For the same purpose *at the command line*, the
/// throwing `init()` honours the `VALUEGUARD_CONFIGS_DIR` environment variable —
/// see that initializer.
///
/// This type is purely path arithmetic: it never reads or writes the lockfile,
/// known-keys cache, or any version directory — those are owned by `Lockfile`,
/// `KnownKeys`, and `Installer`. It only guarantees that `configsDir` exists.
public struct InstallLayout: Sendable {
    /// The name of the environment variable that overrides the configs root.
    ///
    /// When set to a non-empty value, the throwing ``init()`` uses it verbatim
    /// (tilde-expanded) as the `configs/` root instead of
    /// `~/Library/Application Support/ValueGuard/configs/`. This lets the `vg`
    /// CLI's install / activate / uninstall flows be exercised against a throwaway
    /// directory (e.g. `VALUEGUARD_CONFIGS_DIR=/tmp/vg-proto-configs vg install …`)
    /// without ever touching the user's real Application Support tree.
    public static let configsDirEnvVar = "VALUEGUARD_CONFIGS_DIR"

    /// The root of the config install tree: `.../ValueGuard/configs`.
    public let configsDir: URL

    /// Resolves the config install tree and ensures it exists — either the real
    /// Application Support location or the `VALUEGUARD_CONFIGS_DIR` override.
    ///
    /// If `VALUEGUARD_CONFIGS_DIR` is set to a non-empty value, that path (with a
    /// leading `~` expanded) becomes the `configs/` root; it is created with
    /// intermediate directories. This is the CLI / scripting escape hatch for
    /// exercising the install lifecycle off the real tree.
    ///
    /// Otherwise this mirrors `AuditLog.swift`:
    /// `FileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, …,
    /// create: true)` → `appendingPathComponent("ValueGuard")` →
    /// `appendingPathComponent("configs")`, then `createDirectory(…,
    /// withIntermediateDirectories: true)`.
    ///
    /// - Throws: `VGError.io` if the Application Support directory cannot be
    ///   located or the `configs` directory (real or override) cannot be created.
    public init() throws {
        // CLI / test escape hatch: an explicit override directory.
        if let override = ProcessInfo.processInfo.environment[Self.configsDirEnvVar],
           !override.isEmpty {
            let root = URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            )
            do {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true
                )
            } catch {
                throw VGError.io("could not create \(Self.configsDirEnvVar) directory at \(root.path): \(error.localizedDescription)")
            }
            self.configsDir = root
            return
        }

        let supportDir: URL
        do {
            supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("ValueGuard", isDirectory: true)
            .appendingPathComponent("configs", isDirectory: true)
        } catch {
            throw VGError.io("could not locate Application Support directory: \(error.localizedDescription)")
        }
        do {
            try FileManager.default.createDirectory(
                at: supportDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw VGError.io("could not create configs directory at \(supportDir.path): \(error.localizedDescription)")
        }
        self.configsDir = supportDir
    }

    /// Builds a layout rooted at an explicit `configs` directory.
    ///
    /// Used by tests to drive `install`/`activate`/`uninstall` against a
    /// throwaway temp root. Unlike `init()`, this does **not** create the
    /// directory — the caller (or `Installer`) is responsible for ensuring it
    /// exists when needed.
    public init(configsDir: URL) {
        self.configsDir = configsDir
    }

    /// The `configs/active` symlink path (the relative target is set by
    /// `Installer.activate`). May or may not exist on disk.
    public var activeSymlink: URL {
        configsDir.appendingPathComponent("active", isDirectory: false)
    }

    /// The `configs/lockfile.json` path (source of truth for installed configs).
    public var lockfileURL: URL {
        configsDir.appendingPathComponent("lockfile.json", isDirectory: false)
    }

    /// The `configs/known_keys.json` path (TOFU key cache).
    public var knownKeysURL: URL {
        configsDir.appendingPathComponent("known_keys.json", isDirectory: false)
    }

    /// The directory holding a single installed version's artifacts:
    /// `configs/<author>/<slug>/<version>/`.
    public func versionDir(author: String, slug: String, version: String) -> URL {
        slugDir(author: author, slug: slug)
            .appendingPathComponent(version, isDirectory: true)
    }

    /// The directory holding all installed versions of one config:
    /// `configs/<author>/<slug>/`.
    public func slugDir(author: String, slug: String) -> URL {
        configsDir
            .appendingPathComponent(author, isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
    }

    /// The relative symlink target for `configs/active`, i.e.
    /// `"<author>/<slug>/<version>"`. Relative (not absolute) so the active
    /// symlink stays valid if the whole `configs` tree is moved, and so the
    /// target is independent of where the temp/real root lives.
    public func relativeTarget(author: String, slug: String, version: String) -> String {
        "\(author)/\(slug)/\(version)"
    }
}
