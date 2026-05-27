# Phased build plan

The big risk is shipping a content filter before you trust its
false-positive rate. The plan below front-loads the cheap, observable
parts and gates the disruptive features behind a measured calibration
phase.

## Phase 1 — Policy compiler (✅ shipped in v0.1)

Goal: compile a values statement into a `policy.json` with valid
contrastive caption pairs.

Status: works. See `policy-compiler/`.

Acceptance: `npx tsx src/compile.ts examples/personal-values.md` produces
a `personal-values.policy.json` with 3+ categories, 8–12 captions per
side, valid thresholds.

## Phase 2 — Model conversion (✅ scaffolded in v0.1)

Goal: convert SigLIP-2 to CoreML and embed compiled policies into the
binary format the daemon expects.

Status: scripts work; large artifacts not committed.

Acceptance: `python convert_siglip2.py` on an Apple Silicon Mac produces
`output/SigLIP2Vision.mlpackage` (~85 MB) and `output/SigLIP2Text.mlpackage`
(~110 MB). `python embed_captions.py personal-values.policy.json` produces
`personal-values.policy.bin`.

## Phase 3 — Daemon with mock classifier (✅ scaffolded in v0.1)

Goal: prove the capture → embed → score → log loop runs end-to-end
without the real model.

Status: works with random embeddings.

Acceptance: `swift run valueguard --policy ... --log-only` requests
permission, captures frames, scores against the policy, writes audit
log entries. Stable for 24 hours without leaks.

## Phase 4 — Real CoreML inference (next)

Goal: wire in the real SigLIP-2 vision tower and validate accuracy.

Tasks:
- Copy `SigLIP2Vision.mlpackage` into `daemon/Resources/`
- Verify `Classifier.swift` loads it and produces 768-dim outputs
- Build a small Python eval script that scores ~50 known-positive and
  ~50 known-negative screenshots, compare against expected categories
- Tune thresholds in the policy until the eval is acceptable

Acceptance: on a hand-curated 100-image eval set, FP rate < 5% and FN
rate < 15% per category.

## Phase 5 — Log-only deployment (next)

Goal: run the daemon on the author's own machine for a week, gathering
real-world false positives and false negatives.

Tasks:
- Run continuously in `--log-only` mode
- Daily: review the audit log, label each flag as TP/FP, sample for FNs
- After 7 days: compute per-category FP rate, threshold tuning

Acceptance: FP rate stable below 2% per category over a 24h window.

## Phase 6 — Action layer (deferred)

Only attempt after Phase 5 produces stable numbers.

Tasks:
- Wire `BlurOverlay` to a real `NSWindow` at `.screenSaver` level
- Add multi-monitor support
- Add Zoom / Keynote / screensharing detection (auto-pause filtering)
- Add an emergency keyboard-shortcut dismiss
- Add a menu-bar status indicator

Acceptance: blur fires within 100 ms of a high-confidence flag, dismisses
on next clean frame, never fires during detected sensitive contexts.

## Phase 7 — Accountability bridge (deferred, Mode A only)

Tasks:
- Cloudflare Worker on a domain the author owns
- Daemon POSTs `{ts, category, score, blurred_thumb_b64}` to the worker
- Worker forwards to a configured Twilio or email destination
- Heartbeat loop — partner gets pinged if heartbeats stop for >10 min

Acceptance: blurred thumbnails arrive at the partner within 30s of the
flag. Daemon kill produces a "heartbeat lost" alert within 15 min.

## Phase 8 — Corporate packaging (deferred, Mode B/C only)

Tasks:
- Code-sign and notarize the daemon with Developer ID
- Build a signed `.pkg` with a postinstall registering a LaunchDaemon
- Build a `.mobileconfig` config profile for MDM that pre-grants
  Screen Recording and points the daemon at a signed `policy.bin` URL
- Encrypted audit log (SQLCipher) with admin-readable key option

Acceptance: deployable via Jamf to a test fleet of 5 machines, runs
under launchd, survives reboots and user logouts, audit log readable
only with the configured key.

## What's deliberately NOT on this list

- A fine-tuned MLP head on logged flags. Phase 5 is the data-collection
  step for this; Phase 6 is the moment it becomes worth training. Until
  then, the frozen SigLIP-2 zero-shot is enough.
- Cross-platform support. macOS-only is a feature, not a bug —
  ScreenCaptureKit and CoreML are why this works at sub-watt.
- A UI for editing policies. Editing the `values.md` and recompiling is
  the UI for now. A real settings pane comes later.
- An iOS version. The Screen Time API does not expose framebuffer
  access. This product fundamentally can't exist on iOS.
