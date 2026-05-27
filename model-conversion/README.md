# model-conversion

Python utilities for the offline (one-time) parts of the pipeline:

1. `convert_siglip2.py` — downloads SigLIP-2 base from HuggingFace and
   converts both towers to CoreML. The vision tower is INT8-quantized for
   the Apple Neural Engine.
2. `embed_captions.py` — takes a compiled `policy.json` from the
   `policy-compiler` and bakes the caption embeddings into a `policy.bin`
   the daemon mmaps at startup.

## Setup

Requires Apple Silicon. Python 3.11 (coremltools doesn't yet support 3.13).

```bash
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Step 1 — Convert the model (runs once, ~10 min)

```bash
python convert_siglip2.py
```

Outputs to `output/`:

- `SigLIP2Vision.mlpackage` (~85 MB INT8) — copy to `daemon/Resources/`.
- `SigLIP2Text.mlpackage` (~110 MB FP16) — used by `embed_captions.py`.

The first run downloads ~1 GB from HuggingFace into `cache/`.

## Step 2 — Embed a compiled policy

```bash
python embed_captions.py ../policy-compiler/examples/personal-values.policy.json
```

Writes `personal-values.policy.bin` next to the input. This is what the
daemon loads at runtime.

If the CoreML text tower exists in `output/`, `embed_captions.py` uses it
(matches what the daemon would compute). Otherwise it falls back to the
PyTorch model, which is slower but numerically equivalent.

## policy.bin format

All little-endian.

```
magic        : 4 bytes  = b"VGP1"
version      : uint32   = 1
n_categories : uint32
embed_dim    : uint32   = 768
reserved     : uint32   = 0

repeated n_categories times:
  id_len    : uint32
  id_utf8   : id_len bytes
  threshold : float32
  action    : uint8   (0=log, 1=blur, 2=block)
  padding   : 3 bytes
  pos_vec   : 768 float32  (L2-normalized average of positive captions)
  neg_vec   : 768 float32  (L2-normalized average of negative captions)
```

The Swift daemon reads this via memory-mapped I/O — no parser allocations
in the hot path. See `daemon/Sources/ValueGuard/PolicyLoader.swift`.

## Why not just ship the PyTorch model

CoreML on the Apple Neural Engine is roughly 10× faster than PyTorch on
the GPU and runs at sub-watt power. Per-frame inference budget on the
ANE is ~10–15 ms for the base vision tower; the same model on CPU is
~200 ms. For an always-on daemon that matters.
