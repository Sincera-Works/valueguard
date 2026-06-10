from __future__ import annotations

import struct
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def pack_vgp1(categories: list[dict], embed_dim: int = 8, version: int = 1, magic: bytes = b"VGP1") -> bytes:
    """Mirror of the writer in model-conversion/embed_captions.py — keep the
    layout in sync with that docstring (the format's definition)."""
    out = struct.pack("<4sIIII", magic, version, len(categories), embed_dim, 0)
    for cat in categories:
        cid = cat["id"].encode("utf-8")
        out += struct.pack("<I", len(cid)) + cid
        out += struct.pack("<f", cat["threshold"])
        out += struct.pack("<B3x", cat["action"])
        out += np.asarray(cat["pos"], dtype="<f4").tobytes()
        out += np.asarray(cat["neg"], dtype="<f4").tobytes()
    return out


def unit(vec: list[float]) -> np.ndarray:
    v = np.asarray(vec, dtype=np.float32)
    return v / np.linalg.norm(v)


@pytest.fixture
def simple_policy_bytes() -> bytes:
    dim = 8
    pos = unit([1, 0, 0, 0, 0, 0, 0, 0])
    neg = unit([0, 1, 0, 0, 0, 0, 0, 0])
    return pack_vgp1(
        [
            {"id": "violence", "threshold": 0.25, "action": 0, "pos": pos, "neg": neg},
            {"id": "naïve-category-ü", "threshold": 0.9, "action": 2, "pos": neg, "neg": pos},
        ],
        embed_dim=dim,
    )
