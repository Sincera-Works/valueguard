"""Append-only NDJSON audit log. Port of daemon/Sources/ValueGuard/AuditLog.swift.

Record shapes, field names, and field ORDER match the Swift writer exactly —
downstream consumers (calibration tooling) key on them:

  sample:      ts, type, category, pos, neg, threshold, firing, cached, window_id[, app]
  flag:        ts, type, category, pos, neg, threshold, action[, window_id[, app]]
  activated/cleared: ts, type, window_id[, app][, category]
  disappeared: ts, type, window_id[, app]

On Linux, window_id carries the monitor index — per-monitor capture is the
documented v0.1 narrowing of macOS's per-window model (docs/LINUX.md).

Flags and transitions go to audit.log; per-frame samples go to the optional
scores log (large — calibration only), exactly as on macOS. Plain NDJSON, no
encryption or chaining, matching current macOS behavior; tamper-evidence is
the cross-platform follow-up (repo issue #37).
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

from .policy import CategoryScore, PolicyAction

_ACTION_NAMES = {PolicyAction.LOG: "log", PolicyAction.BLUR: "blur", PolicyAction.BLOCK: "block"}


def _now_iso() -> str:
    # ISO8601 with fractional seconds, UTC — same as Swift's
    # ISO8601DateFormatter with .withFractionalSeconds (millisecond precision).
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


class AuditLog:
    def __init__(
        self,
        audit_path: Path,
        include_window_info: bool = False,
        scores_log_path: Optional[Path] = None,
    ) -> None:
        self._audit_path = audit_path
        self._scores_path = scores_log_path
        self._include_window_info = include_window_info
        audit_path.parent.mkdir(parents=True, exist_ok=True)
        audit_path.touch(exist_ok=True)
        if scores_log_path is not None:
            scores_log_path.parent.mkdir(parents=True, exist_ok=True)
            scores_log_path.touch(exist_ok=True)

    def _write(self, fields: dict, path: Path) -> None:
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(fields, separators=(",", ":")) + "\n")

    def record_sample(self, score: CategoryScore, window_id: int, cached: bool, app: str | None = None) -> None:
        """Per-frame score record for every category — what calibration needs.
        No-op unless the scores log is enabled."""
        if self._scores_path is None:
            return
        fields = {
            "ts": _now_iso(),
            "type": "sample",
            "category": score.category.id,
            "pos": score.positive_score,
            "neg": score.negative_score,
            "threshold": score.category.threshold,
            "firing": score.firing,
            "cached": cached,
            "window_id": window_id,
        }
        if self._include_window_info and app is not None:
            fields["app"] = app
        self._write(fields, self._scores_path)

    def record_flag(self, score: CategoryScore, window_id: int | None = None, app: str | None = None) -> None:
        """A category crossed its threshold on this frame."""
        fields = {
            "ts": _now_iso(),
            "type": "flag",
            "category": score.category.id,
            "pos": score.positive_score,
            "neg": score.negative_score,
            "threshold": score.category.threshold,
            "action": _ACTION_NAMES[score.category.action],
        }
        if window_id is not None:
            fields["window_id"] = window_id
            if self._include_window_info and app is not None:
                fields["app"] = app
        self._write(fields, self._audit_path)

    def record_transition(self, kind: str, window_id: int, category_id: str | None = None, app: str | None = None) -> None:
        assert kind in ("activated", "cleared")
        fields = {"ts": _now_iso(), "type": kind, "window_id": window_id}
        if self._include_window_info and app is not None:
            fields["app"] = app
        if category_id is not None:
            fields["category"] = category_id
        self._write(fields, self._audit_path)

    def record_disappeared(self, window_id: int, app: str | None = None) -> None:
        fields = {"ts": _now_iso(), "type": "disappeared", "window_id": window_id}
        if self._include_window_info and app is not None:
            fields["app"] = app
        self._write(fields, self._audit_path)
