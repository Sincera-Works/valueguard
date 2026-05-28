import XCTest
@testable import ValueGuardMarketplace

/// Table-driven tests for ``ManifestValidator`` — the pure enforcement of the
/// §2 "field-by-field rules" table over a decoded ``Manifest``.
///
/// The strategy is a single canonical, fully-valid `Manifest` built in code
/// (``makeValidManifest()``); each negative test mutates exactly one field via
/// a copy helper and asserts `ManifestValidator.validate(_:)` throws
/// `VGError.manifestSchema`. The validator touches no filesystem and does no
/// cryptography, so these tests need no bundle, no temp dirs, and no archive —
/// the end-to-end / hash / signature coverage lives in `VerifyTamperTests`.
///
/// `manifest.json` decoding (structure) is `Manifest.decode`'s job and is not
/// re-exercised here; the canonical manifest is constructed directly through the
/// public memberwise initializers.
final class ManifestValidatorTests: XCTestCase {

    // MARK: - Canonical valid manifest

    /// A standard base64-encoded raw 32-byte Ed25519 public key, used as the
    /// canonical `author.public_key`. Derived from a real keypair so the
    /// base64-of-exactly-32-bytes shape rule is satisfied for the happy path.
    private static let validPublicKeyBase64: String =
        Ed25519.generateKeypair().publicRaw.base64EncodedString()

    /// A well-formed 64-character lowercase-hex string for the model-ref digest
    /// shape rules (P0 validates shape only).
    private static let hex64 = String(repeating: "a", count: 64)

    /// A well-formed `"sha256:<64 lowercase hex>"` artifact-hash string.
    private static let prefixedHash = "sha256:" + hex64

    /// Build a §2-valid `Manifest`. Every field is set to a value that passes
    /// the corresponding rule, so the result is the accept-case baseline that the
    /// negative tests mutate one field at a time.
    private func makeValidManifest() -> Manifest {
        let author = Manifest.Author(
            handle: "fixture-author",
            displayName: "Fixture Author",
            verified: false,
            publicKey: Self.validPublicKeyBase64
        )

        let modelRef = Manifest.ModelRef(
            family: "siglip2-base-patch16-256",
            huggingfaceId: "google/siglip2-base-patch16-256",
            weightsSha256: Self.hex64,
            coremlPackageSha256: Self.hex64,
            inputResolution: 256,
            embeddingDim: 768
        )

        let thresholds = [
            Manifest.ThresholdEntry(id: "explicit_content", threshold: 0.184, action: "blur"),
            Manifest.ThresholdEntry(id: "graphic_violence", threshold: 0.5, action: "block"),
        ]

        let categories = [
            Manifest.CategoryEntry(id: "explicit_content", action: "blur", shortDescription: "Explicit imagery."),
            Manifest.CategoryEntry(id: "graphic_violence", action: "block", shortDescription: "Graphic violence."),
        ]

        let compatibility = Manifest.Compatibility(
            minDaemonVersion: "0.1.0",
            maxDaemonVersion: nil,
            minPolicyBinVersion: 1
        )

        let summary = Manifest.CalibrationSummary(nSamplesTotal: 1000, nCategories: 2)

        return Manifest(
            schemaVersion: 1,
            configId: "personal-values-strict",
            name: "Personal Values (Strict)",
            description: "A canonical, fully valid fixture manifest used as the accept-case baseline for the ManifestValidator rule table.",
            author: author,
            license: "MIT",
            version: "1.0.0",
            createdAt: "2026-05-28T00:00:00Z",
            modelRef: modelRef,
            policyHash: Self.prefixedHash,
            policyJsonHash: Self.prefixedHash,
            calibrationHash: Self.prefixedHash,
            thresholds: thresholds,
            calibrationMethod: "label_free_normal",
            calibrationSummary: summary,
            categories: categories,
            compatibility: compatibility,
            forkOf: nil,
            tags: ["personal", "strict"]
        )
    }

    // MARK: - Mutation helpers
    //
    // `Manifest` and its nested types use immutable `let` stored properties, so
    // there is no in-place setter. Each helper rebuilds the manifest (or a nested
    // struct) from the canonical baseline with a single field replaced.

    /// Rebuild a `Manifest` from `m` with the closure-named fields overridden.
    /// Only the scalar fields the negative tests need are parameterized; the rest
    /// are copied verbatim from the baseline.
    private func copy(
        _ m: Manifest,
        schemaVersion: Int? = nil,
        configId: String? = nil,
        name: String? = nil,
        description: String? = nil,
        author: Manifest.Author? = nil,
        license: String? = nil,
        version: String? = nil,
        createdAt: String? = nil,
        thresholds: [Manifest.ThresholdEntry]? = nil,
        calibrationMethod: String? = nil,
        categories: [Manifest.CategoryEntry]? = nil,
        compatibility: Manifest.Compatibility? = nil,
        tags: [String]?? = nil
    ) -> Manifest {
        Manifest(
            schemaVersion: schemaVersion ?? m.schemaVersion,
            configId: configId ?? m.configId,
            name: name ?? m.name,
            description: description ?? m.description,
            author: author ?? m.author,
            license: license ?? m.license,
            version: version ?? m.version,
            createdAt: createdAt ?? m.createdAt,
            modelRef: m.modelRef,
            policyHash: m.policyHash,
            policyJsonHash: m.policyJsonHash,
            calibrationHash: m.calibrationHash,
            thresholds: thresholds ?? m.thresholds,
            calibrationMethod: calibrationMethod ?? m.calibrationMethod,
            calibrationSummary: m.calibrationSummary,
            categories: categories ?? m.categories,
            compatibility: compatibility ?? m.compatibility,
            forkOf: m.forkOf,
            // Double-optional: `nil` means "leave unchanged", `.some(x)` means set.
            tags: tags ?? m.tags
        )
    }

    /// Rebuild `author` with a single field replaced.
    private func copyAuthor(
        _ a: Manifest.Author,
        handle: String? = nil,
        publicKey: String? = nil
    ) -> Manifest.Author {
        Manifest.Author(
            handle: handle ?? a.handle,
            displayName: a.displayName,
            verified: a.verified,
            publicKey: publicKey ?? a.publicKey
        )
    }

    /// Assert that validating `m` throws specifically `VGError.manifestSchema`
    /// (not some other error), reporting `because` on failure.
    private func assertRejected(
        _ m: Manifest,
        because reason: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ManifestValidator.validate(m),
            "expected rejection: \(reason)",
            file: file,
            line: line
        ) { error in
            guard let vg = error as? VGError, case .manifestSchema = vg else {
                XCTFail(
                    "expected VGError.manifestSchema (\(reason)), got \(error)",
                    file: file,
                    line: line
                )
                return
            }
        }
    }

    // MARK: - Accept case

    /// The canonical baseline manifest must validate without throwing, and a
    /// prerelease version (`1.5.0-rc.1`) and an absent `tags` array must also be
    /// accepted (the optional-and-well-formed paths).
    func testAcceptsValid() throws {
        let m = makeValidManifest()
        XCTAssertNoThrow(try ManifestValidator.validate(m), "the canonical manifest must validate")

        // Prerelease SemVer is allowed for `version` (only build metadata is not).
        XCTAssertNoThrow(
            try ManifestValidator.validate(copy(m, version: "1.5.0-rc.1")),
            "a prerelease version must be accepted"
        )

        // `tags` is optional; absence is valid.
        XCTAssertNoThrow(
            try ManifestValidator.validate(copy(m, tags: .some(nil))),
            "a manifest without tags must be accepted"
        )

        // SemVer helper direct checks (the rule the version field rides on).
        XCTAssertTrue(ManifestValidator.isValidSemVer("1.5.0-rc.1", allowBuildMetadata: false))
        XCTAssertTrue(ManifestValidator.isValidSemVer("0.0.0", allowBuildMetadata: false))

        // RFC3339 helper: 'Z' accepted, lowercase / offset rejected.
        XCTAssertTrue(ManifestValidator.isRFC3339UTC("2026-05-28T00:00:00Z"))
        XCTAssertTrue(ManifestValidator.isRFC3339UTC("2026-05-28T12:34:56.789Z"))
    }

    // MARK: - config_id

    /// `config_id` must match `^[a-z][a-z0-9-]{1,38}[a-z0-9]$`: reject too-short,
    /// uppercase, and leading-hyphen forms.
    func testRejectsBadConfigId() {
        let m = makeValidManifest()

        // Too short (1 char — the pattern requires a leading char + 1..38 + trailing = min 3).
        assertRejected(copy(m, configId: "a"), because: "config_id too short")

        // Uppercase is not in the character class.
        assertRejected(copy(m, configId: "Personal-Values"), because: "config_id uppercase")

        // Leading hyphen — first char must be [a-z].
        assertRejected(copy(m, configId: "-strict"), because: "config_id leading hyphen")

        // Trailing hyphen — last char must be [a-z0-9].
        assertRejected(copy(m, configId: "strict-"), because: "config_id trailing hyphen")

        // Underscore is not permitted (hyphen-only separator).
        assertRejected(copy(m, configId: "strict_personal"), because: "config_id underscore")
    }

    // MARK: - version (SemVer)

    /// `version` must be a valid SemVer 2.0 core (`MAJOR.MINOR.PATCH`).
    func testRejectsBadSemVer() {
        let m = makeValidManifest()

        assertRejected(copy(m, version: "1.0"), because: "version missing patch component")
        assertRejected(copy(m, version: "v1.0.0"), because: "version with leading v")
        assertRejected(copy(m, version: "1.0.0.0"), because: "version with four components")
        assertRejected(copy(m, version: "1.01.0"), because: "version with leading-zero minor")
        assertRejected(copy(m, version: "x.y.z"), because: "version non-numeric core")
        assertRejected(copy(m, version: ""), because: "version empty")

        // Helper-level confirmation.
        XCTAssertFalse(ManifestValidator.isValidSemVer("1.0", allowBuildMetadata: false))
        XCTAssertFalse(ManifestValidator.isValidSemVer("1.01.0", allowBuildMetadata: false))
    }

    /// `version` forbids build metadata even though the SemVer grammar allows it
    /// elsewhere: `1.0.0+abc` must be rejected for the manifest version field.
    func testRejectsBuildMetadata() {
        let m = makeValidManifest()

        assertRejected(copy(m, version: "1.0.0+abc"), because: "version with build metadata")
        assertRejected(copy(m, version: "1.0.0-rc.1+build.7"), because: "version prerelease + build metadata")

        // The helper distinguishes the two modes: build metadata is invalid when
        // disallowed but a well-formed +build is accepted when allowed (the shape
        // used for compatibility.*_daemon_version).
        XCTAssertFalse(ManifestValidator.isValidSemVer("1.0.0+abc", allowBuildMetadata: false))
        XCTAssertTrue(ManifestValidator.isValidSemVer("1.0.0+abc", allowBuildMetadata: true))
    }

    // MARK: - created_at (RFC 3339 UTC)

    /// `created_at` must be RFC 3339 UTC terminated by an uppercase `Z` with no
    /// numeric offset.
    func testRejectsBadCreatedAt() {
        let m = makeValidManifest()

        // Numeric offset instead of 'Z'.
        assertRejected(copy(m, createdAt: "2026-05-28T00:00:00+00:00"), because: "created_at numeric offset")
        // Lowercase zone designator.
        assertRejected(copy(m, createdAt: "2026-05-28T00:00:00z"), because: "created_at lowercase z")
        // Missing zone designator entirely.
        assertRejected(copy(m, createdAt: "2026-05-28T00:00:00"), because: "created_at no zone")
        // Out-of-range month.
        assertRejected(copy(m, createdAt: "2026-13-28T00:00:00Z"), because: "created_at month 13")
        // Not a timestamp at all.
        assertRejected(copy(m, createdAt: "not-a-date"), because: "created_at not a date")

        // Helper-level confirmation: 'Z' accepted, offset rejected.
        XCTAssertTrue(ManifestValidator.isRFC3339UTC("2026-05-28T00:00:00Z"))
        XCTAssertFalse(ManifestValidator.isRFC3339UTC("2026-05-28T00:00:00+00:00"))
    }

    // MARK: - thresholds[].threshold range

    /// `thresholds[].threshold` must lie in `[0.0, 1.0]`.
    func testRejectsThresholdOutOfRange() {
        let m = makeValidManifest()

        let tooHigh = [
            Manifest.ThresholdEntry(id: "explicit_content", threshold: 1.5, action: "blur"),
            Manifest.ThresholdEntry(id: "graphic_violence", threshold: 0.5, action: "block"),
        ]
        assertRejected(copy(m, thresholds: tooHigh), because: "threshold > 1.0")

        let negative = [
            Manifest.ThresholdEntry(id: "explicit_content", threshold: -0.1, action: "blur"),
        ]
        assertRejected(copy(m, thresholds: negative), because: "threshold < 0.0")
    }

    // MARK: - action enums

    /// `thresholds[].action` and `categories[].action` must be one of
    /// `log | blur | block`.
    func testRejectsBadAction() {
        let m = makeValidManifest()

        // Bad threshold action.
        let badThresholdAction = [
            Manifest.ThresholdEntry(id: "explicit_content", threshold: 0.184, action: "warn"),
        ]
        assertRejected(
            copy(m, thresholds: badThresholdAction, categories: [
                Manifest.CategoryEntry(id: "explicit_content", action: "blur", shortDescription: nil),
            ]),
            because: "thresholds[].action 'warn'"
        )

        // Bad category action.
        let badCategoryAction = [
            Manifest.CategoryEntry(id: "explicit_content", action: "redact", shortDescription: nil),
        ]
        assertRejected(
            copy(m, thresholds: [
                Manifest.ThresholdEntry(id: "explicit_content", threshold: 0.184, action: "blur"),
            ], categories: badCategoryAction),
            because: "categories[].action 'redact'"
        )
    }

    // MARK: - calibration_method enum

    /// `calibration_method` must be one of the §2 enum values.
    func testRejectsBadCalibrationMethod() {
        let m = makeValidManifest()

        assertRejected(copy(m, calibrationMethod: "magic"), because: "calibration_method 'magic'")
        assertRejected(copy(m, calibrationMethod: ""), because: "calibration_method empty")
        assertRejected(copy(m, calibrationMethod: "Label_Free_Normal"), because: "calibration_method wrong case")

        // Each valid value is accepted.
        for method in ["label_free_normal", "gaussian_mixture", "conformal", "none"] {
            XCTAssertNoThrow(
                try ManifestValidator.validate(copy(m, calibrationMethod: method)),
                "calibration_method '\(method)' must be accepted"
            )
        }
    }

    // MARK: - tags

    /// `tags` must contain at most 8 entries, each matching `^[a-z0-9-]{1,24}$`.
    func testRejectsTooManyTags() {
        let m = makeValidManifest()

        // 9 tags exceeds the cap of 8.
        let nineTags = (1...9).map { "tag\($0)" }
        assertRejected(copy(m, tags: .some(nineTags)), because: "9 tags exceeds cap of 8")

        // A tag with uppercase violates the per-tag regex.
        assertRejected(copy(m, tags: .some(["Personal"])), because: "tag with uppercase")

        // Exactly 8 well-formed tags is the boundary and must be accepted.
        let eightTags = (1...8).map { "tag\($0)" }
        XCTAssertNoThrow(
            try ManifestValidator.validate(copy(m, tags: .some(eightTags))),
            "exactly 8 well-formed tags must be accepted"
        )
    }

    // MARK: - author.public_key length

    /// `author.public_key` must be standard base64 decoding to exactly 32 bytes.
    func testRejectsBadPublicKeyLength() {
        let m = makeValidManifest()

        // Base64 of 31 bytes (too short).
        let key31 = Data(repeating: 0x42, count: 31).base64EncodedString()
        assertRejected(
            copy(m, author: copyAuthor(m.author, publicKey: key31)),
            because: "public_key decodes to 31 bytes"
        )

        // Base64 of 33 bytes (too long).
        let key33 = Data(repeating: 0x42, count: 33).base64EncodedString()
        assertRejected(
            copy(m, author: copyAuthor(m.author, publicKey: key33)),
            because: "public_key decodes to 33 bytes"
        )

        // Not valid base64 at all.
        assertRejected(
            copy(m, author: copyAuthor(m.author, publicKey: "not valid base64 !!!")),
            because: "public_key not base64"
        )

        // Empty string.
        assertRejected(
            copy(m, author: copyAuthor(m.author, publicKey: "")),
            because: "public_key empty"
        )
    }
}
