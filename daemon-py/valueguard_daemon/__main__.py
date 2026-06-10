"""ValueGuard daemon entry point: python -m valueguard_daemon

Samples every monitor at 1 Hz, classifies frames against the compiled
policy, and appends flags/transitions to the audit log. v0.1 is log-only;
there is no action dispatch in this build.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

from . import __version__
from .audit import AuditLog
from .capture import MonitorCapture
from .classifier import Classifier
from .engine import Engine
from .paths import default_audit_path, default_policy_path
from .policy import Policy


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="valueguard_daemon", description=__doc__)
    parser.add_argument("--policy", type=Path, default=default_policy_path())
    parser.add_argument("--model", type=Path, required=True, help="SigLIP2Vision .onnx path")
    parser.add_argument("--audit-log", type=Path, default=default_audit_path())
    parser.add_argument("--scores-log", type=Path, default=None, help="optional per-frame NDJSON for calibration")
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--frames", type=int, default=0, help="stop after N ticks (0 = run forever)")
    parser.add_argument("--once", action="store_true", help="single tick, then exit (smoke mode)")
    parser.add_argument("--providers", choices=["cpu", "cuda", "directml"], default="cpu")
    parser.add_argument("--no-hash-gate", action="store_true")
    parser.add_argument("--hash-threshold", type=int, default=4)
    parser.add_argument("--hysteresis-required", type=int, default=3)
    parser.add_argument("--hysteresis-seconds", type=float, default=10.0)
    args = parser.parse_args(argv)

    policy = Policy.load(args.policy)
    classifier = Classifier(args.model, providers=args.providers)
    audit = AuditLog(args.audit_log, scores_log_path=args.scores_log)
    engine = Engine(
        policy,
        classifier.embed,
        audit,
        hash_gate_enabled=not args.no_hash_gate,
        hash_distance_threshold=args.hash_threshold,
        hysteresis_required=args.hysteresis_required,
        hysteresis_seconds=args.hysteresis_seconds,
    )
    capture = MonitorCapture()

    print(
        f"valueguard_daemon {__version__}: {len(policy.categories)} categories, "
        f"providers={classifier.providers}, monitors={capture.monitor_ids}, "
        f"hash-gate={'off' if args.no_hash_gate else f'on (distance<{args.hash_threshold})'}, "
        f"hysteresis={args.hysteresis_required}-of-{args.hysteresis_seconds}s, log-only",
        file=sys.stderr,
    )

    max_frames = 1 if args.once else args.frames
    tick = 0
    tick_ms: list[float] = []
    try:
        while True:
            t0 = time.monotonic()
            for monitor_id in capture.monitor_ids:
                frame = capture.grab(monitor_id)
                engine.process_frame(monitor_id, frame, now=time.monotonic())
            engine.prune_monitors(set(capture.monitor_ids))
            elapsed = time.monotonic() - t0
            tick_ms.append(elapsed * 1000)
            tick += 1
            if max_frames and tick >= max_frames:
                break
            time.sleep(max(0.0, args.interval - elapsed))
    except KeyboardInterrupt:
        pass
    finally:
        capture.close()

    if tick_ms:
        s = sorted(tick_ms)
        print(
            f"valueguard_daemon: {tick} ticks, {engine.inference_count} inferences, "
            f"tick ms p50={s[len(s) // 2]:.1f} p95={s[min(len(s) - 1, int(len(s) * 0.95))]:.1f} max={s[-1]:.1f}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
