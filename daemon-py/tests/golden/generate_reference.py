"""Regenerate the golden-vector test artifacts.

Creates a deterministic synthetic image (no external assets, no licensing
questions) and records the PyTorch tower's embedding for it. Run with the
model-conversion venv, which has torch + transformers:

    cd daemon-py/tests/golden
    ../../../model-conversion/.venv/bin/python generate_reference.py

Commit both outputs. The reference embedding comes from PyTorch — NOT from
the ONNX graph — so the golden test independently cross-checks the export
AND the daemon's preprocess against the original model.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

HERE = Path(__file__).parent
REPO = HERE.resolve().parents[2]
sys.path.insert(0, str(REPO / "daemon-py"))

# Same model + wrapper semantics as model-conversion/{convert_siglip2,export_onnx}.py
# (inlined so this script doesn't depend on a sibling tree being checked out).
MODEL_ID = "google/siglip2-base-patch16-256"
CACHE_DIR = REPO / "model-conversion" / "cache"


def make_image() -> Image.Image:
    """Deterministic 640×400 synthetic scene (non-square on purpose, so the
    direct-resize geometry is exercised)."""
    img = Image.new("RGB", (640, 400))
    px = img.load()
    for y in range(400):
        for x in range(640):
            px[x, y] = (x * 255 // 639, y * 255 // 399, (x + y) * 255 // 1038)
    draw = ImageDraw.Draw(img)
    draw.ellipse([80, 60, 280, 260], fill=(220, 40, 40))
    draw.rectangle([360, 140, 580, 340], fill=(40, 180, 220))
    draw.polygon([(320, 30), (400, 120), (240, 120)], fill=(250, 250, 60))
    return img


def main() -> None:
    from transformers import AutoModel
    import torch

    from valueguard_daemon.preprocess import normalize, resize_rgb

    img = make_image()
    img.save(HERE / "golden.png")

    tensor = normalize(resize_rgb(np.asarray(img)))

    model = AutoModel.from_pretrained(MODEL_ID, cache_dir=CACHE_DIR)
    model.eval()
    with torch.no_grad():
        out = model.vision_model(pixel_values=torch.from_numpy(tensor))
        embedding = torch.nn.functional.normalize(out.pooler_output, dim=-1).numpy()[0]

    (HERE / "golden_embedding.json").write_text(json.dumps([float(v) for v in embedding]))
    print(f"wrote golden.png + golden_embedding.json (norm={float(np.linalg.norm(embedding)):.6f})")


if __name__ == "__main__":
    main()
