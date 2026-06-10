# ValueGuard on Linux

Design + status for the Linux daemon (issue #34, P1a). The product property
is unchanged: **pixels never leave the device.** This is the companion to
`docs/WINDOWS.md` — the preprocess contract, scoring semantics, inference
tiers, and audit-log contract pinned there apply verbatim; this page covers
only what Linux adds or narrows.

Status: **P1a implemented in `daemon-py/`** — a cross-platform Python daemon
whose Linux build is the stepping stone to Windows (same code runs on
Windows via mss/GDI + onnxruntime; only paths and autostart differ).

## Component mapping

| Concern | macOS | Linux |
|---|---|---|
| Capture | ScreenCaptureKit @ 1 Hz | mss (XGetImage/XShm) @ 1 Hz, X11 |
| Inference | CoreML, ANE | onnxruntime, `[CPU]` default; CUDA opt-in |
| Daemon | Swift | Python 3.12, `daemon-py/` |
| Autostart | LaunchAgent | per-user systemd unit (`daemon-py/systemd/`) |
| Data dir | `~/Library/Application Support/ValueGuard/` | `$XDG_DATA_HOME/ValueGuard/` (default `~/.local/share/ValueGuard/`) |

## The v0.1 narrowing: per-monitor, not per-window

The macOS daemon captures and scores individual *windows*, keys hysteresis
per window, and records `window_id`/`app` in the audit log. Linux P1a is
deliberately **per-monitor full-frame**: one capture + one hysteresis state
per monitor, and `window_id` in audit records carries the **monitor index**.
This is a temporary narrowing, not a design position — X11 per-window
attribution (EWMH `_NET_ACTIVE_WINDOW` for the `app` field first, true
per-window capture later) is a tracked follow-up. Windows inherits the same
narrowing initially.

## Wayland

Out of scope for P1a. The first target machine (omen) runs X11 only — no
compositor, pipewire, or xdg-desktop-portal active. Wayland capture needs
the ScreenCast portal + PipeWire and a consent flow with a restore token;
that's its own follow-up issue when a Wayland target exists.

## Performance (measured on omen, i7-10700)

fp32, onnxruntime 1.26 CPU EP: **p50 = 120.1 ms, p95 = 120.4 ms** per
inference — 12% of the 1 Hz budget before the hash gate, which skips
inference entirely on static frames (hamming < 4 on the 9×8 dHash, exactly
the macOS gate). CUDA on the RTX 2060 SUPER is an optional perf tier, never
a correctness dependency.

Smoke-measured end-to-end (Xvfb 1920×1080, real calibrated policy, hash
gate off = worst case): tick p50 = 103 ms, p95 = 140 ms over 65 frames; with
the gate on, a static screen costs 1 inference per content change and ticks
drop to ~29 ms. **Max RSS ≈ 498 MB with the fp32 model** — well above the
macOS daemon's <200 MB INT8 budget; switching the deployment to the fp16
artifact roughly halves it, and the INT8 calibration pass (P2) is the real
fix. Tracked as a P2 acceptance criterion, not a P1a blocker.

## Verification gates (P1a)

1. Unit suite (`daemon-py/tests/`) — VGP1 round-trip + error taxonomy,
   raw-cosine firing (boundary `pos == threshold` fires), hysteresis
   boundary semantics, audit field names/order, hash-gate cache behavior,
   per-monitor isolation, preprocess contract.
2. Golden-vector test — image → daemon preprocess → ONNX vs a
   PyTorch-recorded reference embedding, cosine ≥ 0.999.
3. Live smoke on omen — dedicated Xvfb (not a display owned by another
   service), real `policy.bin`: `--once`, then a **sustained ≥ 60-frame run
   with p95 end-to-end frame time < 1000 ms**, monotonic audit timestamps,
   stable RSS.

## What Linux P1a deliberately does not do

Blur/kill actions (log-only v0.1, enforced in code), Wayland, per-window
attribution, the `vg` marketplace CLI, tamper-evident audit logging (#37 —
the NDJSON format here matches macOS exactly so #37 lands once for both).
