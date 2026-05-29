import Foundation
import ValueGuardCore

/// The result of an offline `.vgconfig` verification: an ordered list of named
/// checks (each pass/fail with optional detail) plus the decoded manifest and a
/// handful of derived values the CLI and installer need.
///
/// `vg verify` prints one line per `Check` (label + `ok`/`FAIL`) and exits with
/// status `0` iff ``allPassed`` is `true`. `vg install` reuses the same report
/// to refuse installation when any check fails.
public struct VerifyReport: Sendable {
    /// One named verification step.
    public struct Check: Sendable {
        /// Human-readable label, e.g. `"verifying policy.bin hash"`.
        public let label: String
        /// Whether the check passed.
        public let ok: Bool
        /// Optional detail (failure reason, or an informational note such as the
        /// `"unverified"` status for an unpinned registry signature).
        public let detail: String?

        public init(label: String, ok: Bool, detail: String? = nil) {
            self.label = label
            self.ok = ok
            self.detail = detail
        }
    }

    /// The ordered checks performed, in §4 display order.
    public let checks: [Check]
    /// The decoded `manifest.json`.
    public let manifest: Manifest
    /// Bare lowercase SHA-256 hex of the author's raw 32-byte Ed25519 public key.
    public let authorFingerprint: String
    /// Bare lowercase SHA-256 hex of the *entire* `.vgconfig` file (content
    /// address; recorded as `bundle_sha256` in the lockfile on install).
    public let bundleSha256: String
    /// Whether the bundle is registry-verified. Always `false` in P0: there is
    /// no pinned registry key yet, so `signatures/registry.sig` (if present) is
    /// reported as `unverified` and the badge stays off.
    public let registryVerified: Bool

    /// `true` iff every check passed.
    public var allPassed: Bool {
        checks.allSatisfy { $0.ok }
    }

    public init(
        checks: [Check],
        manifest: Manifest,
        authorFingerprint: String,
        bundleSha256: String,
        registryVerified: Bool
    ) {
        self.checks = checks
        self.manifest = manifest
        self.authorFingerprint = authorFingerprint
        self.bundleSha256 = bundleSha256
        self.registryVerified = registryVerified
    }
}

/// Top-level offline verify orchestrator. Executes the load-bearing 9-step
/// VERIFY ORDER over a `.vgconfig` bundle and produces a `VerifyReport`.
///
/// The verification is entirely offline: structural layout, content hashes, the
/// `VGP1` policy.bin parse (via the canonical `ValueGuardCore` reader — never a
/// second parser), the three-way cross-checks between `manifest.json`,
/// `policy.json` and `policy.bin`, the `MANIFEST.SHA256` recomputation, and the
/// Ed25519 signature over that digest. No network, no registry trust.
///
/// Failure model:
/// - Problems that make a meaningful report impossible — a bad archive,
///   path-traversal / illegal layout, an undecodable manifest, or a manifest
///   that violates the §2 schema — are thrown as `VGError` *before* the report
///   is assembled (the signature stage is never reached on a malformed
///   manifest, per §VERIFY ORDER).
/// - Problems discovered *after* the manifest is sound — hash mismatches,
///   cross-check disagreements, a `MANIFEST.SHA256` mismatch, a public-key
///   mismatch, or a bad signature — are recorded as failed `Check`s so the CLI
///   can print the full check list, and `allPassed` reflects them (false). They
///   do not throw, so callers always receive the complete report.
public enum BundleVerifier {

    // MARK: - Check labels (§4 display order)

    private enum Label {
        static let layout = "checking bundle layout"
        static let manifestSchema = "validating manifest.json"
        static let policyBinHash = "verifying policy.bin hash"
        static let policyJSONHash = "verifying policy.json hash"
        static let calibrationHash = "verifying calibration.json hash"
        static let policyBinParse = "loading policy.bin (VGP1)"
        static let manifestCrossCheck = "cross-checking manifest vs policy.bin"
        static let policyJSONSchema = "validating policy.json"
        static let policyJSONCrossCheck = "cross-checking policy.json vs policy.bin"
        static let manifestDigest = "verifying MANIFEST.SHA256"
        static let publicKey = "matching author public key"
        static let signature = "verifying signature"
        static let registrySignature = "verifying registry signature"
    }

    // MARK: - Verify

    /// Verify the `.vgconfig` at `bundleURL`.
    ///
    /// Extracts the bundle to a fresh temp directory and runs the full 9-step
    /// verification in place. The temp `extractedDir` is returned so the caller
    /// can either consume it (the installer moves the validated version dir into
    /// the install tree) or delete it (`vg verify` removes it once it has the
    /// report). On a thrown error the temp dir is cleaned up automatically.
    ///
    /// - Returns: the assembled `VerifyReport` and the temp `extractedDir`.
    /// - Throws: `VGError` for hard failures (bad archive, illegal layout,
    ///   undecodable / schema-invalid manifest). Recoverable check failures do
    ///   not throw — inspect `report.allPassed`.
    public static func verify(bundleAt bundleURL: URL) throws -> (report: VerifyReport, extractedDir: URL) {
        // Whole-file content address, computed up front from the raw bytes.
        let bundleSha256 = try Hashing.sha256Hex(ofFileAt: bundleURL)

        // ---- Step 1: structural layout (no extraction) -------------------
        // List members WITH their tar entry type and reject on type, not name
        // alone: a member named e.g. `policy.bin` that is actually a symlink
        // would otherwise pass the name guard and be dereferenced by the hash /
        // VGP1-parse / digest steps. assertSafeLayout(typed:) rejects symlinks,
        // hardlinks, devices, fifos, and any non-regular member (the lone
        // `signatures/` directory excepted) before extraction.
        let typedMembers = try Archive.listTyped(bundleAt: bundleURL)
        try Archive.assertSafeLayout(typedMembers)

        // The validated regular-file member set (excludes the signatures/
        // directory entry). This is the EXACT set the MANIFEST.SHA256 digest is
        // built and verified over — never an independent filesystem walk — so
        // the digest can never silently disagree with what the hash / parse
        // steps read.
        let members = typedMembers
            .filter { $0.isRegularFile }
            .map { $0.name }

        // ---- Step 2: extract to a fresh temp dir -------------------------
        let extractedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vg-verify-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)
        } catch {
            throw VGError.io("could not create temp dir for verification: \(error.localizedDescription)")
        }

        // From here on, any thrown error must clean up the temp dir so callers
        // never leak it; a successful return hands ownership to the caller.
        do {
            try Archive.extract(bundleAt: bundleURL, into: extractedDir)

            let report = try runChecks(
                extractedDir: extractedDir,
                members: members,
                bundleSha256: bundleSha256
            )
            return (report, extractedDir)
        } catch {
            try? FileManager.default.removeItem(at: extractedDir)
            throw error
        }
    }

    // MARK: - Check pipeline

    /// Run steps 3–9 over an already-extracted bundle and assemble the report.
    private static func runChecks(
        extractedDir: URL,
        members: [String],
        bundleSha256: String
    ) throws -> VerifyReport {
        var checks: [VerifyReport.Check] = []

        // Layout already passed to reach this point (step 1).
        checks.append(.init(label: Label.layout, ok: true))

        let manifestURL = extractedDir.appendingPathComponent("manifest.json")
        let policyBinURL = extractedDir.appendingPathComponent("policy.bin")
        let policyJSONURL = extractedDir.appendingPathComponent("policy.json")
        let calibrationURL = extractedDir.appendingPathComponent("calibration.json")

        // ---- Step 3: decode + schema-validate manifest.json --------------
        // Hard failures: an undecodable or schema-invalid manifest throws here,
        // before any signature work (per the VERIFY ORDER).
        let manifestData = try readFile(manifestURL, what: "manifest.json")
        let manifest = try Manifest.decode(from: manifestData)
        try ManifestValidator.validate(manifest)
        checks.append(.init(label: Label.manifestSchema, ok: true))

        // The author fingerprint is derived from the (schema-validated, so
        // 32-byte-base64) public key. This succeeds because the validator has
        // already confirmed the base64/length shape.
        let authorPublicKeyRaw = try Ed25519.publicKeyRaw(fromBase64: manifest.author.publicKey)
        let authorFingerprint = Ed25519.fingerprint(publicKeyRaw: authorPublicKeyRaw)

        // ---- Step 4: recompute the three content hashes ------------------
        appendHashCheck(
            &checks,
            label: Label.policyBinHash,
            field: "policy_hash",
            fileURL: policyBinURL,
            expectedPrefixed: manifest.policyHash
        )
        appendHashCheck(
            &checks,
            label: Label.policyJSONHash,
            field: "policy_json_hash",
            fileURL: policyJSONURL,
            expectedPrefixed: manifest.policyJsonHash
        )
        appendHashCheck(
            &checks,
            label: Label.calibrationHash,
            field: "calibration_hash",
            fileURL: calibrationURL,
            expectedPrefixed: manifest.calibrationHash
        )

        // ---- Step 5: parse policy.bin (VGP1) + cross-check vs manifest ---
        // policy.bin is parsed by the canonical ValueGuardCore reader only.
        // A parse failure is recorded as a failed check (not thrown): the
        // bundle is structurally present but its binary is unreadable, which is
        // a verification result, not an orchestration error.
        let policy: ValueGuardCore.Policy?
        do {
            policy = try PolicyBinCrossCheck.load(policyBinURL)
            checks.append(.init(label: Label.policyBinParse, ok: true))
        } catch {
            policy = nil
            checks.append(.init(label: Label.policyBinParse, ok: false, detail: detail(error)))
        }

        if let policy {
            checks.append(crossCheckResult(label: Label.manifestCrossCheck) {
                try PolicyBinCrossCheck.crossCheck(manifest: manifest, policy: policy)
            })
        } else {
            checks.append(.init(
                label: Label.manifestCrossCheck,
                ok: false,
                detail: "skipped: policy.bin did not parse"
            ))
        }

        // ---- Step 6: validate policy.json + cross-check vs policy.bin ----
        let policyJSON: PolicyJSONDocument?
        do {
            let policyJSONData = try readFile(policyJSONURL, what: "policy.json")
            let doc = try PolicyJSONValidator.decode(from: policyJSONData)
            try PolicyJSONValidator.validate(doc)
            policyJSON = doc
            checks.append(.init(label: Label.policyJSONSchema, ok: true))
        } catch {
            policyJSON = nil
            checks.append(.init(label: Label.policyJSONSchema, ok: false, detail: detail(error)))
        }

        if let policy, let policyJSON {
            checks.append(crossCheckResult(label: Label.policyJSONCrossCheck) {
                try PolicyBinCrossCheck.crossCheck(policyJSON: policyJSON, policy: policy)
            })
        } else {
            checks.append(.init(
                label: Label.policyJSONCrossCheck,
                ok: false,
                detail: "skipped: policy.json or policy.bin unavailable"
            ))
        }

        // ---- Step 7: rebuild + compare MANIFEST.SHA256 -------------------
        let signaturesDir = extractedDir.appendingPathComponent("signatures", isDirectory: true)
        let manifestSha256URL = signaturesDir.appendingPathComponent("MANIFEST.SHA256")
        var manifestDigestBytes: Data?
        do {
            let expected = try ManifestDigest.build(
                forExtractedDir: extractedDir,
                coveredMembers: members
            )
            let onDisk = try readFile(manifestSha256URL, what: "signatures/MANIFEST.SHA256")
            if expected == onDisk {
                manifestDigestBytes = onDisk
                checks.append(.init(label: Label.manifestDigest, ok: true))
            } else {
                manifestDigestBytes = nil
                checks.append(.init(
                    label: Label.manifestDigest,
                    ok: false,
                    detail: "recomputed digest list does not match bundled "
                        + "signatures/MANIFEST.SHA256"
                ))
            }
        } catch {
            manifestDigestBytes = nil
            checks.append(.init(label: Label.manifestDigest, ok: false, detail: detail(error)))
        }

        // ---- Step 8: author.pub matches manifest.author.public_key -------
        let authorPubURL = signaturesDir.appendingPathComponent("author.pub")
        do {
            let pubData = try readFile(authorPubURL, what: "signatures/author.pub")
            let pubText = String(data: pubData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let bundledPubRaw = try Ed25519.publicKeyRaw(fromBase64: pubText)
            if bundledPubRaw == authorPublicKeyRaw {
                checks.append(.init(label: Label.publicKey, ok: true))
            } else {
                checks.append(.init(
                    label: Label.publicKey,
                    ok: false,
                    detail: "signatures/author.pub does not match manifest.author.public_key"
                ))
            }
        } catch {
            checks.append(.init(label: Label.publicKey, ok: false, detail: detail(error)))
        }

        // ---- Step 9: Ed25519-verify author.sig over MANIFEST.SHA256 ------
        let authorSigURL = signaturesDir.appendingPathComponent("author.sig")
        do {
            let sig = try readFile(authorSigURL, what: "signatures/author.sig")
            if let message = manifestDigestBytes {
                let ok = Ed25519.verify(
                    signature: sig,
                    message: message,
                    publicKeyRaw: authorPublicKeyRaw
                )
                checks.append(.init(
                    label: Label.signature,
                    ok: ok,
                    detail: ok ? nil : "Ed25519 signature over MANIFEST.SHA256 is invalid"
                ))
            } else {
                // MANIFEST.SHA256 didn't match / wasn't readable: a signature
                // over it cannot be trusted even if it verifies against tampered
                // bytes, so record the dependency failure explicitly.
                checks.append(.init(
                    label: Label.signature,
                    ok: false,
                    detail: "skipped: MANIFEST.SHA256 mismatch or unreadable"
                ))
            }
        } catch {
            checks.append(.init(label: Label.signature, ok: false, detail: detail(error)))
        }

        // registry.sig is OPTIONAL. In P0 there is no pinned registry key, so a
        // present signature is reported as informational/unverified and never
        // counts toward allPassed; an absent signature adds no check.
        if members.contains("signatures/registry.sig") {
            checks.append(.init(
                label: Label.registrySignature,
                ok: true,
                detail: "unverified (no pinned registry key in P0)"
            ))
        }

        return VerifyReport(
            checks: checks,
            manifest: manifest,
            authorFingerprint: authorFingerprint,
            bundleSha256: bundleSha256,
            registryVerified: false
        )
    }

    // MARK: - Step helpers

    /// Recompute the `sha256:`-prefixed hash of the file at `fileURL` and compare
    /// it to the manifest's expected value, appending a pass/fail `Check`.
    private static func appendHashCheck(
        _ checks: inout [VerifyReport.Check],
        label: String,
        field: String,
        fileURL: URL,
        expectedPrefixed: String
    ) {
        do {
            let got = try Hashing.sha256Prefixed(ofFileAt: fileURL)
            if got == expectedPrefixed {
                checks.append(.init(label: label, ok: true))
            } else {
                checks.append(.init(
                    label: label,
                    ok: false,
                    detail: "\(field): expected \(expectedPrefixed), got \(got)"
                ))
            }
        } catch {
            checks.append(.init(label: label, ok: false, detail: detail(error)))
        }
    }

    /// Run a cross-check body, mapping a thrown `VGError` to a failed `Check`.
    private static func crossCheckResult(
        label: String,
        _ body: () throws -> Void
    ) -> VerifyReport.Check {
        do {
            try body()
            return .init(label: label, ok: true)
        } catch {
            return .init(label: label, ok: false, detail: detail(error))
        }
    }

    // MARK: - Utilities

    /// Read a required bundle file, re-wrapping a missing/unreadable file as a
    /// `VGError.io` whose detail names the member.
    private static func readFile(_ url: URL, what: String) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw VGError.io("could not read \(what): \(error.localizedDescription)")
        }
    }

    /// Best-effort human detail for a thrown error: a `VGError`'s
    /// `errorDescription` (already prefixed by its case), else the localized
    /// description.
    private static func detail(_ error: Error) -> String {
        if let vg = error as? VGError, let message = vg.errorDescription {
            return message
        }
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return "\(error)"
    }
}
