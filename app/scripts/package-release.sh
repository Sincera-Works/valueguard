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
# notarized + stapled app).
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

echo "==> [8/8] final Gatekeeper assessment (assess the app, not the DMG container)"
spctl -a -t exec -vv "$APP" 2>&1 || true

echo ""
echo "DONE: $DMG"
ls -lh "$DMG"
