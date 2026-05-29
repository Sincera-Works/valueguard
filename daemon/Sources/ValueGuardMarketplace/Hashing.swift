import Foundation
import CryptoKit

/// SHA-256 helpers in the two output conventions the marketplace contract uses,
/// plus hex-shape validation.
///
/// Two distinct conventions are intentionally never conflated:
///
/// - **Bare hex** — lowercase, 64 hex characters. Used for
///   `signatures/MANIFEST.SHA256` lines, `bundle_sha256` in the lockfile, and
///   the Ed25519 public-key fingerprint. This matches the existing daemon SHA256
///   idiom `digest.map { String(format: "%02x", $0) }.joined()`.
/// - **`sha256:`-prefixed hex** — the bare hex with a literal `"sha256:"`
///   prefix. Used for the manifest's `policy_hash`, `policy_json_hash`, and
///   `calibration_hash` fields.
///
/// All file-reading variants hash the *raw* on-disk bytes. The verify path must
/// never re-canonicalize before hashing, so callers compute digests straight
/// from the file contents via these helpers.
public enum Hashing {
    // MARK: - Bare hex

    /// SHA-256 of `data` as bare lowercase 64-character hex.
    public static func sha256Hex(_ data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }

    /// SHA-256 of the raw bytes of the file at `url`, as bare lowercase hex.
    ///
    /// - Throws: `VGError.io` if the file cannot be read.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        sha256Hex(try readFile(url))
    }

    // MARK: - sha256: prefixed

    /// SHA-256 of `data` as `"sha256:" + ` bare lowercase hex.
    public static func sha256Prefixed(_ data: Data) -> String {
        "sha256:" + sha256Hex(data)
    }

    /// SHA-256 of the raw bytes of the file at `url`, as `"sha256:" + ` bare hex.
    ///
    /// - Throws: `VGError.io` if the file cannot be read.
    public static func sha256Prefixed(ofFileAt url: URL) throws -> String {
        "sha256:" + (try sha256Hex(ofFileAt: url))
    }

    // MARK: - Shape validation

    /// Whether `s` is exactly 64 characters drawn from `[0-9a-f]` (bare hex).
    public static func isValidSha256Hex(_ s: String) -> Bool {
        guard s.utf8.count == 64 else { return false }
        for byte in s.utf8 {
            switch byte {
            case 0x30...0x39, // 0-9
                 0x61...0x66: // a-f
                continue
            default:
                return false
            }
        }
        return true
    }

    /// If `s` is a well-formed `"sha256:<64 lowercase hex>"`, returns the bare
    /// hex portion; otherwise returns `nil`.
    public static func stripSha256Prefix(_ s: String) -> String? {
        let prefix = "sha256:"
        guard s.hasPrefix(prefix) else { return nil }
        let hex = String(s.dropFirst(prefix.count))
        return isValidSha256Hex(hex) ? hex : nil
    }

    // MARK: - Private

    /// Render a digest as bare lowercase hex, matching the daemon's idiom.
    private static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Read the raw bytes of a file, re-wrapping any failure as `VGError.io`.
    private static func readFile(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw VGError.io("could not read \(url.path): \(error.localizedDescription)")
        }
    }
}
