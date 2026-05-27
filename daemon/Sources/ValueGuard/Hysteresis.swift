import Foundation

/// Per-window debouncing state machine.
///
/// Matches the reference Python spec's `HysteresisWindow`: `required` positive
/// hits within `windowSeconds` triggers an `activated` transition. The next
/// interval where the window passes a tick with no positive hit (and all
/// previous hits have aged out) triggers a `cleared` transition.
///
/// Struct + `mutating` methods so the daemon can hold one per window inside
/// its actor-isolated state map without reaching for reference types.
public struct HysteresisState: Sendable {
    public enum Transition: Sendable {
        case unchanged
        case activated
        case cleared
    }

    public let required: Int
    public let windowSeconds: Double

    private var hits: [Date] = []
    public private(set) var active: Bool = false

    public init(required: Int = 3, windowSeconds: Double = 10) {
        self.required = required
        self.windowSeconds = windowSeconds
    }

    private mutating func evict(now: Date) {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        while let first = hits.first, first < cutoff {
            hits.removeFirst()
        }
    }

    /// Append a positive hit at `now`. Returns `.activated` only on the
    /// boundary where this hit promotes us from inactive to active.
    public mutating func recordPositive(at now: Date = Date()) -> Transition {
        evict(now: now)
        hits.append(now)
        if hits.count >= required && !active {
            active = true
            return .activated
        }
        return .unchanged
    }

    /// Record a tick with no positive hit. Returns `.cleared` only on the
    /// boundary where we had been active and the eviction has just emptied
    /// the hit window.
    public mutating func recordNegative(at now: Date = Date()) -> Transition {
        evict(now: now)
        if hits.isEmpty && active {
            active = false
            return .cleared
        }
        return .unchanged
    }
}
