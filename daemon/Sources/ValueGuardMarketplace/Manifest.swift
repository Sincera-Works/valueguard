import Foundation

/// Codable mirror of the §2 `manifest.json` schema.
///
/// Property names are camelCase for Swift idiom, but every type declares
/// explicit `CodingKeys` that map to the exact snake_case wire keys. We do
/// **not** use `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase`:
/// the manifest is a signed artifact, so decoding (and the test-only
/// encoding) must round-trip byte-for-byte against the keys defined in the
/// spec, with no heuristic name munging.
///
/// `Manifest` only models structure and types. The §2 "field-by-field rules"
/// table (regex, ranges, enums, SemVer/RFC3339 shape) is enforced separately
/// by `ManifestValidator` over a decoded value, and the cryptographic /
/// hash cross-checks live in `BundleVerifier`. Decoding here succeeds for any
/// JSON that is structurally well-formed against the schema.
///
/// `calibration_summary` is decoded leniently: §2 only sketches its inner
/// fields, and P0 validates that `calibration.json` exists, hashes correctly,
/// and is valid JSON — never the internal semantics of the summary. Only the
/// two fields the spec names explicitly are surfaced, and both are optional.
public struct Manifest: Codable, Sendable {
    /// `schema_version` — exactly `1` for now (range enforced by the validator).
    public let schemaVersion: Int
    /// `config_id` — slug under the author namespace.
    public let configId: String
    /// Human-readable display name.
    public let name: String
    /// Plain-text description.
    public let description: String
    /// Authorship and the Ed25519 public key the bundle is signed with.
    public let author: Author
    /// SPDX-style license identifier (`LicenseRef-...` allowed).
    public let license: String
    /// SemVer 2.0 string (prerelease allowed, no build metadata).
    public let version: String
    /// `created_at` — RFC 3339 UTC, `Z` suffix, no numeric offset.
    public let createdAt: String
    /// Reference to the vision model the policy was compiled against.
    public let modelRef: ModelRef
    /// `policy_hash` — `"sha256:<hex>"` of the bundled `policy.bin`.
    public let policyHash: String
    /// `policy_json_hash` — `"sha256:<hex>"` of the bundled `policy.json`.
    public let policyJsonHash: String
    /// `calibration_hash` — `"sha256:<hex>"` of the bundled `calibration.json`.
    public let calibrationHash: String
    /// Per-category threshold + action, cross-checked against `policy.bin`.
    public let thresholds: [ThresholdEntry]
    /// `calibration_method` — one of the §2 enum values.
    public let calibrationMethod: String
    /// `calibration_summary` — optional, decoded opaquely (see type docs).
    public let calibrationSummary: CalibrationSummary?
    /// Per-category action + short description (subset of the full policy).
    public let categories: [CategoryEntry]
    /// Daemon / policy.bin compatibility window.
    public let compatibility: Compatibility
    /// `fork_of` — present only when this config derives from another.
    public let forkOf: ForkRef?
    /// Optional tags (≤ 8, validated by `ManifestValidator`).
    public let tags: [String]?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case configId = "config_id"
        case name
        case description
        case author
        case license
        case version
        case createdAt = "created_at"
        case modelRef = "model_ref"
        case policyHash = "policy_hash"
        case policyJsonHash = "policy_json_hash"
        case calibrationHash = "calibration_hash"
        case thresholds
        case calibrationMethod = "calibration_method"
        case calibrationSummary = "calibration_summary"
        case categories
        case compatibility
        case forkOf = "fork_of"
        case tags
    }

    /// `author` block.
    public struct Author: Codable, Sendable {
        /// `handle` — author namespace (`^[a-z0-9][a-z0-9-]{1,38}$`).
        public let handle: String
        /// `display_name` — optional human-facing label.
        public let displayName: String?
        /// `verified` — `false` unless the registry counter-signs.
        public let verified: Bool
        /// `public_key` — base64 of the raw 32-byte Ed25519 public key.
        public let publicKey: String

        public init(handle: String, displayName: String?, verified: Bool, publicKey: String) {
            self.handle = handle
            self.displayName = displayName
            self.verified = verified
            self.publicKey = publicKey
        }

        private enum CodingKeys: String, CodingKey {
            case handle
            case displayName = "display_name"
            case verified
            case publicKey = "public_key"
        }
    }

    /// `model_ref` block.
    public struct ModelRef: Codable, Sendable {
        /// `family` — model family identifier (e.g. `siglip2-base-patch16-256`).
        public let family: String
        /// `huggingface_id` — optional source model id.
        public let huggingfaceId: String?
        /// `weights_sha256` — hex digest of the HF safetensors (shape-checked only in P0).
        public let weightsSha256: String
        /// `coreml_package_sha256` — hex digest of the local CoreML conversion output.
        public let coremlPackageSha256: String
        /// `input_resolution` — optional square input edge in pixels.
        public let inputResolution: Int?
        /// `embedding_dim` — must equal `policy.bin` embed dim (cross-checked).
        public let embeddingDim: Int

        public init(family: String, huggingfaceId: String?, weightsSha256: String, coremlPackageSha256: String, inputResolution: Int?, embeddingDim: Int) {
            self.family = family
            self.huggingfaceId = huggingfaceId
            self.weightsSha256 = weightsSha256
            self.coremlPackageSha256 = coremlPackageSha256
            self.inputResolution = inputResolution
            self.embeddingDim = embeddingDim
        }

        private enum CodingKeys: String, CodingKey {
            case family
            case huggingfaceId = "huggingface_id"
            case weightsSha256 = "weights_sha256"
            case coremlPackageSha256 = "coreml_package_sha256"
            case inputResolution = "input_resolution"
            case embeddingDim = "embedding_dim"
        }
    }

    /// One entry of the `thresholds` array.
    public struct ThresholdEntry: Codable, Sendable {
        /// Category id (matches a `policy.bin` / `policy.json` category).
        public let id: String
        /// Threshold in `[0.0, 1.0]`; cross-checked against `policy.bin`
        /// by exact `Float` bit pattern.
        public let threshold: Double
        /// `log` | `blur` | `block`.
        public let action: String

        public init(id: String, threshold: Double, action: String) {
            self.id = id
            self.threshold = threshold
            self.action = action
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case threshold
            case action
        }
    }

    /// One entry of the `categories` array.
    public struct CategoryEntry: Codable, Sendable {
        /// Category id (must be a subset of `policy.bin` ids).
        public let id: String
        /// `log` | `blur` | `block`.
        public let action: String
        /// `short_description` — optional one-liner.
        public let shortDescription: String?

        public init(id: String, action: String, shortDescription: String?) {
            self.id = id
            self.action = action
            self.shortDescription = shortDescription
        }

        private enum CodingKeys: String, CodingKey {
            case id
            case action
            case shortDescription = "short_description"
        }
    }

    /// `compatibility` block.
    public struct Compatibility: Codable, Sendable {
        /// `min_daemon_version` — SemVer of `valueguardd` (shape-checked only in P0).
        public let minDaemonVersion: String
        /// `max_daemon_version` — optional upper bound.
        public let maxDaemonVersion: String?
        /// `min_policy_bin_version` — VGP1 format version floor (≥ 1).
        public let minPolicyBinVersion: Int

        public init(minDaemonVersion: String, maxDaemonVersion: String?, minPolicyBinVersion: Int) {
            self.minDaemonVersion = minDaemonVersion
            self.maxDaemonVersion = maxDaemonVersion
            self.minPolicyBinVersion = minPolicyBinVersion
        }

        private enum CodingKeys: String, CodingKey {
            case minDaemonVersion = "min_daemon_version"
            case maxDaemonVersion = "max_daemon_version"
            case minPolicyBinVersion = "min_policy_bin_version"
        }
    }

    /// `fork_of` block — points at the parent config this was derived from.
    public struct ForkRef: Codable, Sendable {
        /// Parent author handle.
        public let author: String
        /// Parent `config_id`.
        public let configId: String
        /// Parent version.
        public let version: String

        public init(author: String, configId: String, version: String) {
            self.author = author
            self.configId = configId
            self.version = version
        }

        private enum CodingKeys: String, CodingKey {
            case author
            case configId = "config_id"
            case version
        }
    }

    /// `calibration_summary` block.
    ///
    /// Decoded leniently — §2 only sketches the inner fields and P0 does not
    /// validate their semantics. Only the two fields the spec names are
    /// surfaced, and both are optional so that any superset of fields (the
    /// `per_category` array, `prior_unsafe`, `conformal_alpha`, …) decodes
    /// without error and without needing a model here.
    public struct CalibrationSummary: Codable, Sendable {
        /// `n_samples_total` — total calibration samples, if reported.
        public let nSamplesTotal: Int?
        /// `n_categories` — number of calibrated categories, if reported.
        public let nCategories: Int?

        public init(nSamplesTotal: Int?, nCategories: Int?) {
            self.nSamplesTotal = nSamplesTotal
            self.nCategories = nCategories
        }

        private enum CodingKeys: String, CodingKey {
            case nSamplesTotal = "n_samples_total"
            case nCategories = "n_categories"
        }
    }

    public init(
        schemaVersion: Int,
        configId: String,
        name: String,
        description: String,
        author: Author,
        license: String,
        version: String,
        createdAt: String,
        modelRef: ModelRef,
        policyHash: String,
        policyJsonHash: String,
        calibrationHash: String,
        thresholds: [ThresholdEntry],
        calibrationMethod: String,
        calibrationSummary: CalibrationSummary?,
        categories: [CategoryEntry],
        compatibility: Compatibility,
        forkOf: ForkRef?,
        tags: [String]?
    ) {
        self.schemaVersion = schemaVersion
        self.configId = configId
        self.name = name
        self.description = description
        self.author = author
        self.license = license
        self.version = version
        self.createdAt = createdAt
        self.modelRef = modelRef
        self.policyHash = policyHash
        self.policyJsonHash = policyJsonHash
        self.calibrationHash = calibrationHash
        self.thresholds = thresholds
        self.calibrationMethod = calibrationMethod
        self.calibrationSummary = calibrationSummary
        self.categories = categories
        self.compatibility = compatibility
        self.forkOf = forkOf
        self.tags = tags
    }

    /// Decode a `Manifest` from raw `manifest.json` bytes.
    ///
    /// Uses a plain `JSONDecoder` with **no** key conversion strategy, so the
    /// explicit `CodingKeys` above are the sole mapping from wire to Swift.
    /// On failure the underlying `DecodingError` is unpacked into a
    /// human-readable message (offending key + coding path) and re-thrown as
    /// `VGError.manifestDecode` — never as a generic `VGError.io`.
    ///
    /// This is a structural decode only; schema rules are enforced afterward
    /// by `ManifestValidator.validate(_:)`.
    public static func decode(from data: Data) throws -> Manifest {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Manifest.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw VGError.manifestDecode("missing key '\(key.stringValue)'\(pathSuffix(ctx))")
        } catch let DecodingError.typeMismatch(type, ctx) {
            throw VGError.manifestDecode("expected \(type)\(pathSuffix(ctx))")
        } catch let DecodingError.valueNotFound(type, ctx) {
            throw VGError.manifestDecode("missing value of type \(type)\(pathSuffix(ctx))")
        } catch let DecodingError.dataCorrupted(ctx) {
            let path = codingPathString(ctx.codingPath)
            let where_ = path.isEmpty ? "" : " at \(path)"
            throw VGError.manifestDecode("\(ctx.debugDescription)\(where_)")
        } catch {
            throw VGError.manifestDecode(error.localizedDescription)
        }
    }

    /// Render a `DecodingError.Context`'s coding path as a `" at a.b.c"`
    /// suffix (empty string when the path is the document root).
    private static func pathSuffix(_ ctx: DecodingError.Context) -> String {
        let path = codingPathString(ctx.codingPath)
        return path.isEmpty ? "" : " at \(path)"
    }

    /// Join a coding path into a dotted string, rendering array indices as
    /// `[n]` so e.g. `thresholds[0].action` reads naturally.
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
