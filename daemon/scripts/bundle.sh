#!/usr/bin/env bash
# Build a signed valueguard.app bundle so macOS TCC can grant Screen Recording
# permission directly to the daemon rather than to its parent process.
#
# Output: daemon/dist/valueguard.app
#
# Re-run after any source change; the bundle ID and signature stay stable
# across rebuilds, so TCC permission persists.
set -euo pipefail

DAEMON_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
BUNDLE_ID="${BUNDLE_ID:-works.sincera.valueguard}"
APP_PATH="$DAEMON_DIR/dist/valueguard.app"

# Build the executable
cd "$DAEMON_DIR"
swift build -c "$BUILD_CONFIG"
BIN_SRC="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/valueguard"
if [ ! -x "$BIN_SRC" ]; then
    echo "error: binary not found at $BIN_SRC" >&2
    exit 1
fi

# Lay out the bundle
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp "$BIN_SRC" "$APP_PATH/Contents/MacOS/valueguard"

# Copy CoreML model into the bundle if it's been placed alongside daemon/Resources
if [ -d "$DAEMON_DIR/Resources" ]; then
    cp -R "$DAEMON_DIR/Resources/." "$APP_PATH/Contents/Resources/"
fi

cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>ValueGuard</string>
    <key>CFBundleDisplayName</key>
    <string>ValueGuard</string>
    <key>CFBundleExecutable</key>
    <string>valueguard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>ValueGuard samples the screen at 1Hz and scores each frame against your local content policy. Screen content is processed entirely on-device and never transmitted off the machine.</string>
</dict>
</plist>
EOF

# Ad-hoc signature. Stable across rebuilds because the bundle ID is the TCC key.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_PATH"

echo ""
echo "Built $APP_PATH"
echo "Bundle ID: $BUNDLE_ID"
echo ""
echo "First run:"
echo "  '$APP_PATH/Contents/MacOS/valueguard' --policy <path> --log-only"
echo "  → macOS will prompt for Screen Recording the first time. Click Open System Settings,"
echo "    toggle valueguard on. No Ghostty restart needed."
