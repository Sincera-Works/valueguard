from __future__ import annotations

import numpy as np
import pytest
from conftest import pack_vgp1, unit

from valueguard_daemon import policy as P


def load(tmp_path, data: bytes) -> P.Policy:
    f = tmp_path / "policy.bin"
    f.write_bytes(data)
    return P.Policy.load(f)


def test_round_trip(tmp_path, simple_policy_bytes):
    pol = load(tmp_path, simple_policy_bytes)
    assert pol.embed_dim == 8
    assert [c.id for c in pol.categories] == ["violence", "naïve-category-ü"]
    cat = pol.categories[0]
    assert cat.threshold == pytest.approx(0.25)
    assert cat.action == P.PolicyAction.LOG
    assert cat.positive_embedding.dtype == np.float32
    assert np.linalg.norm(cat.positive_embedding) == pytest.approx(1.0)
    assert pol.categories[1].action == P.PolicyAction.BLOCK


def test_bad_magic(tmp_path, simple_policy_bytes):
    with pytest.raises(P.BadMagic):
        load(tmp_path, b"NOPE" + simple_policy_bytes[4:])


def test_unsupported_version(tmp_path):
    data = pack_vgp1([], version=2)
    with pytest.raises(P.UnsupportedVersion):
        load(tmp_path, data)


def test_file_too_short(tmp_path):
    with pytest.raises(P.FileTooShort):
        load(tmp_path, b"VGP1\x01")


def test_truncated_category(tmp_path, simple_policy_bytes):
    with pytest.raises(P.TruncatedCategory):
        load(tmp_path, simple_policy_bytes[:-8])


def test_invalid_action(tmp_path):
    data = pack_vgp1([{"id": "x", "threshold": 0.5, "action": 7, "pos": unit([1, 1]), "neg": unit([1, -1])}], embed_dim=2)
    with pytest.raises(P.InvalidAction):
        load(tmp_path, data)


def test_invalid_utf8(tmp_path):
    good = pack_vgp1([{"id": "ab", "threshold": 0.5, "action": 0, "pos": unit([1, 1]), "neg": unit([1, -1])}], embed_dim=2)
    # id bytes start at offset 24 ("ab") — corrupt them with invalid UTF-8.
    bad = good[:24] + b"\xff\xfe" + good[26:]
    with pytest.raises(P.InvalidUTF8):
        load(tmp_path, bad)


def test_evaluate_raw_cosine_firing(tmp_path, simple_policy_bytes):
    """Firing is raw cosine pos >= threshold — no softmax. The boundary case
    (pos == threshold) fires, matching Swift's `pos >= cat.threshold`."""
    pol = load(tmp_path, simple_policy_bytes)
    e1 = np.zeros(8, dtype=np.float32)
    e1[0] = 1.0  # aligned with violence.pos
    scores = pol.evaluate(e1)
    assert scores[0].firing and scores[0].positive_score == pytest.approx(1.0)
    assert scores[0].negative_score == pytest.approx(0.0)
    assert not scores[1].firing  # cosine 0.0 < 0.9

    boundary = np.zeros(8, dtype=np.float32)
    boundary[0] = 0.25
    boundary_scores = pol.evaluate(boundary)
    assert boundary_scores[0].positive_score == pytest.approx(0.25)
    assert boundary_scores[0].firing

    assert len(scores) == 2  # every category scored, firing or not


def test_evaluate_dim_mismatch(tmp_path, simple_policy_bytes):
    pol = load(tmp_path, simple_policy_bytes)
    with pytest.raises(ValueError):
        pol.evaluate(np.zeros(16, dtype=np.float32))
