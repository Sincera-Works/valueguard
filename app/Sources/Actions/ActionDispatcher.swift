import Foundation

/// Routes audit-log transitions to user-action handlers.
///
/// Subscribes to `AuditLogTailer.onTransition` (the canonical "category
/// activated on this window" event) rather than every per-frame flag,
/// because notify/blur/block all operate at activation granularity. The
/// hysteresis layer in the daemon already debounces individual flags into
/// `activated` / `cleared` transitions for us.
@MainActor
final class ActionDispatcher {
    private let tailer: AuditLogTailer
    private let overrides: ActionOverrides
    private let notify = NotifyAction()
    private let blur = BlurOverlayManager()
    private var lastFlagScore: [String: Float] = [:]
    private var activeWindowCategory: [UInt32: String] = [:]

    init(tailer: AuditLogTailer, overrides: ActionOverrides) {
        self.tailer = tailer
        self.overrides = overrides
    }

    func start() {
        tailer.onFlag = { [weak self] event in
            self?.lastFlagScore[event.category] = event.positive
            // Each flag tick lets BlurOverlayManager re-check whether the
            // offending window is still the user's active window, and
            // reposition the blur to its current bounds.
            if let wid = event.windowID,
               let cat = self?.activeWindowCategory[wid],
               cat == event.category {
                self?.blur.reposition(forWindowID: wid, app: event.app)
            }
        }
        tailer.onTransition = { [weak self] event in
            self?.handleTransition(event)
        }
        tailer.start()
    }

    func stop() {
        tailer.stop()
        tailer.onFlag = nil
        tailer.onTransition = nil
    }

    private func handleTransition(_ event: AuditLogTailer.TransitionEvent) {
        switch event.kind {
        case .activated:
            guard let category = event.category else { return }
            let action = overrides.action(for: category)
            switch action {
            case .log:
                return
            case .notify:
                let score = lastFlagScore[category] ?? 0
                Task { await notify.notify(category: category, app: event.app, score: score) }
            case .blur:
                guard let wid = event.windowID else { return }
                activeWindowCategory[wid] = category
                blur.show(forWindowID: wid, category: category, app: event.app)
            case .block:
                Task { await BlockAction.run(app: event.app, category: category) }
            }
        case .cleared, .disappeared:
            guard let wid = event.windowID else { return }
            activeWindowCategory.removeValue(forKey: wid)
            blur.dismiss(forWindowID: wid)
        }
    }
}
