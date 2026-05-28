import XCTest
@testable import ValueGuardMarketplace
import ValueGuardCore

/// End-to-end verification tests over a *real* signed `.vgconfig` built by
/// ``FixtureBuilder`` from the repository's calibrated example `policy.bin` /
/// `policy.json`.
///
/// These tests are the integration counterpart to the pure-unit `SignVerifyTests`
/// / `ManifestValidatorTests`: they drive the full nine-step `BundleVerifier`
/// pipeline on disk (extract → manifest schema → content hashes → VGP1 parse →
/// cross-checks → `MANIFEST.SHA256` → public-key match → Ed25519 signature) and
/// assert both that a pristine bundle passes and that each distinct tamper
/// surface is caught with the *specific* failing check the design mandates.
///
/// Failure-model split exercised here (mirrors `BundleVerifier`'s contract):
/// - Hard failures (illegal layout / path traversal) are *thrown* as `VGError`
///   before any report is assembled — `testPathTraversalMemberRejected`.
/// - Content/crypto failures (hashes, cross-checks, digest, signature, key)
///   surface as failed `Check`s with `allPassed == false`, never a throw — every
///   other test here.
///
/// Tamper timing relative to signing:
/// - `tweak` runs *before* `MANIFEST.SHA256` is built and `author.sig` is
///   signed, so a tweak that mutates the manifest value flows into the signed
///   bundle (used for the cross-check test, where we deliberately keep the
///   signature valid so the *cross-check* — not the signature — is what fails).
/// - `Staging.tamperAfterSign` runs *after* the signature is written but before
///   the archive is created, leaving `MANIFEST.SHA256` / `author.sig` stale
///   relative to the mutated bytes (used for the hash / manifest / signature /
///   public-key tamper tests).
final class VerifyTamperTests: XCTestCase {

    // MARK: - Check labels (must match BundleVerifier's private Label enum)

    // BundleVerifier.Label is private, so the verify report identifies checks by
    // these exact human-readable strings. Keeping them here (rather than reaching
    // into the library) matches the CLI's own contract: it only ever prints the
    // label text. If a label changes in BundleVerifier these constants update in
    // lock-step.
    private enum Label {
        static let layout = "checking bundle layout"
        static let manifestSchema = "validating manifest.json"
        static let policyBinHash = "verifying policy.bin hash"
        static let policyJSONHash = "verifying policy.json hash"
        static let calibrationHash = "verifying calibration.json hash"
        static let manifestDigest = "verifying MANIFEST.SHA256"
        static let publicKey = "matching author public key"
        static let signature = "verifying signature"
        static let manifestCrossCheck = "cross-checking manifest vs policy.bin"
    }

    // MARK: - Cleanup tracking

    /// Temp `.vgconfig` files and extracted dirs to remove in `tearDown`, so the
    /// suite leaves nothing behind in `FileManager.temporaryDirectory`.
    private var cleanup: [URL] = []

    override func tearDown() {
        let fm = FileManager.default
        for url in cleanup {
            try? fm.removeItem(at: url)
        }
        cleanup.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    /// Verify a fixture bundle, registering the bundle file and the returned temp
    /// `extractedDir` for cleanup. Returns the report (the `extractedDir` is the
    /// verifier's responsibility to surface; `vg verify` deletes it, which we do
    /// in `tearDown`).
    private func verify(
        _ bundle: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> VerifyReport {
        cleanup.append(bundle)
        let (report, extractedDir) = try BundleVerifier.verify(bundleAt: bundle)
        cleanup.append(extractedDir)
        return report
    }

    /// Locate a check by its label, failing the test if it is absent (a missing
    /// check usually means a `Label` constant drifted from `BundleVerifier`).
    private func check(
        _ report: VerifyReport,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> VerifyReport.Check? {
        let found = report.checks.first { $0.label == label }
        if found == nil {
            XCTFail("expected a check labeled \"\(label)\"; got: "
                + report.checks.map(\.label).joined(separator: ", "),
                file: file, line: line)
        }
        return found
    }

    /// Assert a specific check is present and FAILED.
    private func assertFailed(
        _ report: VerifyReport,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let c = check(report, label, file: file, line: line) else { return }
        XCTAssertFalse(c.ok, "expected check \"\(label)\" to FAIL but it passed",
                       file: file, line: line)
    }

    /// Assert a specific check is present and PASSED.
    private func assertPassed(
        _ report: VerifyReport,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let c = check(report, label, file: file, line: line) else { return }
        XCTAssertTrue(c.ok, "expected check \"\(label)\" to pass but it FAILED"
            + (c.detail.map { " — \($0)" } ?? ""),
            file: file, line: line)
    }

    // MARK: - 1. Pristine bundle passes end-to-end

    /// A freshly built, untampered bundle must pass every check, expose the
    /// expected derived values, and report `registryVerified == false` (no
    /// pinned registry key in P0).
    func testVerifyValidBundlePasses() throws {
        let fixture = try FixtureBuilder.buildSignedBundle()
        let report = try verify(fixture.bundle)

        XCTAssertTrue(
            report.allPassed,
            "a pristine signed bundle must pass all checks; failed: "
                + report.checks.filter { !$0.ok }
                    .map { "\($0.label) [\($0.detail ?? "")]" }
                    .joined(separator: "; ")
        )

        // Every check, including the ones with no §4 example line, must be ok.
        for c in report.checks {
            XCTAssertTrue(c.ok, "check \"\(c.label)\" unexpectedly failed: \(c.detail ?? "")")
        }

        // Spot-check the load-bearing steps individually.
        assertPassed(report, Label.layout)
        assertPassed(report, Label.manifestSchema)
        assertPassed(report, Label.policyBinHash)
        assertPassed(report, Label.policyJSONHash)
        assertPassed(report, Label.calibrationHash)
        assertPassed(report, Label.manifestCrossCheck)
        assertPassed(report, Label.manifestDigest)
        assertPassed(report, Label.publicKey)
        assertPassed(report, Label.signature)

        // P0 never reports a verified registry badge.
        XCTAssertFalse(report.registryVerified, "P0 must never report a verified registry badge")

        // The author fingerprint is the bare-hex SHA-256 of the signing key's
        // public half, and matches the manifest's recorded public key.
        XCTAssertTrue(
            Hashing.isValidSha256Hex(report.authorFingerprint),
            "author fingerprint must be 64-char bare lowercase hex"
        )
        let pubRaw = try Ed25519.publicKeyRaw(fromBase64: fixture.manifest.author.publicKey)
        XCTAssertEqual(
            report.authorFingerprint,
            Ed25519.fingerprint(publicKeyRaw: pubRaw),
            "report fingerprint must match the manifest author public key"
        )

        // The whole-file content address is a well-formed bare hash.
        XCTAssertTrue(
            Hashing.isValidSha256Hex(report.bundleSha256),
            "bundle_sha256 must be 64-char bare lowercase hex"
        )

        // The decoded manifest round-trips its identity fields.
        XCTAssertEqual(report.manifest.author.handle, "fixture-author")
        XCTAssertEqual(report.manifest.configId, "personal-values-strict")
        XCTAssertEqual(report.manifest.version, "1.0.0")
    }

    // MARK: - 2. Tampered policy.bin → content-hash failure

    /// Flipping a byte of `policy.bin` *after* signing leaves the manifest's
    /// `policy_hash` and the bundled `MANIFEST.SHA256` stale, so the policy.bin
    /// hash check must FAIL (and, because the digest line for policy.bin no
    /// longer matches, so must `MANIFEST.SHA256` — and therefore the signature).
    func testTamperedPolicyBinFailsHash() throws {
        let fixture = try FixtureBuilder.buildSignedBundle { staging in
            staging.tamperAfterSign = { dir in
                let url = dir.appendingPathComponent("policy.bin")
                var bytes = try Data(contentsOf: url)
                // Flip a byte well past the VGP1 header so the file still parses
                // but its hash changes — isolating the *hash* check as the first
                // failure surface (a header flip could fail the VGP1 parse first).
                let idx = bytes.index(bytes.startIndex, offsetBy: bytes.count - 1)
                bytes[idx] ^= 0xFF
                try bytes.write(to: url, options: .atomic)
            }
        }

        let report = try verify(fixture.bundle)

        XCTAssertFalse(report.allPassed, "a flipped policy.bin byte must fail verification")
        assertFailed(report, Label.policyBinHash)
        // Cascades: the digest list covers policy.bin, so MANIFEST.SHA256 and the
        // signature over it must also fail.
        assertFailed(report, Label.manifestDigest)
        assertFailed(report, Label.signature)
    }

    // MARK: - 3. Tampered policy.json → content-hash failure

    /// Editing `policy.json` bytes after signing must fail `policy_json_hash`
    /// (and cascade into the digest + signature, since the digest covers it).
    func testTamperedPolicyJSONFailsHash() throws {
        let fixture = try FixtureBuilder.buildSignedBundle { staging in
            staging.tamperAfterSign = { dir in
                let url = dir.appendingPathComponent("policy.json")
                var bytes = try Data(contentsOf: url)
                // Append a byte of trailing whitespace: still valid-ish JSON
                // trailing, but a different byte stream → different hash.
                bytes.append(0x20)
                try bytes.write(to: url, options: .atomic)
            }
        }

        let report = try verify(fixture.bundle)

        XCTAssertFalse(report.allPassed, "an edited policy.json must fail verification")
        assertFailed(report, Label.policyJSONHash)
        assertFailed(report, Label.manifestDigest)
        assertFailed(report, Label.signature)
    }

    // MARK: - 4. Tampered manifest.json → MANIFEST.SHA256 line mismatch

    /// Rewriting `manifest.json`'s bytes after signing makes the recomputed
    /// `MANIFEST.SHA256` line for `manifest.json` disagree with the bundled
    /// digest, so the digest check (and the signature over it) must FAIL. The
    /// manifest must still decode and schema-validate, so the verifier reaches
    /// the digest stage rather than throwing early.
    func testTamperedManifestFailsManifestSha256() throws {
        let fixture = try FixtureBuilder.buildSignedBundle { staging in
            staging.tamperAfterSign = { dir in
                let url = dir.appendingPathComponent("manifest.json")
                let original = try Data(contentsOf: url)
                // Mutate a benign, still-schema-valid field by editing the raw
                // bytes: flip the display name text. We re-decode → mutate →
                // re-encode canonically so the file remains a valid §2 manifest
                // (the digest, not the schema, is the intended failure).
                var manifest = try Manifest.decode(from: original)
                let mutatedAuthor = Manifest.Author(
                    handle: manifest.author.handle,
                    displayName: "Tampered Display Name",
                    verified: manifest.author.verified,
                    publicKey: manifest.author.publicKey
                )
                manifest = Self.replacingAuthor(manifest, with: mutatedAuthor)
                let mutated = try CanonicalJSON.encode(manifest)
                XCTAssertNotEqual(mutated, original, "tamper must change the manifest bytes")
                try mutated.write(to: url, options: .atomic)
            }
        }

        let report = try verify(fixture.bundle)

        XCTAssertFalse(report.allPassed, "a post-sign manifest edit must fail verification")
        // The schema is still valid (we only changed a display name), so the
        // manifest schema check passes and the failure is the digest + signature.
        assertPassed(report, Label.manifestSchema)
        assertFailed(report, Label.manifestDigest)
        assertFailed(report, Label.signature)
    }

    // MARK: - 5. Corrupted signature → signature failure

    /// Corrupting `signatures/author.sig` after it is written (the bytes it signs
    /// are untouched, so `MANIFEST.SHA256` still matches) must isolate the
    /// *signature* check as the failure: Ed25519 verify returns false.
    func testBadSignatureFails() throws {
        let fixture = try FixtureBuilder.buildSignedBundle { staging in
            staging.tamperAfterSign = { dir in
                let url = dir.appendingPathComponent("signatures/author.sig")
                var sig = try Data(contentsOf: url)
                XCTAssertEqual(sig.count, 64, "Ed25519 signature must be 64 bytes")
                // Flip the first byte: still 64 bytes (so it's not a length/parse
                // failure) but no longer a valid signature over MANIFEST.SHA256.
                sig[sig.startIndex] ^= 0x01
                try sig.write(to: url, options: .atomic)
            }
        }

        let report = try verify(fixture.bundle)

        XCTAssertFalse(report.allPassed, "a corrupted author.sig must fail verification")
        // The signed message (MANIFEST.SHA256) is intact, so the digest check
        // still passes — isolating the signature as the sole failure.
        assertPassed(report, Label.manifestDigest)
        assertPassed(report, Label.publicKey)
        assertFailed(report, Label.signature)
    }

    // MARK: - 6. Mismatched public key → public-key / signature failure

    /// Replacing both `signatures/author.pub` and `manifest.author.public_key`
    /// with a *different, unrelated* key (so they still match each other and the
    /// public-key check passes) must fail the *signature* check, because the
    /// original private key signed `MANIFEST.SHA256` and the swapped public key
    /// cannot verify it.
    ///
    /// This is the realistic attack: an attacker who re-points the manifest at
    /// their own key without re-signing. The mismatch surfaces at the signature
    /// stage, not the `author.pub == public_key` stage.
    func testMismatchedPublicKeyFails() throws {
        // A second, unrelated keypair the attacker substitutes in.
        let attacker = Ed25519.generateKeypair()
        let attackerPubBase64 = attacker.publicRaw.base64EncodedString()

        let fixture = try FixtureBuilder.buildSignedBundle { staging in
            // Re-point the manifest's recorded public key BEFORE signing so the
            // manifest bytes are covered by the (still-original-key) signature.
            // We deliberately do NOT re-sign with the attacker key — the original
            // private key remains the signer, so the signature won't verify under
            // the swapped public key.
            let original = staging.manifest.author
            let swapped = Manifest.Author(
                handle: original.handle,
                displayName: original.displayName,
                verified: original.verified,
                publicKey: attackerPubBase64
            )
            staging.manifest = Self.replacingAuthor(staging.manifest, with: swapped)

            // Keep author.pub consistent with manifest.author.public_key so the
            // public-key MATCH check passes and the failure lands squarely on the
            // signature step.
            staging.tamperAfterSign = { dir in
                let url = dir.appendingPathComponent("signatures/author.pub")
                try Data(attackerPubBase64.utf8).write(to: url, options: .atomic)
            }
        }

        let report = try verify(fixture.bundle)

        XCTAssertFalse(report.allPassed, "a swapped author key with no re-sign must fail verification")
        // author.pub and manifest.author.public_key agree (both the attacker key),
        // so the public-key match check passes...
        assertPassed(report, Label.publicKey)
        // ...but the signature was made by the ORIGINAL private key, so it cannot
        // verify under the swapped public key.
        assertFailed(report, Label.signature)
    }

    // MARK: - 7. Threshold mismatch → manifest↔policy.bin cross-check failure

    /// Perturbing a manifest `thresholds[]` value (before signing, so the bundle
    /// stays internally consistent: hashes + digest + signature all valid) must
    /// fail the manifest-vs-policy.bin cross-check by exact `Float` bit-pattern
    /// inequality — and *only* that check.
    func testThresholdMismatchFailsCrossCheck() throws {
        let fixture = try FixtureBuilder.buildSignedBundle { staging in
            // Mutate the first threshold so its Float bit pattern no longer
            // matches policy.bin. Adding a clearly-different delta guarantees a
            // distinct Float even after the Double→Float narrowing in the check.
            var thresholds = staging.manifest.thresholds
            guard let first = thresholds.first else {
                XCTFail("fixture manifest has no thresholds to perturb")
                return
            }
            let bumped = Manifest.ThresholdEntry(
                id: first.id,
                threshold: first.threshold + 0.05,
                action: first.action
            )
            thresholds[0] = bumped
            staging.manifest = Self.replacingThresholds(staging.manifest, with: thresholds)
        }

        let report = try verify(fixture.bundle)

        XCTAssertFalse(report.allPassed, "a manifest threshold differing from policy.bin must fail")
        assertFailed(report, Label.manifestCrossCheck)
        // The bundle is otherwise internally consistent: the manifest still hashes
        // and signs correctly (the tweak ran before signing), so the hash, digest
        // and signature checks all pass — the cross-check is the sole failure.
        assertPassed(report, Label.policyBinHash)
        assertPassed(report, Label.manifestDigest)
        assertPassed(report, Label.signature)
    }

    // MARK: - 8. Path-traversal member → hard layout rejection (thrown)

    /// A bundle whose member list contains a path-traversal entry must be
    /// rejected by `Archive.assertSafeLayout` *before* extraction — a hard
    /// `VGError.bundleLayout` throw, not a soft failed check.
    ///
    /// We assert this two ways:
    ///  1. Directly against `assertSafeLayout` with synthetic malicious member
    ///     arrays (the path-traversal guard's contract, independent of tar), and
    ///  2. End-to-end: a real `.vgconfig` that actually *contains* a `../evil`
    ///     entry must make `BundleVerifier.verify` throw `VGError.bundleLayout`.
    func testPathTraversalMemberRejected() throws {
        // (1) Synthetic member arrays exercising each traversal / illegal shape.
        // A valid baseline (the full required set) must NOT throw.
        let validBaseline = [
            "manifest.json", "policy.bin", "policy.json", "calibration.json",
            "signatures/author.sig", "signatures/author.pub", "signatures/MANIFEST.SHA256",
        ]
        XCTAssertNoThrow(
            try Archive.assertSafeLayout(validBaseline),
            "the canonical required member set must pass the layout guard"
        )

        // Each of these augments the valid baseline with one illegal member, so
        // the ONLY reason to reject is the traversal/illegal entry.
        let illegalMembers: [String] = [
            "../evil",                 // parent-relative traversal
            "/abs/evil",               // absolute path
            "foo/../bar",              // embedded ".." component
            "./sneaky",                // leading "."
            "signatures/../escape",    // traversal out of signatures/
            "unknown.txt",             // unknown top-level member
            "signatures/evil.sig",     // unknown signatures/ member
            "nested/dir/file",         // nested member outside signatures/
        ]
        for bad in illegalMembers {
            let members = validBaseline + [bad]
            XCTAssertThrowsError(
                try Archive.assertSafeLayout(members),
                "assertSafeLayout must reject illegal member \"\(bad)\""
            ) { error in
                guard case VGError.bundleLayout = error else {
                    XCTFail("expected VGError.bundleLayout for \"\(bad)\", got \(error)")
                    return
                }
            }
        }

        // A missing required member must also be rejected (layout completeness).
        XCTAssertThrowsError(
            try Archive.assertSafeLayout(["manifest.json", "policy.bin"]),
            "a member set missing required files must be rejected"
        ) { error in
            guard case VGError.bundleLayout = error else {
                XCTFail("expected VGError.bundleLayout for an incomplete member set, got \(error)")
                return
            }
        }

        // (2) End-to-end: build a valid bundle, then repack it with an extra
        //     "../evil" entry actually present in the archive, and confirm verify
        //     throws bundleLayout before extraction.
        let fixture = try FixtureBuilder.buildSignedBundle()
        cleanup.append(fixture.bundle)
        let malicious = try makeBundleWithTraversalMember(basedOn: fixture.bundle)
        cleanup.append(malicious)

        XCTAssertThrowsError(
            try BundleVerifier.verify(bundleAt: malicious),
            "a bundle containing a traversal member must be rejected before extraction"
        ) { error in
            guard case VGError.bundleLayout = error else {
                XCTFail("expected VGError.bundleLayout from verify, got \(error)")
                return
            }
        }
    }

    // MARK: - 9. Symlink member → hard type rejection (representation split)

    /// A bundle whose `policy.bin` is actually a SYMLINK — not a regular file —
    /// must be rejected before extraction, even when the bundle is otherwise
    /// fully self-consistent.
    ///
    /// This reproduces the representation-split exploit: the signer-side digest
    /// walk (and the legacy verifier walk) lists only `isRegularFile` entries, so
    /// a symlinked `policy.bin` is *omitted* from `MANIFEST.SHA256` — yet the
    /// per-file hash step and the VGP1 parse step both *follow* the symlink. We
    /// build exactly that bundle: `policy.bin` is symlinked to the reference
    /// VGP1 file (same bytes, so the hash matches and the binary parses), the
    /// digest is recomputed by the signer walk (which omits the symlink), and
    /// `author.sig` is signed over that digest. Under the old name-only layout
    /// guard this passed with `allPassed == true`; the type-aware guard must now
    /// reject it.
    ///
    /// The fix is type-checked at layout time (step 1, before extraction), so the
    /// rejection is a *thrown* `VGError.bundleLayout`, not a soft failed check —
    /// the same hard-failure path as a path-traversal member.
    func testSymlinkPolicyBinMemberRejected() throws {
        // Target the symlink at the reference VGP1 file: identical bytes to the
        // staged policy.bin, so the manifest's policy_hash still matches and the
        // VGP1 parse still succeeds when the verifier follows the link — proving
        // the bundle is self-consistent and only the TYPE guard catches it.
        let symlinkTarget = FixtureBuilder.examplePolicyBinURL()

        let fixture = try FixtureBuilder.buildSignedBundle { staging in
            // Replace the regular policy.bin with a symlink BEFORE signing, so
            // the signer-side digest walk omits the (now non-regular) member and
            // the signature covers a digest that is self-consistent with the
            // bundle the verifier will see.
            do {
                try staging.replaceWithSymlink("policy.bin", target: symlinkTarget)
            } catch {
                XCTFail("could not stage policy.bin symlink: \(error)")
            }
        }
        cleanup.append(fixture.bundle)

        // Sanity: the archive really does carry policy.bin as a symlink (type
        // 'l'), so the test exercises the type guard rather than a tar that
        // silently dereferenced it.
        let typed = try Archive.listTyped(bundleAt: fixture.bundle)
        let policyBin = typed.first { $0.name == "policy.bin" }
        XCTAssertNotNil(policyBin, "archive must list a policy.bin member")
        XCTAssertEqual(
            policyBin?.typeChar, "l",
            "policy.bin must be archived as a symlink for this regression test"
        )
        XCTAssertEqual(
            policyBin?.isRegularFile, false,
            "policy.bin must NOT be classified as a regular file"
        )

        // The fix: verify must REJECT the symlinked member as a hard layout
        // error, before extraction. (Before the fix this returned a report with
        // allPassed == true.)
        XCTAssertThrowsError(
            try BundleVerifier.verify(bundleAt: fixture.bundle),
            "a bundle whose policy.bin is a symlink must be rejected"
        ) { error in
            guard case VGError.bundleLayout = error else {
                XCTFail("expected VGError.bundleLayout for a symlink member, got \(error)")
                return
            }
        }
    }

    // MARK: - Malicious-bundle construction

    /// Re-pack a valid `.vgconfig` into a new gzipped tar that *additionally*
    /// contains a `../evil` member, so `tar -tzf` lists a real traversal entry
    /// and `Archive.assertSafeLayout` must reject it.
    ///
    /// We extract the valid bundle's members into a staging dir, drop an `evil`
    /// file there, and invoke `/usr/bin/tar` directly with an explicit member
    /// list that includes the literal traversal path `../evil`. (`Archive.create`
    /// would also work, but listing `../evil` explicitly is clearest here and
    /// keeps the malicious-archive construction self-contained in the test.)
    private func makeBundleWithTraversalMember(basedOn validBundle: URL) throws -> URL {
        let fm = FileManager.default

        // Stage a child dir we will tar from, plus a sibling "evil" file that the
        // archive will reference as "../evil" relative to that child.
        let root = fm.temporaryDirectory
            .appendingPathComponent("vg-malicious-" + UUID().uuidString, isDirectory: true)
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        cleanup.append(root)

        // Unpack the valid bundle's contents into `stage`.
        try Archive.extract(bundleAt: validBundle, into: stage)

        // Write the sibling target the traversal entry will point at.
        try Data("pwned".utf8).write(
            to: root.appendingPathComponent("evil"),
            options: .atomic
        )

        // Build the malicious archive: the valid members (relative to `stage`)
        // plus the literal "../evil" traversal member.
        let out = fm.temporaryDirectory
            .appendingPathComponent("vg-malicious-" + UUID().uuidString + ".vgconfig")
        let members = [
            "manifest.json", "policy.bin", "policy.json", "calibration.json",
            "signatures/author.pub", "signatures/author.sig", "signatures/MANIFEST.SHA256",
            "../evil",
        ]
        var args = ["-czf", out.path, "--no-mac-metadata", "-C", stage.path]
        args.append(contentsOf: members)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw VGError.archive("malicious tar build failed (\(proc.terminationStatus)): \(stderr)")
        }

        // Sanity: the archive really does list the traversal member, so the test
        // is exercising the guard rather than a tar that silently dropped it.
        let listed = try Archive.list(bundleAt: out)
        XCTAssertTrue(
            listed.contains("../evil"),
            "malicious archive must actually contain the ../evil member; listed: \(listed)"
        )

        return out
    }

    // MARK: - Manifest field-replacement helpers

    // `Manifest` has `let` stored properties (no setters), so mutating a single
    // nested field means rebuilding the value through the public memberwise init
    // with one component swapped. These mirror the helper pattern in
    // `ManifestValidatorTests`.

    /// Return a copy of `manifest` with its `author` replaced.
    private static func replacingAuthor(_ manifest: Manifest, with author: Manifest.Author) -> Manifest {
        Manifest(
            schemaVersion: manifest.schemaVersion,
            configId: manifest.configId,
            name: manifest.name,
            description: manifest.description,
            author: author,
            license: manifest.license,
            version: manifest.version,
            createdAt: manifest.createdAt,
            modelRef: manifest.modelRef,
            policyHash: manifest.policyHash,
            policyJsonHash: manifest.policyJsonHash,
            calibrationHash: manifest.calibrationHash,
            thresholds: manifest.thresholds,
            calibrationMethod: manifest.calibrationMethod,
            calibrationSummary: manifest.calibrationSummary,
            categories: manifest.categories,
            compatibility: manifest.compatibility,
            forkOf: manifest.forkOf,
            tags: manifest.tags
        )
    }

    /// Return a copy of `manifest` with its `thresholds` replaced.
    private static func replacingThresholds(
        _ manifest: Manifest,
        with thresholds: [Manifest.ThresholdEntry]
    ) -> Manifest {
        Manifest(
            schemaVersion: manifest.schemaVersion,
            configId: manifest.configId,
            name: manifest.name,
            description: manifest.description,
            author: manifest.author,
            license: manifest.license,
            version: manifest.version,
            createdAt: manifest.createdAt,
            modelRef: manifest.modelRef,
            policyHash: manifest.policyHash,
            policyJsonHash: manifest.policyJsonHash,
            calibrationHash: manifest.calibrationHash,
            thresholds: thresholds,
            calibrationMethod: manifest.calibrationMethod,
            calibrationSummary: manifest.calibrationSummary,
            categories: manifest.categories,
            compatibility: manifest.compatibility,
            forkOf: manifest.forkOf,
            tags: manifest.tags
        )
    }
}
