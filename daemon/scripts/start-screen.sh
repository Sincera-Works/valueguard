#!/usr/bin/env bash
# Start the ValueGuard screen daemon. Designed to be called from an existing
# orchestration script (e.g. start-filtering.sh) or directly from a LaunchAgent.
#
# Configuration via environment variables:
#   VALUEGUARD_APP     Path to the signed .app bundle (default: ../dist/valueguard.app
#                      relative to this script)
#   VALUEGUARD_POLICY  REQUIRED. Absolute path to the compiled policy.bin.
#   VALUEGUARD_FLAGS   Optional. Extra CLI flags appended to the daemon invocation.
#                      Examples: "--log-only", "--monitor-apps Safari,Chrome",
#                      "--rate 2", "--include-window-info".
#
# Writes the daemon PID to ~/.valueguard/screen.pid for stop-screen.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALUEGUARD_APP="${VALUEGUARD_APP:-$SCRIPT_DIR/../dist/valueguard.app}"
# Canonicalize the .app path. The kernel reports the resolved path in argv,
# so anything containing `..` will fail to match in pgrep below.
if [ -d "$VALUEGUARD_APP" ]; then
    VALUEGUARD_APP="$(cd "$VALUEGUARD_APP" && pwd -P)"
fi
POLICY="${VALUEGUARD_POLICY:-}"
EXTRA_FLAGS=(${VALUEGUARD_FLAGS:-})
PID_DIR="${HOME}/.valueguard"
PID_FILE="$PID_DIR/screen.pid"

if [ -z "$POLICY" ]; then
    echo "error: VALUEGUARD_POLICY must be set to an absolute path to a compiled policy.bin" >&2
    exit 1
fi
if [ ! -f "$POLICY" ]; then
    echo "error: policy file not found: $POLICY" >&2
    exit 1
fi
if [ ! -d "$VALUEGUARD_APP" ]; then
    echo "error: $VALUEGUARD_APP not found. Run scripts/bundle.sh first." >&2
    exit 1
fi

mkdir -p "$PID_DIR"

# Stop any existing instance, ignoring errors.
"$SCRIPT_DIR/stop-screen.sh" >/dev/null 2>&1 || true

# Launch via `open` so LaunchServices attributes TCC to the bundle ID rather
# than to the shell that runs this script. Without this, TCC's Screen Recording
# grant gets routed to your terminal emulator instead of valueguard.
open -n "$VALUEGUARD_APP" --args \
    --policy "$POLICY" \
    "${EXTRA_FLAGS[@]}"

# `open -n` returns immediately. Give the .app a beat to spawn, then capture
# the PID for stop-screen.sh.
sleep 1
INNER_BIN="$VALUEGUARD_APP/Contents/MacOS/valueguard"
PID="$(pgrep -f "$INNER_BIN" | head -1 || true)"
if [ -z "$PID" ]; then
    echo "error: daemon failed to start (no process matching $INNER_BIN found)" >&2
    exit 1
fi
echo "$PID" > "$PID_FILE"
echo "valueguard: started pid=$PID app=$VALUEGUARD_APP"
echo "valueguard: audit log at ~/Library/Application Support/ValueGuard/audit.log"
