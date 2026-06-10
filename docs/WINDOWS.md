# ValueGuard on Windows

Design for the Windows port (issue #34). The product property is unchanged:
**pixels never leave the device.** This document is the canonical spec for
everything platform-specific; the VGP1 policy format and the policy-compiler
flow are shared with macOS and documented elsewhere.

Status: **P0 (model portability) merged; P1b (the cross-platform `daemon-py`
running on Windows) verified 2026-06-09** on a Windows 11 Enterprise Eval VM
(KVM on omen, 6 vCPU): all 35 unit tests + the golden-vector test pass, and
the live smoke in a real interactive desktop session (GDI capture) measured
65 frames gate-off at tick p50 = 219 ms / p95 = 641 ms (< 1000 ms gate) and
gate-on static-screen at 1 inference per 10 ticks — the daemon ran
**unmodified** from the Linux-verified code. The native C#/WGC daemon below
remains the unbuilt optimization path; P2 (packaging/calibration/INT8) is
not started.

Windows deployment facts learned in P1b:

- **onnxruntime needs the VC++ 2015–2022 redistributable** — fresh Windows
  lacks it and the import fails with `DLL load failed` (install
  `vc_redist.x64.exe` from `aka.ms/vs/17/release/vc_redist.x64.exe`).
- GDI capture is per-session: anything launched from an SSH session sees no
  desktop. Run the daemon in the interactive session — for remote testing,
  a scheduled task created with `/it` and `schtasks /run`; for real use, the
  HKCU `Run` autostart already specified below.
- `schtasks /tr` caps the command at 261 chars — wrap the daemon invocation
  in a `.cmd` file.

## Component mapping

| Concern | macOS | Windows |
|---|---|---|
| Capture | ScreenCaptureKit @ 1 Hz | Windows.Graphics.Capture (WGC) @ 1 Hz |
| Inference | CoreML, ANE, INT8 | ONNX Runtime, providers `[DirectML, CPU]` |
| Model artifact | `SigLIP2Vision.mlpackage` | `SigLIP2Vision.fp32.onnx` / `.fp16.onnx` (`model-conversion/export_onnx.py`) |
| Daemon | Swift (SPM) | C# / .NET 8, `net8.0-windows10.0.19041.0` |
| Policy binary | VGP1 `policy.bin` (mmap) | identical bytes, `MemoryMappedFile` |
| Audit log | append-only NDJSON | identical format (see below) |
| Autostart | LaunchAgent plist | HKCU `Run` key |
| Data dir | `~/Library/Application Support/ValueGuard/` | `%LOCALAPPDATA%\ValueGuard\` |
| Model cache | `~/Library/Caches/ValueGuard/` | `%LOCALAPPDATA%\ValueGuard\cache\` (native daemon only — daemon-py loads the .onnx directly from `models\`, no compile cache) |

Policy compilation needs nothing new: the paste-bridge app path is
model-agnostic, and `embed_captions.py` already has a PyTorch fallback that
runs on Windows — no ONNX text tower is required.

## The preprocess contract (pinned)

One contract, three places that must agree: `export_onnx.py`,
`test_onnx_parity.py`, and the Windows frame pipeline.

- **Tensor:** float32, NCHW, `(1, 3, 256, 256)`, **RGB** channel order.
- **Normalization:** `x / 127.5 − 1.0` per channel (pixel `[0,255]` →
  `[−1,1]`). This is exactly the `scale=1/127.5, bias=−1` CoreML bakes into
  its ImageType (`convert_siglip2.py`). ONNX has no image-input abstraction,
  so on Windows this is an explicit pre-step — **it is not in the graph.**
- **Geometry:** scale the captured frame directly to 256×256, no center-crop.
  This mirrors the macOS daemon hot path (`ScreenCapture.swift` rasterizes the
  stream straight to 256×256). The macOS *calibration* path center-crops
  instead — that divergence is pre-existing on macOS, tracked separately, and
  the Windows daemon must follow the hot path, not the calibration path.
- WGC frames arrive BGRA: swizzle B↔R during the float conversion pass.

## Scoring (pinned)

Port `Policy.evaluate` (`daemon/Sources/ValueGuard/Policy.swift`) exactly:
raw cosine — `dot(positiveEmbedding, embedding) >= threshold` fires the
category. The negative vector is computed and logged but does not gate
firing. **No softmax**: earlier designs used
`softmax([pos·img, neg·img])` and some docs still say so; the daemon dropped
it for calibration reasons, and existing `policy.bin` thresholds are
calibrated against raw cosine. Hysteresis semantics port from
`Hysteresis.swift` unchanged.

VGP1 is little-endian and must match byte-for-byte
(`model-conversion/embed_captions.py` is the format's definition).

## Inference tiers

CPU EP is the **correctness baseline** — full operator coverage, and the only
EP the parity gate runs against. DirectML is a **performance tier, never a
correctness dependency**: sessions are created with provider priority
`[DirectML, CPU]`, so unsupported ops partition to CPU automatically.

| Tier | Artifact | EP | When |
|---|---|---|---|
| Baseline | fp32 | CPU | always works; gates parity (≥ 0.999 vs PyTorch) |
| Default | fp16 | DirectML → CPU | any DX12 GPU (incl. integrated); parity ≥ 0.995 |
| Calibrated | INT8 | DirectML → CPU | P2 only — quantized with onnxruntime on real hardware during calibration, mirroring the macOS calibration-before-action rule |

At 1 Hz, even CPU-only fp32 (~tens of ms/frame on a modern CPU) leaves huge
headroom; DirectML is about power draw, not feasibility. NPU (e.g. QNN EP) is
out of scope until a target machine exists.

## Capture (P1)

- **API floor: Windows 10 2004** (WGC completeness; `IsCursorCaptureEnabled`).
- The daemon is unpackaged; `GraphicsCaptureItem` comes from
  `IGraphicsCaptureItemInterop::CreateForMonitor` — no picker UI for
  whole-monitor capture.
- Frame pump: `Direct3D11CaptureFramePool` (free-threaded), but **sampled** —
  copy + downscale one frame per second, drop the rest. Downscale on GPU
  (D3D11 `CopySubresourceRegion` + a 256×256 staging texture) before the CPU
  readback so we never read back full frames.
- Consent/border: Win11 draws a capture border (where the OS supports it,
  `GraphicsCaptureSession.IsBorderRequired` can request removal subject to
  consent). The border is cosmetic; ValueGuard's threat model is the user
  themselves, who wants it running — a visible indicator is acceptable, even
  desirable. Multi-monitor: one session per monitor, round-robin within the
  1 Hz budget.

## Daemon process model (P1)

- **Per-user autostart process, not a Windows Service.** Session-0 isolation
  means a service cannot see the interactive desktop; capture must run in the
  user's session. Autostart via HKCU
  `Software\Microsoft\Windows\CurrentVersion\Run`.
- Single instance via a named mutex (`works.sincera.valueguard`).
- Audit log: append-only NDJSON at `%LOCALAPPDATA%\ValueGuard\audit.log`,
  same record shape as macOS (`AuditLog.swift`). The macOS log is plain
  NDJSON today — Windows matches that, one contract on both platforms.
  Tamper-evident chaining / at-rest encryption is a **cross-platform
  follow-up**, not a Windows-only invention.
- Actions: v0.1 ships `action: "log"` only, exactly like macOS. Blur/kill
  stay locked until calibration (P2) measures a false-positive rate.
- Air-gappable: no network calls anywhere in the daemon. Network remains
  opt-in and absent from P1 entirely.

## Phases & verification

| Phase | Deliverable | Verified by | Where |
|---|---|---|---|
| **P0** ✅ | `export_onnx.py`, `test_onnx_parity.py`, this doc | parity gate: fp32 cosine ≥ 0.999 vs PyTorch, fp16 ≥ 0.995, norms ≈ 1 | any Mac/Linux (CPU EP) |
| **P1** | `windows/` C# daemon: VGP1 loader, WGC 1 Hz source, preprocess, ORT session, `Policy.evaluate` + hysteresis port, audit log | unit tests on the VGP1 loader + scorer; **golden-vector test** (checked-in test image + reference embedding committed from P0); live smoke on real Windows hardware | Windows machine |
| **P2** | installer, autostart, calibration, INT8 | ≥ a week of logged flags → measured FP rate before any action unlock | Windows machine |

P1 does not merge on compile evidence alone — it needs the runtime smoke on
actual hardware. Out of scope for the port: the `vg` marketplace CLI on
Windows, blur/kill overlays, the partner-notification bridge.

## Risks

- **Pooler export fidelity** — SigLIP-2's attention-pooling head is the main
  graph-parity risk; that is precisely what the P0 gate measures.
- **Preprocess drift** — the golden-vector test exists because graph parity
  alone can't catch a BGRA swizzle or rounding mistake in the C# pipeline.
- **fp16 overflow** — converted with `keep_io_types=True`; if the fp16 gate
  ever fails, ship fp32 (1 Hz makes fp32-on-CPU acceptable) and investigate.
- **WGC consent changes** — Microsoft tightens capture consent over time;
  the P1 deployment smoke must re-verify on current Win11 before release.
