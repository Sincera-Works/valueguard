import Foundation
import ValueGuardCore

/// Produces a fully valid, signed `.vgconfig` bundle from a directory of policy
/// artifacts — the authoring (producer) half of the marketplace, the inverse of
/// ``BundleVerifier``.
///
/// `Packer` is the single home for the pack-and-sign pipeline. Given an input
/// directory that contains at least `policy.bin` and `policy.json`, an author
/// identity, a signing keypair, and config metadata, it:
///
/// 1. Stages the bundle members into a fresh temp directory.
/// 2. Copies `policy.bin` / `policy.json` in verbatim (their raw on-disk bytes
///    drive `policy_hash` / `policy_json_hash` — never canonicalize them).
/// 3. Parses `policy.bin` via the canonical VGP1 reader and synthesizes a
///    `calibration.json` if the caller did not supply one.
/// 4. Builds a §2-valid ``Manifest`` whose `thresholds[]` / `categories[]` mirror
///    the parsed binary exactly. Each threshold is carried as `Double(Float)` — a
///    lossless `Float -> Double` widening — so it narrows back to the identical
///    bit pattern the policy.bin cross-check compares against.
/// 5. Writes `signatures/author.pub` (the same base64 as `manifest.author.public_key`).
/// 6. Encodes the canonical `manifest.json`, builds `signatures/MANIFEST.SHA256`
///    over a producer-side filesystem walk, Ed25519-signs it, and writes
///    `signatures/author.sig`.
/// 7. `tar -czf`s the canonical member set into the requested output bundle.
///
/// The pipeline is deliberately the producer's own implementation, decoupled from
/// the verifier so the two can be tested against each other. A bundle produced by
/// ``pack(_:)`` is expected to pass every step of ``BundleVerifier/verify(bundleAt:)``;
/// the round-trip test asserts exactly that.
///
/// - Note: `model_ref.weights_sha256` / `coreml_package_sha256` are validated for
///   *shape only* in P0 (64-char lowercase hex), never network-checked. The packer
///   accepts them as input; when omitted it emits a clearly-marked placeholder and
///   surfaces a ``Warning`` so the caller can tell the author the model digests are
///   not real.
public enum Packer {

    // MARK: - Input

    /// The author identity that signs the bundle.
    public struct Author {
        /// Registry handle (`^[a-z0-9][a-z0-9-]{1,38}$`).
        public let handle: String
        /// Human-readable display name shown in the CLI / UI.
        public let displayName: String

        public init(handle: String, displayName: String) {
            self.handle = handle
            self.displayName = displayName
        }
    }

    /// The vision-model reference digests carried in `model_ref`.
    ///
    /// Both are validated for shape only (64-char lowercase hex) in P0. Pass real
    /// digests when known; leave either `nil` to accept the placeholder (which
    /// triggers a ``Warning``).
    public struct ModelRefDigests {
        /// HF safetensors digest, or `nil` to use the placeholder.
        public let weightsSha256: String?
        /// Local CoreML conversion digest, or `nil` to use the placeholder.
        public let coremlPackageSha256: String?

        public init(weightsSha256: String? = nil, coremlPackageSha256: String? = nil) {
            self.weightsSha256 = weightsSha256
            self.coremlPackageSha256 = coremlPackageSha256
        }
    }

    /// The config metadata that fills the non-derived manifest fields.
    public struct ConfigMetadata {
        /// `config_id` (`^[a-z][a-z0-9-]{1,38}[a-z0-9]$`).
        public let configId: String
        /// Human-readable `name` (1–80 chars).
        public let name: String
        /// `description` (1–2000 chars).
        public let description: String
        /// SemVer 2.0 `version` (no build metadata).
        public let version: String
        /// SPDX license identifier.
        public let license: String
        /// `tags` (≤ 8, each `^[a-z0-9-]{1,24}$`); empty means no `tags` field.
        public let tags: [String]
        /// Model-reference digests (shape-validated only in P0).
        public let modelRef: ModelRefDigests

        public init(
            configId: String,
            name: String,
            description: String,
            version: String,
            license: String = "MIT",
            tags: [String] = [],
            modelRef: ModelRefDigests = ModelRefDigests()
        ) {
            self.configId = configId
            self.name = name
            self.description = description
            self.version = version
            self.license = license
            self.tags = tags
            self.modelRef = modelRef
        }
    }

    // MARK: - Output

    /// A non-fatal advisory emitted during packing (e.g. a placeholder model
    /// digest was substituted). The CLI prints these to stderr so the author is
    /// aware without the pack failing.
    public struct Warning {
        public let message: String
        public init(_ message: String) { self.message = message }
    }

    /// The result of a successful pack: where the bundle landed plus any advisories.
    public struct Result {
        /// The produced `.vgconfig` bundle URL.
        public let bundle: URL
        /// The fully-populated manifest as encoded into the bundle.
        public let manifest: Manifest
        /// Non-fatal advisories raised while packing (may be empty).
        public let warnings: [Warning]
    }

    // MARK: - Pack

    /// The default model family / HF id the daemon targets. Used to fill the
    /// `model_ref` family and id; the digests come from the caller (or the
    /// placeholder). These describe the model the daemon will run, not the bundle.
    private static let defaultModelFamily = "siglip2-base-patch16-256"
    private static let defaultModelHuggingfaceId = "google/siglip2-base-patch16-256"
    private static let defaultModelInputResolution = 256

    /// A clearly-marked placeholder 64-char lowercase hex used when a real model
    /// digest is not supplied. It is shape-valid (so verify passes) but obviously
    /// not a real digest, and its use is always accompanied by a ``Warning``.
    static let placeholderModelDigest = String(repeating: "0", count: 64)

    /// Pack a `.vgconfig` from a directory of policy artifacts.
    ///
    /// - Parameters:
    ///   - inputDir: directory containing at least `policy.bin` and `policy.json`.
    ///     If a `calibration.json` is present it is used verbatim; otherwise a
    ///     minimal valid one is synthesized.
    ///   - author: the author identity (handle + display name).
    ///   - privateKeyRaw: the 32-byte raw Ed25519 private seed to sign with.
    ///   - publicKeyRaw: the 32-byte raw Ed25519 public key (the verifying half of
    ///     `privateKeyRaw`); written to `author.pub` and the manifest.
    ///   - metadata: the config metadata filling the non-derived manifest fields.
    ///   - createdAt: the `created_at` RFC 3339 UTC timestamp. Defaults to now.
    ///   - outputBundle: the `.vgconfig` file URL to write (parent must exist).
    /// - Returns: a ``Result`` with the bundle URL, the encoded manifest, and any
    ///   advisories.
    /// - Throws: ``VGError`` on I/O, a missing input artifact, or an unparseable
    ///   `policy.bin`.
    @discardableResult
    public static func pack(
        inputDir: URL,
        author: Author,
        privateKeyRaw: Data,
        publicKeyRaw: Data,
        metadata: ConfigMetadata,
        createdAt: String = rfc3339Now(),
        outputBundle: URL
    ) throws -> Result {
        let fm = FileManager.default
        var warnings: [Warning] = []

        // ---- input artifacts must exist ---------------------------------
        let inPolicyBin = inputDir.appendingPathComponent("policy.bin")
        let inPolicyJSON = inputDir.appendingPathComponent("policy.json")
        guard fm.fileExists(atPath: inPolicyBin.path) else {
            throw VGError.notFound("policy.bin not found in input dir: \(inPolicyBin.path)")
        }
        guard fm.fileExists(atPath: inPolicyJSON.path) else {
            throw VGError.notFound("policy.json not found in input dir: \(inPolicyJSON.path)")
        }

        // ---- staging dir ------------------------------------------------
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("vg-pack-stage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }
        let signaturesDir = stagingDir.appendingPathComponent("signatures", isDirectory: true)
        try fm.createDirectory(at: signaturesDir, withIntermediateDirectories: true)

        // ---- copy policy.bin / policy.json verbatim ---------------------
        // Raw on-disk bytes drive policy_hash / policy_json_hash; never recode.
        try copyVerbatim(from: inPolicyBin, to: stagingDir.appendingPathComponent("policy.bin"))
        try copyVerbatim(from: inPolicyJSON, to: stagingDir.appendingPathComponent("policy.json"))

        // ---- parse policy.bin + stage calibration.json ------------------
        let policy = try PolicyBinCrossCheck.load(stagingDir.appendingPathComponent("policy.bin"))

        let stagedCalibration = stagingDir.appendingPathComponent("calibration.json")
        let inCalibration = inputDir.appendingPathComponent("calibration.json")
        if fm.fileExists(atPath: inCalibration.path) {
            try copyVerbatim(from: inCalibration, to: stagedCalibration)
        } else {
            let calibrationData = try makeCalibrationJSON(categoryCount: policy.categories.count)
            try calibrationData.write(to: stagedCalibration, options: .atomic)
        }

        // ---- resolve model_ref digests (shape-only validated in P0) -----
        let weightsSha256: String
        if let supplied = metadata.modelRef.weightsSha256 {
            weightsSha256 = supplied
        } else {
            weightsSha256 = placeholderModelDigest
            warnings.append(Warning(
                "model_ref.weights_sha256 not supplied — using a placeholder (\(placeholderModelDigest)). "
                + "Pass --weights-sha256 with the real HF safetensors digest before publishing."
            ))
        }
        let coremlSha256: String
        if let supplied = metadata.modelRef.coremlPackageSha256 {
            coremlSha256 = supplied
        } else {
            coremlSha256 = placeholderModelDigest
            warnings.append(Warning(
                "model_ref.coreml_package_sha256 not supplied — using a placeholder (\(placeholderModelDigest)). "
                + "Pass --coreml-sha256 with the real CoreML conversion digest before publishing."
            ))
        }

        // ---- Ed25519 public key wiring ----------------------------------
        let publicKeyBase64 = publicKeyRaw.base64EncodedString()
        try Data(publicKeyBase64.utf8).write(
            to: signaturesDir.appendingPathComponent("author.pub"),
            options: .atomic
        )

        // ---- content hashes over the staged raw bytes -------------------
        let policyHash = try Hashing.sha256Prefixed(ofFileAt: stagingDir.appendingPathComponent("policy.bin"))
        let policyJSONHash = try Hashing.sha256Prefixed(ofFileAt: stagingDir.appendingPathComponent("policy.json"))
        let calibrationHash = try Hashing.sha256Prefixed(ofFileAt: stagedCalibration)

        // ---- build the manifest mirroring the parsed policy.bin ---------
        let manifest = makeManifest(
            policy: policy,
            author: author,
            metadata: metadata,
            createdAt: createdAt,
            publicKeyBase64: publicKeyBase64,
            weightsSha256: weightsSha256,
            coremlPackageSha256: coremlSha256,
            policyHash: policyHash,
            policyJSONHash: policyJSONHash,
            calibrationHash: calibrationHash
        )

        // ---- write manifest.json (canonical) ----------------------------
        let manifestData = try CanonicalJSON.encode(manifest)
        try manifestData.write(
            to: stagingDir.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        // ---- MANIFEST.SHA256 + sign -------------------------------------
        let manifestDigest = try signerDigest(forStagingDir: stagingDir)
        try manifestDigest.write(
            to: signaturesDir.appendingPathComponent("MANIFEST.SHA256"),
            options: .atomic
        )
        let signature = try Ed25519.sign(message: manifestDigest, privateKeyRaw: privateKeyRaw)
        try signature.write(
            to: signaturesDir.appendingPathComponent("author.sig"),
            options: .atomic
        )

        // ---- archive ----------------------------------------------------
        // Canonical member order: §2 required top-level, then signatures members.
        let members = [
            "manifest.json",
            "policy.bin",
            "policy.json",
            "calibration.json",
            "signatures/author.pub",
            "signatures/author.sig",
            "signatures/MANIFEST.SHA256",
        ]
        try Archive.create(members: members, inStagingDir: stagingDir, outputBundle: outputBundle)

        return Result(bundle: outputBundle, manifest: manifest, warnings: warnings)
    }

    // MARK: - Manifest synthesis

    /// Build a §2-valid ``Manifest`` mirroring the parsed `policy.bin`.
    ///
    /// `thresholds[]` and `categories[]` are derived from the binary's categories
    /// so the cross-checks pass. Each threshold is carried as
    /// `Double(category.threshold)` — a lossless `Float -> Double` widening, so
    /// `Float(double)` narrows back to the identical bit pattern that
    /// `PolicyBinCrossCheck.floatBitsEqual` compares against.
    static func makeManifest(
        policy: ValueGuardCore.Policy,
        author: Author,
        metadata: ConfigMetadata,
        createdAt: String,
        publicKeyBase64: String,
        weightsSha256: String,
        coremlPackageSha256: String,
        policyHash: String,
        policyJSONHash: String,
        calibrationHash: String
    ) -> Manifest {
        let thresholds = policy.categories.map { cat in
            Manifest.ThresholdEntry(
                id: cat.id,
                threshold: Double(cat.threshold),
                action: PolicyBinCrossCheck.actionString(cat.action)
            )
        }
        let categories = policy.categories.map { cat in
            Manifest.CategoryEntry(
                id: cat.id,
                action: PolicyBinCrossCheck.actionString(cat.action),
                shortDescription: "Category \(cat.id) (\(PolicyBinCrossCheck.actionString(cat.action)))."
            )
        }

        let manifestAuthor = Manifest.Author(
            handle: author.handle,
            displayName: author.displayName,
            verified: false,
            publicKey: publicKeyBase64
        )

        let modelRef = Manifest.ModelRef(
            family: defaultModelFamily,
            huggingfaceId: defaultModelHuggingfaceId,
            weightsSha256: weightsSha256,
            coremlPackageSha256: coremlPackageSha256,
            inputResolution: defaultModelInputResolution,
            embeddingDim: policy.embedDim
        )

        let compatibility = Manifest.Compatibility(
            minDaemonVersion: "0.1.0",
            maxDaemonVersion: nil,
            minPolicyBinVersion: 1
        )

        let summary = Manifest.CalibrationSummary(
            nSamplesTotal: 0,
            nCategories: policy.categories.count
        )

        return Manifest(
            schemaVersion: 1,
            configId: metadata.configId,
            name: metadata.name,
            description: metadata.description,
            author: manifestAuthor,
            license: metadata.license,
            version: metadata.version,
            createdAt: createdAt,
            modelRef: modelRef,
            policyHash: policyHash,
            policyJsonHash: policyJSONHash,
            calibrationHash: calibrationHash,
            thresholds: thresholds,
            calibrationMethod: "label_free_normal",
            calibrationSummary: summary,
            categories: categories,
            compatibility: compatibility,
            forkOf: nil,
            tags: metadata.tags.isEmpty ? nil : metadata.tags
        )
    }

    // MARK: - Signer-side MANIFEST.SHA256

    /// Compute `signatures/MANIFEST.SHA256` the way a *producer* would: walk the
    /// staging tree, emit a coreutils-style `"<hex>  <relpath>\n"` line for every
    /// **regular file** outside `signatures/`, sorted by the relative path's UTF-8
    /// byte sequence, with a trailing newline per line.
    ///
    /// This is the single home for the producer-side digest walk (both ``pack(_:)``
    /// and the test ``FixtureBuilder`` route through it). It is deliberately the
    /// producer's own implementation, decoupled from the verifier's strict
    /// `ManifestDigest.build(forExtractedDir:coveredMembers:)`: it follows symlinks
    /// when hashing but lists only `isRegularFile` entries, so a symlinked member
    /// is *omitted* from the listing — exactly what the tamper fixtures rely on to
    /// build a self-consistent-but-rejectable bundle.
    public static func signerDigest(forStagingDir dir: URL) throws -> Data {
        let fm = FileManager.default
        let root = dir.standardizedFileURL
        let rootPath = root.path

        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: nil
        ) else {
            throw VGError.io("could not enumerate staging dir: \(rootPath)")
        }

        var relPaths: [String] = []
        for case let fileURL as URL in enumerator {
            let full = fileURL.standardizedFileURL.path
            var prefix = rootPath
            if !prefix.hasSuffix("/") { prefix += "/" }
            let relative = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : fileURL.lastPathComponent

            if relative == "signatures" || relative.hasPrefix("signatures/") {
                if relative == "signatures" { enumerator.skipDescendants() }
                continue
            }
            // Stat the entry loudly: a `try?` here would turn a transient failure
            // (e.g. the entry vanishing between enumeration and stat) into a
            // SILENT exclusion from the digest — the bundle would pack fine but
            // fail self-verify with a misleading "signature invalid". Surface it.
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: Set(keys))
            } catch {
                throw VGError.io(
                    "could not stat staged file '\(relative)' while building the manifest digest: "
                    + error.localizedDescription)
            }
            if values.isRegularFile == true {
                relPaths.append(relative)
            }
        }

        relPaths.sort { a, b in
            Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
        }

        var out = Data()
        for rel in relPaths {
            let hex = try Hashing.sha256Hex(ofFileAt: dir.appendingPathComponent(rel))
            out.append(Data((hex + "  " + rel + "\n").utf8))
        }
        return out
    }

    // MARK: - calibration.json synthesis

    /// Produce a minimal but well-formed `calibration.json`. P0 validates that the
    /// file exists, hashes correctly, and is valid JSON — never its inner field
    /// semantics — so a small object satisfies the contract.
    static func makeCalibrationJSON(categoryCount: Int) throws -> Data {
        let object: [String: Any] = [
            "method": "label_free_normal",
            "n_samples_total": 0,
            "n_categories": categoryCount,
        ]
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    // MARK: - Helpers

    /// Copy a file's raw bytes to a staged path, overwriting any existing file.
    private static func copyVerbatim(from src: URL, to dst: URL) throws {
        let data = try Data(contentsOf: src)
        try data.write(to: dst, options: .atomic)
    }

    /// The current instant as an RFC 3339 UTC timestamp with no offset
    /// (`yyyy-MM-ddTHH:mm:ssZ`) — the `created_at` shape the validator accepts.
    public static func rfc3339Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
