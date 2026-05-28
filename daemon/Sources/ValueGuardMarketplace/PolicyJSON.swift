import Foundation

/// Codable + validator for the human-readable `policy.json` document.
///
/// This mirrors the app's `PolicyTypes.swift` *exactly*: the stored property
/// names are literal `snake_case` so they byte-match the on-disk `policy.json`
/// keys, and decoding uses a plain `JSONDecoder` with **no** key-decoding
/// strategy (`.convertFromSnakeCase` is deliberately not used). The validation
/// rules are the same as the daemon/app `PolicyParser` (id pattern, 6–14
/// captions per side, threshold in 0…1) with the additional §2 marketplace cap
/// of 1–20 categories per bundle.
///
/// `policy.json` is the human-readable companion to `policy.bin`; the binary
/// `VGP1` form remains the authoritative contract (see `PolicyBinCrossCheck`),
/// and this type never re-derives or alters it.

/// The action taken when a category matches a frame.
public enum PolicyJSONAction: String, Codable, Sendable {
    case log
    case blur
    case block
}

/// One category in the human-readable `policy.json`.
public struct PolicyJSONCategory: Codable, Sendable {
    public let id: String
    public let description: String
    public let positive_captions: [String]
    public let negative_captions: [String]
    public let threshold: Double
    public let threshold_note: String
    public let action: PolicyJSONAction

    public init(
        id: String,
        description: String,
        positive_captions: [String],
        negative_captions: [String],
        threshold: Double,
        threshold_note: String,
        action: PolicyJSONAction
    ) {
        self.id = id
        self.description = description
        self.positive_captions = positive_captions
        self.negative_captions = negative_captions
        self.threshold = threshold
        self.threshold_note = threshold_note
        self.action = action
    }
}

/// The top-level `policy.json` document.
public struct PolicyJSONDocument: Codable, Sendable {
    public let categories: [PolicyJSONCategory]
    public let clarifications: [String]
    public let calibration_note: String

    public init(
        categories: [PolicyJSONCategory],
        clarifications: [String],
        calibration_note: String
    ) {
        self.categories = categories
        self.clarifications = clarifications
        self.calibration_note = calibration_note
    }
}

/// Decoder + schema validator for `policy.json`.
public enum PolicyJSONValidator {

    /// `^[a-z][a-z0-9_]*$` — category ids are lowercase snake_case starting
    /// with a letter (matches the app/daemon `PolicyParser`). Built once at
    /// load via the runtime `Regex` initializer; the pattern is a compile-time
    /// constant so the force-try never fails.
    private static let idPattern = try! Regex("^[a-z][a-z0-9_]*$")

    /// Decode raw `policy.json` bytes into a `PolicyJSONDocument`.
    ///
    /// Uses a plain `JSONDecoder` with no key-decoding strategy so the literal
    /// snake_case property names map directly to the on-disk keys. Any decode
    /// failure is re-wrapped as `VGError.policyJSONSchema` with a key/path hint.
    public static func decode(from data: Data) throws -> PolicyJSONDocument {
        do {
            return try JSONDecoder().decode(PolicyJSONDocument.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw VGError.policyJSONSchema(
                "missing key '\(key.stringValue)' at \(codingPathString(ctx.codingPath))")
        } catch let DecodingError.typeMismatch(type, ctx) {
            throw VGError.policyJSONSchema(
                "expected \(type) at \(codingPathString(ctx.codingPath))")
        } catch let DecodingError.valueNotFound(type, ctx) {
            throw VGError.policyJSONSchema(
                "missing \(type) at \(codingPathString(ctx.codingPath))")
        } catch let DecodingError.dataCorrupted(ctx) {
            throw VGError.policyJSONSchema(ctx.debugDescription)
        } catch {
            throw VGError.policyJSONSchema(error.localizedDescription)
        }
    }

    /// Validate a decoded `policy.json` against the human-readable schema:
    /// 1–20 categories (§2 cap); each id matches `^[a-z][a-z0-9_]*$`; 6–14
    /// captions per side; threshold in `0...1`.
    public static func validate(_ doc: PolicyJSONDocument) throws {
        let count = doc.categories.count
        guard count >= 1 else {
            throw VGError.policyJSONSchema("policy.json must contain at least one category")
        }
        guard count <= 20 else {
            throw VGError.policyJSONSchema(
                "policy.json has \(count) categories — the maximum is 20")
        }
        for cat in doc.categories {
            guard (try? idPattern.wholeMatch(in: cat.id)) != nil else {
                throw VGError.policyJSONSchema(
                    "category id '\(cat.id)' must be lowercase snake_case and start with a letter")
            }
            let pos = cat.positive_captions.count
            let neg = cat.negative_captions.count
            if pos < 6 || pos > 14 {
                throw VGError.policyJSONSchema(
                    "category '\(cat.id)' has \(pos) positive captions — expected 6–14")
            }
            if neg < 6 || neg > 14 {
                throw VGError.policyJSONSchema(
                    "category '\(cat.id)' has \(neg) negative captions — expected 6–14")
            }
            if cat.threshold < 0 || cat.threshold > 1 {
                throw VGError.policyJSONSchema(
                    "category '\(cat.id)' threshold \(cat.threshold) is outside 0…1")
            }
        }
    }

    private static func codingPathString(_ path: [CodingKey]) -> String {
        path.map { key in
            if let index = key.intValue {
                return "[\(index)]"
            }
            return key.stringValue
        }.joined(separator: ".")
    }
}
