import Foundation
import XCTest
@testable import ValueGuardMarketplace
import ValueGuardCore

/// Test-only helper that synthesizes a fully valid, signed `.vgconfig` bundle
/// from the repository's example policy artifacts, so the verify / install /
/// tamper tests have a *real* bundle to operate on rather than a hand-rolled
/// fixture that might drift from the production contract.
///
/// The reference artifacts are read from the canonical repo (NOT the worktree):
/// `policy-compiler/examples/personal-values.calibrated.policy.{bin,json}`. The
/// `policy.bin` is the authoritative VGP1 binary; `FixtureBuilder` parses it via
/// `PolicyBinCrossCheck.load` (the only VGP1 reader) and derives the manifest's
/// `thresholds[]` / `categories[]` and a synthetic `policy.json`-aligned set
/// directly from the parsed `Float` thresholds and `PolicyAction`s. Because
/// `Float -> Double -> Float` round-trips bit-for-bit, the manifest `Double`
/// thresholds compare bit-exactly against `policy.bin` in
/// `PolicyBinCrossCheck.crossCheck`, so the synthesized bundle passes every step
/// of the verify pipeline.
///
/// All output is written to fresh temp directories; nothing under the reference
/// repo or the install layout is ever touched.
///
/// ## Tampering
/// `buildSignedBundle(tweak:)` exposes a single `tweak` hook over a mutable
/// ``Staging`` value. The hook runs *before* `MANIFEST.SHA256` is built and
/// signed, so mutating `staging.manifest`, rewriting a staged file, or adding /
/// removing members yields a bundle whose signature still covers the mutated
/// contents (useful for "manifest violates a rule" / cross-check tests). To
/// simulate corruption *after* signing — a flipped `policy.bin` byte, a bad
/// `author.sig`, a swapped public key — assign ``Staging/tamperAfterSign``,
/// which the builder invokes after the signature is written but before the
/// archive is created, leaving `MANIFEST.SHA256` / `author.sig` stale relative
/// to the mutated bytes.
enum FixtureBuilder {

    // MARK: - Reference artifact locations

    /// Root of the canonical (non-worktree) reference repository.
    static let referenceRepo = URL(fileURLWithPath: "/Users/bradmcauley/projects/valueguard")

    /// The calibrated example `policy.bin` in the reference repo.
    static func examplePolicyBinURL() -> URL {
        referenceRepo
            .appendingPathComponent("policy-compiler")
            .appendingPathComponent("examples")
            .appendingPathComponent("personal-values.calibrated.policy.bin")
    }

    /// The calibrated example `policy.json` in the reference repo.
    static func examplePolicyJSONURL() -> URL {
        referenceRepo
            .appendingPathComponent("policy-compiler")
            .appendingPathComponent("examples")
            .appendingPathComponent("personal-values.calibrated.policy.json")
    }

    // MARK: - Staging

    /// Mutable view of a bundle being assembled, handed to the `tweak` hook.
    ///
    /// The builder stages every member as a file under ``dir`` and keeps the
    /// canonical member ordering in ``members``. The manifest is held as a value
    /// in ``manifest`` and re-encoded to `manifest.json` *after* the tweak runs,
    /// so mutating it through the hook flows into the signed bundle.
    struct Staging {
        /// Absolute path to the staging directory (the future archive root).
        var dir: URL
        /// The manifest value, re-encoded to `manifest.json` after `tweak`.
        var manifest: Manifest
        /// Member paths to archive, in §2 canonical order. Mutate to add/remove
        /// optional members or to inject a (rejected) traversal member.
        var members: [String]
        /// Raw Ed25519 public key (32 bytes) the bundle is signed with.
        var publicKeyRaw: Data
        /// Raw Ed25519 private key (32 bytes) used to sign `MANIFEST.SHA256`.
        var privateKeyRaw: Data
        /// Optional post-signing corruption hook. Runs after `author.sig` /
        /// `MANIFEST.SHA256` are written but before `Archive.create`, so any
        /// mutation it makes leaves the signature/digest stale (tamper tests).
        var tamperAfterSign: ((URL) throws -> Void)?

        /// Write raw bytes to a staged member path (overwrites).
        func write(_ data: Data, to member: String) throws {
            let url = dir.appendingPathComponent(member)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }

        /// Read the current bytes of a staged member path.
        func read(_ member: String) throws -> Data {
            try Data(contentsOf: dir.appendingPathComponent(member))
        }

        /// Replace a staged member with a SYMLINK pointing at `target`.
        ///
        /// Removes the existing staged file (if any) and creates a symbolic link
        /// in its place, so `tar` will archive the member as a symlink rather
        /// than a regular file. Used by the symlink-member regression test to
        /// reproduce the representation-split exploit. The member name is kept
        /// in ``members`` so the archive still lists it.
        func replaceWithSymlink(_ member: String, target: URL) throws {
            let fm = FileManager.default
            let url = dir.appendingPathComponent(member)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            try fm.createSymbolicLink(at: url, withDestinationURL: target)
        }
    }

    // MARK: - Build

    /// Synthesize a valid signed `.vgconfig` from the reference example
    /// artifacts.
    ///
    /// Pipeline:
    /// 1. Make a fresh temp staging dir.
    /// 2. Copy the example `policy.bin` and `policy.json` in verbatim (their raw
    ///    bytes drive `policy_hash` / `policy_json_hash`).
    /// 3. Parse `policy.bin` via `PolicyBinCrossCheck.load` and synthesize a
    ///    `calibration.json`, then a `Manifest` whose `thresholds[]` /
    ///    `categories[]` mirror the parsed binary exactly (thresholds carried as
    ///    `Double(Float)` so the Float-bit cross-check matches).
    /// 4. Generate an Ed25519 keypair; set `manifest.author.public_key` and write
    ///    `signatures/author.pub` to the same base64.
    /// 5. Run the caller's `tweak` (may mutate manifest / files / members).
    /// 6. Re-encode `manifest.json` (canonical JSON), recompute the three content
    ///    hashes from the staged bytes, and patch them back into the manifest if
    ///    the tweak left them stale — then re-encode once more so the on-disk
    ///    manifest's hashes match the staged artifacts (unless the tweak
    ///    deliberately broke them; see note below).
    /// 7. Build `signatures/MANIFEST.SHA256` from the staged files, Ed25519-sign
    ///    it, write `author.sig`.
    /// 8. Run `tamperAfterSign` if set.
    /// 9. `tar -czf` the canonical member set into a fresh temp `.vgconfig`.
    ///
    /// - Parameter tweak: optional mutation hook over the staging state, run
    ///   before signing. Pass `nil` for a pristine valid bundle.
    /// - Returns: the bundle URL, the raw private key (so tests can re-sign or
    ///   derive the fingerprint), and the final encoded manifest value.
    @discardableResult
    static func buildSignedBundle(
        tweak: ((inout Staging) -> Void)? = nil
    ) throws -> (bundle: URL, privateKeyRaw: Data, manifest: Manifest) {
        let fm = FileManager.default

        // ---- 1. staging dir ---------------------------------------------
        let stagingDir = fm.temporaryDirectory
            .appendingPathComponent("vg-fixture-stage-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let signaturesDir = stagingDir.appendingPathComponent("signatures", isDirectory: true)
        try fm.createDirectory(at: signaturesDir, withIntermediateDirectories: true)

        // ---- 2. copy reference policy.bin / policy.json verbatim --------
        let policyBinData = try Data(contentsOf: examplePolicyBinURL())
        let policyJSONData = try Data(contentsOf: examplePolicyJSONURL())
        try policyBinData.write(to: stagingDir.appendingPathComponent("policy.bin"), options: .atomic)
        try policyJSONData.write(to: stagingDir.appendingPathComponent("policy.json"), options: .atomic)

        // ---- 3. parse policy.bin + synthesize calibration.json + manifest
        let policy = try PolicyBinCrossCheck.load(stagingDir.appendingPathComponent("policy.bin"))

        let calibrationData = try makeCalibrationJSON(categoryCount: policy.categories.count)
        try calibrationData.write(to: stagingDir.appendingPathComponent("calibration.json"), options: .atomic)

        // Ed25519 keypair (used for both the manifest field and author.pub).
        let keypair = Ed25519.generateKeypair()
        let publicKeyBase64 = keypair.publicRaw.base64EncodedString()

        // Hashes of the staged artifacts (raw on-disk bytes — never canonicalize).
        let policyHash = try Hashing.sha256Prefixed(ofFileAt: stagingDir.appendingPathComponent("policy.bin"))
        let policyJSONHash = try Hashing.sha256Prefixed(ofFileAt: stagingDir.appendingPathComponent("policy.json"))
        let calibrationHash = try Hashing.sha256Prefixed(ofFileAt: stagingDir.appendingPathComponent("calibration.json"))

        var manifest = makeManifest(
            policy: policy,
            publicKeyBase64: publicKeyBase64,
            policyHash: policyHash,
            policyJSONHash: policyJSONHash,
            calibrationHash: calibrationHash
        )

        // author.pub mirrors manifest.author.public_key (same base64 32 bytes).
        try Data(publicKeyBase64.utf8).write(
            to: signaturesDir.appendingPathComponent("author.pub"),
            options: .atomic
        )

        // Canonical member order: §2 required top-level, then signatures members
        // (author.pub/author.sig/MANIFEST.SHA256). manifest.json is written below.
        var members = [
            "manifest.json",
            "policy.bin",
            "policy.json",
            "calibration.json",
            "signatures/author.pub",
            "signatures/author.sig",
            "signatures/MANIFEST.SHA256",
        ]

        // ---- 4./5. assemble staging + run tweak -------------------------
        var staging = Staging(
            dir: stagingDir,
            manifest: manifest,
            members: members,
            publicKeyRaw: keypair.publicRaw,
            privateKeyRaw: keypair.privateRaw,
            tamperAfterSign: nil
        )
        tweak?(&staging)
        manifest = staging.manifest
        members = staging.members

        // ---- 6. write manifest.json (canonical) -------------------------
        let manifestData = try CanonicalJSON.encode(manifest)
        try manifestData.write(
            to: stagingDir.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        // ---- 7. MANIFEST.SHA256 + sign ----------------------------------
        // Compute the digest the way a *signer* would: a plain filesystem walk
        // that emits a line for every regular file outside signatures/. This is
        // deliberately the signer's own implementation (decoupled from the
        // verifier's strict `ManifestDigest.build`) so a tampering fixture can
        // produce a *self-consistent* bundle — e.g. one whose policy.bin is a
        // symlink, where the walk omits the symlinked member exactly as the
        // legacy verifier would have, letting the regression test prove the new
        // type guard catches what the digest alone no longer can.
        let manifestDigest = try signerDigest(forStagingDir: stagingDir)
        try manifestDigest.write(
            to: signaturesDir.appendingPathComponent("MANIFEST.SHA256"),
            options: .atomic
        )
        let signature = try Ed25519.sign(message: manifestDigest, privateKeyRaw: staging.privateKeyRaw)
        try signature.write(
            to: signaturesDir.appendingPathComponent("author.sig"),
            options: .atomic
        )

        // ---- 8. post-signing tamper hook --------------------------------
        if let tamper = staging.tamperAfterSign {
            try tamper(stagingDir)
        }

        // ---- 9. archive -------------------------------------------------
        let bundleURL = fm.temporaryDirectory
            .appendingPathComponent("vg-fixture-" + UUID().uuidString + ".vgconfig")
        try Archive.create(members: members, inStagingDir: stagingDir, outputBundle: bundleURL)

        // The archived bundle is now self-contained; the staging tree is no
        // longer needed. Remove it so each call doesn't leak a temp dir
        // (~40KB) into temporaryDirectory.
        try? fm.removeItem(at: stagingDir)

        return (bundleURL, staging.privateKeyRaw, manifest)
    }

    // MARK: - Manifest synthesis

    /// Build a §2-valid `Manifest` mirroring the parsed `policy.bin`.
    ///
    /// `thresholds[]` and `categories[]` are derived from the binary's
    /// categories so the cross-checks pass. Each threshold is carried as
    /// `Double(category.threshold)` — a lossless `Float -> Double` widening, so
    /// `Float(double)` narrows back to the identical bit pattern that
    /// `PolicyBinCrossCheck.floatBitsEqual` compares against.
    static func makeManifest(
        policy: ValueGuardCore.Policy,
        publicKeyBase64: String,
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
                shortDescription: "Synthesized fixture category \(cat.id)."
            )
        }

        let author = Manifest.Author(
            handle: "fixture-author",
            displayName: "Fixture Author",
            verified: false,
            publicKey: publicKeyBase64
        )

        // 64-char lowercase hex shapes for the model-ref digests (P0 validates
        // shape only — never network-checked).
        let hex64 = String(repeating: "a", count: 64)

        let modelRef = Manifest.ModelRef(
            family: "siglip2-base-patch16-256",
            huggingfaceId: "google/siglip2-base-patch16-256",
            weightsSha256: hex64,
            coremlPackageSha256: hex64,
            inputResolution: 256,
            embeddingDim: policy.embedDim
        )

        let compatibility = Manifest.Compatibility(
            minDaemonVersion: "0.1.0",
            maxDaemonVersion: nil,
            minPolicyBinVersion: 1
        )

        let summary = Manifest.CalibrationSummary(
            nSamplesTotal: 1000,
            nCategories: policy.categories.count
        )

        return Manifest(
            schemaVersion: 1,
            configId: "personal-values-strict",
            name: "Personal Values (Strict)",
            description: "Fixture config synthesized from the calibrated personal-values example policy.bin for marketplace tests.",
            author: author,
            license: "MIT",
            version: "1.0.0",
            createdAt: "2026-05-28T00:00:00Z",
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
            tags: ["personal", "strict"]
        )
    }

    // MARK: - Signer-side MANIFEST.SHA256

    /// Compute `signatures/MANIFEST.SHA256` the way a *signer* would: walk the
    /// staging tree, emit a coreutils-style `"<hex>  <relpath>\n"` line for every
    /// **regular file** outside `signatures/`, sorted by the relative path's
    /// UTF-8 byte sequence, with a trailing newline.
    ///
    /// This is intentionally a standalone reimplementation of the legacy digest
    /// walk (it follows symlinks when hashing, but only lists `isRegularFile`
    /// entries — so a symlinked member is *omitted* from the listing). It models
    /// the producer side and is decoupled from the verifier's strict
    /// `ManifestDigest.build(forExtractedDir:coveredMembers:)`, which now refuses
    /// any on-disk/declared mismatch. A symlink-member fixture built here is thus
    /// self-consistent against this digest yet must be rejected by the verifier.
    static func signerDigest(forStagingDir dir: URL) throws -> Data {
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
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true {
                relPaths.append(relative)
            }
        }

        relPaths.sort { a, b in
            Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8))
        }

        var out = Data()
        for rel in relPaths {
            // Hash the file's bytes (following a symlink if `rel` is one — but a
            // symlinked member is never *listed*, per the regular-file filter
            // above, so this only ever hashes true regular files in practice).
            let hex = try Hashing.sha256Hex(ofFileAt: dir.appendingPathComponent(rel))
            out.append(Data((hex + "  " + rel + "\n").utf8))
        }
        return out
    }

    // MARK: - calibration.json synthesis

    /// Produce a minimal but well-formed `calibration.json`. P0 validates that
    /// the file exists, hashes correctly, and is valid JSON — never its inner
    /// field semantics — so a small object satisfies the contract.
    private static func makeCalibrationJSON(categoryCount: Int) throws -> Data {
        let object: [String: Any] = [
            "method": "label_free_normal",
            "n_samples_total": 1000,
            "n_categories": categoryCount,
        ]
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }
}
