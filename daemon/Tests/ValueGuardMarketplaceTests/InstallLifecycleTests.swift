import XCTest
@testable import ValueGuardMarketplace
import ValueGuardCore

/// End-to-end lifecycle tests for the install layer (`Installer` +
/// `InstallLayout` + `Lockfile` + `KnownKeys`) driven against a throwaway temp
/// `configs` root rather than the user's real Application Support tree.
///
/// Every test rents a fresh temp directory in `setUp` and points
/// `InstallLayout(configsDir:)` at it, so installs/activations/uninstalls never
/// touch `~/Library/Application Support/ValueGuard`. The real `.vgconfig`
/// bundles come from ``FixtureBuilder``, so the verify pipeline these tests lean
/// on is the production one — install only proceeds when a bundle truly passes
/// all nine verify steps.
///
/// Coverage (mirrors the §5 install/activate/uninstall + §5/§7 TOFU semantics):
/// - `install → list → activate → uninstall` happy path, including the lockfile
///   and `known_keys.json` bookkeeping each step writes.
/// - `activate` builds a *relative* `configs/active` symlink whose target is the
///   exact `"author/slug/version"` string, and the swap is an atomic `rename(2)`
///   (the active path is always a valid symlink, never a missing-link window).
/// - TOFU first-use records the author key; a second install under the *same*
///   handle with a *different* signing key is refused (`VGError.keyChanged`),
///   leaving the on-disk tree and lockfile untouched.
/// - Re-installing the same `author/slug/version` is an immutability error
///   (`VGError.alreadyInstalled`, §2 "republishing a version is forbidden").
final class InstallLifecycleTests: XCTestCase {

    // MARK: - Per-test temp configs root

    /// Fresh temp `configs` root for the test under way (deleted in `tearDown`).
    private var configsRoot: URL!
    /// `.vgconfig` files and other temp artifacts to remove in `tearDown`.
    private var cleanup: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        configsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vg-install-test-" + UUID().uuidString, isDirectory: true)
        // Intentionally do NOT create it: Installer.install must create the
        // configs root itself when handed an explicit-temp-root InstallLayout
        // (init(configsDir:) does not create the directory). The lifecycle tests
        // implicitly verify that by installing into a non-existent root.
    }

    override func tearDown() {
        let fm = FileManager.default
        if let root = configsRoot {
            try? fm.removeItem(at: root)
        }
        for url in cleanup {
            try? fm.removeItem(at: url)
        }
        cleanup.removeAll()
        configsRoot = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// An `Installer` rooted at this test's temp `configs` directory.
    private func makeInstaller() -> Installer {
        Installer(layout: InstallLayout(configsDir: configsRoot))
    }

    /// The layout used by `makeInstaller()`, for direct path assertions.
    private func makeLayout() -> InstallLayout {
        InstallLayout(configsDir: configsRoot)
    }

    /// Build a pristine signed fixture bundle and register it for cleanup.
    private func buildFixture(
        tweak: ((inout FixtureBuilder.Staging) -> Void)? = nil
    ) throws -> (bundle: URL, privateKeyRaw: Data, manifest: Manifest) {
        let fixture = try FixtureBuilder.buildSignedBundle(tweak: tweak)
        cleanup.append(fixture.bundle)
        return fixture
    }

    /// Build a fixture with an injected `keypair` and an optional custom `slug` /
    /// `version`, keeping the bundle internally consistent so it still passes the
    /// full verify pipeline.
    ///
    /// `FixtureBuilder` generates a fresh keypair per call, so two default builds
    /// share the same author *handle* but have *different* signing keys — which the
    /// installer's TOFU check would refuse. To install two configs under one
    /// author (the activate-swap test) we must sign both with the SAME key. The
    /// `tweak` runs before `MANIFEST.SHA256` is built/signed, so overriding
    /// `staging.privateKeyRaw` / `staging.publicKeyRaw`, re-pointing
    /// `manifest.author.public_key`, and rewriting `signatures/author.pub` to the
    /// injected key all flow into a coherently-signed bundle.
    private func buildFixture(
        keypair: (privateRaw: Data, publicRaw: Data),
        slug: String? = nil,
        version: String? = nil
    ) throws -> (bundle: URL, privateKeyRaw: Data, manifest: Manifest) {
        let pubBase64 = keypair.publicRaw.base64EncodedString()
        return try buildFixture { staging in
            // Sign with the injected key instead of the per-call random one.
            staging.privateKeyRaw = keypair.privateRaw
            staging.publicKeyRaw = keypair.publicRaw

            // Re-point the manifest's recorded public key (and optionally slug /
            // version) to stay consistent with the injected signing key.
            var manifest = staging.manifest
            manifest = Self.replacingAuthorPublicKey(manifest, with: pubBase64)
            if let slug { manifest = Self.replacingConfigId(manifest, with: slug) }
            if let version { manifest = Self.replacingVersion(manifest, with: version) }
            staging.manifest = manifest

            // FixtureBuilder writes author.pub from its own generated key BEFORE
            // the tweak runs; rewrite it to the injected public key so author.pub
            // == manifest.author.public_key and the signature verifies.
            staging.tamperAfterSign = { dir in
                try Data(pubBase64.utf8).write(
                    to: dir.appendingPathComponent("signatures/author.pub"),
                    options: .atomic
                )
            }
        }
    }

    /// The author fingerprint a bundle's signing key produces — the value the
    /// installer records in the lockfile / known_keys for that bundle. Derived
    /// from the manifest's recorded public key (which `FixtureBuilder` sets to the
    /// signing key's public half).
    private func fingerprint(of manifest: Manifest) throws -> String {
        let raw = try Ed25519.publicKeyRaw(fromBase64: manifest.author.publicKey)
        return Ed25519.fingerprint(publicKeyRaw: raw)
    }

    // MARK: - 1. install → list

    /// Installing a valid bundle materializes the full version directory, writes a
    /// single lockfile entry with the correct content-address + fingerprint, and
    /// records the author key in `known_keys.json` (first use). `list()` then
    /// reports exactly that one config, inactive until `activate`.
    func testInstallThenList() throws {
        let fixture = try buildFixture()
        let installer = makeInstaller()
        let layout = makeLayout()

        let coords = try installer.install(bundleAt: fixture.bundle)
        XCTAssertEqual(coords.author, "fixture-author")
        XCTAssertEqual(coords.slug, "personal-values-strict")
        XCTAssertEqual(coords.version, "1.0.0")

        // Version directory exists with all five members + the signatures/ dir.
        let versionDir = layout.versionDir(author: coords.author, slug: coords.slug, version: coords.version)
        let fm = FileManager.default
        for member in ["manifest.json", "policy.bin", "policy.json", "calibration.json"] {
            XCTAssertTrue(
                fm.fileExists(atPath: versionDir.appendingPathComponent(member).path),
                "installed version dir must contain \(member)"
            )
        }
        var sigIsDir: ObjCBool = false
        XCTAssertTrue(
            fm.fileExists(atPath: versionDir.appendingPathComponent("signatures").path, isDirectory: &sigIsDir)
                && sigIsDir.boolValue,
            "installed version dir must contain the signatures/ directory"
        )
        for sig in ["author.pub", "author.sig", "MANIFEST.SHA256"] {
            XCTAssertTrue(
                fm.fileExists(atPath: versionDir.appendingPathComponent("signatures").appendingPathComponent(sig).path),
                "signatures/ must contain \(sig)"
            )
        }

        // Lockfile has exactly one entry with the right coordinates + metadata.
        let lockfile = try Lockfile.load(layout.lockfileURL)
        XCTAssertEqual(lockfile.schemaVersion, 1)
        XCTAssertNil(lockfile.active, "nothing is active until activate() is called")
        XCTAssertEqual(lockfile.configs.count, 1)
        let entry = try XCTUnwrap(lockfile.entry(author: coords.author, slug: coords.slug))
        XCTAssertEqual(entry.installedVersion, "1.0.0")
        XCTAssertNil(entry.pin, "P0 never sets a pin")
        XCTAssertTrue(Hashing.isValidSha256Hex(entry.bundleSha256), "bundle_sha256 must be bare 64-hex")
        XCTAssertEqual(
            entry.bundleSha256,
            try Hashing.sha256Hex(ofFileAt: fixture.bundle),
            "lockfile bundle_sha256 must be the whole-file SHA-256 of the .vgconfig"
        )
        let expectedFingerprint = try fingerprint(of: fixture.manifest)
        XCTAssertEqual(entry.authorKeyFingerprint, expectedFingerprint)

        // known_keys recorded the handle on first use (full 64-hex fingerprint).
        let known = try KnownKeys.load(layout.knownKeysURL)
        XCTAssertEqual(known.schemaVersion, 1)
        let record = try XCTUnwrap(known.keys["fixture-author"], "first install must record the author key")
        XCTAssertEqual(record.fingerprint, expectedFingerprint)
        XCTAssertEqual(record.publicKey, fixture.manifest.author.publicKey)
        XCTAssertFalse(record.firstSeen.isEmpty, "first_seen must be set")

        // list() reflects exactly the installed config, inactive.
        let listed = try installer.list()
        XCTAssertEqual(listed.count, 1)
        let only = try XCTUnwrap(listed.first)
        XCTAssertEqual(only.author, "fixture-author")
        XCTAssertEqual(only.slug, "personal-values-strict")
        XCTAssertEqual(only.version, "1.0.0")
        XCTAssertFalse(only.active, "freshly installed config is inactive until activate()")
        XCTAssertEqual(only.fingerprint, expectedFingerprint)
    }

    // MARK: - 2. activate creates a relative symlink

    /// `activate` must point `configs/active` at the *relative* target
    /// `"author/slug/version"` (location-independent so the tree can move), and
    /// resolving that link must reach the installed `policy.bin`. `list()` then
    /// marks the config active, and re-activating is idempotent.
    func testActivateCreatesRelativeSymlink() throws {
        let fixture = try buildFixture()
        let installer = makeInstaller()
        let layout = makeLayout()

        try installer.install(bundleAt: fixture.bundle)
        try installer.activate(author: "fixture-author", slug: "personal-values-strict")

        let fm = FileManager.default

        // The active path is a symlink (not a regular dir/file).
        let attrs = try fm.attributesOfItem(atPath: layout.activeSymlink.path)
        XCTAssertEqual(
            attrs[.type] as? FileAttributeType, .typeSymbolicLink,
            "configs/active must be a symbolic link"
        )

        // Its raw target is the RELATIVE "author/slug/version" — not an absolute
        // path. destinationOfSymbolicLink reads the link without following it.
        let target = try fm.destinationOfSymbolicLink(atPath: layout.activeSymlink.path)
        XCTAssertEqual(
            target, "fixture-author/personal-values-strict/1.0.0",
            "active symlink target must be the relative author/slug/version string"
        )
        XCTAssertFalse(
            (target as NSString).isAbsolutePath,
            "active symlink target must be relative, not absolute"
        )

        // Resolving the link reaches the installed policy.bin.
        let resolvedPolicyBin = layout.activeSymlink
            .resolvingSymlinksInPath()
            .appendingPathComponent("policy.bin")
        XCTAssertTrue(
            fm.fileExists(atPath: resolvedPolicyBin.path),
            "resolving configs/active must reach the installed policy.bin"
        )

        // list() now marks the config active.
        let listedActive = try installer.list()
        XCTAssertEqual(listedActive.count, 1)
        XCTAssertTrue(try XCTUnwrap(listedActive.first).active, "the activated config must report active == true")

        // Lockfile active field is kept in sync.
        let lock = try Lockfile.load(layout.lockfileURL)
        XCTAssertEqual(lock.active, "fixture-author/personal-values-strict")

        // current() resolves to the same config.
        let cur = try XCTUnwrap(try installer.current())
        XCTAssertEqual(cur.author, "fixture-author")
        XCTAssertEqual(cur.slug, "personal-values-strict")
        XCTAssertEqual(cur.version, "1.0.0")
        XCTAssertTrue(cur.active)

        // Re-activating is idempotent: same target, still one active config.
        XCTAssertNoThrow(try installer.activate(author: "fixture-author", slug: "personal-values-strict"))
        let targetAgain = try fm.destinationOfSymbolicLink(atPath: layout.activeSymlink.path)
        XCTAssertEqual(targetAgain, "fixture-author/personal-values-strict/1.0.0")
        XCTAssertTrue(try XCTUnwrap(try installer.list().first).active)
    }

    // MARK: - 3. activate is an atomic rename swap

    /// Swapping the active config from one installed version to another must never
    /// leave `configs/active` missing: before *and* after the swap, the path is a
    /// valid symlink resolving to a real `policy.bin`. We install two distinct
    /// configs (same author, different slug) and assert the active link is always
    /// well-formed and lands on the new target.
    func testActivateIsAtomicRename() throws {
        let installer = makeInstaller()
        let layout = makeLayout()
        let fm = FileManager.default

        // Two distinct configs under the same author handle. They MUST share a
        // signing key: each FixtureBuilder build otherwise generates a fresh key,
        // and installing the second under the same handle with a different key
        // would (correctly) trip the TOFU key-change refusal. Inject one keypair
        // into both so the only difference is the slug.
        let sharedKey = Ed25519.generateKeypair()
        let first = try buildFixture(keypair: sharedKey, slug: "config-alpha")
        let second = try buildFixture(keypair: sharedKey, slug: "config-beta")

        try installer.install(bundleAt: first.bundle)
        try installer.install(bundleAt: second.bundle)

        // Activate the first; the active link must be valid and resolve to alpha.
        try installer.activate(author: "fixture-author", slug: "config-alpha")
        assertActiveSymlinkValid(
            layout: layout, fm: fm,
            expectedTarget: "fixture-author/config-alpha/1.0.0"
        )

        // Swap to the second. rename(2) replaces the existing link in one step:
        // the active path is a valid symlink before this call (asserted above) and
        // a valid symlink after it (asserted below) — there is no intermediate
        // missing-symlink state, because rename(2) atomically replaces the entry.
        try installer.activate(author: "fixture-author", slug: "config-beta")
        assertActiveSymlinkValid(
            layout: layout, fm: fm,
            expectedTarget: "fixture-author/config-beta/1.0.0"
        )

        // The lockfile active field reflects the latest swap.
        let lock = try Lockfile.load(layout.lockfileURL)
        XCTAssertEqual(lock.active, "fixture-author/config-beta")

        // list() marks only beta active.
        let listed = try installer.list()
        let alpha = try XCTUnwrap(listed.first { $0.slug == "config-alpha" })
        let beta = try XCTUnwrap(listed.first { $0.slug == "config-beta" })
        XCTAssertFalse(alpha.active, "alpha must no longer be active after swapping to beta")
        XCTAssertTrue(beta.active, "beta must be active after the swap")
    }

    /// Assert `configs/active` is a symbolic link whose raw target equals
    /// `expectedTarget` and which resolves to a real `policy.bin` — i.e. the
    /// active path is in a valid (never missing/dangling) state.
    private func assertActiveSymlinkValid(
        layout: InstallLayout,
        fm: FileManager,
        expectedTarget: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let path = layout.activeSymlink.path
        do {
            let attrs = try fm.attributesOfItem(atPath: path)
            XCTAssertEqual(
                attrs[.type] as? FileAttributeType, .typeSymbolicLink,
                "configs/active must be a symbolic link", file: file, line: line
            )
            let target = try fm.destinationOfSymbolicLink(atPath: path)
            XCTAssertEqual(target, expectedTarget,
                           "active symlink target mismatch", file: file, line: line)
            let resolvedBin = layout.activeSymlink
                .resolvingSymlinksInPath()
                .appendingPathComponent("policy.bin")
            XCTAssertTrue(
                fm.fileExists(atPath: resolvedBin.path),
                "active symlink must resolve to a real policy.bin (no dangling/missing link)",
                file: file, line: line
            )
        } catch {
            XCTFail("configs/active must be a valid symlink: \(error)", file: file, line: line)
        }
    }

    // MARK: - 4. uninstall removes the tree + lockfile entry

    /// Uninstalling an active config removes its directory tree, drops its
    /// lockfile entry, and clears `configs/active` (and the lockfile `active`
    /// field) since it pointed at this config. `list()` is then empty.
    func testUninstallRemovesTreeAndLockfileEntry() throws {
        let fixture = try buildFixture()
        let installer = makeInstaller()
        let layout = makeLayout()
        let fm = FileManager.default

        try installer.install(bundleAt: fixture.bundle)
        try installer.activate(author: "fixture-author", slug: "personal-values-strict")

        // Sanity: it is installed and active before uninstall.
        let slugDir = layout.slugDir(author: "fixture-author", slug: "personal-values-strict")
        XCTAssertTrue(fm.fileExists(atPath: slugDir.path), "slug dir must exist before uninstall")
        XCTAssertTrue(
            fm.fileExists(atPath: layout.activeSymlink.path),
            "active symlink must exist before uninstall (it pointed at this config)"
        )

        try installer.uninstall(author: "fixture-author", slug: "personal-values-strict")

        // The slug directory tree is gone.
        XCTAssertFalse(
            fm.fileExists(atPath: slugDir.path),
            "uninstall must remove the entire slug directory tree"
        )

        // The active symlink is cleared (it pointed at the removed config), so no
        // dangling link is left behind.
        XCTAssertFalse(
            fm.fileExists(atPath: layout.activeSymlink.path),
            "uninstall must clear the active symlink when it named the removed config"
        )
        // destinationOfSymbolicLink should now throw (no link present).
        XCTAssertThrowsError(
            try fm.destinationOfSymbolicLink(atPath: layout.activeSymlink.path),
            "active symlink must be removed, not left dangling"
        )

        // Lockfile entry is gone and active is cleared.
        let lock = try Lockfile.load(layout.lockfileURL)
        XCTAssertTrue(lock.configs.isEmpty, "uninstall must drop the lockfile entry")
        XCTAssertNil(lock.active, "uninstall must clear the lockfile active field")

        // list() reflects an empty install set.
        XCTAssertTrue(try installer.list().isEmpty, "list() must be empty after uninstalling the only config")
        XCTAssertNil(try installer.current(), "current() must be nil after uninstalling the active config")

        // Uninstalling a config that is not installed is a clean error.
        XCTAssertThrowsError(
            try installer.uninstall(author: "fixture-author", slug: "personal-values-strict")
        ) { error in
            guard case VGError.notInstalled = error else {
                XCTFail("expected VGError.notInstalled for a missing config, got \(error)")
                return
            }
        }
    }

    // MARK: - 5. TOFU first-use records the key

    /// The first install of a bundle from an unseen author handle records that
    /// author's public key + fingerprint in `known_keys.json` (trust-on-first-use)
    /// and stamps a `first_seen` timestamp.
    func testTOFUFirstUseRecordsKey() throws {
        let fixture = try buildFixture()
        let installer = makeInstaller()
        let layout = makeLayout()

        // No known_keys before install.
        let before = try KnownKeys.load(layout.knownKeysURL)
        XCTAssertNil(before.keys["fixture-author"], "the author must be unseen before first install")

        try installer.install(bundleAt: fixture.bundle)

        // After install the handle is recorded with the signing key's fingerprint.
        let after = try KnownKeys.load(layout.knownKeysURL)
        let record = try XCTUnwrap(
            after.keys["fixture-author"],
            "first install must record the author key (trust on first use)"
        )
        let expectedFingerprint = try fingerprint(of: fixture.manifest)
        XCTAssertEqual(record.fingerprint, expectedFingerprint)
        XCTAssertTrue(Hashing.isValidSha256Hex(record.fingerprint), "stored fingerprint must be full 64-hex")
        XCTAssertEqual(record.publicKey, fixture.manifest.author.publicKey)
        XCTAssertFalse(record.firstSeen.isEmpty, "first_seen must be stamped on first use")

        // A repeated check against the recorded key reports a match (not first-use,
        // not changed) — the key is now pinned.
        switch after.check(handle: "fixture-author", fingerprint: expectedFingerprint) {
        case .matches:
            break
        default:
            XCTFail("the recorded key must match on a subsequent check")
        }
    }

    // MARK: - 6. TOFU key change is refused

    /// A second install under the *same* author handle but signed with a
    /// *different* key must be refused with `VGError.keyChanged`, and must leave
    /// the on-disk tree, lockfile, and known_keys exactly as the first install
    /// left them (no partial state, no overwrite).
    ///
    /// The TOFU check is keyed on the author *handle*, and `Installer.install`
    /// runs the immutability (`alreadyInstalled`) guard on the exact
    /// `author/slug/version` directory *before* the TOFU check. So the second
    /// bundle uses a DIFFERENT slug (a new config from the same author) to clear
    /// the immutability guard and reach the key check — modelling an author whose
    /// signing key rotated between two of their configs. Each independent
    /// `FixtureBuilder.buildSignedBundle()` call generates a fresh Ed25519 keypair
    /// but reuses the same handle (`fixture-author`), giving us the key change.
    func testTOFUKeyChangeRefuses() throws {
        let installer = makeInstaller()
        let layout = makeLayout()

        // First install pins key A under fixture-author.
        let first = try buildFixture()
        try installer.install(bundleAt: first.bundle)
        let pinnedFingerprint = try fingerprint(of: first.manifest)

        // Capture the post-first-install state to prove the refused install is a
        // no-op on disk.
        let known1 = try KnownKeys.load(layout.knownKeysURL)
        let lock1 = try Lockfile.load(layout.lockfileURL)
        XCTAssertEqual(known1.keys["fixture-author"]?.fingerprint, pinnedFingerprint)
        XCTAssertEqual(lock1.configs.count, 1)

        // Second bundle: same handle, DIFFERENT slug (clears the immutability
        // guard) and a DIFFERENT signing key (the per-call random keypair).
        let second = try buildFixture { staging in
            staging.manifest = Self.replacingConfigId(staging.manifest, with: "rotated-key-config")
        }
        let newFingerprint = try fingerprint(of: second.manifest)
        XCTAssertNotEqual(
            newFingerprint, pinnedFingerprint,
            "the two fixtures must be signed with different keys for this test to be meaningful"
        )

        XCTAssertThrowsError(
            try installer.install(bundleAt: second.bundle),
            "installing a config from a known handle under a different key must be refused"
        ) { error in
            guard case let VGError.keyChanged(handle, oldFingerprint, newFp) = error else {
                XCTFail("expected VGError.keyChanged, got \(error)")
                return
            }
            XCTAssertEqual(handle, "fixture-author")
            XCTAssertEqual(oldFingerprint, pinnedFingerprint, "keyChanged must report the previously-pinned fingerprint")
            XCTAssertEqual(newFp, newFingerprint, "keyChanged must report the rejected bundle's fingerprint")
        }

        // The refusal happens before any disk mutation: known_keys still pins key
        // A, the lockfile is unchanged, and no second version dir was created.
        let known2 = try KnownKeys.load(layout.knownKeysURL)
        XCTAssertEqual(
            known2.keys["fixture-author"]?.fingerprint, pinnedFingerprint,
            "a refused install must not overwrite the pinned key"
        )
        XCTAssertEqual(known2.keys.count, 1, "no extra known_keys entry may be written on refusal")

        let lock2 = try Lockfile.load(layout.lockfileURL)
        XCTAssertEqual(lock2.configs.count, 1, "a refused install must not add a lockfile entry")
        XCTAssertEqual(
            lock2.configs.first?.authorKeyFingerprint, pinnedFingerprint,
            "the lockfile entry's fingerprint must remain key A's"
        )

        // The installed tree is unchanged: still exactly one version dir, the one
        // from the first install, and the refused config's slug dir was never
        // created on disk.
        let listed = try installer.list()
        XCTAssertEqual(listed.count, 1, "a refused install must not register a second config")
        XCTAssertEqual(listed.first?.slug, "personal-values-strict")
        XCTAssertEqual(listed.first?.fingerprint, pinnedFingerprint)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.slugDir(author: "fixture-author", slug: "rotated-key-config").path
            ),
            "a refused install must not leave the rejected config's directory tree on disk"
        )
    }

    // MARK: - 7. Re-installing the same version is rejected

    /// Installing the same `author/slug/version` twice is an immutability error
    /// (§2 forbids republishing a version). The second install must throw
    /// `VGError.alreadyInstalled` and leave the first install's state intact.
    func testReinstallSameVersionRejected() throws {
        let fixture = try buildFixture()
        let installer = makeInstaller()
        let layout = makeLayout()

        try installer.install(bundleAt: fixture.bundle)
        XCTAssertEqual(try installer.list().count, 1)

        // Re-installing the exact same bundle (same author/slug/version) is
        // refused — the version directory already exists on disk.
        XCTAssertThrowsError(
            try installer.install(bundleAt: fixture.bundle),
            "re-installing the same author/slug/version must be rejected (immutability)"
        ) { error in
            guard case VGError.alreadyInstalled = error else {
                XCTFail("expected VGError.alreadyInstalled, got \(error)")
                return
            }
        }

        // The first install's state is intact: still exactly one config, still the
        // same version, lockfile unchanged in count.
        let listed = try installer.list()
        XCTAssertEqual(listed.count, 1, "a rejected reinstall must not duplicate the config")
        XCTAssertEqual(listed.first?.version, "1.0.0")
        let lock = try Lockfile.load(layout.lockfileURL)
        XCTAssertEqual(lock.configs.count, 1)
    }

    // MARK: - Manifest field-replacement helpers

    // `Manifest` exposes only `let` stored properties, so changing a single field
    // means rebuilding the value through the public memberwise init with one
    // component swapped (the same pattern used by `ManifestValidatorTests` /
    // `VerifyTamperTests`).

    /// Return a copy of `manifest` with its `config_id` (install slug) replaced.
    private static func replacingConfigId(_ manifest: Manifest, with configId: String) -> Manifest {
        Manifest(
            schemaVersion: manifest.schemaVersion,
            configId: configId,
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
            thresholds: manifest.thresholds,
            calibrationMethod: manifest.calibrationMethod,
            calibrationSummary: manifest.calibrationSummary,
            categories: manifest.categories,
            compatibility: manifest.compatibility,
            forkOf: manifest.forkOf,
            tags: manifest.tags
        )
    }

    /// Return a copy of `manifest` with its `version` replaced.
    private static func replacingVersion(_ manifest: Manifest, with version: String) -> Manifest {
        Manifest(
            schemaVersion: manifest.schemaVersion,
            configId: manifest.configId,
            name: manifest.name,
            description: manifest.description,
            author: manifest.author,
            license: manifest.license,
            version: version,
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

    /// Return a copy of `manifest` with its `author.public_key` replaced (handle,
    /// display name, and verified flag preserved).
    private static func replacingAuthorPublicKey(_ manifest: Manifest, with publicKeyBase64: String) -> Manifest {
        let author = Manifest.Author(
            handle: manifest.author.handle,
            displayName: manifest.author.displayName,
            verified: manifest.author.verified,
            publicKey: publicKeyBase64
        )
        return Manifest(
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
}
