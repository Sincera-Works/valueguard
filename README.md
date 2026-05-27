# ValueGuard

On-device content filtering for macOS. Your screen never leaves your machine.

ValueGuard is a local daemon that samples the screen, runs each frame through
a SigLIP-2 vision encoder on the Apple Neural Engine, and compares the
embedding against a precomputed policy of what you have decided to filter.
The policy itself is compiled from a plain-English values statement by an LLM
running in the cloud — but the cloud only ever sees the values statement, never
a single pixel of your screen.

## Why this exists

Existing content-filtering products fall into two camps:

- **Domain blockers** (Covenant Eyes, Net Nanny, Canopy on macOS) — work at the
  hostname or browser layer. They cannot see what is actually on your screen,
  only which URL produced it. They lose on every novel domain, every embedded
  iframe, every screenshare.
- **Cloud accountability** (Covenant Eyes, Truple) — upload screenshots to a
  vendor server for classification, then notify a partner. Effective, but the
  privacy and compliance story is rough. Not a thing you can put on a
  corporate laptop.

ValueGuard takes the third path: classify pixels on-device, in real time,
using a frozen SigLIP-2 vision encoder. Nothing leaves the machine at runtime.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  SETUP — runs once per policy update             │
│                                                  │
│  values.md ──► Sonnet API ──► policy.json        │
│                                  │                │
│                                  ▼                │
│                             SigLIP-2 text encoder │
│                             (one-time, Python)    │
│                                  │                │
│                                  ▼                │
│                             policy.bin            │
│  ──────────────────────────────────────────       │
│  Sonnet sees only the values statement.           │
│  Never receives a pixel of the user's screen.     │
└─────────────────────────────────────────────────┘
                       │
                       ▼  (one-time download, or MDM push)
┌─────────────────────────────────────────────────┐
│  RUNTIME DAEMON — always on, fully air-gappable  │
│                                                  │
│  ScreenCaptureKit ─► SigLIP-2 (CoreML / ANE)     │
│                     ─► cosine sim vs policy.bin  │
│                     ─► action (log / blur / kill)│
│                                                  │
│  Network: optional. Off by default.              │
│  Audit log: local-only, encrypted at rest.       │
└─────────────────────────────────────────────────┘
```

## Repository layout

```
valueguard/
├── policy-compiler/    TypeScript — values.md → policy.json via Sonnet API
├── model-conversion/   Python — HuggingFace SigLIP-2 → CoreML, caption embedding
├── daemon/             Swift — macOS daemon, ScreenCaptureKit + CoreML
└── docs/               Architecture, threat model, build instructions
```

## Status

Early. The compiler runs and emits valid `policy.json`. Model conversion script
runs but produces large artifacts that are not yet integrated. The daemon is
scaffolded but not wired end-to-end.

See `docs/BUILD.md` for the phased build plan.

## Quick start

```bash
# 1. Compile a policy from a values statement
cd policy-compiler
npm install
export ANTHROPIC_API_KEY=sk-ant-...
npx tsx src/compile.ts examples/personal-values.md personal

# 2. Convert SigLIP-2 to CoreML (runs once, ~10 minutes, requires Apple Silicon)
cd ../model-conversion
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python convert_siglip2.py

# 3. Embed the compiled policy captions into policy.bin
python embed_captions.py ../policy-compiler/examples/personal-values.policy.json

# 4. Build and run the daemon (work in progress)
cd ../daemon
swift build
swift run valueguard --policy ../policy-compiler/examples/personal-values.policy.bin
```

## Design constraints

- **No frame data leaves the device.** Ever. Not for inference, not for
  audit, not for telemetry.
- **Network is opt-in.** The daemon must work air-gapped. Network is used
  only for the optional partner-notification bridge.
- **Calibration before action.** v1 ships with `action: "log"` for every
  category. Blur and kill are unlocked once you have a week of logged flags
  and a measured false-positive rate.
- **No backwards-compatibility shims.** This is greenfield.

## License

MIT. See [LICENSE](LICENSE).
