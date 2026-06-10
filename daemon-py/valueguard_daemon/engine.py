"""Per-tick orchestration. Port of ValueGuardDaemon.tick (ValueGuardDaemon.swift).

Decoupled from mss and onnxruntime so the gate/cache/hysteresis/audit
interplay is unit-testable: the loop hands frames in, the engine does
exactly what the Swift tick does, per monitor instead of per window:

  1. hash gate — skip classification if content hasn't materially changed
  2. classify (or reuse the cached scores if static)
  3. sample records for every category (scores log), flag records for firing
  4. feed firing into hysteresis; record activated/cleared boundary transitions
  5. clean up state for monitors that disappeared

v0.1 is log-only and this port enforces it in code: there is no action
dispatch path at all — blur/block arrive in the audit log as the recorded
`action` and nothing else happens.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Callable, Optional

import numpy as np

from .audit import AuditLog
from .framehash import DEFAULT_DISTANCE_THRESHOLD, difference_hash, hamming_distance
from .hysteresis import HysteresisState, Transition
from .policy import CategoryScore, Policy


@dataclass
class _MonitorState:
    hysteresis: HysteresisState
    last_hash: Optional[int] = None
    last_scores: list[CategoryScore] = field(default_factory=list)


class Engine:
    def __init__(
        self,
        policy: Policy,
        embed: Callable[[np.ndarray], np.ndarray],
        audit: AuditLog,
        hash_gate_enabled: bool = True,
        hash_distance_threshold: int = DEFAULT_DISTANCE_THRESHOLD,
        hysteresis_required: int = 3,
        hysteresis_seconds: float = 10.0,
    ) -> None:
        self._policy = policy
        self._embed = embed
        self._audit = audit
        self._hash_gate_enabled = hash_gate_enabled
        self._hash_distance_threshold = hash_distance_threshold
        self._hysteresis_required = hysteresis_required
        self._hysteresis_seconds = hysteresis_seconds
        self._states: dict[int, _MonitorState] = {}
        self.inference_count = 0

    def process_frame(self, monitor_id: int, rgb256: np.ndarray, now: float) -> list[CategoryScore]:
        """Run one monitor's 256×256 RGB frame through the tick pipeline."""
        state = self._states.get(monitor_id)
        if state is None:
            state = _MonitorState(
                hysteresis=HysteresisState(self._hysteresis_required, self._hysteresis_seconds)
            )
            self._states[monitor_id] = state

        frame_hash = difference_hash(rgb256)
        if self._hash_gate_enabled and state.last_hash is not None:
            is_static = hamming_distance(state.last_hash, frame_hash) < self._hash_distance_threshold
        else:
            is_static = False
        state.last_hash = frame_hash

        if not is_static:
            embedding = self._embed(rgb256)
            state.last_scores = self._policy.evaluate(embedding)
            self.inference_count += 1

        for score in state.last_scores:
            self._audit.record_sample(score, window_id=monitor_id, cached=is_static)
            if score.firing:
                self._audit.record_flag(score, window_id=monitor_id)

        firing = [s for s in state.last_scores if s.firing]
        if firing:
            transition = state.hysteresis.record_positive(now)
            if transition is Transition.ACTIVATED:
                self._audit.record_transition("activated", monitor_id, category_id=firing[0].category.id)
        else:
            transition = state.hysteresis.record_negative(now)
            if transition is Transition.CLEARED:
                self._audit.record_transition("cleared", monitor_id)

        return state.last_scores

    def prune_monitors(self, current_ids: set[int]) -> None:
        """Drop state for monitors no longer present (mirrors the Swift
        gone-window cleanup, including the disappeared record for any monitor
        that vanished while its hysteresis was active)."""
        for monitor_id in [m for m in self._states if m not in current_ids]:
            if self._states[monitor_id].hysteresis.active:
                self._audit.record_disappeared(monitor_id)
            del self._states[monitor_id]
