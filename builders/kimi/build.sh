#!/usr/bin/env bash

set -euo pipefail

OUT="${OUTPUT_DIR:-.}"
BUNDLE_DIR="$OUT/kimi-cli-offline"
mkdir -p "$BUNDLE_DIR/wheels"

curl -sLo "$BUNDLE_DIR/uv.tar.gz" \
    "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz"
tar xzf "$BUNDLE_DIR/uv.tar.gz" -C "$BUNDLE_DIR" --strip-components=1 uv-x86_64-unknown-linux-gnu/uv
chmod +x "$BUNDLE_DIR/uv"
rm "$BUNDLE_DIR/uv.tar.gz"

"$BUNDLE_DIR/uv" python install 3.13
"$BUNDLE_DIR/uv" venv --python 3.13 --seed "$BUNDLE_DIR/.build-venv"
"$BUNDLE_DIR/.build-venv/bin/pip" download kimi-cli \
    --prefer-binary \
    -d "$BUNDLE_DIR/wheels"
rm -rf "$BUNDLE_DIR/.build-venv"

cp install.sh "$BUNDLE_DIR/"
chmod +x "$BUNDLE_DIR/install.sh"

tar czf "$OUT/kimi-cli-offline.tar.gz" -C "$OUT" kimi-cli-offline
