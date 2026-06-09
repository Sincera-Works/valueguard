"""Gate the ONNX export: PyTorch vs onnxruntime CPU-EP embedding parity.

This is the P0 acceptance gate for the Windows port (issue #34): identical
input tensors through the PyTorch vision tower and the exported ONNX graph
must produce embeddings with

    cosine similarity >= 0.999  (fp32)
    cosine similarity >= 0.995  (fp16, if present)

and every embedding must be L2-normalized (||v|| within 1e-3 of 1.0).

Inputs are deterministic seeded tensors already in the normalized [-1, 1]
domain — the same x/127.5 - 1.0 contract documented in export_onnx.py and
docs/WINDOWS.md. Graph parity only; end-to-end preprocessing drift is
covered by the P1 golden-vector test on Windows.

Exit code 0 = pass, 1 = fail.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import torch
from transformers import AutoModel

from export_onnx import CACHE_DIR, EMBED_DIM, IMAGE_SIZE, MODEL_ID, OUT_DIR, VisionWrapper

N_SAMPLES = 8
FP32_GATE = 0.999
FP16_GATE = 0.995
NORM_TOL = 1e-3


def make_inputs() -> np.ndarray:
    rng = np.random.default_rng(seed=20260609)
    # Quantize to the 256 levels a real BGRA frame can produce, then apply the
    # canonical normalization, so the test domain matches the daemon's.
    pixels = rng.integers(0, 256, size=(N_SAMPLES, 3, IMAGE_SIZE, IMAGE_SIZE))
    return (pixels.astype(np.float32) / 127.5) - 1.0


def torch_embeddings(inputs: np.ndarray) -> np.ndarray:
    model = AutoModel.from_pretrained(MODEL_ID, cache_dir=CACHE_DIR)
    model.eval()
    wrapper = VisionWrapper(model.vision_model)
    wrapper.eval()
    with torch.no_grad():
        out = wrapper(torch.from_numpy(inputs))
    return out.numpy()


def onnx_embeddings(model_path: Path, inputs: np.ndarray) -> np.ndarray:
    import onnxruntime as ort

    sess = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
    rows = [sess.run(["embedding"], {"pixel_values": inputs[i : i + 1]})[0] for i in range(len(inputs))]
    return np.concatenate(rows, axis=0)


def check(name: str, ref: np.ndarray, got: np.ndarray, gate: float) -> bool:
    ok = True
    norms = np.linalg.norm(got, axis=-1)
    if not np.allclose(norms, 1.0, atol=NORM_TOL):
        print(f"[{name}] FAIL: embeddings not L2-normalized (norms {norms})")
        ok = False
    cos = np.sum(ref * got, axis=-1) / (np.linalg.norm(ref, axis=-1) * norms)
    worst = float(cos.min())
    status = "ok" if worst >= gate else "FAIL"
    print(f"[{name}] cosine min={worst:.6f} mean={float(cos.mean()):.6f} gate={gate} -> {status}")
    return ok and worst >= gate


def main() -> int:
    fp32_path = OUT_DIR / "SigLIP2Vision.fp32.onnx"
    if not fp32_path.exists():
        print(f"missing {fp32_path} — run export_onnx.py first", file=sys.stderr)
        return 1

    inputs = make_inputs()
    print(f"[parity] {N_SAMPLES} seeded inputs, dim check: expecting (*, {EMBED_DIM})")
    ref = torch_embeddings(inputs)
    assert ref.shape == (N_SAMPLES, EMBED_DIM)

    passed = check("fp32", ref, onnx_embeddings(fp32_path, inputs), FP32_GATE)

    fp16_path = OUT_DIR / "SigLIP2Vision.fp16.onnx"
    if fp16_path.exists():
        passed = check("fp16", ref, onnx_embeddings(fp16_path, inputs), FP16_GATE) and passed
    else:
        print("[fp16] not present — skipped")

    print("PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
