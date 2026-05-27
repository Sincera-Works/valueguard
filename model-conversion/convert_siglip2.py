"""Convert google/siglip2-base-patch16-256 from HuggingFace to CoreML.

Outputs two CoreML packages into ./output/:
  - SigLIP2Vision.mlpackage  — the vision tower (runs in the daemon hot path)
  - SigLIP2Text.mlpackage    — the text tower (runs once during policy embed)

The vision tower is INT8-quantized for the Apple Neural Engine. The text
tower stays in FP16 because it only runs at policy-compile time and the
quantization error matters more for the few text vectors we'll embed.

Run on an Apple Silicon Mac. The first run downloads ~1GB from HuggingFace.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import coremltools as ct
import torch
from transformers import AutoModel, AutoProcessor

MODEL_ID = "google/siglip2-base-patch16-256"
IMAGE_SIZE = 256
EMBED_DIM = 768
TEXT_CONTEXT = 64  # SigLIP-2 base text encoder context length

OUT_DIR = Path(__file__).parent / "output"
CACHE_DIR = Path(__file__).parent / "cache"


class VisionWrapper(torch.nn.Module):
    """Returns the L2-normalized pooled image embedding."""

    def __init__(self, vision_model: torch.nn.Module) -> None:
        super().__init__()
        self.vision_model = vision_model

    def forward(self, pixel_values: torch.Tensor) -> torch.Tensor:
        out = self.vision_model(pixel_values=pixel_values)
        pooled = out.pooler_output
        return torch.nn.functional.normalize(pooled, dim=-1)


class TextWrapper(torch.nn.Module):
    """Returns the L2-normalized pooled text embedding."""

    def __init__(self, text_model: torch.nn.Module) -> None:
        super().__init__()
        self.text_model = text_model

    def forward(self, input_ids: torch.Tensor) -> torch.Tensor:
        out = self.text_model(input_ids=input_ids)
        pooled = out.pooler_output
        return torch.nn.functional.normalize(pooled, dim=-1)


def export_vision(model: torch.nn.Module, out_path: Path) -> None:
    print(f"[vision] tracing at {IMAGE_SIZE}x{IMAGE_SIZE}")
    wrapped = VisionWrapper(model.vision_model).eval()
    dummy = torch.randn(1, 3, IMAGE_SIZE, IMAGE_SIZE)
    traced = torch.jit.trace(wrapped, dummy, strict=False)

    print("[vision] converting to CoreML (FP16)")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
                color_layout=ct.colorlayout.RGB,
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )

    print("[vision] linear-quantizing weights to INT8")
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig,
        OptimizationConfig,
        linear_quantize_weights,
    )

    config = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8"),
    )
    mlmodel = linear_quantize_weights(mlmodel, config=config)

    mlmodel.short_description = "SigLIP-2 base-patch16-256 vision tower, INT8."
    mlmodel.save(str(out_path))
    print(f"[vision] saved {out_path}")


def export_text(model: torch.nn.Module, out_path: Path) -> None:
    print(f"[text] tracing at context length {TEXT_CONTEXT}")
    wrapped = TextWrapper(model.text_model).eval()
    dummy = torch.zeros(1, TEXT_CONTEXT, dtype=torch.int32)
    traced = torch.jit.trace(wrapped, dummy, strict=False)

    print("[text] converting to CoreML (FP16)")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, TEXT_CONTEXT), dtype=int),
        ],
        outputs=[ct.TensorType(name="embedding")],
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )

    mlmodel.short_description = (
        f"SigLIP-2 base-patch16-256 text tower, FP16, context={TEXT_CONTEXT}."
    )
    mlmodel.save(str(out_path))
    print(f"[text] saved {out_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vision-only", action="store_true")
    parser.add_argument("--text-only", action="store_true")
    args = parser.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("HF_HOME", str(CACHE_DIR))

    print(f"Loading {MODEL_ID} from HuggingFace (cache: {CACHE_DIR})")
    model = AutoModel.from_pretrained(MODEL_ID).eval()

    if not args.text_only:
        export_vision(model, OUT_DIR / "SigLIP2Vision.mlpackage")
    if not args.vision_only:
        export_text(model, OUT_DIR / "SigLIP2Text.mlpackage")

    print("")
    print("Done. Daemon expects the vision package at:")
    print(f"  daemon/Resources/SigLIP2Vision.mlpackage")
    print(f"Copy or symlink {OUT_DIR / 'SigLIP2Vision.mlpackage'} there.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
