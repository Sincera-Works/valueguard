# Installing ValueGuard

ValueGuard is layer 4 of the four-layer content-filtering stack described in
`docs/ARCHITECTURE.md`. This document covers two install paths:

1. **Standalone**, for testing or for use without an existing filtering stack
2. **Wired into an existing `start-filtering.sh`**, where ValueGuard replaces
   a CLIP-based Python screen daemon

Either way, you need a built `valueguard.app` and a compiled `policy.bin`.

---

## Prerequisites

```sh
# 1. Convert SigLIP-2 → CoreML (Apple Silicon, ~10 min, one time)
cd model-conversion
python3.11 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python convert_siglip2.py

# 2. Compile a policy from a values statement
cd ../policy-compiler
npm install
export ANTHROPIC_API_KEY=sk-ant-...
npx tsx src/compile.ts examples/personal-values.md personal

# 3. Embed the captions into a policy.bin
cd ../model-conversion
python embed_captions.py ../policy-compiler/examples/personal-values.policy.json

# 4. Build the daemon + bundle the signed .app
cd ../daemon
./scripts/setup-codesign.sh   # one-time, only if you don't have an Apple Dev cert
./scripts/bundle.sh
```

At this point you have:

- `daemon/dist/valueguard.app` — the signed bundle
- `policy-compiler/examples/personal-values.policy.bin` — the policy

---

## Standalone install

### Run once, attached

```sh
export VALUEGUARD_POLICY="$PWD/../policy-compiler/examples/personal-values.policy.bin"
./scripts/start-screen.sh
```

The first run will trigger a macOS Screen Recording prompt for `valueguard`.
Grant it via System Settings → Privacy & Security → Screen Recording. No
Ghostty restart required (the bundle is signed with your Apple Dev cert, so
TCC keys to its identity rather than to the parent shell).

Stop with:

```sh
./scripts/stop-screen.sh
```

### Auto-start at login (LaunchAgent)

```sh
export VALUEGUARD_POLICY="/absolute/path/to/personal-values.policy.bin"
./scripts/install-launchagent.sh
```

This generates `~/Library/LaunchAgents/works.sincera.valueguard.plist`,
loads it via `launchctl`, and starts the daemon. Logs land in
`~/Library/Logs/ValueGuard/launchd.{out,err}`.

Verify:

```sh
launchctl list | grep works.sincera.valueguard
tail ~/Library/Logs/ValueGuard/launchd.err
```

Uninstall:

```sh
./scripts/uninstall-launchagent.sh
```

---

## Integration with an existing `start-filtering.sh`

If you already run a four-layer stack (hosts file + PAC proxy + semantic
mitmproxy + Python screen daemon), ValueGuard replaces the fourth layer.
Two changes:

### 1. Stop the existing Python screen daemon

In your `start-filtering.sh`, replace the `python3 screen_daemon.py &` line
with a call to ValueGuard's start script:

```sh
# Layer 4: screen daemon (ValueGuard, replaces Python screen_daemon.py)
export VALUEGUARD_POLICY="/Users/$USER/Documents/.../my.policy.bin"
export VALUEGUARD_FLAGS="--include-window-info"   # optional
/path/to/valueguard/daemon/scripts/start-screen.sh
```

`start-screen.sh` exits immediately after launching the daemon, so it does
not need to be backgrounded.

### 2. Stop ValueGuard on shutdown

In your `stop-filtering.sh`, add:

```sh
/path/to/valueguard/daemon/scripts/stop-screen.sh
```

`stop-screen.sh` is idempotent and safe to call when nothing is running.

### Optional: drop your existing LaunchAgent

If your existing stack uses a single LaunchAgent that calls
`start-filtering.sh`, you do not need ValueGuard's own LaunchAgent —
your existing one already starts everything in order. Don't run both.

---

## Configuration

Environment variables read by `start-screen.sh` and `install-launchagent.sh`:

| Var | Required | Description |
|---|---|---|
| `VALUEGUARD_POLICY` | yes | Absolute path to compiled `policy.bin` |
| `VALUEGUARD_APP` | no | Path to `.app` bundle. Default: `../dist/valueguard.app` |
| `VALUEGUARD_FLAGS` | no | Extra CLI flags forwarded to the daemon |

Useful `VALUEGUARD_FLAGS` values:

- `--log-only` — collect data without ever blurring (recommended for the
  calibration phase; see `docs/BUILD.md` Phase 5)
- `--monitor-apps Safari,Google Chrome,Firefox` — restrict to specific
  apps. Default is the browser list.
- `--all-windows` — classify every visible window (smoke testing only)
- `--rate 2` — sample at 2 Hz instead of 1 Hz
- `--hits 5 --hysteresis-seconds 15` — tune the debouncer
- `--no-hash-gate` — disable per-window hash skip (debugging)
- `--include-window-info` — include app names in the audit log

The full list is in `valueguard --help`.

---

## What gets installed where

| Path | Contents |
|---|---|
| `daemon/dist/valueguard.app` | The signed app bundle |
| `~/.valueguard/screen.pid` | Daemon PID (used by stop-screen.sh) |
| `~/Library/Application Support/ValueGuard/audit.log` | Per-event JSON-line log |
| `~/Library/Caches/ValueGuard/SigLIP2Vision.mlmodelc` | Compiled CoreML model cache |
| `~/Library/LaunchAgents/works.sincera.valueguard.plist` | LaunchAgent (if installed) |
| `~/Library/Logs/ValueGuard/launchd.{out,err}` | LaunchAgent log redirects |

---

## Verification checklist

After installing, every layer should respond:

```sh
# Daemon is running
pgrep -f valueguard.app/Contents/MacOS/valueguard && echo "ok"

# Audit log has recent entries
tail -1 ~/Library/Application\ Support/ValueGuard/audit.log

# Live diagnostics via unified log
log show --predicate 'subsystem == "works.sincera.valueguard"' --last 5m \
    | grep -E "ACTIVATED|CLEARED|hash-gate|monitorApps"

# If LaunchAgent installed:
launchctl list | grep works.sincera.valueguard
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Daemon exits immediately with "Screen Recording permission required" | TCC declined the .app | Grant via System Settings → Privacy & Security → Screen Recording. The `valueguard` entry should already be in the list. |
| TCC dialog attributes the request to Ghostty / Terminal | Daemon was launched directly instead of via `open` | Use `scripts/start-screen.sh`, not `swift run` |
| `bundle.sh` says "Signed ad-hoc" | No Apple Developer cert or self-signed cert in the login keychain | Either join the Apple Developer Program (recommended) or run `scripts/setup-codesign.sh` to generate a self-signed cert |
| Blur overlays appear as flat gray | `NSVisualEffectView.alphaValue < 1.0` | Failure mode #5 from the reference spec. `alphaValue` MUST stay 1.0; darken via a tint NSView instead. Our `ValueGuardOverlay/main.swift` does this correctly. |
| Audit log has 0 entries with `--monitor-apps Safari` set, despite Safari being open | Safari is in the greenlist | Check `CaptureFilter.defaultGreenlist`. The greenlist takes precedence over the monitor list. Use `--all-windows` for diagnostic. |
| LaunchAgent fails with I/O error after `install-launchagent.sh` | Invalid plist keys | `install-launchagent.sh` generates a known-good plist; if you hand-edited it, check for `StartInterval` or `ThrottleInterval` keys that the reference spec calls out as failure-causing |
