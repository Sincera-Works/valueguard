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
    //
    // The reference `policy.bin` / `policy.json` are located *portably* — there
    // must be NO machine-specific absolute path in the test sources, or the
    // integration tests only pass on one developer's laptop and fail on CI.
    //
    // Resolution order:
    //   1. If the repo's committed calibrated example exists under
    //      `policy-compiler/examples/` (the repo root is derived at runtime from
    //      this source file's `#filePath`, walking up the tree — never hard
    //      coded), use it verbatim. This keeps the fixture identical to the
    //      production artifact when an author has the optional, gitignored
    //      example checked out locally.
    //   2. Otherwise (CI, a fresh clone — the example artifacts are gitignored,
    //      see repo `.gitignore` `*.policy.bin` / `*.policy.json`), synthesize a
    //      byte-valid VGP1 `policy.bin` and its companion `policy.json` into a
    //      stable per-process cache dir and use those. The synthesizer follows
    //      the VGP1 contract (`model-conversion/embed_captions.py`) exactly; it
    //      does NOT reimplement or alter the `ValueGuardCore` reader, which still
    //      parses every byte it produces.
    //
    // Both paths yield artifacts that round-trip through `PolicyBinCrossCheck`
    // and pass the full verify pipeline, so the suite is machine-independent.

    /// Absolute path to the directory containing THIS source file, derived from
    /// the Swift `#filePath` macro (the compiler-substituted source path) — the
    /// portable anchor for locating committed repo artifacts at runtime.
    private static let sourceDir: URL =
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()

    /// The repository root, derived by walking up from this source file:
    /// `<root>/daemon/Tests/ValueGuardMarketplaceTests/FixtureBuilder.swift`, so
    /// the root is four directories above `sourceDir`. Computed from `#filePath`
    /// alone — no environment lookup and no hard-coded user path.
    private static let repoRoot: URL =
        sourceDir
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // daemon/Tests -> daemon
            .deletingLastPathComponent()   // daemon -> repo root

    /// Committed (optional, gitignored) calibrated example under the repo's
    /// `policy-compiler/examples/`. Present on a developer machine that has run
    /// the policy compiler; absent on CI / a fresh clone.
    private static let committedExampleBin: URL =
        repoRoot
            .appendingPathComponent("policy-compiler")
            .appendingPathComponent("examples")
            .appendingPathComponent("personal-values.calibrated.policy.bin")

    private static let committedExampleJSON: URL =
        repoRoot
            .appendingPathComponent("policy-compiler")
            .appendingPathComponent("examples")
            .appendingPathComponent("personal-values.calibrated.policy.json")

    /// Stable per-process cache directory for synthesized reference artifacts.
    /// One dir per process so repeated `buildSignedBundle` calls (and the
    /// symlink regression test, which targets `examplePolicyBinURL()` as a
    /// persistent on-disk link destination) all see the same bytes.
    private static let synthCacheDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vg-fixture-reference-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Resolve the reference `policy.bin` / `policy.json` once: prefer the
    /// committed example when both exist, otherwise synthesize a matched pair
    /// into the cache. Returns the two URLs (both files exist on disk on return).
    ///
    /// Synthesis is performed atomically as a pair so the bin/json always agree
    /// (same category ids / thresholds / actions), which the cross-checks demand.
    private static let referenceArtifacts: (bin: URL, json: URL) = {
        let fm = FileManager.default
        if fm.fileExists(atPath: committedExampleBin.path),
           fm.fileExists(atPath: committedExampleJSON.path) {
            return (committedExampleBin, committedExampleJSON)
        }

        // Fallback: synthesize into the per-process cache.
        let binURL = synthCacheDir.appendingPathComponent("reference.policy.bin")
        let jsonURL = synthCacheDir.appendingPathComponent("reference.policy.json")
        do {
            if !(fm.fileExists(atPath: binURL.path) && fm.fileExists(atPath: jsonURL.path)) {
                let (binData, jsonData) = try synthesizeReferencePolicy()
                try binData.write(to: binURL, options: .atomic)
                try jsonData.write(to: jsonURL, options: .atomic)
            }
        } catch {
            // The synthesizer is deterministic and self-contained; a failure
            // here means the test environment itself is broken (e.g. no writable
            // temp dir). Fail loudly with a precise, actionable message rather
            // than letting a downstream `Data(contentsOf:)` throw an opaque error.
            fatalError(
                "FixtureBuilder could not locate or synthesize the reference "
                + "policy artifacts.\n"
                + "  committed example bin: \(committedExampleBin.path) (absent)\n"
                + "  synth cache dir:       \(synthCacheDir.path)\n"
                + "  underlying error:      \(error)")
        }
        return (binURL, jsonURL)
    }()

    /// The calibrated example `policy.bin` — committed example if present,
    /// otherwise the synthesized VGP1 binary (resolved portably; never hard
    /// coded).
    static func examplePolicyBinURL() -> URL {
        referenceArtifacts.bin
    }

    /// The calibrated example `policy.json` — committed example if present,
    /// otherwise the synthesized companion document.
    static func examplePolicyJSONURL() -> URL {
        referenceArtifacts.json
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
    ///
    /// The implementation now lives in the library as ``Packer/signerDigest(forStagingDir:)``
    /// so the producer-side digest walk has exactly one home shared between the
    /// shipping `vg pack` path and these fixtures; this thin wrapper preserves the
    /// existing call sites.
    static func signerDigest(forStagingDir dir: URL) throws -> Data {
        try Packer.signerDigest(forStagingDir: dir)
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

    // MARK: - Reference policy synthesis (CI fallback)

    /// One synthesized category: id + threshold + action + caption counts. The
    /// thresholds mirror the calibrated example's value scale and are chosen so
    /// `Float(Double(value))` is bit-stable (the cross-check compares 32-bit
    /// patterns). The embeddings are deterministic L2-normalized vectors derived
    /// from the id, so the binary is fully reproducible and parseable.
    private struct SynthCategory {
        let id: String
        let threshold: Float
        let action: PolicyAction
        let positiveCaptions: [String]
        let negativeCaptions: [String]
    }

    /// VGP1 embedding dimension. Matches the model the manifest's `model_ref`
    /// declares (`siglip2-base-patch16-256`, embed dim 768) so the
    /// manifest↔policy.bin embedding-dim cross-check passes.
    private static let synthEmbedDim = 768

    /// The synthesized category set (mirrors the calibrated example's shape: a
    /// small multi-category policy with mixed `block` / `log` actions). Caption
    /// counts sit inside the 6–14 per-side range `PolicyJSONValidator` enforces.
    private static let synthCategories: [SynthCategory] = [
        SynthCategory(
            id: "explicit_sexual_acts",
            threshold: 0.1011,
            action: .block,
            positiveCaptions: synthCaptions(prefix: "explicit", count: 10),
            negativeCaptions: synthCaptions(prefix: "benign-explicit", count: 10)
        ),
        SynthCategory(
            id: "sexualized_nudity_contemporary",
            threshold: 0.072,
            action: .block,
            positiveCaptions: synthCaptions(prefix: "nudity", count: 12),
            negativeCaptions: synthCaptions(prefix: "benign-nudity", count: 12)
        ),
        SynthCategory(
            id: "gambling_interface",
            threshold: 0.1386,
            action: .block,
            positiveCaptions: synthCaptions(prefix: "gambling", count: 12),
            negativeCaptions: synthCaptions(prefix: "benign-gambling", count: 12)
        ),
        SynthCategory(
            id: "graphic_realworld_violence",
            threshold: 0.0679,
            action: .log,
            positiveCaptions: synthCaptions(prefix: "violence", count: 12),
            negativeCaptions: synthCaptions(prefix: "benign-violence", count: 12)
        ),
    ]

    /// Deterministic placeholder captions (`"<prefix> caption N"`).
    private static func synthCaptions(prefix: String, count: Int) -> [String] {
        (0..<count).map { "\(prefix) caption \($0)" }
    }

    /// Build a matched (policy.bin, policy.json) pair from `synthCategories`.
    ///
    /// `policy.bin` is packed in the little-endian VGP1 layout pinned by
    /// `model-conversion/embed_captions.py` (and parsed by `ValueGuardCore`'s
    /// `Policy(loadingFrom:)`); `policy.json` carries the same ids / thresholds /
    /// actions plus captions, so both cross-checks (manifest↔bin and json↔bin)
    /// pass. This writes bytes only — it never touches the VGP1 *reader*.
    private static func synthesizeReferencePolicy() throws -> (bin: Data, json: Data) {
        let bin = packVGP1(categories: synthCategories, embedDim: synthEmbedDim)
        let json = try makeReferencePolicyJSON(categories: synthCategories)
        return (bin, json)
    }

    /// Pack categories into a VGP1 binary (all little-endian), byte-for-byte per
    /// the documented contract:
    /// `magic "VGP1" | version=1 | n_categories | embed_dim | reserved=0`, then
    /// per category `id_len | id_utf8 | threshold:f32 | action:u8 | pad[3] |
    /// pos_vec[embed_dim]:f32 (L2-normalized) | neg_vec[embed_dim]:f32`.
    private static func packVGP1(categories: [SynthCategory], embedDim: Int) -> Data {
        var data = Data()
        data.append(contentsOf: [0x56, 0x47, 0x50, 0x31])           // "VGP1"
        appendLE(&data, UInt32(1))                                   // version
        appendLE(&data, UInt32(categories.count))                    // n_categories
        appendLE(&data, UInt32(embedDim))                            // embed_dim
        appendLE(&data, UInt32(0))                                   // reserved

        for (index, cat) in categories.enumerated() {
            let idBytes = Array(cat.id.utf8)
            appendLE(&data, UInt32(idBytes.count))                   // id_len
            data.append(contentsOf: idBytes)                         // id_utf8
            appendLE(&data, cat.threshold.bitPattern)                // threshold f32
            data.append(cat.action.rawValue)                         // action u8
            data.append(contentsOf: [0, 0, 0])                       // 3 bytes padding

            // Deterministic, L2-normalized embeddings. Distinct seeds per side /
            // category keep the vectors well-formed unit vectors; their exact
            // values are irrelevant to verification (no scoring is exercised),
            // only that the byte layout is valid VGP1.
            appendVector(&data, unitVector(seed: UInt64(index) &* 2 &+ 1, dim: embedDim))
            appendVector(&data, unitVector(seed: UInt64(index) &* 2 &+ 2, dim: embedDim))
        }
        return data
    }

    /// Append a little-endian fixed-width integer.
    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    /// Append an array of `Float` as little-endian IEEE-754 bytes.
    private static func appendVector(_ data: inout Data, _ vec: [Float]) {
        for f in vec {
            appendLE(&data, f.bitPattern)
        }
    }

    /// A deterministic L2-normalized `dim`-vector from a seed (a tiny SplitMix64
    /// PRNG mapped into [-1, 1), then normalized). Self-contained — no Foundation
    /// RNG, so it is identical on every platform.
    private static func unitVector(seed: UInt64, dim: Int) -> [Float] {
        var state = seed &+ 0x9E3779B97F4A7C15
        func next() -> Float {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            // Map the top 24 bits to [-1, 1).
            let unit = Float(z >> 40) / Float(1 << 24)   // [0, 1)
            return unit * 2 - 1
        }
        var v = [Float](repeating: 0, count: dim)
        var norm: Float = 0
        for i in 0..<dim {
            let x = next()
            v[i] = x
            norm += x * x
        }
        norm = norm.squareRoot()
        if norm > 0 {
            for i in 0..<dim { v[i] /= norm }
        } else {
            // Degenerate seed (vanishingly unlikely): emit a canonical basis vector.
            v[0] = 1
        }
        return v
    }

    /// Build a §-valid `policy.json` whose categories mirror the VGP1 bytes:
    /// same ids / thresholds / actions, captions in the 6–14 per-side range. The
    /// threshold is written as the `Double(Float)` widening of the packed value,
    /// so `Float(jsonThreshold)` narrows back to the identical bit pattern.
    private static func makeReferencePolicyJSON(categories: [SynthCategory]) throws -> Data {
        let cats: [[String: Any]] = categories.map { cat in
            [
                "id": cat.id,
                "description": "Synthesized reference category \(cat.id).",
                "positive_captions": cat.positiveCaptions,
                "negative_captions": cat.negativeCaptions,
                "threshold": Double(cat.threshold),
                "threshold_note": "Synthesized fixture threshold.",
                "action": PolicyBinCrossCheck.actionString(cat.action),
            ]
        }
        let object: [String: Any] = [
            "categories": cats,
            "clarifications": ["Synthesized reference policy for marketplace tests."],
            "calibration_note": "Synthesized fixture — not a real calibration.",
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
