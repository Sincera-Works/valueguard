# daemon-py — the cross-platform ValueGuard daemon

Python port of the macOS daemon for Linux (first) and Windows (next), per
issue #34. The Swift sources under `daemon/Sources/ValueGuard/` are the
reference implementation; each module here names the file it ports and must
match its semantics. The design rationale lives in `docs/LINUX.md` and
`docs/WINDOWS.md`.

**v0.1 is log-only, enforced in code** — there is no action-dispatch path;
blur/block show up in the audit log as the recorded `action` and nothing
else happens.

## Run

```sh
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -m valueguard_daemon \
    --model ../model-conversion/output/SigLIP2Vision.fp32.onnx \
    --policy ~/.local/share/ValueGuard/policy.bin
```

`--once` does a single tick (smoke mode); `--frames N` stops after N ticks;
`--scores-log path.ndjson` enables the per-frame calibration log;
`--providers cuda|directml` opts into an accelerator (CPU stays the
correctness baseline and the fallback). The model artifact is gitignored —
build it with `model-conversion/export_onnx.py`.

Autostart: `systemd/valueguard.service` (Linux, per-user unit); on Windows,
an HKCU `Run` entry pointing at `pythonw -m valueguard_daemon ...`.

## Layout

| Module | Ports | Notes |
|---|---|---|
| `policy.py` | `Policy.swift` | VGP1 byte-exact; raw-cosine `evaluate` |
| `hysteresis.py` | `Hysteresis.swift` | 3-of-10s default, boundary transitions |
| `framehash.py` | `Hash.swift` | 9×8 dHash gate, hamming < 4 = static |
| `audit.py` | `AuditLog.swift` | NDJSON, identical field names + order |
| `engine.py` | `ValueGuardDaemon.tick` | per **monitor**, not per window (v0.1 narrowing, see docs/LINUX.md) |
| `capture.py` | `ScreenCapture.swift` | mss @ 1 Hz, BGRA→RGB→256×256 |
| `classifier.py` | `Classifier.swift` | onnxruntime, CPU EP baseline |
| `preprocess.py` | — | the pinned contract (docs/WINDOWS.md) |

## Tests

```sh
.venv/bin/python -m pytest tests/
```

`tests/test_golden_vector.py` cross-checks image → preprocess → ONNX against
a PyTorch-recorded reference embedding (skips if the .onnx isn't built;
regenerate artifacts with `tests/golden/generate_reference.py`).
