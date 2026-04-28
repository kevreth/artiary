#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUTPUT_DIR:-.}"
BUNDLE_DIR="$OUT/playwright-chromium-offline"
VERSIONS="$SCRIPT_DIR/../../versions.yml"
BASE_IMAGE=$(yq '.image.node' "$VERSIONS")

mkdir -p "$BUNDLE_DIR"

CONTAINER=$(docker run -d "$BASE_IMAGE" sleep 600)
trap "docker rm -f $CONTAINER >/dev/null 2>&1" EXIT

echo "==> Installing playwright in container"
docker exec "$CONTAINER" npm install -g playwright

echo "==> Snapshotting pre-install apt state"
docker exec "$CONTAINER" dpkg --get-selections > /tmp/pw-before.txt

echo "==> Running playwright install --with-deps chromium"
docker exec "$CONTAINER" bash -c "playwright install --with-deps chromium"

echo "==> Capturing apt packages added by --with-deps"
docker exec "$CONTAINER" dpkg --get-selections > /tmp/pw-after.txt
comm -13 <(sort /tmp/pw-before.txt) <(sort /tmp/pw-after.txt) \
  | awk '{print $1}' > "$OUT/playwright-apt-deps.txt"
COUNT=$(wc -l < "$OUT/playwright-apt-deps.txt")
echo "  Captured $COUNT packages → $(realpath "$OUT/playwright-apt-deps.txt")"
echo
echo "  Add these to the apt: section of versions.yml, then run 'make freeze':"
sed 's/^/    - /' "$OUT/playwright-apt-deps.txt"
echo

echo "==> Copying Chromium browser binaries"
docker cp "$CONTAINER:/root/.cache/ms-playwright" "$BUNDLE_DIR/ms-playwright"

PW_VERSION=$(docker exec "$CONTAINER" \
  node -e "console.log(require('/usr/local/lib/node_modules/playwright/package.json').version)" \
  2>/dev/null || echo "unknown")
echo "  playwright version: $PW_VERSION"

cp "$SCRIPT_DIR/install.sh" "$BUNDLE_DIR/"
chmod +x "$BUNDLE_DIR/install.sh"

tar czf "$OUT/playwright-chromium-offline.tar.gz" -C "$OUT" playwright-chromium-offline
rm -rf "$BUNDLE_DIR"
echo "==> Built playwright-chromium-offline.tar.gz"
