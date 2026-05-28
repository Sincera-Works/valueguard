import Foundation

/// Best-effort extractor for "I am okay with X" / "I am fine with Y" phrases
/// from a values.md file. These are the user's declared exceptions —
/// content they explicitly want NOT to fire — and form the most important
/// negative test set for calibration.
enum ValuesExclusionExtractor {
    /// Returns a list of short search-query terms extracted from the values
    /// text. e.g. "I am okay with cats" → ["cats"].
    static func extract(from values: String) -> [String] {
        var queries: [String] = []
        let lines = values.components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "^[-*\\s]+", with: "", options: .regularExpression)
            // Look for the most common phrasings the model emits in policy
            // discussions and the user might write naturally.
            let patterns = [
                "(?i)^I am (?:okay|ok|fine|happy) (?:with|to see) (.+?)\\.?$",
                "(?i)^(?:okay|ok|fine|allow|allowed): (.+?)\\.?$",
                "(?i)(?:cats|wolves|cats and|including) (.+?)\\.?$",
            ]
            for pattern in patterns {
                if let match = try? NSRegularExpression(pattern: pattern, options: []).firstMatch(
                    in: line, range: NSRange(line.startIndex..., in: line)
                ),
                   match.numberOfRanges > 1,
                   let r = Range(match.range(at: 1), in: line) {
                    let captured = String(line[r])
                    queries.append(contentsOf: splitCaptured(captured))
                    break
                }
            }
        }
        // De-dup, lowercase, drop trivially short queries.
        var seen = Set<String>()
        return queries.compactMap { q in
            let cleaned = q.trimmingCharacters(in: .whitespaces).lowercased()
            guard cleaned.count >= 3, seen.insert(cleaned).inserted else { return nil }
            return cleaned
        }
    }

    /// "cats and wolves and farm animals" → ["cats", "wolves", "farm animals"]
    private static func splitCaptured(_ s: String) -> [String] {
        s.replacingOccurrences(of: " and ", with: ", ")
            .replacingOccurrences(of: " & ", with: ", ")
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
