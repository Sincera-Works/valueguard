import Foundation

/// Codable mirror of `configs/lockfile.json` (§5) — the source of truth for
/// "what is installed and why".
///
/// The on-disk directory tree under `configs/<author>/<slug>/<version>/` is a
/// cache; `lockfile.json` records which configs are installed, at which
/// version, the content-address of the bundle they came from, and the author
/// key fingerprint that signed them. `active` names the `author/slug` whose
/// version directory the `configs/active` symlink points at (the symlink and
/// this field are kept in sync by `Installer`).
///
/// JSON shape (§5):
/// ```json
/// {
///   "schema_version": 1,
///   "active": "acme/strict-personal",
///   "configs": [
///     {
///       "author": "acme",
///       "slug": "strict-personal",
///       "pin": "^1.4",
///       "installed_version": "1.4.0",
///       "installed_at": "2026-05-28T14:02:11Z",
///       "bundle_sha256": "7c2a...",
///       "author_key_fingerprint": "abc1..."
///     }
///   ]
/// }
/// ```
///
/// Snake_case wire keys are mapped via explicit `CodingKeys` (no
/// `.convertFromSnakeCase`). Writes go through `CanonicalJSON.encode` so the
/// emitted bytes are deterministic; reads use a plain `JSONDecoder` (the
/// lockfile is a file we author ourselves, never a third-party signed artifact,
/// so there is no re-canonicalization concern here).
public struct Lockfile: Codable, Sendable {

    /// Lockfile schema version. Always `1` in P0.
    public var schemaVersion: Int

    /// The currently active config as `"author/slug"`, or `nil` if none is
    /// active. Kept in sync with the `configs/active` symlink by `Installer`.
    public var active: String?

    /// One entry per installed config (an `author/slug` is installed at most
    /// once; the version it is pinned to lives in `Entry.installedVersion`).
    public var configs: [Entry]

    /// A single installed-config record.
    public struct Entry: Codable, Sendable {
        /// Author handle.
        public var author: String
        /// Config slug.
        public var slug: String
        /// SemVer pin expression (e.g. `"^1.4"`), or `nil` if pinned exactly /
        /// not managed by `vg update` (out of scope for P0).
        public var pin: String?
        /// The exact version installed on disk (the version directory name).
        public var installedVersion: String
        /// RFC3339 UTC timestamp of when this config was installed.
        public var installedAt: String
        /// Bare lowercase hex SHA256 of the entire `.vgconfig` bundle file
        /// (content address).
        public var bundleSha256: String
        /// Bare lowercase hex SHA256 of the author's raw 32-byte Ed25519 public
        /// key (full 64 hex chars).
        public var authorKeyFingerprint: String

        private enum CodingKeys: String, CodingKey {
            case author
            case slug
            case pin
            case installedVersion = "installed_version"
            case installedAt = "installed_at"
            case bundleSha256 = "bundle_sha256"
            case authorKeyFingerprint = "author_key_fingerprint"
        }

        public init(
            author: String,
            slug: String,
            pin: String?,
            installedVersion: String,
            installedAt: String,
            bundleSha256: String,
            authorKeyFingerprint: String
        ) {
            self.author = author
            self.slug = slug
            self.pin = pin
            self.installedVersion = installedVersion
            self.installedAt = installedAt
            self.bundleSha256 = bundleSha256
            self.authorKeyFingerprint = authorKeyFingerprint
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case active
        case configs
    }

    public init(schemaVersion: Int = 1, active: String? = nil, configs: [Entry] = []) {
        self.schemaVersion = schemaVersion
        self.active = active
        self.configs = configs
    }

    /// Load the lockfile at `url`.
    ///
    /// If the file is absent, returns an empty lockfile
    /// (`{schema_version: 1, active: nil, configs: []}`) rather than throwing —
    /// a fresh install root has no lockfile yet.
    ///
    /// - Throws: `VGError.io` if the file exists but cannot be read or decoded.
    public static func load(_ url: URL) throws -> Lockfile {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Lockfile()
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VGError.io("could not read lockfile at \(url.path): \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(Lockfile.self, from: data)
        } catch {
            throw VGError.io("could not decode lockfile at \(url.path): \(error.localizedDescription)")
        }
    }

    /// Write the lockfile to `url` using `CanonicalJSON.encode` (deterministic
    /// sorted-key, slash-unescaped JSON).
    ///
    /// - Throws: `VGError.io` if encoding or the atomic write fails.
    public func save(to url: URL) throws {
        let data = try CanonicalJSON.encode(self)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw VGError.io("could not write lockfile at \(url.path): \(error.localizedDescription)")
        }
    }

    /// Return the entry for `author/slug`, or `nil` if not installed.
    public func entry(author: String, slug: String) -> Entry? {
        guard let i = index(author: author, slug: slug) else { return nil }
        return configs[i]
    }

    /// Return the index of the entry for `author/slug` in `configs`, or `nil`
    /// if not present.
    public func index(author: String, slug: String) -> Int? {
        return configs.firstIndex { $0.author == author && $0.slug == slug }
    }
}
