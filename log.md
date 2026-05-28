# ValueGuard change log

State-changing actions (build changes, signing swaps, policy revisions, model
upgrades). Newest first.

## 2026-05-28 — Phase 6 action layer: window level, emergency dismiss, auto-pause

Started Phase 6 (action layer). Three changes, app + daemon both build clean.

- **Blur window level → `.screenSaver`.** Was `.statusBar` (app
  `BlurOverlayManager`) and `maximumWindow+1` (daemon `ValueGuardOverlay`).
  Now both sit at `.screenSaver` per the Phase 6 spec — above the menu bar
  and status items, still above `.normal` so click-raises don't flicker.
- **Emergency dismiss hotkey (⌃⌥⌘D).** New `app/Sources/Actions/EmergencyHotkey.swift`
  using Carbon `RegisterEventHotKey` (fires system-wide, no Accessibility
  permission — required since the offending app, not ValueGuard, is frontmost
  when a blur is up). Tears down all blurs and snoozes actions for 120 s via
  `ActionDispatcher.emergencyDismiss()`. Also surfaced as a "Dismiss blur now"
  menu item for discoverability.
- **Auto-pause in sensitive contexts.** New
  `app/Sources/Actions/SensitiveContextMonitor.swift`. Heuristic: frontmost
  app is a known conferencing/recording bundle ID (Zoom, Teams classic+new,
  Webex, Meet desktop, OBS, QuickTime), OR Keynote/PowerPoint owns a
  full-display window (slideshow). When sensitive: dismiss all blurs + suppress
  blur/notify/block (logging continues). Wired through `ActionDispatcher`,
  gated by new `AppSettings.autoPauseInSensitiveContexts` (default on, General
  tab toggle). Known gap: browser-tab calls (Meet/Teams in a tab) are not
  detected — bundle ID too broad.

**Adversarial pre-PR review (multi-agent workflow): 8 confirmed findings, all
fixed before PR.**

- *(major)* Post-resume re-show gap: a blur torn down for a call/share/snooze
  never came back if the offending content stayed continuously on screen (the
  daemon emits no fresh `.activated` while hysteresis stays active). Fixed:
  `ActionDispatcher` now tracks `pendingBlur` on every transition regardless of
  suppression, and `resumeActions()` re-shows them when a sensitive context
  ends or the snooze elapses.
- *(major)* Heuristic only checked the *frontmost* app, so a backgrounded
  conferencing app during a real screen-share (user clicked into the shared
  window) leaked the blur onto the share. Fixed: `conferencingActive()` now
  also counts a known app that owns a visible normal-layer window; a menubar-
  only idle app still doesn't count (no all-day over-suppression).
- *(minor)* Emergency snooze never auto-resumed → fixed with a one-shot snooze
  `Timer` calling `resumeActions()`.
- *(minor)* Up-to-2 s poll latency could let a blur fire before suppression →
  fixed with a live `isSensitiveNow()` re-check on the blur path.
- *(minor)* `RegisterEventHotKey`/`InstallEventHandler` return values ignored →
  now checked, logged, and the handler is torn down on failure.
- *(nit)* nonisolated `deinit` touched Carbon APIs off-main → deinit removed
  (app-lifetime object; OS reclaims the hotkey on exit).
- *(nit)* `start()` idempotency guard added.
- *(nit)* Slideshow doc comment corrected (full-screen *editing* also trips it;
  intentional, on the safe side).

(4 further findings were reviewed and rejected as unreachable in current code.)

Not yet done for Phase 6: blur-fire latency instrumentation (<100 ms
acceptance). Behavior verification still pending — needs a real call/share and
flagged content to exercise the new paths end-to-end. Note Phase 6 is
nominally gated on Phase 5 (log-only deployment) producing stable numbers;
proceeded at user request.
