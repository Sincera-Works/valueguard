# daemon

The always-on macOS process. Samples the screen at 1 Hz, runs each frame
through SigLIP-2 on the Apple Neural Engine, scores against the loaded
policy, and acts.

## Status: scaffold

The package builds and runs end-to-end with a **mock classifier** that
emits random embeddings — useful for proving the capture loop, policy
loader, scoring math, and audit log all work together. Wire in the real
CoreML model by copying it into `Resources/`.

## Build

```bash
cd daemon
swift build
```

The first build downloads no dependencies — pure Foundation + CoreML +
ScreenCaptureKit.

## Run (with mock classifier)

```bash
# Compile a policy first (see ../policy-compiler/README.md)
# Then embed the captions (see ../model-conversion/README.md)
# Then:
swift run valueguard \
  --policy ../policy-compiler/examples/personal-values.policy.bin \
  --log-only
```

You'll be prompted for Screen Recording permission. Grant it, re-run.

## Run (with real classifier)

Copy or symlink the converted model into `Resources/`:

```bash
mkdir -p Resources
ln -s ../../model-conversion/output/SigLIP2Vision.mlpackage Resources/
```

`Classifier.swift` searches several paths — `Resources/SigLIP2Vision.mlpackage`
and `../model-conversion/output/SigLIP2Vision.mlpackage` are both tried
automatically.

## File layout

```
Sources/
├── ValueGuard/              library
│   ├── ValueGuardDaemon.swift    main capture/inference/action loop
│   ├── Policy.swift              binary policy loader + scoring math
│   ├── ScreenCapture.swift       ScreenCaptureKit wrapper
│   ├── Classifier.swift          CoreML wrapper (with mock fallback)
│   ├── AuditLog.swift            append-only JSON-line log
│   └── BlurOverlay.swift         full-screen blur (stub — disabled in v0.1)
└── ValueGuardCLI/           executable
    └── main.swift                argument parsing, daemon kickoff
```

## What works today

- Loads a compiled `policy.bin` via memory-mapped I/O.
- Requests Screen Recording permission.
- Captures a 256×256 BGRA frame from the main display via ScreenCaptureKit.
- Runs the frame through the classifier (real CoreML if available, random
  embeddings otherwise).
- Scores against every category using softmax-over-pair.
- Writes JSON-line audit events to
  `~/Library/Application Support/ValueGuard/audit.log`.

## What doesn't work yet

- **BlurOverlay is a stub.** Real overlay needs `NSApplication.shared.run()`
  on the main thread and a borderless `NSWindow` at `.screenSaver` level.
  Not wired in until the false-positive rate is measured (see
  `docs/BUILD.md`).
- **Block action is a stub.** No tab-close / app-kill behavior yet.
- **No watchdog.** A crash with the blur active would leave the screen
  permanently covered. Mitigation: blur isn't enabled.
- **No multi-monitor support.** Captures the main display only.
- **No tamper resistance.** Runs as a regular user process; trivial to kill.
  The corporate-mode deployment plan is to promote to `launchd` daemon with
  a config profile.

## Threat model

See `../docs/THREAT-MODEL.md`.
