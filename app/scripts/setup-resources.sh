#!/usr/bin/env bash
# Populate app/Resources/ with the SigLIP-2 tokenizer assets.
#
# These three files (tokenizer.json, tokenizer_config.json,
# special_tokens_map.json) ship inside ValueGuard.app's Resources for the
# Bayesian calibrator's caption tokenizer. The 33 MB tokenizer.json is too
# large to commit cleanly; this script pulls it (and the small siblings)
# out of the local HuggingFace cache so each developer doesn't need to
# vendor it in git.
#
# Requires you've previously fetched the SigLIP-2 model (e.g. by running
# model-conversion/convert_siglip2.py once).

set -euo pipefail

MODEL_ID="google/siglip2-base-patch16-256"
RESOURCES_DIR="$(cd "$(dirname "$0")/.." && pwd)/Resources"
HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}/hub/models--google--siglip2-base-patch16-256/snapshots"

if [ ! -d "$HF_CACHE" ]; then
    cat >&2 <<EOM
error: SigLIP-2 model not found in HuggingFace cache.
       Expected: $HF_CACHE
       Fix:      cd ../model-conversion && python convert_siglip2.py
                 (this fetches the model once; subsequent runs are cached)
EOM
    exit 1
fi

SNAPSHOT=$(ls "$HF_CACHE" | head -1)
SRC_DIR="$HF_CACHE/$SNAPSHOT"

mkdir -p "$RESOURCES_DIR"

for f in tokenizer.json tokenizer_config.json special_tokens_map.json; do
    src=$(readlink -f "$SRC_DIR/$f" 2>/dev/null || readlink "$SRC_DIR/$f")
    if [ -z "$src" ] || [ ! -f "$src" ]; then
        echo "error: $f missing in HF cache at $SRC_DIR/$f" >&2
        exit 1
    fi
    cp "$src" "$RESOURCES_DIR/$f"
    echo "  $f → Resources/  ($(wc -c < "$RESOURCES_DIR/$f") bytes)"
done

echo ""
echo "Done. Next: xcodegen generate && xcodebuild -scheme ValueGuardApp build"
