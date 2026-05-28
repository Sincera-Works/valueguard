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
    /// Suppress blur/notify/block while a call, screen share, or slideshow is
    /// detected (see `SensitiveContextMonitor`). Logging continues regardless.
    var autoPauseInSensitiveContexts: Bool {
        didSet { defaults.set(autoPauseInSensitiveContexts, forKey: Keys.autoPauseInSensitiveContexts) }
    }

    init() {
        self.logOnly = defaults.object(forKey: Keys.logOnly) as? Bool ?? true
        self.sampleRateHz = defaults.object(forKey: Keys.sampleRateHz) as? Double ?? 1.0
        self.writeScoresLog = defaults.object(forKey: Keys.writeScoresLog) as? Bool ?? true
        self.autoPauseInSensitiveContexts = defaults.object(forKey: Keys.autoPauseInSensitiveContexts) as? Bool ?? true
    }

    private enum Keys {
        static let logOnly = "ValueGuard.logOnly"
        static let sampleRateHz = "ValueGuard.sampleRateHz"
        static let writeScoresLog = "ValueGuard.writeScoresLog"
        static let autoPauseInSensitiveContexts = "ValueGuard.autoPauseInSensitiveContexts"
    }
}
