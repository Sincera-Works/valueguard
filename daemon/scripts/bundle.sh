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

# Also ship the blur_overlay sibling binary so the daemon can launch it.
OVERLAY_SRC="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/blur_overlay"
if [ -x "$OVERLAY_SRC" ]; then
    cp "$OVERLAY_SRC" "$APP_PATH/Contents/MacOS/blur_overlay"
else
    echo "warning: blur_overlay binary not found at $OVERLAY_SRC; blur actions will fail at runtime"
fi

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

# Pick a stable code-signing identity so TCC's Designated Requirement is
# constant across rebuilds. Preference order:
#   1. $VALUEGUARD_CERT_NAME if set and present
#   2. The first "Apple Development:" identity (real Apple dev account)
#   3. The first "Apple Developer:" identity
#   4. The first "ValueGuard Developer" identity (from setup-codesign.sh)
#   5. Ad-hoc (TCC grants won't persist across rebuilds in this case)
pick_identity() {
    local pattern="$1"
    security find-identity -p codesigning -v 2>/dev/null \
        | awk -v p="$pattern" '$0 ~ p { print $2; exit }'
}

if [ -n "${VALUEGUARD_CERT_NAME:-}" ]; then
    SIGN_SHA="$(pick_identity "\"${VALUEGUARD_CERT_NAME}\"")"
    SIGN_LABEL="$VALUEGUARD_CERT_NAME"
fi
if [ -z "${SIGN_SHA:-}" ]; then
    SIGN_SHA="$(pick_identity 'Apple Development:')"
    [ -n "$SIGN_SHA" ] && SIGN_LABEL="Apple Development"
fi
if [ -z "${SIGN_SHA:-}" ]; then
    SIGN_SHA="$(pick_identity 'Apple Developer:')"
    [ -n "$SIGN_SHA" ] && SIGN_LABEL="Apple Developer"
fi
if [ -z "${SIGN_SHA:-}" ]; then
    SIGN_SHA="$(pick_identity '"ValueGuard Developer"')"
    [ -n "$SIGN_SHA" ] && SIGN_LABEL="ValueGuard Developer (self-signed)"
fi

# Sign every nested executable explicitly so subprocesses launched by the
# daemon (blur_overlay) carry a valid signature. Then sign the bundle. We
# avoid --deep because it's deprecated; explicit signing is the modern path.
sign_one() {
    local target="$1"
    local id="$2"
    if [ -n "${SIGN_SHA:-}" ]; then
        codesign --force --sign "$SIGN_SHA" --identifier "$id" "$target"
    else
        codesign --force --sign - --identifier "$id" "$target"
    fi
}

for binary in valueguard blur_overlay; do
    binpath="$APP_PATH/Contents/MacOS/$binary"
    [ -x "$binpath" ] && sign_one "$binpath" "$BUNDLE_ID"
done
sign_one "$APP_PATH" "$BUNDLE_ID"

if [ -n "${SIGN_SHA:-}" ]; then
    echo "Signed with: $SIGN_LABEL ($SIGN_SHA)"
else
    echo "Signed ad-hoc — no stable identity found."
    echo "Run scripts/setup-codesign.sh to make TCC grants persist across rebuilds."
fi

echo ""
echo "Built $APP_PATH"
echo "Bundle ID: $BUNDLE_ID"
echo ""
echo "First run:"
echo "  '$APP_PATH/Contents/MacOS/valueguard' --policy <path> --log-only"
echo "  → macOS will prompt for Screen Recording the first time. Click Open System Settings,"
echo "    toggle valueguard on. No Ghostty restart needed."
