# Architecture

## One-line summary

A local daemon samples the screen, runs each frame through SigLIP-2 on the
Apple Neural Engine, and compares the resulting embedding against a
precomputed policy of contrastive caption pairs. The policy itself is
authored once, in plain English, by an LLM running in the cloud — but the
cloud only ever sees the values statement, never a pixel of the user's
screen.

## The two halves

The whole system splits cleanly across a privacy boundary:

```
┌─────────────────────────── CLOUD ────────────────────────────┐
│                                                              │
│  values statement                                           │
│       │                                                      │
│       ▼                                                      │
│  an LLM ──► policy.json                                      │
│  (sees values only,       (categories,                       │
│   never any pixels)        contrastive captions,             │
│                            thresholds, actions)              │
│                                                              │
└──────────────────────────────────────────────────────────────┘
                       │
                       │  one-time download
                       │  (or MDM push)
                       ▼
┌─────────────────────────── LOCAL ────────────────────────────┐
│                                                              │
│  SigLIP-2 text encoder ──► policy.bin                        │
│  (runs once, locally,      (N categories ×                   │
│   embeds captions          2 × 768-dim                       │
│   into vectors)             float32 vectors)                 │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Daemon (always on, fully air-gappable)              │   │
│  │                                                       │   │
│  │   ScreenCaptureKit @ 1 Hz                             │   │
│  │        │                                              │   │
│  │        ▼                                              │   │
│  │   256×256 BGRA buffer                                 │   │
│  │        │                                              │   │
│  │        ▼                                              │   │
│  │   SigLIP-2 vision (CoreML / ANE, INT8)                │   │
│  │        │                                              │   │
│  │        ▼                                              │   │
│  │   768-dim L2-normalized embedding                     │   │
│  │        │                                              │   │
│  │        ▼                                              │   │
│  │   Cosine sim vs policy.bin (softmax over pair)        │   │
│  │        │                                              │   │
│  │        ▼                                              │   │
│  │   For each category that crosses threshold:           │   │
│  │     - append to audit log (local, encrypted)          │   │
│  │     - optionally trigger action (blur / block)        │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

## Why this split is the whole product

The system has exactly one boundary that matters: pixel data does not
leave the device, ever.

That single property is what makes ValueGuard deployable on corporate
laptops, viable in finance/healthcare/legal/government, and acceptable in
intimate personal-accountability contexts. Every other architectural
choice serves that boundary:

- The cloud part exists because LLMs are good at compiling fuzzy human
  values into precise SigLIP-2 caption pairs, and humans are bad at it.
  But the cloud part takes only the values statement — generic text.
- The local part exists because it has to. On-device inference is the
  only path that preserves the privacy guarantee. CoreML on the Apple
  Neural Engine makes it cheap enough that a continuous 1 Hz workload is
  inconsequential — sub-watt sustained power, under 200 MB resident.

## Component responsibilities

### Compiling a policy — two paths

`policy.json` is produced by an LLM from the plain-English values statement.
There are two paths, and they differ in *which* model and *who* calls it:

- **App (`app/`, the end-user path):** the menubar app generates a prompt and
  the user pastes it into *any* chat AI they choose (Claude.ai, ChatGPT, …),
  then pastes the JSON back. The app holds no API key and makes no model calls
  itself — it is model-agnostic.
- **`policy-compiler/` CLI (TypeScript, the scripted/authoring path):** calls
  the Anthropic API (Sonnet) directly.

### `policy-compiler/` (TypeScript)

- Input: a plain-English `values.md` and a deployment mode
- Output: `policy.json` — structured categories, contrastive caption pairs,
  thresholds, suggested actions
- Talks to: Anthropic API (Sonnet) — this CLI/authoring path only; the shipped
  app instead pastes into a user-chosen chat AI (see above)
- Privacy: sends only the values statement; never sees screen content

### `model-conversion/` (Python)

- `convert_siglip2.py`: HuggingFace `google/siglip2-base-patch16-256` →
  CoreML `.mlpackage`, with INT8 weight quantization on the vision tower
- `embed_captions.py`: runs the compiled `policy.json` through the
  SigLIP-2 text tower and packs the resulting embeddings into `policy.bin`
- Privacy: runs locally; the only network call is the initial HuggingFace
  model download

### `daemon/` (Swift)

- `ScreenCapture`: ScreenCaptureKit-based 1 Hz frame source
- `Classifier`: CoreML wrapper for the SigLIP-2 vision tower
- `Policy`: memory-mapped loader for `policy.bin` + cosine-sim scoring
- `AuditLog`: append-only JSON-line log under
  `~/Library/Application Support/ValueGuard/`
- `BlurOverlay`: full-screen blur action (stub; disabled in v0.1)
- `ValueGuardDaemon`: the loop tying it all together

## Scoring math

For each frame and each category, the daemon computes:

```
pos_score = positive_embedding · image_embedding
neg_score = negative_embedding · image_embedding
P(unsafe) = softmax([pos_score, neg_score])[0]
```

The category fires when `P(unsafe) >= threshold`. This is the standard
CLIP-style zero-shot classification recipe, applied per-category.

Caption embeddings are L2-normalized averages of 8–12 contrastive
phrasings on each side — the CuPL ensemble pattern. The ensemble is what
makes the recipe robust to phrasing.

## What this is not

- Not a domain blocker. We do not maintain hosts files or PAC scripts.
- Not a network filter. The TLS pixel-interception path is dead on
  modern macOS; this works at the framebuffer instead.
- Not a parental-control product. The threat model is the user themselves
  — they want this running.
- Not a generic CV pipeline. The architecture is shaped specifically
  around "embed → compare to policy" with no detection, segmentation, or
  OCR.

## What this could become

Several extensions are natural but deliberately out of scope for v0.1:

- Higher sampling rates (2–10 Hz adaptive based on recent scores)
- Fine-tuned MLP head on top of frozen SigLIP-2 embeddings, trained on
  the daemon's own logged flags
- Memory-store integration for tracking false positives over time
- A Cloudflare Worker bridge that forwards flagged events to an
  accountability partner (still no raw pixels — blurred thumbnails only)
- Corporate-mode MDM packaging (LaunchDaemon, signed config profile)
