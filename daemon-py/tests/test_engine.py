"""The tick-pipeline orchestration: hash gate -> classify/reuse -> records ->
hysteresis. Mirrors ValueGuardDaemon.tick semantics, per monitor."""

from __future__ import annotations

import json

import numpy as np
import pytest
from conftest import pack_vgp1, unit

from valueguard_daemon.audit import AuditLog
from valueguard_daemon.engine import Engine
from valueguard_daemon.policy import Policy

DIM = 8


@pytest.fixture
def policy(tmp_path) -> Policy:
    f = tmp_path / "p.bin"
    f.write_bytes(
        pack_vgp1(
            [{"id": "violence", "threshold": 0.5, "action": 0,
              "pos": unit([1, 0, 0, 0, 0, 0, 0, 0]), "neg": unit([0, 1, 0, 0, 0, 0, 0, 0])}],
            embed_dim=DIM,
        )
    )
    return Policy.load(f)


class FakeEmbedder:
    """Returns a firing or non-firing embedding depending on frame brightness."""

    def __init__(self):
        self.calls = 0

    def __call__(self, rgb: np.ndarray) -> np.ndarray:
        self.calls += 1
        e = np.zeros(DIM, dtype=np.float32)
        e[0 if rgb.mean() > 128 else 1] = 1.0  # bright frame -> fires
        return e


def frame(value: int) -> np.ndarray:
    rng = np.random.default_rng(value)
    base = rng.integers(0, 64, size=(256, 256, 3)).astype(np.uint8)
    return np.clip(base + value, 0, 255).astype(np.uint8)


def make_engine(policy, tmp_path, **kw):
    embed = FakeEmbedder()
    audit = AuditLog(tmp_path / "audit.log", scores_log_path=tmp_path / "scores.ndjson")
    return Engine(policy, embed, audit, **kw), embed, tmp_path / "audit.log", tmp_path / "scores.ndjson"


def records(path):
    return [json.loads(l) for l in path.read_text().splitlines()]


def test_hash_gate_skips_inference_on_static_frames(policy, tmp_path):
    engine, embed, _, scores_path = make_engine(policy, tmp_path)
    f = frame(0)
    engine.process_frame(1, f, now=0.0)
    engine.process_frame(1, f.copy(), now=1.0)  # identical content
    assert embed.calls == 1  # second frame served from cache
    recs = records(scores_path)
    assert [r["cached"] for r in recs] == [False, True]
    # Cached samples reuse the scores verbatim.
    assert recs[0]["pos"] == recs[1]["pos"]


def test_hash_gate_disabled_always_infers(policy, tmp_path):
    engine, embed, _, _ = make_engine(policy, tmp_path, hash_gate_enabled=False)
    f = frame(0)
    engine.process_frame(1, f, now=0.0)
    engine.process_frame(1, f.copy(), now=1.0)
    assert embed.calls == 2


def test_changed_content_reinfers(policy, tmp_path):
    engine, embed, _, _ = make_engine(policy, tmp_path)
    engine.process_frame(1, frame(0), now=0.0)
    engine.process_frame(1, frame(200), now=1.0)  # very different content
    assert embed.calls == 2


def test_firing_writes_flag_and_activates_hysteresis(policy, tmp_path):
    engine, _, audit_path, _ = make_engine(policy, tmp_path, hash_gate_enabled=False)
    bright = np.full((256, 256, 3), 255, dtype=np.uint8)
    for t in range(3):
        engine.process_frame(1, bright, now=float(t))
    recs = records(audit_path)
    assert [r["type"] for r in recs] == ["flag", "flag", "flag", "activated"]
    assert recs[3]["category"] == "violence"
    assert all(r["window_id"] == 1 for r in recs)


def test_clear_after_quiet_period(policy, tmp_path):
    engine, _, audit_path, _ = make_engine(
        policy, tmp_path, hash_gate_enabled=False, hysteresis_required=2, hysteresis_seconds=5.0
    )
    bright = np.full((256, 256, 3), 255, dtype=np.uint8)
    dark = np.zeros((256, 256, 3), dtype=np.uint8)
    engine.process_frame(1, bright, now=0.0)
    engine.process_frame(1, bright, now=1.0)   # activated
    engine.process_frame(1, dark, now=2.0)     # hits still in window
    engine.process_frame(1, dark, now=10.0)    # hits aged out -> cleared
    types = [r["type"] for r in records(audit_path)]
    assert types == ["flag", "flag", "activated", "cleared"]


def test_monitors_tracked_independently(policy, tmp_path):
    engine, embed, _, scores_path = make_engine(policy, tmp_path)
    f = frame(0)
    engine.process_frame(1, f, now=0.0)
    engine.process_frame(2, f.copy(), now=0.1)  # same content, new monitor: no shared cache
    assert embed.calls == 2
    assert {r["window_id"] for r in records(scores_path)} == {1, 2}


def test_prune_records_disappeared_only_when_active(policy, tmp_path):
    engine, _, audit_path, _ = make_engine(policy, tmp_path, hash_gate_enabled=False, hysteresis_required=1)
    bright = np.full((256, 256, 3), 255, dtype=np.uint8)
    dark = np.zeros((256, 256, 3), dtype=np.uint8)
    engine.process_frame(1, bright, now=0.0)  # monitor 1 active
    engine.process_frame(2, dark, now=0.0)    # monitor 2 never active
    engine.prune_monitors(set())
    recs = [r for r in records(audit_path) if r["type"] == "disappeared"]
    assert [r["window_id"] for r in recs] == [1]
