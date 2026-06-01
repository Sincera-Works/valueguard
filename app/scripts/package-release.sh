#!/usr/bin/env bash
#
# Build, Developer ID-sign, notarize, STAPLE (app + DMG), and DMG-package
# ValueGuard.app for distribution outside the App Store.
#
# Stapling the .app itself (not just the DMG) means first launch works fully
# offline. arm64-only: the model runs on the Apple Neural Engine, so an x86_64
# slice would only add a slow/hot ANE-less path and bloat.
#
# Prereqs: "Developer ID Application" cert (team 8YJK22K2SW) in the login
# keychain; notarytool keychain profile "valueguard-notary"; xcodegen; and the
# gitignored model/tokenizer resources present (daemon/Resources/SigLIP2Vision.mlpackage,
# app/Resources/tokenizer*.json).
#
# Output: app/build/release/ValueGuard.dmg (notarized + stapled; contains a
# notarized + stapled app), and — when the Sparkle signing key is available —
# app/build/release/appcast.xml (EdDSA-signed Sparkle update feed for this DMG).
#
# The Sparkle steps (9/9) are OPTIONAL and self-skipping: if the Sparkle CLI
# tools or the private signing key aren't present (e.g. on a clean CI box without
# the Keychain key), the script prints a clear SKIP message and still produces a
# fully notarized DMG. Notarization NEVER depends on Sparkle.
set -euo pipefail

TEAM_ID="8YJK22K2SW"
NOTARY_PROFILE="valueguard-notary"
SCHEME="ValueGuardApp"
APP_NAME="ValueGuard"

cd "$(dirname "$0")/.."                 # -> app/
ROOT="$(pwd)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/$APP_NAME.xcarchive"
EXPORT="$OUT/export"
DMG="$OUT/$APP_NAME.dmg"
APP="$EXPORT/$APP_NAME.app"

rm -rf "$OUT"; mkdir -p "$OUT"

echo "==> [1/8] regenerating Xcode project"
xcodegen generate >/dev/null

echo "==> [2/8] archiving (Release, arm64-only, manual Developer ID signing)"
xcodebuild -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" -destination 'generic/platform=macOS' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  archive | tail -3

echo "==> [3/8] exporting (developer-id)"
cat > "$OUT/exportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" -exportOptionsPlist "$OUT/exportOptions.plist" | tail -3

echo "==> signature check (expect Developer ID + runtime, arm64 only)"
codesign -dvv "$APP" 2>&1 | grep -E "Authority|TeamIdentifier|flags|Identifier" | head -6
lipo -archs "$APP/Contents/MacOS/$APP_NAME"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> [4/8] notarizing the APP (so it staples for offline first launch)"
APPZIP="$OUT/$APP_NAME-app.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$APPZIP"
xcrun notarytool submit "$APPZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> [5/8] stapling the APP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$APPZIP"   # notarization zip no longer needed; keep $OUT to just the DMG

echo "==> [6/8] building DMG from the stapled app"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> [7/8] notarizing + stapling the DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> [8/9] final Gatekeeper assessment (assess the app, not the DMG container)"
spctl -a -t exec -vv "$APP" 2>&1 || true

# ---------------------------------------------------------------------------
# [9/9] Sparkle: EdDSA-sign the DMG + emit/refresh the appcast feed.
#
# OPTIONAL + self-skipping. Runs only when BOTH are true:
#   1. The Sparkle CLI tools (generate_appcast / sign_update) resolved into
#      DerivedData from the Sparkle SPM artifact bundle.
#   2. A Sparkle EdDSA private key exists in the login Keychain.
# If either is missing we print a SKIP message and exit 0 — the notarized DMG
# above is the deliverable regardless. The private key is read from the Keychain
# automatically by the Sparkle tools; we NEVER pass it on the command line.
#
# The DMG's published download URL follows the GitHub release pattern
#   https://github.com/Sincera-Works/valueguard/releases/download/app-v<ver>/ValueGuard.dmg
# so we hand generate_appcast that exact prefix; it infers the version, length,
# and minimum-OS from the DMG, signs it, and writes the enclosure URL.
# ---------------------------------------------------------------------------
echo "==> [9/9] Sparkle: sign DMG + generate appcast (optional)"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
GH_RELEASE_TAG="app-v$APP_VERSION"
DOWNLOAD_URL_PREFIX="https://github.com/Sincera-Works/valueguard/releases/download/$GH_RELEASE_TAG/"

# Discover the Sparkle tools inside the resolved SPM artifact bundle. The
# DerivedData path is volatile (per-checkout hash), so we resolve it from the
# project's build settings rather than hardcoding it. Fall back to a glob.
SPARKLE_BIN=""
BUILD_ROOT="$(xcodebuild -scheme "$SCHEME" -showBuildSettings -configuration Release 2>/dev/null \
  | awk -F' = ' '/ BUILD_DIR =/{print $2; exit}')"
if [ -n "${BUILD_ROOT:-}" ]; then
  # BUILD_DIR is .../DerivedData/<proj>/Build/Products; the artifacts live under
  # .../DerivedData/<proj>/SourcePackages/artifacts/sparkle/Sparkle/bin
  DD_ROOT="${BUILD_ROOT%/Build/Products}"
  CAND="$DD_ROOT/SourcePackages/artifacts/sparkle/Sparkle/bin"
  [ -x "$CAND/sign_update" ] && SPARKLE_BIN="$CAND"
fi
if [ -z "$SPARKLE_BIN" ]; then
  CAND="$(/bin/ls -dt "$HOME"/Library/Developer/Xcode/DerivedData/ValueGuard-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1 || true)"
  [ -n "$CAND" ] && [ -x "$CAND/sign_update" ] && SPARKLE_BIN="$CAND"
fi

if [ -z "$SPARKLE_BIN" ] || [ ! -x "$SPARKLE_BIN/generate_appcast" ]; then
  echo "    SKIP: Sparkle CLI tools not found (run 'xcodebuild -resolvePackageDependencies'"
  echo "          to populate them). DMG is fully notarized; appcast not generated."
elif ! "$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1; then
  echo "    SKIP: no Sparkle EdDSA private key in the Keychain."
  echo "          Generate one once with: \"$SPARKLE_BIN/generate_keys\""
  echo "          then put the printed SUPublicEDKey into app/project.yml. DMG is"
  echo "          fully notarized; appcast not generated."
else
  # generate_appcast signs every DMG in the directory and (re)writes appcast.xml.
  # It expects the DMG to be the only/primary archive in the staging dir, so we
  # point it at $OUT (which contains exactly ValueGuard.dmg) and write the feed
  # alongside it. --download-url-prefix makes the enclosure URL absolute (GitHub).
  echo "    using Sparkle tools at: $SPARKLE_BIN"
  echo "    signing $DMG and writing appcast (download prefix: $DOWNLOAD_URL_PREFIX)"
  # Keep the generate_appcast working dir clean: only the DMG + appcast.xml.
  # (export/, dmg/, exportOptions.plist also live in $OUT; move the DMG into a
  # dedicated feed dir so generate_appcast doesn't trip over the archive.)
  FEED_DIR="$OUT/appcast"; mkdir -p "$FEED_DIR"
  cp "$DMG" "$FEED_DIR/$APP_NAME.dmg"
  "$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    -o "$FEED_DIR/appcast.xml" \
    "$FEED_DIR"
  cp "$FEED_DIR/appcast.xml" "$OUT/appcast.xml"
  echo "    appcast written: $OUT/appcast.xml"

  echo ""
  echo "    NEXT STEPS (Sparkle publish):"
  echo "      1. Upload $OUT/appcast.xml to the Cloudflare Pages site so it is served"
  echo "         at https://valueguard-configs.pages.dev/appcast.xml (next to the"
  echo "         config registry — same Pages project, sibling file). This URL is the"
  echo "         SUFeedURL baked into the app's Info.plist."
  echo "      2. Create GitHub release '$GH_RELEASE_TAG' on Sincera-Works/valueguard and"
  echo "         attach $DMG as 'ValueGuard.dmg' so the appcast enclosure URL resolves:"
  echo "         ${DOWNLOAD_URL_PREFIX}ValueGuard.dmg"
  echo "      3. Confirm SUPublicEDKey in app/project.yml matches this signing key:"
  echo "         \"$SPARKLE_BIN/generate_keys\" -p"
  echo "         (it must equal the public key compiled into the shipped app, or"
  echo "          Sparkle will reject the update)."
fi

echo ""
echo "DONE: $DMG"
ls -lh "$DMG"
[ -f "$OUT/appcast.xml" ] && { echo "APPCAST: $OUT/appcast.xml"; ls -lh "$OUT/appcast.xml"; }
