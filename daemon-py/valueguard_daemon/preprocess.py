"""The pinned preprocess contract (docs/WINDOWS.md, docs/LINUX.md).

One contract, kept in sync with model-conversion/export_onnx.py and
model-conversion/test_onnx_parity.py:

  - direct resize to 256×256 (NO center-crop — mirrors the macOS daemon hot
    path, which rasterizes the capture stream straight to 256×256)
  - RGB channel order
  - float32 NCHW (1, 3, 256, 256)
  - normalize x / 127.5 - 1.0  (pixel [0,255] -> [-1,1]; CoreML bakes this
    into its ImageType — the ONNX graph does not, so it happens here)
"""

from __future__ import annotations

import numpy as np
from PIL import Image

IMAGE_SIZE = 256


def resize_rgb(rgb: np.ndarray) -> np.ndarray:
    """HxWx3 uint8 RGB at any size -> 256×256 uint8 RGB (direct, no crop)."""
    if rgb.shape[0] == IMAGE_SIZE and rgb.shape[1] == IMAGE_SIZE:
        return rgb
    img = Image.fromarray(rgb, mode="RGB").resize((IMAGE_SIZE, IMAGE_SIZE), Image.BILINEAR)
    return np.asarray(img)


def normalize(rgb256: np.ndarray) -> np.ndarray:
    """256×256 uint8 RGB -> float32 NCHW (1, 3, 256, 256) in [-1, 1]."""
    x = rgb256.astype(np.float32) / 127.5 - 1.0
    return np.expand_dims(x.transpose(2, 0, 1), 0)
