from __future__ import annotations

import json

import numpy as np
import pytest

from valueguard_daemon.audit import AuditLog
from valueguard_daemon.policy import CategoryScore, PolicyAction, PolicyCategory


@pytest.fixture
def score() -> CategoryScore:
    cat = PolicyCategory(
        id='cat "quoted"',
        threshold=0.25,
        action=PolicyAction.BLUR,
        positive_embedding=np.zeros(4, dtype=np.float32),
        negative_embedding=np.zeros(4, dtype=np.float32),
    )
    return CategoryScore(category=cat, positive_score=0.31, negative_score=0.05, firing=True)


def read_records(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


def keys(path):
    return [list(json.loads(line)) for line in path.read_text().splitlines()]


def test_flag_record_shape_and_order(tmp_path, score):
    audit = AuditLog(tmp_path / "audit.log")
    audit.record_flag(score, window_id=1)
    (rec,) = read_records(tmp_path / "audit.log")
    # Field ORDER matches AuditLog.swift — calibration tooling keys on it.
    assert list(rec) == ["ts", "type", "category", "pos", "neg", "threshold", "action", "window_id"]
    assert rec["type"] == "flag"
    assert rec["category"] == 'cat "quoted"'  # escaping survives round-trip
    assert rec["action"] == "blur"
    assert rec["ts"].endswith("Z") and "." in rec["ts"]


def test_flag_without_window(tmp_path, score):
    audit = AuditLog(tmp_path / "audit.log")
    audit.record_flag(score)
    (rec,) = read_records(tmp_path / "audit.log")
    assert "window_id" not in rec


def test_samples_go_to_scores_log_only(tmp_path, score):
    audit_path, scores_path = tmp_path / "audit.log", tmp_path / "scores.ndjson"
    audit = AuditLog(audit_path, scores_log_path=scores_path)
    audit.record_sample(score, window_id=2, cached=True)
    assert audit_path.read_text() == ""
    (rec,) = read_records(scores_path)
    assert list(rec) == ["ts", "type", "category", "pos", "neg", "threshold", "firing", "cached", "window_id"]
    assert rec["cached"] is True and rec["firing"] is True and rec["window_id"] == 2


def test_sample_noop_without_scores_log(tmp_path, score):
    audit = AuditLog(tmp_path / "audit.log")
    audit.record_sample(score, window_id=1, cached=False)
    assert (tmp_path / "audit.log").read_text() == ""


def test_transitions_and_disappeared(tmp_path, score):
    audit = AuditLog(tmp_path / "audit.log")
    audit.record_transition("activated", 1, category_id="violence")
    audit.record_transition("cleared", 1)
    audit.record_disappeared(1)
    recs = read_records(tmp_path / "audit.log")
    assert [r["type"] for r in recs] == ["activated", "cleared", "disappeared"]
    assert recs[0]["category"] == "violence"
    assert "category" not in recs[1]
    assert all(r["window_id"] == 1 for r in recs)


def test_append_only_across_instances(tmp_path, score):
    AuditLog(tmp_path / "audit.log").record_flag(score, window_id=1)
    AuditLog(tmp_path / "audit.log").record_flag(score, window_id=1)
    assert len(read_records(tmp_path / "audit.log")) == 2
