from __future__ import annotations

from valueguard_daemon.hysteresis import HysteresisState, Transition


def test_activates_on_required_within_window():
    h = HysteresisState(required=3, window_seconds=10)
    assert h.record_positive(0.0) is Transition.UNCHANGED
    assert h.record_positive(1.0) is Transition.UNCHANGED
    assert h.record_positive(2.0) is Transition.ACTIVATED
    assert h.active


def test_no_double_activation():
    h = HysteresisState(required=2, window_seconds=10)
    h.record_positive(0.0)
    assert h.record_positive(1.0) is Transition.ACTIVATED
    assert h.record_positive(2.0) is Transition.UNCHANGED  # still active


def test_hits_age_out_before_activation():
    h = HysteresisState(required=3, window_seconds=10)
    h.record_positive(0.0)
    h.record_positive(1.0)
    # Third hit arrives after the first two have aged out of the window.
    assert h.record_positive(20.0) is Transition.UNCHANGED
    assert not h.active


def test_clears_only_after_eviction_empties_window():
    h = HysteresisState(required=2, window_seconds=10)
    h.record_positive(0.0)
    h.record_positive(1.0)
    assert h.active
    # Negative tick while hits are still in-window: no clear yet.
    assert h.record_negative(5.0) is Transition.UNCHANGED
    assert h.active
    # Negative tick after all hits aged out: boundary clear.
    assert h.record_negative(12.0) is Transition.CLEARED
    assert not h.active
    # Subsequent negatives stay unchanged.
    assert h.record_negative(13.0) is Transition.UNCHANGED


def test_negative_when_never_active():
    h = HysteresisState()
    assert h.record_negative(0.0) is Transition.UNCHANGED
