#!/usr/bin/env bash
# Remove the LaunchAgent. Stops the daemon and deletes the plist.

set -euo pipefail

LABEL="works.sincera.valueguard"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    echo "uninstalled $PLIST"
else
    echo "no LaunchAgent found at $PLIST"
fi

# Make sure the daemon and any overlays are stopped.
"$(cd "$(dirname "$0")" && pwd)/stop-screen.sh" 2>/dev/null || true
