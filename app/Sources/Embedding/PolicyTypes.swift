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
            return "Category '\(cat)' has \(count) \(side) captions — expected 6–14."
        case .thresholdRange(let cat, let value):
            return "Category '\(cat)' threshold \(value) is outside 0…1."
        }
    }
}

enum PolicyParser {
    static func parse(_ raw: String) throws -> Policy {
        let trimmed = stripFences(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PolicyParseError.empty }
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

    static func stripFences(_ raw: String) -> String {
        var s = raw
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let m = try? /^```(?:json)?\n([\s\S]*?)\n```$/.wholeMatch(in: s) {
            s = String(m.output.1)
        }
        if s.hasPrefix("```") {
            s.removeFirst(3)
            if s.hasPrefix("json") { s.removeFirst(4) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasSuffix("```") {
            s.removeLast(3)
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
