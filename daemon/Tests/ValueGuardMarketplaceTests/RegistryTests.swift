import XCTest
@testable import ValueGuardMarketplace
import ValueGuardCore
import Foundation

/// Tests for the static registry round trip: `Reindexer` builds a registry tree
/// from real signed `.vgconfig` bundles (via ``FixtureBuilder``), then a
/// `RegistryClient` pointed at that tree over a `file://` base resolves
/// `author/slug[@version]`, downloads the named blob, and content-checks the
/// downloaded bytes against the index's `bundle_sha256`.
///
/// The whole suite runs **offline** — the client's `file://` transport exercises
/// the exact resolve → fetch → sha-check path the `https` transport uses, with no
/// network. Bundles come from `FixtureBuilder`, so the verify pipeline the
/// reindexer leans on is the production one (a bundle is only indexed if it truly
/// passes all nine verify steps).
final class RegistryTests: XCTestCase {

    /// Temp dirs / files to remove in `tearDown`.
    private var cleanup: [URL] = []

    override func tearDown() {
        let fm = FileManager.default
        for url in cleanup { try? fm.removeItem(at: url) }
        cleanup.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    /// A fresh temp directory registered for cleanup.
    private func tempDir(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanup.append(dir)
        return dir
    }

    /// Build a signed fixture bundle and copy it into `bundlesDir` (the reindexer
    /// scans a directory, so the bundle must live under one). Returns the bundle's
    /// whole-file SHA-256 (the content address the index will record).
    @discardableResult
    private func stageFixture(
        into bundlesDir: URL,
        named name: String,
        tweak: ((inout FixtureBuilder.Staging) -> Void)? = nil
    ) throws -> String {
        let fixture = try FixtureBuilder.buildSignedBundle(tweak: tweak)
        cleanup.append(fixture.bundle)
        let dest = bundlesDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: fixture.bundle, to: dest)
        return try Hashing.sha256Hex(ofFileAt: dest)
    }

    // MARK: - 1. reindex → resolve → download → sha-check

    /// Reindex a directory holding one valid bundle, then resolve + download it
    /// through a `file://` `RegistryClient`. The download must succeed and its
    /// bytes must round-trip the content address.
    func testReindexThenResolveAndDownload() throws {
        let bundlesDir = try tempDir("vg-reg-bundles")
        let registryDir = try tempDir("vg-reg-out")

        let sha = try stageFixture(into: bundlesDir, named: "fixture.vgconfig")

        // Build the registry tree.
        let result = try Reindexer.reindex(bundlesDir: bundlesDir, outDir: registryDir)
        XCTAssertEqual(result.indexedCount, 1, "the one valid bundle must be indexed")
        XCTAssertTrue(result.skipped.isEmpty, "no bundle should be skipped: \(result.skipped)")
        XCTAssertEqual(result.index.configs.count, 1)

        // The tree exists as specified by the §6 contract.
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: registryDir.appendingPathComponent("index.json").path))
        XCTAssertTrue(
            fm.fileExists(atPath: registryDir
                .appendingPathComponent("bundles")
                .appendingPathComponent("\(sha).vgconfig").path),
            "the content-addressed blob bundles/<sha>.vgconfig must exist"
        )
        let config = try XCTUnwrap(result.index.configs.first)
        let versionDir = registryDir
            .appendingPathComponent("configs")
            .appendingPathComponent(config.author)
            .appendingPathComponent(config.slug)
            .appendingPathComponent(config.latestVersion)
        XCTAssertTrue(fm.fileExists(atPath: versionDir.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(fm.fileExists(atPath: versionDir.appendingPathComponent("calibration.json").path))

        // The index records the content address and relative paths.
        let version = try XCTUnwrap(config.versions.first)
        XCTAssertEqual(version.bundleSha256, sha)
        XCTAssertEqual(version.bundlePath, "bundles/\(sha).vgconfig")
        XCTAssertEqual(version.manifestPath,
                       "configs/\(config.author)/\(config.slug)/\(config.latestVersion)/manifest.json")
        XCTAssertFalse(config.verified, "verified must be false in the prototype")
        XCTAssertTrue(Hashing.isValidSha256Hex(config.authorFingerprint))

        // index.json re-decodes through the public decoder (web frontend parity).
        let reDecoded = try RegistryIndex.decode(
            from: Data(contentsOf: registryDir.appendingPathComponent("index.json")))
        XCTAssertEqual(reDecoded.schemaVersion, 1)
        XCTAssertEqual(reDecoded.configs.first?.versions.first?.bundleSha256, sha)

        // Resolve + download through a file:// client.
        let client = RegistryClient(baseURL: registryDir)
        let resolved = try client.resolve(author: config.author, slug: config.slug, version: nil)
        XCTAssertEqual(resolved.version.version, config.latestVersion)
        XCTAssertTrue(resolved.bundleURL.isFileURL)

        let downloaded = try client.download(resolved)
        cleanup.append(downloaded)
        XCTAssertTrue(fm.fileExists(atPath: downloaded.path), "download must land a file")
        XCTAssertEqual(
            try Hashing.sha256Hex(ofFileAt: downloaded), sha,
            "downloaded bytes must match the content address"
        )

        // And the downloaded bundle still passes the full verify pipeline.
        let (report, extracted) = try BundleVerifier.verify(bundleAt: downloaded)
        cleanup.append(extracted)
        XCTAssertTrue(report.allPassed, "the downloaded bundle must verify: \(report.checks)")
    }

    // MARK: - 2. explicit @version resolution

    /// Requesting an exact `@version` returns that version; an unknown version is
    /// a precise `notFound` error.
    func testResolveExactVersion() throws {
        let bundlesDir = try tempDir("vg-reg-bundles")
        let registryDir = try tempDir("vg-reg-out")
        try stageFixture(into: bundlesDir, named: "fixture.vgconfig")
        let result = try Reindexer.reindex(bundlesDir: bundlesDir, outDir: registryDir)
        let config = try XCTUnwrap(result.index.configs.first)

        let client = RegistryClient(baseURL: registryDir)
        let resolved = try client.resolve(
            author: config.author, slug: config.slug, version: config.latestVersion)
        XCTAssertEqual(resolved.version.version, config.latestVersion)

        XCTAssertThrowsError(
            try client.resolve(author: config.author, slug: config.slug, version: "9.9.9")
        ) { error in
            guard case VGError.notFound = error else {
                return XCTFail("expected VGError.notFound for an unknown version, got \(error)")
            }
        }

        XCTAssertThrowsError(
            try client.resolve(author: "nobody", slug: "nothing", version: nil)
        ) { error in
            guard case VGError.notFound = error else {
                return XCTFail("expected VGError.notFound for an unknown config, got \(error)")
            }
        }
    }

    // MARK: - 3. tampered bundle_sha256 is rejected on download

    /// If the index's `bundle_sha256` does not match the blob's actual bytes, the
    /// client must refuse the download with `VGError.hashMismatch` — proving the
    /// content-address check gates the bytes before they reach verify/install.
    func testTamperedBundleShaRejected() throws {
        let bundlesDir = try tempDir("vg-reg-bundles")
        let registryDir = try tempDir("vg-reg-out")
        let realSha = try stageFixture(into: bundlesDir, named: "fixture.vgconfig")
        let result = try Reindexer.reindex(bundlesDir: bundlesDir, outDir: registryDir)
        let config = try XCTUnwrap(result.index.configs.first)
        let version = try XCTUnwrap(config.versions.first)

        // Forge a resolution whose recorded sha is wrong but whose bundle_path
        // points at the real (correct) blob — i.e. the index lies about the
        // content address. The client must catch the divergence on download.
        let wrongSha = String(repeating: "0", count: 64)
        XCTAssertNotEqual(wrongSha, realSha)
        let tamperedVersion = RegistryIndex.Version(
            version: version.version,
            createdAt: version.createdAt,
            bundleSha256: wrongSha,
            bundlePath: version.bundlePath,       // still the real blob
            manifestPath: version.manifestPath,
            sizeBytes: version.sizeBytes,
            categories: version.categories
        )
        let client = RegistryClient(baseURL: registryDir)
        let resolved = RegistryClient.Resolved(
            config: config,
            version: tamperedVersion,
            bundleURL: registryDir
                .appendingPathComponent("bundles")
                .appendingPathComponent("\(realSha).vgconfig")
        )

        XCTAssertThrowsError(try client.download(resolved)) { error in
            guard case let VGError.hashMismatch(field, expected, got) = error else {
                return XCTFail("expected VGError.hashMismatch, got \(error)")
            }
            XCTAssertEqual(field, "bundle_sha256")
            XCTAssertEqual(expected, wrongSha, "the mismatch must report the index's (wrong) sha")
            XCTAssertEqual(got, realSha, "the mismatch must report the blob's actual sha")
        }
    }

    // MARK: - 4. a bundle that fails verification is skipped, not aborted

    /// A directory mixing one valid bundle and one that fails verification (a
    /// post-sign tampered `policy.bin`) must index the valid one and skip the bad
    /// one with a reason — never abort the whole reindex.
    func testReindexSkipsUnverifiableBundle() throws {
        let bundlesDir = try tempDir("vg-reg-bundles")
        let registryDir = try tempDir("vg-reg-out")

        // A valid bundle.
        try stageFixture(into: bundlesDir, named: "good.vgconfig")

        // A bundle whose policy.bin is flipped AFTER signing, so MANIFEST.SHA256 /
        // author.sig are stale relative to the bytes — fails verification.
        try stageFixture(into: bundlesDir, named: "bad.vgconfig") { staging in
            staging.tamperAfterSign = { dir in
                let binURL = dir.appendingPathComponent("policy.bin")
                var bytes = try Data(contentsOf: binURL)
                if !bytes.isEmpty { bytes[bytes.count - 1] ^= 0xFF }
                try bytes.write(to: binURL, options: .atomic)
            }
        }

        let result = try Reindexer.reindex(bundlesDir: bundlesDir, outDir: registryDir)
        XCTAssertEqual(result.indexedCount, 1, "only the valid bundle should be indexed")
        XCTAssertEqual(result.skipped.count, 1, "the tampered bundle should be skipped")
        XCTAssertEqual(result.skipped.first?.bundle.lastPathComponent, "bad.vgconfig")
        XCTAssertFalse(result.skipped.first?.reason.isEmpty ?? true, "the skip must carry a reason")
        XCTAssertEqual(result.index.configs.count, 1)
    }

    // MARK: - 5. SemVer ordering / latest non-prerelease

    /// The `SemVer` ordering used for newest-first versions and `latest_version`:
    /// numeric precedence, releases outranking prereleases of the same core.
    func testSemVerOrdering() throws {
        let v100 = try XCTUnwrap(SemVer("1.0.0"))
        let v101 = try XCTUnwrap(SemVer("1.0.1"))
        let v110 = try XCTUnwrap(SemVer("1.1.0"))
        let v200 = try XCTUnwrap(SemVer("2.0.0"))
        let v200rc = try XCTUnwrap(SemVer("2.0.0-rc.1"))

        XCTAssertLessThan(v100, v101)
        XCTAssertLessThan(v101, v110)
        XCTAssertLessThan(v110, v200)
        // A prerelease ranks below its own release core.
        XCTAssertLessThan(v200rc, v200)
        XCTAssertTrue(v200rc.isPrerelease)
        XCTAssertFalse(v200.isPrerelease)
        // Build metadata is ignored for parsing/ordering.
        XCTAssertNotNil(SemVer("1.2.3+build.5"))
        // Malformed cores do not parse.
        XCTAssertNil(SemVer("1.2"))
        XCTAssertNil(SemVer("x.y.z"))
    }
}
