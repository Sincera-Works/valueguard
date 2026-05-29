import Foundation

/// Authoring-time canonical JSON encoder plus a plain decoder.
///
/// `CanonicalJSON` is the single encoder used by every *writer* in the
/// marketplace library and the test signer: `manifest.json` (pack path),
/// `lockfile.json`, and `known_keys.json` are all emitted through
/// `encode(_:)` so their byte layout is deterministic and self-consistent.
///
/// IMPORTANT — this is **not** the verify hash path. `vg verify` / `vg install`
/// never re-canonicalize on-disk artifacts: all hash checks read the exact
/// bytes already present in the bundle (see `Hashing.sha256*(ofFileAt:)`).
/// Re-encoding a third party's `manifest.json` before hashing would reject a
/// legitimately-signed bundle whose author used different float formatting,
/// key order, or slash escaping. `CanonicalJSON` therefore only ever produces
/// bytes we are about to *write and sign ourselves*; it makes no RFC-8785
/// conformance claim. The contract is simply "what this exact encoder emits",
/// and because the same encoder is used by both the writer and the (test)
/// signer, it is internally consistent.
///
/// Output formatting is `[.sortedKeys, .withoutEscapingSlashes]` with no
/// pretty-printing: keys are emitted in ascending UTF-8 order, forward
/// slashes are left unescaped (so `file:///` paths and `author/slug` strings
/// stay readable), and there is no incidental whitespace.
public enum CanonicalJSON {

    /// Encode an `Encodable` value to canonical JSON bytes.
    ///
    /// Uses `JSONEncoder` with `outputFormatting = [.sortedKeys,
    /// .withoutEscapingSlashes]` and no `.prettyPrinted`. Encoding the same
    /// value twice yields byte-identical output.
    ///
    /// - Throws: `VGError.io` if the value cannot be encoded.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw VGError.io("failed to encode JSON: \(error.localizedDescription)")
        }
    }

    /// Decode canonical (or any well-formed) JSON bytes into a `Decodable`.
    ///
    /// A plain `JSONDecoder` with no key conversion strategy: callers that
    /// need snake_case mapping declare explicit `CodingKeys`.
    ///
    /// - Throws: `VGError.io` if the data cannot be decoded into `T`.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw VGError.io("failed to decode JSON: \(error.localizedDescription)")
        }
    }
}
