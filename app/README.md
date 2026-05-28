# ValueGuard.app

A SwiftUI menubar app that wraps the ValueGuard daemon with onboarding, a
paste-bridge policy compiler, Bayesian calibration, and an occlusion-aware
blur intervention layer.

## Requirements

- macOS 14.0+
- Xcode 26+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the `ValueGuard.xcodeproj` is generated from `project.yml` and is not checked in
- The SigLIP-2 vision encoder at `../daemon/Resources/SigLIP2Vision.mlpackage` (produced by `model-conversion/convert_siglip2.py` in this repo; gitignored at 89 MB)
- The SigLIP-2 tokenizer files in `Resources/` (33 MB total; setup script fetches these from your local HuggingFace cache)

## Setup

```sh
brew install xcodegen
./scripts/setup-resources.sh   # copies tokenizer files from ~/.cache/huggingface
xcodegen generate
xcodebuild -scheme ValueGuardApp -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
open build/DerivedData/Build/Products/Debug/ValueGuard.app
```

## Architecture

The app sits on top of the daemon and adds:

```
Sources/
├── ValueGuardApp.swift         @main, LSUIElement wiring, AppDelegate
├── Menubar/                    NSStatusItem shield states + menu
├── Onboarding/                 Welcome → values → copy-prompt → paste-JSON → embed → permission
├── Embedding/                  swift-transformers tokenizer + CoreML text encoder + VGP1 binary writer
├── ModelDownload/              URLSession + SHA-256 + tar extraction for the 539 MB text encoder
├── Calibration/                Wikimedia fetch + Bayesian KDE + conformal prediction + policy.bin patch
├── DaemonControl/              In-process ValueGuardDaemon wrapper (logOnly always true; actions live in the app)
├── Actions/                    AuditLogTailer → ActionDispatcher → notify / blur / block
├── Settings/                   SwiftUI Settings scene: General, Policy, Actions, Calibration, About
└── Support/                    AppSupport paths helper
```

The daemon stays in `logOnly=true` permanently — it produces audit-log
entries and that's it. The app owns the action policy via `Actions/`, which
means changing what happens when a category fires (log → notify → blur →
block) doesn't require re-embedding `policy.bin`.

The blur intervention uses a `CAShapeLayer` mask computed from
`CGWindowListCopyWindowInfo` z-order, so the blur covers only the still-
visible region of the source window — no flicker on clicks (blur is at
`.statusBar`, above all `.normal` windows so click-raises within `.normal`
can't lift the source above it), no over-painting of unrelated foreground
windows (mask subtracts each occluder above source).
