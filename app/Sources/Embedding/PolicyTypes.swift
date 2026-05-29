import Foundation

enum PolicyAction: String, Codable {
    case log
    case blur
    case block
}

struct PolicyCategory: Codable, Identifiable {
    let id: String
    let description: String
    let positive_captions: [String]
    let negative_captions: [String]
    let threshold: Double
    let threshold_note: String
    let action: PolicyAction
}

struct Policy: Codable {
    let categories: [PolicyCategory]
    let clarifications: [String]
    let calibration_note: String
}

enum PolicyParseError: LocalizedError {
    case empty
    case invalidJSON(underlying: Error)
    case schemaMismatch(message: String)
    case noCategories
    case badCategoryID(String)
    case captionCount(category: String, side: String, count: Int)
    case thresholdRange(category: String, value: Double)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "No JSON pasted yet."
        case .invalidJSON(let e):
            return "Not valid JSON: \(e.localizedDescription)"
        case .schemaMismatch(let m):
            return "Schema mismatch: \(m)"
        case .noCategories:
            return "Policy must contain at least one category."
        case .badCategoryID(let id):
            return "Category id '\(id)' must be snake_case, lowercase, start with a letter."
        case .captionCount(let cat, let side, let count):
            return "Category '\(cat)' has \(count) \(side) captions — ask the assistant for between 6 and 14 captions per side."
        case .thresholdRange(let cat, let value):
            return "Category '\(cat)' threshold \(value) is outside 0…1."
        }
    }
}

enum PolicyParser {
    static func parse(_ raw: String) throws -> Policy {
        let extracted = extractJSON(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extracted.isEmpty else { throw PolicyParseError.empty }
        let trimmed = normalizeQuotes(extracted)
        guard let data = trimmed.data(using: .utf8) else {
            throw PolicyParseError.schemaMismatch(message: "input is not UTF-8")
        }
        let policy: Policy
        do {
            policy = try JSONDecoder().decode(Policy.self, from: data)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw PolicyParseError.schemaMismatch(message: "missing key '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.typeMismatch(type, ctx) {
            throw PolicyParseError.schemaMismatch(message: "expected \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.valueNotFound(type, ctx) {
            throw PolicyParseError.schemaMismatch(message: "missing \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
        } catch let DecodingError.dataCorrupted(ctx) {
            throw PolicyParseError.schemaMismatch(message: ctx.debugDescription)
        } catch {
            throw PolicyParseError.invalidJSON(underlying: error)
        }
        try validate(policy)
        return policy
    }

    /// Pull the JSON payload out of a Claude.ai reply that may wrap it in
    /// prose ("Here's your policy: ```json … ``` Let me know!"). Strategy:
    ///   1. The FIRST ```-fenced block anywhere in the input (non-anchored),
    ///      with an optional `json` language tag.
    ///   2. If there is no fence, slice from the first '{' to the last '}'.
    ///   3. Otherwise, return the trimmed input unchanged.
    static func extractJSON(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. First fenced code block anywhere in the text.
        if let m = s.firstMatch(of: /```[ \t]*(?:json)?[ \t]*\r?\n([\s\S]*?)```/) {
            return String(m.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. No fence — slice between the first '{' and the last '}'.
        if let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}"), open < close {
            return String(s[open...close])
        }

        return s
    }

    /// Replace typographic quotes a chat UI may have smart-substituted so the
    /// JSON decoder sees plain ASCII delimiters.
    static func normalizeQuotes(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "\u{201C}", with: "\"") // “ left double
        s = s.replacingOccurrences(of: "\u{201D}", with: "\"") // ” right double
        s = s.replacingOccurrences(of: "\u{2018}", with: "'")  // ‘ left single
        s = s.replacingOccurrences(of: "\u{2019}", with: "'")  // ’ right single
        return s
    }

    private static let idPattern = /^[a-z][a-z0-9_]*$/

    static func validate(_ policy: Policy) throws {
        guard !policy.categories.isEmpty else { throw PolicyParseError.noCategories }
        for cat in policy.categories {
            guard (try? idPattern.wholeMatch(in: cat.id)) != nil else {
                throw PolicyParseError.badCategoryID(cat.id)
            }
            let pos = cat.positive_captions.count
            let neg = cat.negative_captions.count
            if pos < 6 || pos > 14 {
                throw PolicyParseError.captionCount(category: cat.id, side: "positive", count: pos)
            }
            if neg < 6 || neg > 14 {
                throw PolicyParseError.captionCount(category: cat.id, side: "negative", count: neg)
            }
            if cat.threshold < 0 || cat.threshold > 1 {
                throw PolicyParseError.thresholdRange(category: cat.id, value: cat.threshold)
            }
        }
    }
}
