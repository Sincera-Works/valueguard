#!/usr/bin/env bash
# Stop the ValueGuard screen daemon and any blur_overlay subprocesses it
# spawned. Idempotent — safe to call when nothing is running.

set -euo pipefail

PID_DIR="${HOME}/.valueguard"
PID_FILE="$PID_DIR/screen.pid"

if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
        kill -INT "$pid" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
fi

# Catch any orphans + any blur overlays the daemon spawned.
pkill -INT -f "valueguard.app/Contents/MacOS/valueguard"  2>/dev/null || true
pkill -INT -f "valueguard.app/Contents/MacOS/blur_overlay" 2>/dev/null || true
sleep 1
pkill -KILL -f "valueguard.app/Contents/MacOS/valueguard"  2>/dev/null || true
pkill -KILL -f "valueguard.app/Contents/MacOS/blur_overlay" 2>/dev/null || true

echo "valueguard: stopped"
