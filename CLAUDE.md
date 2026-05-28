# Project: ValueGuard — on-device content filtering for macOS

A focused working context for the ValueGuard daemon and Mac app. Open via
`gproject valueguard` from any Ghostty pane (or `⌘⇧V` for new-split-with-context).

## What this is

ValueGuard samples the screen at 1 Hz, runs each frame through a SigLIP-2
vision encoder on the Apple Neural Engine, and compares the embedding against
a precomputed policy of what the user has decided to filter. Frame data
never leaves the device. The policy itself is compiled from a plain-English
values statement — the cloud only ever sees that statement, never a single
pixel.

## Current state

- **Daemon**: built. `daemon/dist/valueguard.app` is a signed bundle; runs
  via `scripts/start-screen.sh` with a `VALUEGUARD_POLICY` env var.
- **Policy compiler**: TypeScript CLI in `policy-compiler/` that calls Sonnet
  via the Anthropic SDK to turn `values.md` → `policy.json`.
- **Caption embedder**: Python in `model-conversion/` that loads SigLIP-2 text
  tower (CoreML or PyTorch fallback) and packs `policy.json` → `policy.bin`.
- **Mac app**: in flight. Lives under `app/` once scaffolded. Goal: replace
  the entire shell-script onboarding with a SwiftUI menubar app that walks
  the user through values → paste-bridge to Claude.ai → policy.bin → first
  TCC prompt. See the plan log entry for sequencing.

## Load-bearing docs (read on demand)

- `README.md` — project overview, architecture diagram, threat model summary.
- `docs/ARCHITECTURE.md` — full system architecture.
- `docs/BUILD.md` — phased build plan (Phase 5 is calibration).
- `docs/INSTALL.md` — current install path (standalone or wired into
  `start-filtering.sh`).
- `docs/THREAT-MODEL.md` — what we defend against and what we don't.
- `daemon/README.md` — daemon-specific build + run instructions.

## Key paths

- **Policy binary lives at runtime**: `~/Library/Application Support/ValueGuard/policy.bin`
- **Audit log**: `~/Library/Application Support/ValueGuard/audit.log`
- **CoreML model cache**: `~/Library/Caches/ValueGuard/SigLIP2Vision.mlmodelc`
- **LaunchAgent (if installed)**: `~/Library/LaunchAgents/works.sincera.valueguard.plist`
- **Existing example policies**: `policy-compiler/examples/personal-values{,.calibrated}.policy.{json,bin}`

## Bundle identifiers

- **Daemon**: `works.sincera.valueguard`
- **App (in-flight)**: `works.sincera.valueguard.app`

Sibling bundle IDs so TCC entries stay separate — when the app starts owning
the daemon lifecycle, Screen Recording gets granted to the app's identity.

## Working agreement with Claude

- Don't duplicate doc content here. This file is a context pointer.
- Log state-changing actions (build changes, signing identity swaps, new
  policy revisions, model upgrades) in `log.md` in this folder.
- The daemon source under `daemon/Sources/` is the canonical Swift code —
  the new app target should import it as an SPM dependency, not fork it.
- Treat the `VGP1` binary format defined in
  `model-conversion/embed_captions.py:1-23` as the contract between the
  policy compiler and the daemon. Any Swift port must match byte-for-byte.
