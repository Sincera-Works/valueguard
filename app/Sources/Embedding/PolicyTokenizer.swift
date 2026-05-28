import Foundation
import Hub
import Tokenizers

enum PolicyTokenizerError: LocalizedError {
    case missingResource(String)
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "Bundled tokenizer resource missing: \(name)"
        case .decodeFailed(let m): return "Failed to decode tokenizer config: \(m)"
        }
    }
}

@MainActor
final class PolicyTokenizer {
    private let tokenizer: any Tokenizer
    let padTokenId: Int
    let maxLength: Int

    init(maxLength: Int = 64) throws {
        guard
            let tokenizerJSONURL = Bundle.main.url(forResource: "tokenizer", withExtension: "json"),
            let tokenizerConfigURL = Bundle.main.url(forResource: "tokenizer_config", withExtension: "json")
        else {
            throw PolicyTokenizerError.missingResource("tokenizer.json / tokenizer_config.json")
        }

        let dataJSON = try Data(contentsOf: tokenizerJSONURL)
        let configJSON = try Data(contentsOf: tokenizerConfigURL)

        let decoder = JSONDecoder()
        let tokenizerData: Config
        let tokenizerConfig: Config
        do {
            tokenizerData = try decoder.decode(Config.self, from: dataJSON)
            tokenizerConfig = try decoder.decode(Config.self, from: configJSON)
        } catch {
            throw PolicyTokenizerError.decodeFailed(String(describing: error))
        }

        self.tokenizer = try AutoTokenizer.from(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
        self.maxLength = maxLength
        // SigLIP-2 uses </s> as both EOS and pad. Fall back to 1 if not exposed.
        self.padTokenId = tokenizer.eosTokenId ?? 1
    }

    /// Tokenize and pad/truncate a caption to `maxLength` tokens.
    func encode(_ text: String) -> [Int32] {
        var ids = tokenizer.encode(text: text)
        if ids.count > maxLength {
            ids = Array(ids.prefix(maxLength))
        } else if ids.count < maxLength {
            ids.append(contentsOf: Array(repeating: padTokenId, count: maxLength - ids.count))
        }
        return ids.map { Int32($0) }
    }
}
