import Foundation
import AppKit

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
    private let sensitive: SensitiveContextMonitor
    private var lastFlagScore: [String: Float] = [:]
    private var activeWindowCategory: [UInt32: String] = [:]
    /// What *should* be blurred right now (category + app per offending
    /// window), tracked on every `.activated`/`.cleared` transition REGARDLESS
    /// of suppression. This is the source of truth for re-showing blurs when a
    /// sensitive context or emergency snooze ends — the daemon won't re-emit a
    /// fresh `.activated` for content that stayed continuously on screen.
    private var pendingBlur: [UInt32: (category: String, app: String?)] = [:]

    /// How long an emergency dismiss keeps actions snoozed, so a blur doesn't
    /// pop straight back while the offending content is still on screen.
    private static let emergencySnooze: TimeInterval = 120

    /// True while a sensitive context (call / screen share / slideshow) is
    /// active — set from `SensitiveContextMonitor`.
    private var sensitivePaused = false
    /// Set by `emergencyDismiss()`; while in the future, actions are snoozed.
    private var snoozeUntil: Date?
    /// Fires when the emergency snooze elapses, so blurs auto-resume.
    private var snoozeTimer: Timer?
    /// Idempotency guard for `start()`.
    private var started = false

    /// When suppressed, only logging continues — no blur/notify/block fires,
    /// and any visible blur has already been pulled down.
    private var actionsSuppressed: Bool {
        if sensitivePaused { return true }
        if let snoozeUntil, snoozeUntil > Date() { return true }
        return false
    }

    init(tailer: AuditLogTailer, overrides: ActionOverrides, autoPauseEnabled: @escaping () -> Bool) {
        self.tailer = tailer
        self.overrides = overrides
        self.sensitive = SensitiveContextMonitor(enabled: autoPauseEnabled)
    }

    /// Emergency panic dismiss: clear every blur immediately and snooze
    /// further actions for a short window. Wired to a system-wide hotkey.
    func emergencyDismiss() {
        blur.dismissAll()
        // Overlays are gone; keep `pendingBlur` so they can be re-shown when
        // the snooze elapses.
        activeWindowCategory.removeAll()
        snoozeUntil = Date().addingTimeInterval(Self.emergencySnooze)
        snoozeTimer?.invalidate()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: Self.emergencySnooze, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.snoozeExpired() }
        }
        NSLog("ValueGuard: emergency dismiss — snoozing actions for \(Int(Self.emergencySnooze))s")
    }

    private func snoozeExpired() {
        snoozeTimer = nil
        snoozeUntil = nil
        resumeActions()
    }

    /// Re-show blurs for every window still considered offending. Called when a
    /// sensitive context ends or the emergency snooze elapses, because the
    /// daemon does not re-emit `.activated` for content that never cleared.
    private func resumeActions() {
        guard !actionsSuppressed else { return }
        for (wid, info) in pendingBlur {
            activeWindowCategory[wid] = info.category
            blur.show(forWindowID: wid, category: info.category, app: info.app)
        }
    }

    func start() {
        guard !started else { return }
        started = true
        sensitive.onChange = { [weak self] isSensitive in
            guard let self else { return }
            self.sensitivePaused = isSensitive
            if isSensitive {
                // Pull every blur off the screen for the duration of the
                // call / share so it isn't broadcast to other participants.
                self.blur.dismissAll()
                self.activeWindowCategory.removeAll()
                NSLog("ValueGuard: sensitive context detected — pausing actions")
            } else {
                NSLog("ValueGuard: sensitive context ended — resuming actions")
                self.resumeActions()
            }
        }
        sensitive.start()
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
        sensitive.stop()
        sensitive.onChange = nil
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        snoozeUntil = nil
        pendingBlur.removeAll()
        activeWindowCategory.removeAll()
        blur.dismissAll()
        started = false
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
                if actionsSuppressed { return }
                let score = lastFlagScore[category] ?? 0
                Task { await notify.notify(category: category, app: event.app, score: score) }
            case .block:
                if actionsSuppressed { return }
                Task { await BlockAction.run(app: event.app, category: category) }
            case .blur:
                guard let wid = event.windowID else { return }
                // Always record what should be blurred so it can be re-shown
                // when suppression lifts (see `resumeActions`).
                pendingBlur[wid] = (category, event.app)
                // Suppress the overlay during a sensitive context / snooze. The
                // live `isSensitiveNow()` re-check closes the gap between the
                // monitor's 2 s poll and a just-started call/slideshow, so a
                // blur can't flash onto a screen-share before the poll catches up.
                if actionsSuppressed || sensitive.isSensitiveNow() { return }
                activeWindowCategory[wid] = category
                blur.show(forWindowID: wid, category: category, app: event.app)
            }
        case .cleared, .disappeared:
            guard let wid = event.windowID else { return }
            pendingBlur.removeValue(forKey: wid)
            activeWindowCategory.removeValue(forKey: wid)
            blur.dismiss(forWindowID: wid)
        }
    }
}
