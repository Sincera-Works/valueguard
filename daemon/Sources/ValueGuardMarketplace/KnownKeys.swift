import Foundation

/// Codable mirror of `configs/known_keys.json` — the Trust-On-First-Use (TOFU)
/// cache that pins each author handle to the Ed25519 public key first seen for
/// it (§5/§7).
///
/// The first time a config from `handle` is installed, `vg` records that
/// author's public key (and its fingerprint) here. On every subsequent install
/// from the same handle, the bundle's key is checked against the recorded one:
/// a match is trusted silently, a *change* is refused (the install aborts and
/// the user is told to edit `known_keys.json` by hand — there is no override
/// flag in P0). This is the only thing standing between a user and a swapped
/// signing key, so the comparison is over the full 64-hex fingerprint, not a
/// truncated display form.
///
/// JSON shape (§5):
/// ```json
/// {
///   "schema_version": 1,
///   "keys": {
///     "acme": {
///       "public_key": "base64-of-raw-32-byte-ed25519-key",
///       "fingerprint": "abc1...",
///       "first_seen": "2026-05-28T14:02:11Z"
///     }
///   }
/// }
/// ```
///
/// Snake_case wire keys are mapped via explicit `CodingKeys` (no
/// `.convertFromSnakeCase`). Writes go through `CanonicalJSON.encode` so the
/// emitted bytes are deterministic; reads use a plain `JSONDecoder` (this file
/// is one we author ourselves, never a third-party signed artifact, so there is
/// no re-canonicalization concern).
public struct KnownKeys: Codable, Sendable {

    /// Known-keys schema version. Always `1` in P0.
    public var schemaVersion: Int

    /// Author handle → trusted-key record.
    public var keys: [String: Record]

    /// A single trusted-key record for one author handle.
    public struct Record: Codable, Sendable {
        /// The author's raw 32-byte Ed25519 public key, base64-encoded (the
        /// same wire form as `manifest.author.public_key`).
        public var publicKey: String
        /// Bare lowercase hex SHA256 of the raw 32-byte public key (full 64 hex
        /// chars). The value compared during the TOFU check.
        public var fingerprint: String
        /// RFC3339 UTC timestamp of when this key was first recorded for the
        /// handle.
        public var firstSeen: String

        private enum CodingKeys: String, CodingKey {
            case publicKey = "public_key"
            case fingerprint
            case firstSeen = "first_seen"
        }

        public init(publicKey: String, fingerprint: String, firstSeen: String) {
            self.publicKey = publicKey
            self.fingerprint = fingerprint
            self.firstSeen = firstSeen
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case keys
    }

    public init(schemaVersion: Int = 1, keys: [String: Record] = [:]) {
        self.schemaVersion = schemaVersion
        self.keys = keys
    }

    /// Load the known-keys cache at `url`.
    ///
    /// If the file is absent, returns an empty cache
    /// (`{schema_version: 1, keys: {}}`) rather than throwing — a fresh install
    /// root has never seen any author yet, so every handle is first-use.
    ///
    /// - Throws: `VGError.io` if the file exists but cannot be read or decoded.
    public static func load(_ url: URL) throws -> KnownKeys {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return KnownKeys()
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw VGError.io("could not read known_keys at \(url.path): \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(KnownKeys.self, from: data)
        } catch {
            throw VGError.io("could not decode known_keys at \(url.path): \(error.localizedDescription)")
        }
    }

    /// Write the known-keys cache to `url` using `CanonicalJSON.encode`
    /// (deterministic sorted-key, slash-unescaped JSON).
    ///
    /// - Throws: `VGError.io` if encoding or the atomic write fails.
    public func save(to url: URL) throws {
        let data = try CanonicalJSON.encode(self)
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw VGError.io("could not write known_keys at \(url.path): \(error.localizedDescription)")
        }
    }

    /// The outcome of a TOFU check for one `handle`/`fingerprint` pair.
    public enum TrustResult: Sendable {
        /// The handle has never been seen — recording it now is trust-on-first-use.
        case firstUse
        /// The handle is known and the fingerprint matches the recorded one.
        case matches
        /// The handle is known but the fingerprint *differs*; carries the
        /// previously-recorded fingerprint so the caller can report both. The
        /// `Installer` refuses the install on this result.
        case changed(oldFingerprint: String)
    }

    /// Check a bundle's author `handle` and key `fingerprint` against the cache.
    ///
    /// Pure (no side effects): returns `.firstUse` for an unseen handle,
    /// `.matches` if the recorded fingerprint equals `fingerprint`, or
    /// `.changed(oldFingerprint:)` if a different key is already trusted for the
    /// handle. The caller decides what to do (record on first use, proceed on a
    /// match, refuse on a change).
    public func check(handle: String, fingerprint: String) -> TrustResult {
        guard let record = keys[handle] else {
            return .firstUse
        }
        if record.fingerprint == fingerprint {
            return .matches
        }
        return .changed(oldFingerprint: record.fingerprint)
    }

    /// Record (or overwrite) the trusted key for `handle`.
    ///
    /// Used on a `.firstUse` result to pin the key. `now` is an RFC3339 UTC
    /// timestamp stored as `first_seen`. This unconditionally writes the record
    /// for the handle; TOFU refusal on a key *change* is enforced by the caller
    /// via `check(handle:fingerprint:)` before recording — `record` itself does
    /// not guard against overwrites.
    public mutating func record(
        handle: String,
        publicKeyBase64: String,
        fingerprint: String,
        now: String
    ) {
        keys[handle] = Record(
            publicKey: publicKeyBase64,
            fingerprint: fingerprint,
            firstSeen: now
        )
    }
}
