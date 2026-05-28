import Foundation

/// What the app does when a category fires, on top of the always-on audit
/// log. Per-category and user-overridable from Settings.
///
/// The daemon stays in `logOnly` mode permanently in this architecture —
/// it produces audit.log entries and that's it. Action policy lives in the
/// app, so it's dynamic (no policy.bin re-embed required) and can be
/// extended without touching the daemon's binary contract.
enum UserAction: String, Codable, CaseIterable, Identifiable {
    case log     // baseline: audit.log only, no UI
    case notify  // macOS user notification
    case blur    // visible blur overlay over the offending window
    case block   // navigate browser tab away / close window

    var id: String { rawValue }

    var label: String {
        switch self {
        case .log:    return "Log only"
        case .notify: return "Notify"
        case .blur:   return "Blur"
        case .block:  return "Block"
        }
    }

    var description: String {
        switch self {
        case .log:    return "Audit log only; nothing visible."
        case .notify: return "macOS notification when the category fires."
        case .blur:   return "Overlay the offending window with a blur."
        case .block:  return "Navigate the offending browser tab to a blank page."
        }
    }

    /// SF Symbol used for menubar / settings rows.
    var symbol: String {
        switch self {
        case .log:    return "doc.text"
        case .notify: return "bell.badge"
        case .blur:   return "drop.fill"
        case .block:  return "hand.raised.fill"
        }
    }
}
