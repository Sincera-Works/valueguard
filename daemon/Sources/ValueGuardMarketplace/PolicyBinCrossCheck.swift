import Foundation
import ValueGuardCore

/// Bridge between the marketplace tooling and the canonical `VGP1` reader.
///
/// `policy.bin` is the authoritative artifact: the daemon's
/// `ValueGuardCore.Policy(loadingFrom:)` is the **only** VGP1 parser in the
/// project, and `vg` MUST NOT reimplement it (the binary layout is a contract
/// pinned in `model-conversion/embed_captions.py` and `Policy.swift`). This
/// type loads `policy.bin` through that reader and cross-checks the parsed
/// result against the bundle's `manifest.json` and `policy.json` so the three
/// representations can never silently disagree.
///
/// `ValueGuardCore.PolicyError` is internal to the daemon library, so a parse
/// failure is caught generically and re-wrapped as `VGError.invalidPolicyBin`.
public enum PolicyBinCrossCheck {

    /// VGP1 is the only policy.bin format version that exists; the reader in
    /// `Policy.swift` hardcodes `version == 1`. `min_policy_bin_version` in the
    /// manifest must therefore not exceed this.
    public static let supportedPolicyBinVersion = 1

    // MARK: - Load

    /// Load `policy.bin` via the canonical `ValueGuardCore` VGP1 reader.
    ///
    /// Any error thrown by `Policy(loadingFrom:)` (the internal
    /// `PolicyError`, or a Foundation read error) is caught generically and
    /// re-wrapped as `VGError.invalidPolicyBin` carrying a human-readable
    /// detail — the internal error type is never re-exported.
    public static func load(_ url: URL) throws -> ValueGuardCore.Policy {
        do {
            return try ValueGuardCore.Policy(loadingFrom: url)
        } catch let error as VGError {
            // Should not normally happen (the reader doesn't throw VGError),
            // but pass our own errors through unchanged rather than nesting.
            throw error
        } catch {
            throw VGError.invalidPolicyBin(
                "could not parse policy.bin at \(url.path): \(describe(error))")
        }
    }

    // MARK: - Action mapping

    /// Map a `ValueGuardCore.PolicyAction` (a `UInt8` raw enum) to its string
    /// form: `log` (0), `blur` (1), `block` (2). Mirrors `PolicyJSONAction`
    /// and the manifest `action` field vocabulary.
    public static func actionString(_ a: ValueGuardCore.PolicyAction) -> String {
        switch a {
        case .log: return "log"
        case .blur: return "blur"
        case .block: return "block"
        }
    }

    // MARK: - Float comparison

    /// Exact bit-pattern equality for `Float`. Used for the §2 rule that the
    /// manifest / policy.json thresholds match `policy.bin` "byte-for-byte":
    /// two `Float`s compare equal iff their 32-bit IEEE-754 representations are
    /// identical. A manifest threshold is a JSON `Double`; the caller narrows
    /// it via `Float(double)` before comparing, so the stored `Float` in
    /// `policy.bin` and the round-tripped manifest value share a bit pattern.
    public static func floatBitsEqual(_ a: Float, _ b: Float) -> Bool {
        return a.bitPattern == b.bitPattern
    }

    // MARK: - Cross-check: manifest vs. policy.bin

    /// Cross-check a decoded `Manifest` against the parsed `policy.bin` (§2).
    ///
    /// Enforced rules:
    /// - `model_ref.embedding_dim` equals `policy.embedDim`.
    /// - `compatibility.min_policy_bin_version` ≤ the only supported VGP1
    ///   version (1). (A floor `≥ 1` is a manifest-schema rule, checked
    ///   earlier by `ManifestValidator`.)
    /// - Every `thresholds[]` entry's `id` exists in `policy.bin`, its
    ///   `threshold` matches the binary's `Float` by exact bit pattern
    ///   (manifest `Double` narrowed via `Float(_:)`), and its `action`
    ///   matches the binary's `PolicyAction`.
    /// - Every `policy.bin` category id is covered by a `thresholds[]` entry
    ///   (the manifest must describe every binary category).
    /// - `categories[]` ids are a subset of `policy.bin` ids.
    ///
    /// Throws `VGError.crossCheck` on the first disagreement.
    public static func crossCheck(manifest: Manifest, policy: ValueGuardCore.Policy) throws {
        // embedding_dim
        let manifestDim = manifest.modelRef.embeddingDim
        guard manifestDim == policy.embedDim else {
            throw VGError.crossCheck(
                "model_ref.embedding_dim (\(manifestDim)) does not match "
                + "policy.bin embed dim (\(policy.embedDim))")
        }

        // min_policy_bin_version: VGP1 is version 1; the manifest must not
        // require a newer format than the reader supports.
        let minBin = manifest.compatibility.minPolicyBinVersion
        guard minBin <= supportedPolicyBinVersion else {
            throw VGError.crossCheck(
                "compatibility.min_policy_bin_version (\(minBin)) exceeds the "
                + "supported VGP1 version (\(supportedPolicyBinVersion))")
        }

        // Index policy.bin categories by id for O(1) lookup.
        let binByID = categoriesByID(policy)

        // Every manifest threshold entry must align with policy.bin.
        for entry in manifest.thresholds {
            guard let cat = binByID[entry.id] else {
                throw VGError.crossCheck(
                    "thresholds[] references category '\(entry.id)' which is "
                    + "absent from policy.bin")
            }

            let manifestThreshold = Float(entry.threshold)
            guard floatBitsEqual(manifestThreshold, cat.threshold) else {
                throw VGError.crossCheck(
                    "threshold for '\(entry.id)' differs from policy.bin: "
                    + "manifest \(thresholdDescription(entry.threshold, as: manifestThreshold)) "
                    + "vs policy.bin \(thresholdDescription(cat.threshold))")
            }

            let binAction = actionString(cat.action)
            guard entry.action == binAction else {
                throw VGError.crossCheck(
                    "action for '\(entry.id)' differs from policy.bin: "
                    + "manifest '\(entry.action)' vs policy.bin '\(binAction)'")
            }
        }

        // The manifest must describe every policy.bin category (so there is a
        // threshold/action of record for each binary category).
        let manifestThresholdIDs = Set(manifest.thresholds.map(\.id))
        for cat in policy.categories where !manifestThresholdIDs.contains(cat.id) {
            throw VGError.crossCheck(
                "policy.bin category '\(cat.id)' has no matching thresholds[] "
                + "entry in the manifest")
        }

        // categories[] ids must be a subset of policy.bin ids.
        for entry in manifest.categories where binByID[entry.id] == nil {
            throw VGError.crossCheck(
                "categories[] references category '\(entry.id)' which is "
                + "absent from policy.bin")
        }
    }

    // MARK: - Cross-check: policy.json vs. policy.bin

    /// Cross-check the human-readable `policy.json` against the parsed
    /// `policy.bin` (§2): the two must describe the *same* category set, and
    /// each shared category's `threshold` (exact `Float` bit pattern) and
    /// `action` must agree.
    ///
    /// Throws `VGError.crossCheck` on the first disagreement.
    public static func crossCheck(policyJSON: PolicyJSONDocument, policy: ValueGuardCore.Policy) throws {
        let binByID = categoriesByID(policy)
        var seen = Set<String>()

        for cat in policyJSON.categories {
            seen.insert(cat.id)
            guard let binCat = binByID[cat.id] else {
                throw VGError.crossCheck(
                    "policy.json category '\(cat.id)' is absent from policy.bin")
            }

            let jsonThreshold = Float(cat.threshold)
            guard floatBitsEqual(jsonThreshold, binCat.threshold) else {
                throw VGError.crossCheck(
                    "threshold for '\(cat.id)' differs between policy.json and "
                    + "policy.bin: policy.json "
                    + "\(thresholdDescription(cat.threshold, as: jsonThreshold)) "
                    + "vs policy.bin \(thresholdDescription(binCat.threshold))")
            }

            let jsonAction = cat.action.rawValue
            let binAction = actionString(binCat.action)
            guard jsonAction == binAction else {
                throw VGError.crossCheck(
                    "action for '\(cat.id)' differs between policy.json and "
                    + "policy.bin: policy.json '\(jsonAction)' vs policy.bin '\(binAction)'")
            }
        }

        // policy.bin must not contain categories the human-readable form omits.
        for binCat in policy.categories where !seen.contains(binCat.id) {
            throw VGError.crossCheck(
                "policy.bin category '\(binCat.id)' is absent from policy.json")
        }
    }

    // MARK: - Helpers

    /// Index a parsed policy's categories by id. (VGP1 ids are unique in
    /// practice; on a duplicate the last wins, which only affects the detail
    /// text of an error that would already fire.)
    private static func categoriesByID(_ policy: ValueGuardCore.Policy) -> [String: ValueGuardCore.PolicyCategory] {
        var map: [String: ValueGuardCore.PolicyCategory] = [:]
        map.reserveCapacity(policy.categories.count)
        for cat in policy.categories {
            map[cat.id] = cat
        }
        return map
    }

    /// Human-readable rendering of a threshold for error messages, including
    /// the raw bit pattern so a "byte-for-byte" mismatch is debuggable.
    private static func thresholdDescription(_ value: Double, as narrowed: Float) -> String {
        return "\(value) (Float \(narrowed), bits 0x\(String(narrowed.bitPattern, radix: 16)))"
    }

    private static func thresholdDescription(_ value: Float) -> String {
        return "\(value) (bits 0x\(String(value.bitPattern, radix: 16)))"
    }

    /// Best-effort human description of an arbitrary error for the
    /// `invalidPolicyBin` re-wrap. Prefers `LocalizedError.errorDescription`,
    /// falls back to the interpolated value (which renders the internal
    /// `PolicyError` case names usefully, e.g. `badMagic`,
    /// `unsupportedVersion(2)`, `mismatchedDim(...)`).
    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return "\(error)"
    }
}
