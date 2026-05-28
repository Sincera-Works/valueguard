import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var logOnly: Bool {
        didSet { defaults.set(logOnly, forKey: Keys.logOnly) }
    }
    var sampleRateHz: Double {
        didSet { defaults.set(sampleRateHz, forKey: Keys.sampleRateHz) }
    }
    var writeScoresLog: Bool {
        didSet { defaults.set(writeScoresLog, forKey: Keys.writeScoresLog) }
    }

    init() {
        self.logOnly = defaults.object(forKey: Keys.logOnly) as? Bool ?? true
        self.sampleRateHz = defaults.object(forKey: Keys.sampleRateHz) as? Double ?? 1.0
        self.writeScoresLog = defaults.object(forKey: Keys.writeScoresLog) as? Bool ?? true
    }

    private enum Keys {
        static let logOnly = "ValueGuard.logOnly"
        static let sampleRateHz = "ValueGuard.sampleRateHz"
        static let writeScoresLog = "ValueGuard.writeScoresLog"
    }
}
