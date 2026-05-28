import XCTest
@testable import ValueGuardMarketplace

/// Unit tests for the cryptographic and hashing primitives that underpin the
/// `.vgconfig` sign/verify contract: Ed25519 round-trip + tamper rejection,
/// the public-key fingerprint convention, the two SHA-256 output conventions
/// (bare hex vs. `sha256:`-prefixed), and canonical JSON byte stability.
///
/// These are pure unit tests — no filesystem, no archive, no network. The
/// end-to-end bundle verify/tamper coverage lives in `VerifyTamperTests`.
final class SignVerifyTests: XCTestCase {

    // MARK: - Ed25519 round-trip

    /// A signature produced by `sign` over a message must verify `true` against
    /// the matching public key, exercising the happy path of the load-bearing
    /// verify primitive.
    func testEd25519RoundTrip() throws {
        let (privateRaw, publicRaw) = Ed25519.generateKeypair()

        // Public key is the raw 32 bytes; private key likewise round-trips
        // through `sign` (which reconstructs it from rawRepresentation).
        XCTAssertEqual(publicRaw.count, 32, "Ed25519 public key must be 32 raw bytes")

        let message = Data("the signed artifact is the raw MANIFEST.SHA256 bytes".utf8)
        let signature = try Ed25519.sign(message: message, privateKeyRaw: privateRaw)

        // Detached Ed25519 signatures are 64 bytes.
        XCTAssertEqual(signature.count, 64, "Ed25519 signature must be 64 raw bytes")

        XCTAssertTrue(
            Ed25519.verify(signature: signature, message: message, publicKeyRaw: publicRaw),
            "a fresh signature must verify against its own public key"
        )

        // Verifying the same signature twice is stable.
        XCTAssertTrue(
            Ed25519.verify(signature: signature, message: message, publicKeyRaw: publicRaw),
            "verification must be deterministic"
        )
    }

    /// `verify` must return `false` — never throw — for every failure mode an
    /// untrusted bundle could present: a tampered message, a corrupted
    /// signature, a wrong public key, and malformed/wrong-length key or
    /// signature bytes.
    func testVerifyRejectsTamperedMessage() throws {
        let (privateRaw, publicRaw) = Ed25519.generateKeypair()
        let message = Data("MANIFEST.SHA256 contents v1".utf8)
        let signature = try Ed25519.sign(message: message, privateKeyRaw: privateRaw)

        // Sanity: the untouched signature verifies.
        XCTAssertTrue(Ed25519.verify(signature: signature, message: message, publicKeyRaw: publicRaw))

        // (1) Tampered message — a single flipped byte must invalidate.
        var tamperedMessage = message
        tamperedMessage[tamperedMessage.startIndex] ^= 0x01
        XCTAssertFalse(
            Ed25519.verify(signature: signature, message: tamperedMessage, publicKeyRaw: publicRaw),
            "a signature must not verify over a tampered message"
        )

        // (2) Tampered signature — a single flipped byte must invalidate.
        var tamperedSignature = signature
        tamperedSignature[tamperedSignature.startIndex] ^= 0x01
        XCTAssertFalse(
            Ed25519.verify(signature: tamperedSignature, message: message, publicKeyRaw: publicRaw),
            "a corrupted signature must not verify"
        )

        // (3) Wrong public key — a different keypair must not verify.
        let (_, otherPublicRaw) = Ed25519.generateKeypair()
        XCTAssertFalse(
            Ed25519.verify(signature: signature, message: message, publicKeyRaw: otherPublicRaw),
            "a signature must not verify against an unrelated public key"
        )

        // (4) Malformed public key (wrong length) folds to false, never throws.
        XCTAssertFalse(
            Ed25519.verify(signature: signature, message: message, publicKeyRaw: Data([0x00, 0x01, 0x02])),
            "a wrong-length public key must yield false, not throw"
        )

        // (5) Malformed signature (wrong length) folds to false, never throws.
        XCTAssertFalse(
            Ed25519.verify(signature: Data([0xFF]), message: message, publicKeyRaw: publicRaw),
            "a wrong-length signature must yield false, not throw"
        )
    }

    // MARK: - Fingerprint

    /// The public-key fingerprint must be deterministic, 64-char bare lowercase
    /// hex, equal to the SHA-256 of the raw 32 key bytes, and distinct for
    /// distinct keys. This is the value stored in lockfile.json / known_keys.json.
    func testFingerprintStable() {
        let (_, publicRaw) = Ed25519.generateKeypair()

        let fp1 = Ed25519.fingerprint(publicKeyRaw: publicRaw)
        let fp2 = Ed25519.fingerprint(publicKeyRaw: publicRaw)

        // Deterministic across calls.
        XCTAssertEqual(fp1, fp2, "fingerprint must be deterministic for the same key")

        // Stored full as 64-char bare lowercase hex.
        XCTAssertTrue(
            Hashing.isValidSha256Hex(fp1),
            "fingerprint must be a 64-char bare lowercase SHA-256 hex string"
        )

        // It is exactly the bare-hex SHA-256 of the raw key bytes.
        XCTAssertEqual(
            fp1,
            Hashing.sha256Hex(publicRaw),
            "fingerprint must equal SHA-256 of the raw 32 public-key bytes"
        )

        // Distinct keys produce distinct fingerprints.
        let (_, otherPublicRaw) = Ed25519.generateKeypair()
        XCTAssertNotEqual(
            fp1,
            Ed25519.fingerprint(publicKeyRaw: otherPublicRaw),
            "distinct keys must have distinct fingerprints"
        )
    }

    // MARK: - SHA-256 hex shape

    /// `sha256Hex` must emit bare lowercase 64-char hex, `isValidSha256Hex` must
    /// accept it and reject the common malformed shapes (wrong length,
    /// uppercase, non-hex).
    func testSha256HexShape() {
        let hex = Hashing.sha256Hex(Data("hello world".utf8))

        // Bare lowercase, exactly 64 hex chars.
        XCTAssertEqual(hex.utf8.count, 64, "bare SHA-256 hex must be 64 characters")
        XCTAssertTrue(Hashing.isValidSha256Hex(hex), "emitted bare hex must validate")
        XCTAssertEqual(hex, hex.lowercased(), "bare hex must be lowercase")

        // Known-answer: SHA-256("hello world") is a stable, well-known digest.
        XCTAssertEqual(
            hex,
            "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
            "SHA-256 of \"hello world\" must match the known digest"
        )

        // Same input hashes identically twice.
        XCTAssertEqual(hex, Hashing.sha256Hex(Data("hello world".utf8)))

        // Rejections.
        XCTAssertFalse(Hashing.isValidSha256Hex(""), "empty string is not valid hex")
        XCTAssertFalse(Hashing.isValidSha256Hex(String(repeating: "a", count: 63)), "63 chars rejected")
        XCTAssertFalse(Hashing.isValidSha256Hex(String(repeating: "a", count: 65)), "65 chars rejected")
        XCTAssertFalse(
            Hashing.isValidSha256Hex(hex.uppercased()),
            "uppercase hex must be rejected (lowercase only)"
        )
        XCTAssertFalse(
            Hashing.isValidSha256Hex(String(repeating: "g", count: 64)),
            "non-hex characters must be rejected"
        )
        // A leading "sha256:" prefix is not bare hex.
        XCTAssertFalse(
            Hashing.isValidSha256Hex("sha256:" + hex),
            "a prefixed string is not bare hex"
        )
    }

    // MARK: - Prefix forms

    /// `sha256Prefixed` must equal `"sha256:" + sha256Hex`, and `stripSha256Prefix`
    /// must round-trip a well-formed prefixed string back to its bare hex while
    /// rejecting malformed inputs.
    func testPrefixForms() {
        let data = Data("policy.bin contents".utf8)
        let bare = Hashing.sha256Hex(data)
        let prefixed = Hashing.sha256Prefixed(data)

        // Prefixed == "sha256:" + bare.
        XCTAssertEqual(prefixed, "sha256:" + bare, "prefixed form is literally \"sha256:\" + bare hex")
        XCTAssertTrue(prefixed.hasPrefix("sha256:"))

        // strip round-trips a valid prefixed string back to the bare hex.
        XCTAssertEqual(
            Hashing.stripSha256Prefix(prefixed),
            bare,
            "stripping a valid prefixed hash must yield the bare hex"
        )

        // strip rejects malformed inputs by returning nil.
        XCTAssertNil(Hashing.stripSha256Prefix(bare), "a bare (unprefixed) hash has no prefix to strip")
        XCTAssertNil(Hashing.stripSha256Prefix("sha256:"), "prefix with no hex is rejected")
        XCTAssertNil(
            Hashing.stripSha256Prefix("sha256:" + String(repeating: "a", count: 63)),
            "prefix with short hex is rejected"
        )
        XCTAssertNil(
            Hashing.stripSha256Prefix("sha256:" + bare.uppercased()),
            "prefix with uppercase hex is rejected (lowercase only)"
        )
        XCTAssertNil(
            Hashing.stripSha256Prefix("md5:" + bare),
            "a non-sha256 prefix is rejected"
        )
        XCTAssertNil(Hashing.stripSha256Prefix(""), "empty string has no prefix")

        // File-reading variants agree with the in-memory variants over identical bytes.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vg-prefix-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try data.write(to: tmp)
            XCTAssertEqual(try Hashing.sha256Hex(ofFileAt: tmp), bare,
                           "file bare-hex must match in-memory bare hex over the same bytes")
            XCTAssertEqual(try Hashing.sha256Prefixed(ofFileAt: tmp), prefixed,
                           "file prefixed hash must match in-memory prefixed hash")
        } catch {
            XCTFail("temp-file hashing failed: \(error)")
        }
    }

    // MARK: - Canonical JSON stability

    /// `CanonicalJSON.encode` must be deterministic (byte-identical across
    /// calls), emit keys in sorted order, leave slashes unescaped, and round-trip
    /// through `decode`.
    func testCanonicalJSONStable() throws {
        struct Sample: Codable, Equatable {
            let zebra: String
            let apple: Int
            let path: String
        }

        let value = Sample(zebra: "z", apple: 1, path: "author/slug/1.0.0")

        let first = try CanonicalJSON.encode(value)
        let second = try CanonicalJSON.encode(value)

        // Deterministic: same value -> identical bytes.
        XCTAssertEqual(first, second, "canonical encoding must be byte-stable")

        let json = String(decoding: first, as: UTF8.self)

        // Keys sorted ascending (apple < path < zebra).
        let appleIdx = json.range(of: "\"apple\"")!.lowerBound
        let pathIdx = json.range(of: "\"path\"")!.lowerBound
        let zebraIdx = json.range(of: "\"zebra\"")!.lowerBound
        XCTAssertTrue(appleIdx < pathIdx && pathIdx < zebraIdx, "keys must be emitted in sorted order")

        // Slashes are NOT escaped.
        XCTAssertTrue(json.contains("author/slug/1.0.0"), "forward slashes must be left unescaped")
        XCTAssertFalse(json.contains("\\/"), "no escaped slashes in canonical output")

        // No pretty-printing whitespace.
        XCTAssertFalse(json.contains("\n"), "canonical output must not be pretty-printed")

        // Round-trips through decode.
        let decoded = try CanonicalJSON.decode(Sample.self, from: first)
        XCTAssertEqual(decoded, value, "canonical JSON must round-trip through decode")
    }
}
