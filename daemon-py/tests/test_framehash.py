from __future__ import annotations

import numpy as np

from valueguard_daemon.framehash import difference_hash, hamming_distance


def gradient_frame() -> np.ndarray:
    x = np.linspace(0, 255, 256, dtype=np.uint8)
    return np.stack([np.tile(x, (256, 1))] * 3, axis=-1)


def test_identical_frames_distance_zero():
    a = gradient_frame()
    assert hamming_distance(difference_hash(a), difference_hash(a.copy())) == 0


def test_gradient_is_all_descending_bits():
    # A strictly left-to-right increasing gradient: every cell is darker than
    # its right neighbor, so no comparison bit is set.
    assert difference_hash(gradient_frame()) == 0
    # Reversed gradient: every bit set.
    assert difference_hash(gradient_frame()[:, ::-1]) == (1 << 64) - 1


def test_content_change_exceeds_threshold():
    a = gradient_frame()
    b = a.copy()
    b[:, :128] = 255  # blow out the left half
    assert hamming_distance(difference_hash(a), difference_hash(b)) >= 4


def test_noise_below_threshold_is_static():
    a = gradient_frame().astype(np.int16)
    rng = np.random.default_rng(3)
    b = np.clip(a + rng.integers(-2, 3, size=a.shape), 0, 255).astype(np.uint8)
    assert hamming_distance(difference_hash(a.astype(np.uint8)), difference_hash(b)) < 4
