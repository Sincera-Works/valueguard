"""VGP1 policy loading and scoring. Port of daemon/Sources/ValueGuard/Policy.swift.

The VGP1 binary format is defined in model-conversion/embed_captions.py and
must be read byte-for-byte identically to the Swift loader (all little-endian):

  magic      : 4 bytes  = b"VGP1"
  version    : uint32   = 1
  n_categories: uint32
  embed_dim  : uint32   = 768
  reserved   : uint32   = 0
  for each category:
    id_len   : uint32
    id_utf8  : id_len bytes
    threshold: float32
    action   : uint8     (0=log, 1=blur, 2=block)
    padding  : 3 bytes
    pos_vec  : embed_dim float32 (L2-normalized)
    neg_vec  : embed_dim float32 (L2-normalized)
"""

from __future__ import annotations

import enum
import struct
from dataclasses import dataclass
from pathlib import Path

import numpy as np

MAGIC = b"VGP1"
SUPPORTED_VERSION = 1
HEADER = struct.Struct("<4sIIII")


class PolicyAction(enum.IntEnum):
    LOG = 0
    BLUR = 1
    BLOCK = 2


class PolicyError(Exception):
    pass


class FileTooShort(PolicyError):
    pass


class BadMagic(PolicyError):
    pass


class UnsupportedVersion(PolicyError):
    pass


class TruncatedCategory(PolicyError):
    pass


class InvalidAction(PolicyError):
    pass


class InvalidUTF8(PolicyError):
    pass


@dataclass(frozen=True)
class PolicyCategory:
    id: str
    threshold: float
    action: PolicyAction
    positive_embedding: np.ndarray  # L2-normalized "unsafe" ensemble, float32
    negative_embedding: np.ndarray  # L2-normalized "safe" ensemble, float32


@dataclass(frozen=True)
class CategoryScore:
    """Per-frame, per-category result, returned for *every* category so
    calibration tooling sees the full score distribution."""

    category: PolicyCategory
    positive_score: float
    negative_score: float
    firing: bool


class Policy:
    def __init__(self, embed_dim: int, categories: list[PolicyCategory]) -> None:
        self.embed_dim = embed_dim
        self.categories = categories

    @classmethod
    def load(cls, path: Path | str) -> "Policy":
        data = Path(path).read_bytes()
        if len(data) < HEADER.size:
            raise FileTooShort(f"{len(data)} bytes")

        magic, version, n_categories, dim, _reserved = HEADER.unpack_from(data, 0)
        if magic != MAGIC:
            raise BadMagic(magic.hex())
        if version != SUPPORTED_VERSION:
            raise UnsupportedVersion(str(version))

        vec_bytes = dim * 4
        offset = HEADER.size
        categories: list[PolicyCategory] = []
        for _ in range(n_categories):
            if offset + 4 > len(data):
                raise TruncatedCategory()
            (id_len,) = struct.unpack_from("<I", data, offset)
            offset += 4

            if offset + id_len > len(data):
                raise TruncatedCategory()
            try:
                cat_id = data[offset : offset + id_len].decode("utf-8")
            except UnicodeDecodeError as exc:
                raise InvalidUTF8() from exc
            offset += id_len

            if offset + 8 > len(data):
                raise TruncatedCategory()
            (threshold,) = struct.unpack_from("<f", data, offset)
            offset += 4
            action_byte = data[offset]
            try:
                action = PolicyAction(action_byte)
            except ValueError as exc:
                raise InvalidAction(str(action_byte)) from exc
            offset += 4  # includes 3 bytes padding

            if offset + 2 * vec_bytes > len(data):
                raise TruncatedCategory()
            pos = np.frombuffer(data, dtype="<f4", count=dim, offset=offset).copy()
            offset += vec_bytes
            neg = np.frombuffer(data, dtype="<f4", count=dim, offset=offset).copy()
            offset += vec_bytes

            categories.append(
                PolicyCategory(
                    id=cat_id,
                    threshold=float(threshold),
                    action=action,
                    positive_embedding=pos,
                    negative_embedding=neg,
                )
            )

        return cls(embed_dim=dim, categories=categories)

    def evaluate(self, embedding: np.ndarray) -> list[CategoryScore]:
        """Score an image embedding against every category.

        Firing semantics: raw cosine, `pos >= threshold`. The negative score
        is computed and logged but does not gate firing — see Policy.swift
        for the calibration history behind dropping the softmax formulation.
        """
        if embedding.shape != (self.embed_dim,):
            raise ValueError(f"embedding dim mismatch: {embedding.shape} != ({self.embed_dim},)")
        scores: list[CategoryScore] = []
        for cat in self.categories:
            pos = float(np.dot(cat.positive_embedding, embedding))
            neg = float(np.dot(cat.negative_embedding, embedding))
            scores.append(
                CategoryScore(
                    category=cat,
                    positive_score=pos,
                    negative_score=neg,
                    firing=pos >= cat.threshold,
                )
            )
        return scores
