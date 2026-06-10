"""ValueGuard cross-platform daemon (Linux first, Windows next).

A Python port of the macOS daemon's platform-neutral core: VGP1 policy
loading, raw-cosine scoring, frame-hash gating, hysteresis, and the
NDJSON audit log — with mss for capture and onnxruntime for inference.

The Swift sources under daemon/Sources/ValueGuard/ are the reference
implementation; every module here names the file it ports and must match
its semantics. v0.1 is log-only: actions are recorded, never dispatched.
"""

__version__ = "0.1.0"
