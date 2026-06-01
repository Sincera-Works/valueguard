import XCTest
@testable import ValueGuardMarketplace
import ValueGuardCore
import Foundation

/// Round-trip tests for the producer-side ``Packer``: a bundle assembled by the
/// packer must pass every step of the verifier, the inverse of the pipeline that
/// the rest of the suite exercises from the verifier side.
///
/// The input artifacts are the same reference `policy.bin` / `policy.json` the
/// verify / install tests use (resolved portably by ``FixtureBuilder`` — committed
/// example when present, synthesized VGP1 otherwise), so the packer is tested
/// against the production policy shape, not a hand-rolled fixture.
final class PackerTests: XCTestCase {

    /// Stage the reference `policy.bin` / `policy.json` into a fresh input dir and
    /// return it. (The packer reads `policy.bin` / `policy.json` from a directory;
    /// the reference URLs may point at the committed examples, so copy them into a
    /// throwaway dir rather than packing in place.)
    private func makeInputDir() throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("vg-packer-input-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(contentsOf: FixtureBuilder.examplePolicyBinURL())
            .write(to: dir.appendingPathComponent("policy.bin"), options: .atomic)
        try Data(contentsOf: FixtureBuilder.examplePolicyJSONURL())
            .write(to: dir.appendingPathComponent("policy.json"), options: .atomic)
        return dir
    }

    /// A bundle packed from the reference artifacts verifies end to end.
    func testPackedBundleVerifies() throws {
        let fm = FileManager.default
        let inputDir = try makeInputDir()
        defer { try? fm.removeItem(at: inputDir) }

        let keypair = Ed25519.generateKeypair()
        let outputURL = fm.temporaryDirectory
            .appendingPathComponent("vg-packer-" + UUID().uuidString + ".vgconfig")
        defer { try? fm.removeItem(at: outputURL) }

        let result = try Packer.pack(
            inputDir: inputDir,
            author: Packer.Author(handle: "sincera", displayName: "Sincera Works"),
            privateKeyRaw: keypair.privateRaw,
            publicKeyRaw: keypair.publicRaw,
            metadata: Packer.ConfigMetadata(
                configId: "personal-values",
                name: "Personal Values",
                description: "Round-trip test config packed from the reference example.",
                version: "1.0.0",
                license: "MIT",
                tags: ["personal", "test"],
                modelRef: Packer.ModelRefDigests(
                    weightsSha256: String(repeating: "a", count: 64),
                    coremlPackageSha256: String(repeating: "b", count: 64)
                )
            ),
            outputBundle: outputURL
        )

        XCTAssertEqual(result.bundle, outputURL)
        // Real digests supplied, so no model-digest placeholder warnings.
        XCTAssertTrue(result.warnings.isEmpty, "unexpected warnings: \(result.warnings.map(\.message))")
        XCTAssertTrue(fm.fileExists(atPath: outputURL.path), "packer did not write the bundle")

        let (report, extracted) = try BundleVerifier.verify(bundleAt: outputURL)
        defer { try? fm.removeItem(at: extracted) }
        XCTAssertTrue(report.allPassed, "packed bundle should verify; checks: \(report.checks)")
    }

    /// Omitting the model digests still produces a valid bundle (P0 shape-checks
    /// only) but raises placeholder warnings.
    func testPackerWarnsOnPlaceholderModelDigests() throws {
        let fm = FileManager.default
        let inputDir = try makeInputDir()
        defer { try? fm.removeItem(at: inputDir) }

        let keypair = Ed25519.generateKeypair()
        let outputURL = fm.temporaryDirectory
            .appendingPathComponent("vg-packer-" + UUID().uuidString + ".vgconfig")
        defer { try? fm.removeItem(at: outputURL) }

        let result = try Packer.pack(
            inputDir: inputDir,
            author: Packer.Author(handle: "sincera", displayName: "Sincera Works"),
            privateKeyRaw: keypair.privateRaw,
            publicKeyRaw: keypair.publicRaw,
            metadata: Packer.ConfigMetadata(
                configId: "personal-values",
                name: "Personal Values",
                description: "Round-trip test config with placeholder model digests.",
                version: "1.0.0"
            ),
            outputBundle: outputURL
        )

        // Two placeholders substituted -> two warnings.
        XCTAssertEqual(result.warnings.count, 2, "expected weights + coreml placeholder warnings")
        XCTAssertEqual(result.manifest.modelRef.weightsSha256, Packer.placeholderModelDigest)
        XCTAssertEqual(result.manifest.modelRef.coremlPackageSha256, Packer.placeholderModelDigest)

        // Placeholder digests are still shape-valid, so the bundle verifies.
        let (report, extracted) = try BundleVerifier.verify(bundleAt: outputURL)
        defer { try? fm.removeItem(at: extracted) }
        XCTAssertTrue(report.allPassed, "placeholder-digest bundle should still verify; checks: \(report.checks)")
    }

    /// A missing `policy.bin` in the input dir is a precise, typed error.
    func testPackerRejectsMissingPolicyBin() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("vg-packer-empty-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let keypair = Ed25519.generateKeypair()
        let outputURL = fm.temporaryDirectory
            .appendingPathComponent("vg-packer-" + UUID().uuidString + ".vgconfig")

        XCTAssertThrowsError(
            try Packer.pack(
                inputDir: dir,
                author: Packer.Author(handle: "sincera", displayName: "Sincera Works"),
                privateKeyRaw: keypair.privateRaw,
                publicKeyRaw: keypair.publicRaw,
                metadata: Packer.ConfigMetadata(
                    configId: "personal-values",
                    name: "Personal Values",
                    description: "should fail",
                    version: "1.0.0"
                ),
                outputBundle: outputURL
            )
        ) { error in
            guard case VGError.notFound = error else {
                return XCTFail("expected VGError.notFound, got \(error)")
            }
        }
    }
}
