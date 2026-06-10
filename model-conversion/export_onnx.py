"""Export the SigLIP-2 vision tower to ONNX for the Windows daemon.

Outputs into ./output/:
  - SigLIP2Vision.fp32.onnx — correctness baseline (CPU EP on any platform)
  - SigLIP2Vision.fp16.onnx — smaller/faster variant (skipped with a warning
    if the float16 converter is unavailable)

The exported graph has identical semantics to the CoreML export in
convert_siglip2.py: it wraps the vision tower and returns the L2-normalized
pooled image embedding (1, 768).

UNLIKE the CoreML export, normalization is NOT baked into the graph. CoreML's
ImageType carries scale=1/127.5, bias=-1; ONNX has no input-image abstraction,
so the caller must feed an already-normalized tensor:

    input "pixel_values": float32 (1, 3, 256, 256), NCHW, RGB,
    normalized per channel as x / 127.5 - 1.0  (pixel range [0,255] -> [-1,1])

This contract is documented in docs/WINDOWS.md and enforced by
test_onnx_parity.py, which applies the same normalization on both the
PyTorch and ONNX sides. Keep the three in sync.

INT8 quantization is deliberately absent: it happens with onnxruntime on
real Windows hardware during calibration (see docs/WINDOWS.md, P2), the
same calibration-before-action rule the macOS daemon follows.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import torch
from transformers import AutoModel

MODEL_ID = "google/siglip2-base-patch16-256"
IMAGE_SIZE = 256
EMBED_DIM = 768
OPSET = 17

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


def export_fp32(wrapper: torch.nn.Module, out_path: Path) -> None:
    example = torch.zeros(1, 3, IMAGE_SIZE, IMAGE_SIZE, dtype=torch.float32)
    torch.onnx.export(
        wrapper,
        (example,),
        str(out_path),
        input_names=["pixel_values"],
        output_names=["embedding"],
        opset_version=OPSET,
        do_constant_folding=True,
        dynamo=False,
    )
    print(f"[vision] wrote {out_path} ({out_path.stat().st_size / 1e6:.1f} MB)")


def convert_fp16(fp32_path: Path, fp16_path: Path) -> bool:
    try:
        import onnx
        # onnxruntime ships a maintained fork of onnxconverter-common's
        # float16 converter; the upstream one leaves the input-boundary Conv
        # with mixed fp32/fp16 types even with keep_io_types.
        from onnxruntime.transformers.float16 import convert_float_to_float16
    except ImportError as exc:
        print(f"[vision] fp16 conversion skipped (missing dependency: {exc})", file=sys.stderr)
        return False
    model = onnx.load(str(fp32_path))
    # Keep the I/O boundary in fp32 so the daemon-side contract is one dtype
    # regardless of which variant it loads; only internal weights/compute drop
    # to fp16.
    model_fp16 = convert_float_to_float16(model, keep_io_types=True)
    onnx.save(model_fp16, str(fp16_path))
    print(f"[vision] wrote {fp16_path} ({fp16_path.stat().st_size / 1e6:.1f} MB)")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-fp16", action="store_true", help="export fp32 only")
    args = parser.parse_args()

    OUT_DIR.mkdir(exist_ok=True)

    print(f"[vision] loading {MODEL_ID}")
    model = AutoModel.from_pretrained(MODEL_ID, cache_dir=CACHE_DIR)
    model.eval()

    wrapper = VisionWrapper(model.vision_model)
    wrapper.eval()

    fp32_path = OUT_DIR / "SigLIP2Vision.fp32.onnx"
    with torch.no_grad():
        export_fp32(wrapper, fp32_path)

    if not args.skip_fp16:
        convert_fp16(fp32_path, OUT_DIR / "SigLIP2Vision.fp16.onnx")

    print("[vision] done — run test_onnx_parity.py before shipping these")
    return 0


if __name__ == "__main__":
    sys.exit(main())
