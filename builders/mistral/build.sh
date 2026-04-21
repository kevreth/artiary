#!/usr/bin/env bash

set -euo pipefail

OUT="${OUTPUT_DIR:-.}"
BUNDLE_DIR="$OUT/mistral-vibe-offline"
mkdir -p "$BUNDLE_DIR/wheels"

curl -sLo "$BUNDLE_DIR/uv.tar.gz" \
    "https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz"
tar xzf "$BUNDLE_DIR/uv.tar.gz" -C "$BUNDLE_DIR" --strip-components=1 uv-x86_64-unknown-linux-gnu/uv
chmod +x "$BUNDLE_DIR/uv"
rm "$BUNDLE_DIR/uv.tar.gz"

# Option A: Download from PyPI (if published)
pip download -q mistral-vibe --only-binary :all: --ignore-requires-python \
    --python-version 3.13 --platform manylinux_2_17_x86_64 \
    -d "$BUNDLE_DIR/wheels"
# Rename the main wheel for easy reference
cp "$BUNDLE_DIR/wheels"/mistral_vibe-*.whl "$BUNDLE_DIR/mistral-vibe.whl" 2>/dev/null || true

# Option B: If it's GitHub-only, clone and build wheel
# git clone --depth 1 https://github.com/mistralai/mistral-vibe.git /tmp/mistral-vibe-src
# cd /tmp/mistral-vibe-src
# python -m build --wheel
# cp dist/*.whl "$BUNDLE_DIR/mistral-vibe.whl"

cp install.sh "$BUNDLE_DIR/"
chmod +x "$BUNDLE_DIR/install.sh"

tar czf "$OUT/mistral-vibe-offline.tar.gz" -C "$OUT" mistral-vibe-offline
