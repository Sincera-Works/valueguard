"""Sample-based difference hash for fast change detection.
Port of daemon/Sources/ValueGuard/Hash.swift.

NOT a strong perceptual hash — sufficient for "did this monitor's content
meaningfully change since last frame." Point-samples a 9×8 grid, compares
each cell to its right neighbor, packs the 64 comparison bits into an int.

The Swift version reads BGRA; here the input is an HxWx3 uint8 RGB array
(the daemon hashes the same 256×256 buffer it classifies, as on macOS).
Grayscale is the same integer mean (r+g+b)//3, so hashes agree across ports
for identical pixel content.
"""

from __future__ import annotations

import numpy as np

DEFAULT_DISTANCE_THRESHOLD = 4  # hamming < 4 == "unchanged" (reference spec)


def difference_hash(rgb: np.ndarray) -> int:
    height, width = rgb.shape[:2]

    # Map the 9×8 hash grid back to pixel coordinates (same arithmetic as Swift).
    xs = np.minimum(np.arange(9) * width // 9, width - 1)
    ys = np.minimum(np.arange(8) * height // 8, height - 1)

    cells = rgb[np.ix_(ys, xs)].astype(np.int64)
    gray = (cells[:, :, 0] + cells[:, :, 1] + cells[:, :, 2]) // 3

    bits = gray[:, :8] > gray[:, 1:]
    h = 0
    for y in range(8):
        for x in range(8):
            if bits[y, x]:
                h |= 1 << (y * 8 + x)
    return h


def hamming_distance(a: int, b: int) -> int:
    return (a ^ b).bit_count()
