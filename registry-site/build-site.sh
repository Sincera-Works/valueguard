#!/usr/bin/env bash
# Assemble the publishable ValueGuard marketplace site into registry-site/dist/.
#
# The deployable tree is the static browse page (index.html) overlaid with a
# REAL, freshly generated registry (index.json + content-addressed bundles +
# extracted manifests) produced by `vg reindex`. Unlike the tracked sample
# registry-site/index.json (3 demo configs, two of them fictional), the
# assembled dist/ contains only genuinely installable, signed bundles — so every
# "vg install" command shown on the page actually works.
#
# Output: registry-site/dist/  (gitignored; safe to delete and regenerate)
#
# Inputs:
#   daemon/dist/bundles/*.vgconfig   the signed bundles to publish (see SEED)
#
# Usage:
#   registry-site/build-site.sh                 # assemble dist/
#   SEED=1 registry-site/build-site.sh          # also (re)pack the example config first
#   registry-site/build-site.sh && \
#     (cd registry-site/dist && python3 -m http.server 8765)   # preview
set -euo pipefail

SITE_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SITE_DIR/.." && pwd)"
DAEMON_DIR="$REPO_DIR/daemon"
BUILD_CONFIG="${BUILD_CONFIG:-debug}"

BUNDLES_DIR="$DAEMON_DIR/dist/bundles"
REGISTRY_DIR="$DAEMON_DIR/dist/registry"
OUT_DIR="$SITE_DIR/dist"
REGISTRY_NAME="${REGISTRY_NAME:-ValueGuard Configs}"

echo "==> building vg ($BUILD_CONFIG)"
( cd "$DAEMON_DIR" && swift build -c "$BUILD_CONFIG" --product vg >/dev/null )
VG="$(cd "$DAEMON_DIR" && swift build -c "$BUILD_CONFIG" --show-bin-path)/vg"
[ -x "$VG" ] || { echo "error: vg binary not found at $VG" >&2; exit 1; }

# Optionally (re)pack the calibrated example config so there is at least one
# bundle to publish on a fresh checkout. Off by default — packing needs a
# signing key, and a real deploy publishes real authors' bundles.
if [ "${SEED:-0}" = "1" ]; then
  echo "==> SEED=1: packing the example personal-values config"
  KEYS_DIR="$DAEMON_DIR/dist/keys"
  mkdir -p "$KEYS_DIR" "$BUNDLES_DIR"
  if [ ! -f "$KEYS_DIR/sincera.key" ]; then
    "$VG" keygen --handle sincera --out "$KEYS_DIR" >/dev/null
  fi
  "$VG" pack \
    --dir "$REPO_DIR/policy-compiler/examples" \
    --key "$KEYS_DIR/sincera.key" \
    --handle sincera \
    --name "Personal Values" \
    --config-id personal-values \
    --version 1.0.0 \
    --license MIT --tag personal --tag strict \
    --out "$BUNDLES_DIR/sincera-personal-values-1.0.0.vgconfig" >/dev/null 2>&1 || true
fi

if ! ls "$BUNDLES_DIR"/*.vgconfig >/dev/null 2>&1; then
  echo "error: no .vgconfig bundles in $BUNDLES_DIR" >&2
  echo "       run with SEED=1 to pack the example config, or 'vg pack' your own." >&2
  exit 1
fi

echo "==> reindexing $BUNDLES_DIR -> $REGISTRY_DIR"
"$VG" reindex --bundles "$BUNDLES_DIR" --out "$REGISTRY_DIR" --name "$REGISTRY_NAME"

echo "==> assembling site into $OUT_DIR"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
# The page itself.
cp "$SITE_DIR/index.html" "$OUT_DIR/index.html"
# The REAL registry payload (overrides the tracked sample index.json).
cp "$REGISTRY_DIR/index.json" "$OUT_DIR/index.json"
cp -R "$REGISTRY_DIR/bundles" "$OUT_DIR/bundles"
cp -R "$REGISTRY_DIR/configs" "$OUT_DIR/configs"
# The Sparkle update feed (app auto-updater). Served at /appcast.xml, which is
# the SUFeedURL baked into the app's Info.plist. Updated by package-release.sh.
if [ -f "$SITE_DIR/appcast.xml" ]; then
  cp "$SITE_DIR/appcast.xml" "$OUT_DIR/appcast.xml"
fi

COUNT="$(/usr/bin/python3 -c "import json;print(len(json.load(open('$OUT_DIR/index.json'))['configs']))" 2>/dev/null || echo '?')"
BYTES="$(du -sh "$OUT_DIR" | cut -f1)"
echo "==> done: $COUNT config(s), $BYTES total in $OUT_DIR"
echo
echo "preview:  (cd '$OUT_DIR' && python3 -m http.server 8765)  then open http://localhost:8765"
echo "deploy:   see registry-site/DEPLOY.md"
