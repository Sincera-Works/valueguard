import Foundation

/// The single public error type for the ValueGuardMarketplace library.
///
/// Every operation in the library that can fail surfaces a `VGError`. The
/// associated `String` payloads carry human-readable detail; the
/// `LocalizedError.errorDescription` is what the `vg` CLI prints to stderr
/// when a subcommand throws (and what drives the check detail lines in
/// `vg verify`).
///
/// `ValueGuardCore.PolicyError` is intentionally *not* re-exported here: it is
/// an internal type of the daemon library, so `policy.bin` parse failures are
/// caught generically and re-wrapped as `.invalidPolicyBin`.
public enum VGError: Error, LocalizedError {
    /// A `/usr/bin/tar` invocation failed (non-zero exit). Payload is stderr.
    case archive(String)
    /// The `.vgconfig` top-level layout is wrong: a required member is missing,
    /// a forbidden/unknown member is present, or an entry is path-traversal
    /// (absolute path, `..` component, leading `/`).
    case bundleLayout(String)
    /// `manifest.json` could not be JSON-decoded into `Manifest`.
    case manifestDecode(String)
    /// `manifest.json` decoded but violated a §2 field-by-field schema rule.
    case manifestSchema(String)
    /// A `sha256:` hash field in the manifest did not match the recomputed
    /// digest of the on-disk artifact.
    case hashMismatch(field: String, expected: String, got: String)
    /// `policy.bin` could not be parsed by the ValueGuardCore VGP1 reader, or
    /// failed a structural sanity check.
    case invalidPolicyBin(String)
    /// `policy.json` decoded but violated the human-readable policy schema
    /// (id pattern, caption counts, threshold range, category count).
    case policyJSONSchema(String)
    /// A cross-check between two artifacts disagreed (manifest vs. policy.bin,
    /// or policy.json vs. policy.bin): dim, version, thresholds, actions, ids.
    case crossCheck(String)
    /// The recomputed `signatures/MANIFEST.SHA256` content did not match the
    /// bytes bundled in the archive.
    case manifestSha256Mismatch(String)
    /// The Ed25519 signature over `MANIFEST.SHA256` failed to verify.
    case signatureInvalid(String)
    /// `signatures/author.pub` did not decode to the same 32 bytes as
    /// `manifest.author.public_key`.
    case publicKeyMismatch(String)
    /// A config referenced by `author/slug` is not present in the lockfile.
    case notInstalled(String)
    /// The exact `author/slug/version` is already installed (republishing the
    /// same version is forbidden by §2 immutability).
    case alreadyInstalled(String)
    /// TOFU refusal: the author handle is already trusted with a different key.
    case keyChanged(handle: String, oldFingerprint: String, newFingerprint: String)
    /// A filesystem / I/O operation failed (read, write, move, symlink, rename).
    case io(String)
    /// A required path or resource was not found, or an argument was malformed.
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .archive(let detail):
            return "archive error: \(detail)"
        case .bundleLayout(let detail):
            return "invalid bundle layout: \(detail)"
        case .manifestDecode(let detail):
            return "could not decode manifest.json: \(detail)"
        case .manifestSchema(let detail):
            return "manifest.json schema violation: \(detail)"
        case .hashMismatch(let field, let expected, let got):
            return "hash mismatch for \(field): expected \(expected), got \(got)"
        case .invalidPolicyBin(let detail):
            return "invalid policy.bin: \(detail)"
        case .policyJSONSchema(let detail):
            return "policy.json schema violation: \(detail)"
        case .crossCheck(let detail):
            return "cross-check failed: \(detail)"
        case .manifestSha256Mismatch(let detail):
            return "MANIFEST.SHA256 mismatch: \(detail)"
        case .signatureInvalid(let detail):
            return "signature verification failed: \(detail)"
        case .publicKeyMismatch(let detail):
            return "public key mismatch: \(detail)"
        case .notInstalled(let ref):
            return "not installed: \(ref)"
        case .alreadyInstalled(let ref):
            return "already installed: \(ref)"
        case .keyChanged(let handle, let oldFingerprint, let newFingerprint):
            return """
            author key changed for \(handle): \
            known key fingerprint \(oldFingerprint), \
            bundle key fingerprint \(newFingerprint). \
            Refusing install. To trust the new key, edit known_keys.json manually.
            """
        case .io(let detail):
            return "I/O error: \(detail)"
        case .notFound(let detail):
            return "not found: \(detail)"
        }
    }
}
