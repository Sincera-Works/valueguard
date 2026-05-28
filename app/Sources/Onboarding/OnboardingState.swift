import Foundation
import Observation

@MainActor
@Observable
final class OnboardingState {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, values, copyPrompt, pasteJSON, embed, permission, done
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .values: return "Your values"
            case .copyPrompt: return "Copy the prompt"
            case .pasteJSON: return "Paste the policy"
            case .embed: return "Build the policy"
            case .permission: return "Grant Screen Recording"
            case .done: return "Done"
            }
        }
    }

    var step: Step = .welcome
    var mode: DeploymentMode = .personal
    var valuesText: String = OnboardingState.defaultValuesText
    var pastedJSON: String = ""
    var parsedPolicy: Policy?
    var parseError: String?

    private static let defaultValuesText = """
    # Your values

    Describe in plain English what you want filtered from your screen.
    Be concrete about edge cases — the model that compiles this prompt
    will surface ambiguities back as clarifying questions.

    Examples:
    - I do not want to see explicit nudity.
    - I am OK with classical or art-historical nudity in a museum context.
    - I do not want to see graphic real-world violence; cartoon violence is fine.
    - I do not want to see gambling content. Sports broadcasts are fine.
    """

    func next() {
        if let i = Step.allCases.firstIndex(of: step), i + 1 < Step.allCases.count {
            step = Step.allCases[i + 1]
        }
    }

    func back() {
        if let i = Step.allCases.firstIndex(of: step), i > 0 {
            step = Step.allCases[i - 1]
        }
    }

    func loadPersistedValues() {
        if let data = try? Data(contentsOf: AppSupport.valuesURL),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            valuesText = text
        }
    }

    func persistValues() {
        try? valuesText.data(using: .utf8)?.write(to: AppSupport.valuesURL)
    }

    func tryParse() {
        do {
            let policy = try PolicyParser.parse(pastedJSON)
            parsedPolicy = policy
            parseError = nil
            persistPolicyJSON()
        } catch {
            parsedPolicy = nil
            parseError = error.localizedDescription
        }
    }

    private func persistPolicyJSON() {
        guard let policy = parsedPolicy,
              let data = try? JSONEncoder().encode(policy) else { return }
        try? data.write(to: AppSupport.policyJSONURL)
    }
}
