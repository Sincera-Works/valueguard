#!/usr/bin/env bash
# Install (or reinstall) the LaunchAgent so valueguard auto-starts at login.
#
# Generates a plist that points at this clone's start-screen.sh and the
# user's chosen policy.bin, then loads it via launchctl.
#
# Required env: VALUEGUARD_POLICY (absolute path to compiled policy.bin)
# Optional env: VALUEGUARD_FLAGS  (extra flags forwarded to the daemon)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
POLICY="${VALUEGUARD_POLICY:-}"
EXTRA_FLAGS="${VALUEGUARD_FLAGS:-}"

if [ -z "$POLICY" ]; then
    echo "error: VALUEGUARD_POLICY must be set to an absolute path" >&2
    exit 1
fi
if [ ! -f "$POLICY" ]; then
    echo "error: policy file not found: $POLICY" >&2
    exit 1
fi

LABEL="works.sincera.valueguard"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST="$LAUNCH_AGENTS/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/ValueGuard"

mkdir -p "$LAUNCH_AGENTS" "$LOG_DIR"

# Unload an existing copy if present.
if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>sleep 30 &amp;&amp; "$SCRIPT_DIR/start-screen.sh"</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>VALUEGUARD_POLICY</key>
        <string>$POLICY</string>
        <key>VALUEGUARD_FLAGS</key>
        <string>$EXTRA_FLAGS</string>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err</string>
</dict>
</plist>
EOF

launchctl load "$PLIST"

echo "installed $PLIST"
echo "verify with: launchctl list | grep $LABEL"
echo "logs: $LOG_DIR/launchd.{out,err}"
echo ""
echo "The 30-second sleep on launch matches the reference Python spec — it"
echo "gives the user session, network, and other LaunchAgents time to settle"
echo "before valueguard requests Screen Recording and starts capturing."
