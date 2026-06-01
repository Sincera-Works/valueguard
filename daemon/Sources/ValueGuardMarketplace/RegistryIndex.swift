import Foundation

/// Codable mirror of the static registry `index.json` schema (§6.2).
///
/// The registry is a static file tree served over HTTPS (object storage + CDN)
/// or, in tests and offline use, over a `file://` base URL. `index.json` is the
/// catalog: a list of configs, each carrying its metadata and a newest-first
/// list of versions, where every version names its content-addressed bundle path
/// and the bundle's sha256. A client resolves `author/slug[@version]` against
/// this document, fetches the named bundle blob, and runs the **exact same**
/// offline verify pipeline as a local install (see ``RegistryClient``).
///
/// Like ``Manifest``, property names are camelCase for Swift idiom but every type
/// declares explicit `CodingKeys` mapping to the exact snake_case wire keys, and
/// decoding uses a plain `JSONDecoder` with **no** key-conversion strategy — the
/// shared schema (the web frontend consumes the same shape) is the single source
/// of truth, so there is no heuristic name munging. `index.json` is *not* a
/// signed artifact (trust derives from the per-bundle signature and content
/// address, not from the index), so the index itself only needs to decode
/// structurally; the per-version `bundle_sha256` is what the client enforces.
///
/// ## Path resolution
/// Every `*_path` field (`bundle_path`, `manifest_path`) is **relative** to the
/// registry base URL. The client resolves each against the base; this file only
/// models the wire shape and never resolves paths itself.
public struct RegistryIndex: Codable, Sendable {
    /// `schema_version` — `1` for the shape modeled here.
    public let schemaVersion: Int
    /// `generated_at` — RFC 3339 UTC timestamp of the last reindex.
    public let generatedAt: String
    /// `registry` — descriptive metadata about the registry instance.
    public let registry: RegistryInfo
    /// `configs` — the catalog, one entry per `author/slug`.
    public let configs: [Config]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case registry
        case configs
    }

    public init(schemaVersion: Int, generatedAt: String, registry: RegistryInfo, configs: [Config]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.registry = registry
        self.configs = configs
    }

    /// `registry` block — descriptive metadata (display name today; room for a
    /// homepage / contact later without a schema bump).
    public struct RegistryInfo: Codable, Sendable {
        /// Human-readable registry name (e.g. `"ValueGuard Configs"`).
        public let name: String

        public init(name: String) {
            self.name = name
        }

        private enum CodingKeys: String, CodingKey {
            case name
        }
    }

    /// One catalog entry: a single `author/slug` with all its published versions.
    public struct Config: Codable, Sendable {
        /// Author handle (`manifest.author.handle`).
        public let author: String
        /// Config slug (`manifest.config_id`).
        public let slug: String
        /// Display name of the latest version.
        public let name: String
        /// Description of the latest version.
        public let description: String
        /// `latest_version` — the highest non-prerelease SemVer in ``versions``.
        public let latestVersion: String
        /// SPDX license identifier of the latest version.
        public let license: String
        /// Tags of the latest version (may be empty).
        public let tags: [String]
        /// `verified` — registry-counter-signed badge. Always `false` in the
        /// prototype (there is no pinned registry key yet).
        public let verified: Bool
        /// `author_fingerprint` — bare lowercase SHA-256 hex of the author's raw
        /// 32-byte Ed25519 public key, as derived by the verifier.
        public let authorFingerprint: String
        /// Published versions, **newest-first** (descending SemVer).
        public let versions: [Version]

        private enum CodingKeys: String, CodingKey {
            case author
            case slug
            case name
            case description
            case latestVersion = "latest_version"
            case license
            case tags
            case verified
            case authorFingerprint = "author_fingerprint"
            case versions
        }

        public init(
            author: String,
            slug: String,
            name: String,
            description: String,
            latestVersion: String,
            license: String,
            tags: [String],
            verified: Bool,
            authorFingerprint: String,
            versions: [Version]
        ) {
            self.author = author
            self.slug = slug
            self.name = name
            self.description = description
            self.latestVersion = latestVersion
            self.license = license
            self.tags = tags
            self.verified = verified
            self.authorFingerprint = authorFingerprint
            self.versions = versions
        }
    }

    /// One published version of a config.
    public struct Version: Codable, Sendable {
        /// SemVer version string.
        public let version: String
        /// `created_at` — RFC 3339 UTC, copied from the bundle's manifest.
        public let createdAt: String
        /// `bundle_sha256` — bare lowercase 64-hex of the whole `.vgconfig` file.
        /// The client re-hashes the downloaded bytes and refuses to hand off any
        /// download whose digest does not equal this value.
        public let bundleSha256: String
        /// `bundle_path` — relative path of the content-addressed bundle blob
        /// (`bundles/<sha256>.vgconfig`), resolved against the registry base.
        public let bundlePath: String
        /// `manifest_path` — relative path of the extracted `manifest.json`
        /// (`configs/<author>/<slug>/<version>/manifest.json`), resolved against
        /// the registry base. For web/preview use; the client does not need it
        /// to install (the bundle carries its own manifest).
        public let manifestPath: String
        /// `size_bytes` — size of the bundle blob in bytes (display / progress).
        public let sizeBytes: Int
        /// `categories` — per-category `{id, action}` summary (for listing UIs).
        public let categories: [CategorySummary]

        private enum CodingKeys: String, CodingKey {
            case version
            case createdAt = "created_at"
            case bundleSha256 = "bundle_sha256"
            case bundlePath = "bundle_path"
            case manifestPath = "manifest_path"
            case sizeBytes = "size_bytes"
            case categories
        }

        public init(
            version: String,
            createdAt: String,
            bundleSha256: String,
            bundlePath: String,
            manifestPath: String,
            sizeBytes: Int,
            categories: [CategorySummary]
        ) {
            self.version = version
            self.createdAt = createdAt
            self.bundleSha256 = bundleSha256
            self.bundlePath = bundlePath
            self.manifestPath = manifestPath
            self.sizeBytes = sizeBytes
            self.categories = categories
        }
    }

    /// One entry of a version's `categories` summary array: the category id and
    /// the action the config takes on it (`log` | `blur` | `block`).
    public struct CategorySummary: Codable, Sendable {
        /// Category id.
        public let id: String
        /// `log` | `blur` | `block`.
        public let action: String

        private enum CodingKeys: String, CodingKey {
            case id
            case action
        }

        public init(id: String, action: String) {
            self.id = id
            self.action = action
        }
    }

    // MARK: - Decode

    /// Decode a `RegistryIndex` from raw `index.json` bytes.
    ///
    /// Uses a plain `JSONDecoder` with **no** key-conversion strategy (the
    /// explicit `CodingKeys` are the sole wire mapping). On failure the underlying
    /// `DecodingError` is unpacked into a human-readable message (offending key +
    /// coding path) and re-thrown as ``VGError/notFound`` — the same idiom
    /// ``Manifest/decode(from:)`` uses for `manifest.json`, so the CLI surfaces a
    /// precise "where in index.json" message rather than an opaque Foundation
    /// error.
    public static func decode(from data: Data) throws -> RegistryIndex {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(RegistryIndex.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw VGError.notFound("index.json: missing key '\(key.stringValue)'\(pathSuffix(ctx))")
        } catch let DecodingError.typeMismatch(type, ctx) {
            throw VGError.notFound("index.json: expected \(type)\(pathSuffix(ctx))")
        } catch let DecodingError.valueNotFound(type, ctx) {
            throw VGError.notFound("index.json: missing value of type \(type)\(pathSuffix(ctx))")
        } catch let DecodingError.dataCorrupted(ctx) {
            let path = codingPathString(ctx.codingPath)
            let where_ = path.isEmpty ? "" : " at \(path)"
            throw VGError.notFound("index.json: \(ctx.debugDescription)\(where_)")
        } catch {
            throw VGError.notFound("index.json: \(error.localizedDescription)")
        }
    }

    /// Render a `DecodingError.Context`'s coding path as a `" at a.b.c"` suffix
    /// (empty string when the path is the document root).
    private static func pathSuffix(_ ctx: DecodingError.Context) -> String {
        let path = codingPathString(ctx.codingPath)
        return path.isEmpty ? "" : " at \(path)"
    }

    /// Join a coding path into a dotted string, rendering array indices as `[n]`
    /// so e.g. `configs[0].versions[1].bundle_sha256` reads naturally.
    private static func codingPathString(_ codingPath: [CodingKey]) -> String {
        var out = ""
        for key in codingPath {
            if let idx = key.intValue {
                out += "[\(idx)]"
            } else {
                if !out.isEmpty { out += "." }
                out += key.stringValue
            }
        }
        return out
    }
}
