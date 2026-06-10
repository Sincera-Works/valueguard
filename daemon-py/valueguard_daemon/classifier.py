"""onnxruntime wrapper around the exported SigLIP-2 vision tower.

Analog of daemon/Sources/ValueGuard/Classifier.swift. CPU EP is the
correctness baseline; accelerators (CUDAExecutionProvider on Linux,
DmlExecutionProvider on Windows) are opt-in performance tiers — onnxruntime
partitions unsupported ops back to CPU automatically, so they can never
change results beyond float tolerance.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np

from .preprocess import normalize, resize_rgb

PROVIDER_SETS = {
    "cpu": ["CPUExecutionProvider"],
    "cuda": ["CUDAExecutionProvider", "CPUExecutionProvider"],
    "directml": ["DmlExecutionProvider", "CPUExecutionProvider"],
}


class Classifier:
    def __init__(self, model_path: Path | str, providers: str = "cpu") -> None:
        import onnxruntime as ort

        available = set(ort.get_available_providers())
        requested = PROVIDER_SETS[providers]
        usable = [p for p in requested if p in available]
        if not usable:
            usable = ["CPUExecutionProvider"]
        self._session = ort.InferenceSession(str(model_path), providers=usable)
        self.providers = usable

    def embed(self, rgb: np.ndarray) -> np.ndarray:
        """HxWx3 uint8 RGB frame -> L2-normalized (768,) float32 embedding."""
        tensor = normalize(resize_rgb(rgb))
        (out,) = self._session.run(["embedding"], {"pixel_values": tensor})
        return out[0]
