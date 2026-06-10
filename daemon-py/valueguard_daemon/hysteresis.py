"""Per-monitor debouncing state machine. Port of daemon/Sources/ValueGuard/Hysteresis.swift.

`required` positive hits within `window_seconds` triggers an ACTIVATED
transition. The next tick with no positive hit, once all previous hits have
aged out, triggers CLEARED. Transitions fire only on the boundary.
"""

from __future__ import annotations

import enum
from collections import deque


class Transition(enum.Enum):
    UNCHANGED = "unchanged"
    ACTIVATED = "activated"
    CLEARED = "cleared"


class HysteresisState:
    def __init__(self, required: int = 3, window_seconds: float = 10.0) -> None:
        self.required = required
        self.window_seconds = window_seconds
        self._hits: deque[float] = deque()
        self.active = False

    def _evict(self, now: float) -> None:
        cutoff = now - self.window_seconds
        while self._hits and self._hits[0] < cutoff:
            self._hits.popleft()

    def record_positive(self, now: float) -> Transition:
        """Append a positive hit. Returns ACTIVATED only on the boundary where
        this hit promotes us from inactive to active."""
        self._evict(now)
        self._hits.append(now)
        if len(self._hits) >= self.required and not self.active:
            self.active = True
            return Transition.ACTIVATED
        return Transition.UNCHANGED

    def record_negative(self, now: float) -> Transition:
        """Record a tick with no positive hit. Returns CLEARED only on the
        boundary where we had been active and eviction has just emptied the
        hit window."""
        self._evict(now)
        if not self._hits and self.active:
            self.active = False
            return Transition.CLEARED
        return Transition.UNCHANGED
