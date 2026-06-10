from __future__ import annotations

import numpy as np
import pytest

from valueguard_daemon.preprocess import IMAGE_SIZE, normalize, resize_rgb


def test_normalize_contract():
    """The pinned contract: x/127.5 - 1.0, float32 NCHW (1,3,256,256)."""
    rgb = np.zeros((IMAGE_SIZE, IMAGE_SIZE, 3), dtype=np.uint8)
    rgb[0, 0] = [255, 0, 128]
    out = normalize(rgb)
    assert out.shape == (1, 3, IMAGE_SIZE, IMAGE_SIZE)
    assert out.dtype == np.float32
    assert out[0, 0, 0, 0] == pytest.approx(1.0)     # 255 -> +1
    assert out[0, 1, 0, 0] == pytest.approx(-1.0)    # 0   -> -1
    assert out[0, 2, 0, 0] == pytest.approx(128 / 127.5 - 1.0, abs=1e-6)
    assert out.min() >= -1.0 and out.max() <= 1.0


def test_resize_is_direct_no_crop():
    """A 2:1 frame must be squashed, not cropped — content from both extreme
    edges survives (mirrors the macOS hot path's direct rasterization)."""
    wide = np.zeros((200, 400, 3), dtype=np.uint8)
    wide[:, :20] = 250   # left edge bright
    wide[:, -20:] = 120  # right edge mid
    out = resize_rgb(wide)
    assert out.shape == (IMAGE_SIZE, IMAGE_SIZE, 3)
    assert out[:, :5].mean() > 200    # left edge content present
    assert 80 < out[:, -5:].mean() < 160  # right edge content present (crop would lose one)


def test_resize_passthrough_at_native_size():
    rgb = np.full((IMAGE_SIZE, IMAGE_SIZE, 3), 7, dtype=np.uint8)
    assert resize_rgb(rgb) is rgb
