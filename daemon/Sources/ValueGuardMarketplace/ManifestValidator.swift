import Foundation

/// Enforces the §2 "field-by-field rules" table over an already-decoded
/// ``Manifest``.
///
/// This validator is **pure**: it touches no filesystem and does no
/// cryptography. Structural decoding is `Manifest.decode(from:)`'s job, the
/// hash and signature checks live in `BundleVerifier`, and the byte-for-byte
/// `policy.bin` cross-checks live in `PolicyBinCrossCheck`. ``validate(_:)``
/// only confirms that every scalar field is well-formed against the schema
/// rules (regex, ranges, enums, SemVer/RFC3339 shape).
///
/// On the **first** violation it throws `VGError.manifestSchema(reason)` with a
/// concise human-readable reason (the `errorDescription` prepends
/// `"manifest.json schema violation: "`, so the reason here does not repeat
/// that prefix). Validation is fail-fast: the rules are checked in roughly the
/// order they appear in the §2 table so the first reported error is stable.
public enum ManifestValidator {
    // MARK: - Enumerated value sets

    /// Allowed `action` values for `thresholds[]` and `categories[]`.
    private static let actionValues: Set<String> = ["log", "blur", "block"]

    /// Allowed `calibration_method` values.
    private static let calibrationMethods: Set<String> = [
        "label_free_normal", "gaussian_mixture", "conformal", "none",
    ]

    // MARK: - Entry point

    /// Validate every §2 field-by-field rule over `m`.
    ///
    /// - Throws: `VGError.manifestSchema` on the first violation.
    public static func validate(_ m: Manifest) throws {
        // schema_version == 1
        guard m.schemaVersion == 1 else {
            throw fail("schema_version must be exactly 1, got \(m.schemaVersion)")
        }

        // config_id: ^[a-z][a-z0-9-]{1,38}[a-z0-9]$
        guard matches(m.configId, configIdPattern) else {
            throw fail("config_id '\(m.configId)' does not match ^[a-z][a-z0-9-]{1,38}[a-z0-9]$")
        }

        // name: 1-80 chars, no control chars
        try validateName(m.name)

        // description: 1-2000 chars
        let descCount = m.description.count
        guard descCount >= 1, descCount <= 2000 else {
            throw fail("description must be 1–2000 characters, got \(descCount)")
        }

        // author.handle: ^[a-z0-9][a-z0-9-]{1,38}$
        guard matches(m.author.handle, handlePattern) else {
            throw fail("author.handle '\(m.author.handle)' does not match ^[a-z0-9][a-z0-9-]{1,38}$")
        }

        // author.public_key: base64 of exactly 32 raw bytes
        try validatePublicKey(m.author.publicKey)

        // license: non-empty SPDX-ish (any non-empty string, LicenseRef- allowed)
        guard !m.license.isEmpty else {
            throw fail("license must be a non-empty SPDX identifier")
        }

        // version: SemVer 2.0 with optional prerelease, NO build metadata
        guard isValidSemVer(m.version, allowBuildMetadata: false) else {
            throw fail("version '\(m.version)' is not a valid SemVer 2.0 string (no build metadata allowed)")
        }

        // created_at: RFC 3339 UTC 'Z', no numeric offset
        guard isRFC3339UTC(m.createdAt) else {
            throw fail("created_at '\(m.createdAt)' is not RFC 3339 UTC (must end with 'Z', no offset)")
        }

        // model_ref.weights_sha256 / coreml_package_sha256: bare 64-char hex shape only
        guard Hashing.isValidSha256Hex(m.modelRef.weightsSha256) else {
            throw fail("model_ref.weights_sha256 '\(m.modelRef.weightsSha256)' is not 64 lowercase hex characters")
        }
        guard Hashing.isValidSha256Hex(m.modelRef.coremlPackageSha256) else {
            throw fail("model_ref.coreml_package_sha256 '\(m.modelRef.coremlPackageSha256)' is not 64 lowercase hex characters")
        }

        // model_ref.embedding_dim > 0
        guard m.modelRef.embeddingDim > 0 else {
            throw fail("model_ref.embedding_dim must be > 0, got \(m.modelRef.embeddingDim)")
        }

        // policy_hash / policy_json_hash / calibration_hash: "sha256:<64hex>"
        try validatePrefixedHash(m.policyHash, field: "policy_hash")
        try validatePrefixedHash(m.policyJsonHash, field: "policy_json_hash")
        try validatePrefixedHash(m.calibrationHash, field: "calibration_hash")

        // thresholds[].threshold in 0...1, action in enum
        for (i, t) in m.thresholds.enumerated() {
            guard t.threshold >= 0.0, t.threshold <= 1.0 else {
                throw fail("thresholds[\(i)].threshold must be in [0.0, 1.0], got \(t.threshold)")
            }
            guard actionValues.contains(t.action) else {
                throw fail("thresholds[\(i)].action '\(t.action)' must be one of log | blur | block")
            }
        }

        // calibration_method in enum
        guard calibrationMethods.contains(m.calibrationMethod) else {
            throw fail("calibration_method '\(m.calibrationMethod)' must be one of label_free_normal | gaussian_mixture | conformal | none")
        }

        // categories[].action in enum
        for (i, c) in m.categories.enumerated() {
            guard actionValues.contains(c.action) else {
                throw fail("categories[\(i)].action '\(c.action)' must be one of log | blur | block")
            }
        }

        // compatibility.min_daemon_version: SemVer shape only
        guard isValidSemVer(m.compatibility.minDaemonVersion, allowBuildMetadata: true) else {
            throw fail("compatibility.min_daemon_version '\(m.compatibility.minDaemonVersion)' is not a valid SemVer string")
        }
        // compatibility.max_daemon_version (optional): SemVer shape only when present
        if let maxv = m.compatibility.maxDaemonVersion {
            guard isValidSemVer(maxv, allowBuildMetadata: true) else {
                throw fail("compatibility.max_daemon_version '\(maxv)' is not a valid SemVer string")
            }
        }

        // compatibility.min_policy_bin_version >= 1
        guard m.compatibility.minPolicyBinVersion >= 1 else {
            throw fail("compatibility.min_policy_bin_version must be >= 1, got \(m.compatibility.minPolicyBinVersion)")
        }

        // tags: <= 8, each ^[a-z0-9-]{1,24}$
        if let tags = m.tags {
            guard tags.count <= 8 else {
                throw fail("tags must contain at most 8 entries, got \(tags.count)")
            }
            for (i, tag) in tags.enumerated() {
                guard matches(tag, tagPattern) else {
                    throw fail("tags[\(i)] '\(tag)' does not match ^[a-z0-9-]{1,24}$")
                }
            }
        }
    }

    // MARK: - Per-field helpers

    /// `name` must be 1–80 characters with no Unicode control scalars.
    private static func validateName(_ name: String) throws {
        let count = name.count
        guard count >= 1, count <= 80 else {
            throw fail("name must be 1–80 characters, got \(count)")
        }
        for scalar in name.unicodeScalars where CharacterSet.controlCharacters.contains(scalar) {
            throw fail("name must not contain control characters")
        }
    }

    /// `author.public_key` must be standard base64 decoding to exactly 32 bytes.
    private static func validatePublicKey(_ b64: String) throws {
        guard let raw = Data(base64Encoded: b64) else {
            throw fail("author.public_key is not valid base64")
        }
        guard raw.count == 32 else {
            throw fail("author.public_key must decode to exactly 32 bytes, got \(raw.count)")
        }
    }

    /// A `policy_hash`-style field must be exactly `"sha256:<64 lowercase hex>"`.
    private static func validatePrefixedHash(_ value: String, field: String) throws {
        guard Hashing.stripSha256Prefix(value) != nil else {
            throw fail("\(field) '\(value)' must be of the form sha256:<64 lowercase hex>")
        }
    }

    // MARK: - SemVer

    /// Whether `s` is a valid SemVer 2.0 string.
    ///
    /// The grammar enforced is `MAJOR.MINOR.PATCH` (each a non-negative integer
    /// without leading zeros, except the literal `0`), an optional
    /// `-<prerelease>` segment, and — only when `allowBuildMetadata` is true —
    /// an optional `+<build>` segment.
    ///
    /// Prerelease identifiers are dot-separated and each must be a non-empty
    /// alphanumeric/hyphen token; a numeric prerelease identifier must not have
    /// leading zeros. Build-metadata identifiers are dot-separated, each a
    /// non-empty alphanumeric/hyphen token (leading zeros permitted, per spec).
    ///
    /// - Parameters:
    ///   - s: candidate string.
    ///   - allowBuildMetadata: when `false`, any `+build` suffix makes the
    ///     string invalid (the manifest `version` rule forbids build metadata);
    ///     when `true`, a well-formed `+build` suffix is accepted (used for the
    ///     `compatibility.*_daemon_version` shape checks).
    public static func isValidSemVer(_ s: String, allowBuildMetadata: Bool) -> Bool {
        guard !s.isEmpty else { return false }

        // Split off build metadata at the first '+'.
        var core = Substring(s)
        var build: Substring? = nil
        if let plus = core.firstIndex(of: "+") {
            build = core[core.index(after: plus)...]
            core = core[..<plus]
        }

        // Build metadata present but not allowed -> invalid.
        if build != nil && !allowBuildMetadata {
            return false
        }

        // Split off prerelease at the first '-' within the remaining core.
        var versionCore = core
        var prerelease: Substring? = nil
        if let dash = core.firstIndex(of: "-") {
            prerelease = core[core.index(after: dash)...]
            versionCore = core[..<dash]
        }

        // MAJOR.MINOR.PATCH
        let parts = versionCore.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        for part in parts where !isNumericIdentifier(part) {
            return false
        }

        // Prerelease: dot-separated identifiers.
        if let pre = prerelease {
            let ids = pre.split(separator: ".", omittingEmptySubsequences: false)
            guard !ids.isEmpty else { return false }
            for id in ids where !isPrereleaseIdentifier(id) {
                return false
            }
        }

        // Build metadata: dot-separated identifiers (leading zeros allowed).
        if let b = build {
            let ids = b.split(separator: ".", omittingEmptySubsequences: false)
            guard !ids.isEmpty else { return false }
            for id in ids where !isBuildIdentifier(id) {
                return false
            }
        }

        return true
    }

    /// A SemVer numeric version part: digits only, no leading zero unless the
    /// value is exactly `0`.
    private static func isNumericIdentifier(_ s: Substring) -> Bool {
        guard !s.isEmpty else { return false }
        for ch in s.utf8 where !(0x30...0x39).contains(ch) {
            return false
        }
        if s.count > 1 && s.first == "0" {
            return false
        }
        return true
    }

    /// A SemVer prerelease identifier: non-empty `[0-9A-Za-z-]`; if it is purely
    /// numeric it must not have a leading zero.
    private static func isPrereleaseIdentifier(_ s: Substring) -> Bool {
        guard !s.isEmpty else { return false }
        var allDigits = true
        for ch in s.utf8 {
            switch ch {
            case 0x30...0x39: // 0-9
                continue
            case 0x41...0x5A, 0x61...0x7A, 0x2D: // A-Z a-z '-'
                allDigits = false
            default:
                return false
            }
        }
        if allDigits && s.count > 1 && s.first == "0" {
            return false
        }
        return true
    }

    /// A SemVer build-metadata identifier: non-empty `[0-9A-Za-z-]`, leading
    /// zeros permitted.
    private static func isBuildIdentifier(_ s: Substring) -> Bool {
        guard !s.isEmpty else { return false }
        for ch in s.utf8 {
            switch ch {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D:
                continue
            default:
                return false
            }
        }
        return true
    }

    // MARK: - RFC 3339 UTC

    /// Whether `s` is an RFC 3339 timestamp expressed in UTC with a literal
    /// `Z` zone designator and **no** numeric offset.
    ///
    /// Accepts `YYYY-MM-DDTHH:MM:SSZ` with an optional fractional-seconds part
    /// (`.` followed by one or more digits) before the `Z`. The date-time
    /// separator may be `T` or a space, per RFC 3339 §5.6. Field ranges
    /// (month 01–12, day 01–31, hour 00–23, minute/second 00–59, with seconds
    /// allowing the leap-second value 60) are checked numerically. Any explicit
    /// numeric offset (`+00:00`, `-05:00`) or a lowercase `z` is rejected.
    public static func isRFC3339UTC(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        // Minimum: "YYYY-MM-DDTHH:MM:SSZ" == 20 characters.
        guard scalars.count >= 20 else { return false }

        func digit(_ i: Int) -> Bool {
            guard i < scalars.count else { return false }
            return scalars[i].value >= 0x30 && scalars[i].value <= 0x39
        }
        func value(_ i: Int) -> Int { Int(scalars[i].value) - 0x30 }
        func twoDigit(_ start: Int) -> Int? {
            guard digit(start), digit(start + 1) else { return nil }
            return value(start) * 10 + value(start + 1)
        }

        // YYYY
        guard digit(0), digit(1), digit(2), digit(3) else { return false }
        // '-'
        guard scalars[4] == "-" else { return false }
        // MM
        guard let month = twoDigit(5), month >= 1, month <= 12 else { return false }
        // '-'
        guard scalars[7] == "-" else { return false }
        // DD
        guard let day = twoDigit(8), day >= 1, day <= 31 else { return false }
        // 'T' or space separator
        guard scalars[10] == "T" || scalars[10] == " " else { return false }
        // HH
        guard let hour = twoDigit(11), hour >= 0, hour <= 23 else { return false }
        // ':'
        guard scalars[13] == ":" else { return false }
        // MM
        guard let minute = twoDigit(14), minute >= 0, minute <= 59 else { return false }
        // ':'
        guard scalars[16] == ":" else { return false }
        // SS (allow leap second 60)
        guard let second = twoDigit(17), second >= 0, second <= 60 else { return false }

        // Position 19 onward: optional fractional seconds then mandatory 'Z'.
        var i = 19
        if i < scalars.count && scalars[i] == "." {
            i += 1
            let fracStart = i
            while i < scalars.count && scalars[i].value >= 0x30 && scalars[i].value <= 0x39 {
                i += 1
            }
            // Require at least one fractional digit.
            guard i > fracStart else { return false }
        }

        // Exactly an uppercase 'Z' must terminate the string.
        guard i == scalars.count - 1, scalars[i] == "Z" else { return false }
        return true
    }

    // MARK: - Regex patterns

    private static let configIdPattern = makeRegex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$")
    private static let handlePattern = makeRegex("^[a-z0-9][a-z0-9-]{1,38}$")
    private static let tagPattern = makeRegex("^[a-z0-9-]{1,24}$")

    /// Build a `Regex` from a compile-time-constant pattern. The patterns above
    /// are fixed string literals known to be well-formed, so the force-try
    /// cannot fail at runtime.
    private static func makeRegex(_ pattern: String) -> Regex<AnyRegexOutput> {
        // swiftlint:disable:next force_try
        return try! Regex(pattern)
    }

    /// Whole-string match against `regex`. `wholeMatch(in:)` returns an optional
    /// `Match`; `try?` collapses both the throw and the no-match cases, so a
    /// single non-nil check is the match predicate.
    private static func matches(_ s: String, _ regex: Regex<AnyRegexOutput>) -> Bool {
        ((try? regex.wholeMatch(in: s)) ?? nil) != nil
    }

    // MARK: - Error construction

    /// Wrap a reason string in `VGError.manifestSchema`.
    private static func fail(_ reason: String) -> VGError {
        VGError.manifestSchema(reason)
    }
}
