import Foundation
import CryptoKit

/// Ed25519 sign/verify and public-key fingerprinting via CryptoKit's
/// `Curve25519.Signing` (available on macOS 11+, fine on `.macOS(.v14)`).
///
/// The marketplace wire form for an Ed25519 public key is the **raw 32 bytes**,
/// base64-encoded as text. Both `manifest.author.public_key` and
/// `signatures/author.pub` hold that same base64 string, so verification decodes
/// both to `Data` and compares the raw 32-byte representations.
///
/// The signed artifact is the **raw bytes of `signatures/MANIFEST.SHA256`** — the
/// detached signature lives in `signatures/author.sig` (64 raw bytes). Signing is
/// only exercised by tests and the hidden `vg pack` helper; this enum performs no
/// key management or persistence.
///
/// - Important: `Curve25519.Signing.PublicKey.isValid(signature:for:)` returns a
///   `Bool` and does **not** throw on a bad signature. `verify` checks that Bool
///   and reports `false` for any failure (malformed signature, malformed key, or a
///   genuine mismatch), so the verify path never throws on an attacker-controlled
///   bundle.
public enum Ed25519 {
    // MARK: - Verify

    /// Verify a detached Ed25519 `signature` over `message` with the raw 32-byte
    /// public key `publicKeyRaw`.
    ///
    /// Returns `false` — never throws — for any failure: a malformed public key,
    /// a malformed/wrong-length signature, or a genuine signature mismatch. This
    /// is load-bearing for `vg verify` / `vg install`, which process untrusted
    /// bundles and must treat all bad input as "signature invalid" rather than as
    /// an error to propagate.
    public static func verify(signature: Data, message: Data, publicKeyRaw: Data) -> Bool {
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyRaw) else {
            return false
        }
        // isValidSignature(_:for:) returns Bool and does not throw; a malformed
        // or wrong-length signature simply yields false.
        return publicKey.isValidSignature(signature, for: message)
    }

    // MARK: - Public-key parsing

    /// Decode a base64 public key into its raw 32 bytes.
    ///
    /// - Throws: `VGError.signatureInvalid` if `b64` is not valid base64 or does
    ///   not decode to exactly 32 bytes.
    public static func publicKeyRaw(fromBase64 b64: String) throws -> Data {
        guard let raw = Data(base64Encoded: b64) else {
            throw VGError.signatureInvalid("public key is not valid base64")
        }
        guard raw.count == 32 else {
            throw VGError.signatureInvalid(
                "public key must decode to 32 bytes, got \(raw.count)"
            )
        }
        return raw
    }

    // MARK: - Fingerprint

    /// The fingerprint of a public key: bare lowercase SHA-256 hex of its raw 32
    /// bytes. Stored full (64 hex chars) in `lockfile.json` and `known_keys.json`;
    /// display may truncate, but storage is always full.
    public static func fingerprint(publicKeyRaw: Data) -> String {
        Hashing.sha256Hex(publicKeyRaw)
    }

    // MARK: - Keygen + sign (test / pack only)

    /// Generate a fresh Ed25519 keypair, returning the raw 32-byte private and
    /// public key bytes. Used only by tests and the hidden pack path; this enum
    /// performs no key persistence.
    public static func generateKeypair() -> (privateRaw: Data, publicRaw: Data) {
        let privateKey = Curve25519.Signing.PrivateKey()
        return (privateKey.rawRepresentation, privateKey.publicKey.rawRepresentation)
    }

    /// Produce a detached Ed25519 signature (64 raw bytes) over `message` with the
    /// raw 32-byte private key `privateKeyRaw`.
    ///
    /// - Throws: `VGError.signatureInvalid` if `privateKeyRaw` is not a valid raw
    ///   Ed25519 private key, or if signing fails.
    public static func sign(message: Data, privateKeyRaw: Data) throws -> Data {
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyRaw)
        } catch {
            throw VGError.signatureInvalid(
                "invalid Ed25519 private key: \(error.localizedDescription)"
            )
        }
        do {
            return try privateKey.signature(for: message)
        } catch {
            throw VGError.signatureInvalid("signing failed: \(error.localizedDescription)")
        }
    }
}
