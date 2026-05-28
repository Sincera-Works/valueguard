import Foundation
import Observation

/// Per-category user-set actions, persisted in UserDefaults.
///
/// Storage shape: `[category_id: UserAction.rawValue]`. Categories without
/// an entry default to `.log` — same baseline as policy.bin's default action.
@MainActor
@Observable
final class ActionOverrides {
    private let key = "ValueGuard.actionOverrides"
    private let defaults = UserDefaults.standard

    private(set) var overrides: [String: UserAction]

    init() {
        if let raw = defaults.dictionary(forKey: key) as? [String: String] {
            var parsed: [String: UserAction] = [:]
            for (k, v) in raw { parsed[k] = UserAction(rawValue: v) }
            self.overrides = parsed
        } else {
            self.overrides = [:]
        }
    }

    func action(for categoryID: String) -> UserAction {
        overrides[categoryID] ?? .log
    }

    func set(_ action: UserAction, for categoryID: String) {
        overrides[categoryID] = action
        persist()
    }

    private func persist() {
        let raw = overrides.mapValues { $0.rawValue }
        defaults.set(raw, forKey: key)
    }
}
