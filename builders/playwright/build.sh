#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUTPUT_DIR:-.}"
BUNDLE_DIR="$OUT/playwright-chromium-offline"
VERSIONS="${ARTIARY_VERSIONS:-${XDG_DATA_HOME:-$HOME/.local/share}/artiary/versions.yml}"
BASE_IMAGE=$(yq '.image.base' "$VERSIONS")

mkdir -p "$BUNDLE_DIR"

CONTAINER=$(docker run -d "$BASE_IMAGE" sleep 600)
trap "docker rm -f $CONTAINER >/dev/null 2>&1" EXIT

echo "==> Installing playwright in container"
docker exec "$CONTAINER" npm install -g playwright

echo "==> Snapshotting pre-install apt state"
docker exec "$CONTAINER" dpkg --get-selections > /tmp/pw-before.txt

echo "==> Running playwright install-deps chromium"
docker exec "$CONTAINER" bash -c "playwright install-deps chromium"

echo "==> Capturing apt packages added by install-deps"
docker exec "$CONTAINER" dpkg --get-selections > /tmp/pw-after.txt
comm -13 <(sort /tmp/pw-before.txt) <(sort /tmp/pw-after.txt) \
  | awk '{print $1}' > "$OUT/playwright-apt-deps.txt"
COUNT=$(wc -l < "$OUT/playwright-apt-deps.txt")
echo "  Captured $COUNT packages → $(realpath "$OUT/playwright-apt-deps.txt")"

if [ "$COUNT" -gt 0 ]; then
  echo "==> Downloading .deb packages for offline installation"

  cat > /tmp/download-debs.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
mkdir -p /tmp/debs && cd /tmp/debs
apt-get update -qq 2>/dev/null || true
{
  while read -r pkg; do
    apt-cache depends --recurse --no-recommends --no-suggests \
      --no-conflicts --no-breaks --no-replaces --no-enhances "$pkg" \
      2>/dev/null | grep '^\w' | grep -v '^<' || true
  done
} | sort -u > /tmp/pw-all-deps.txt

while read -r pkg; do
  avail_ver=$(apt-cache show "$pkg" 2>/dev/null | awk 'BEGIN{v=""} /^Version:/{v=$2} /^Filename:/{print v; exit}')
  [ -z "$avail_ver" ] && continue
  apt-get download "${pkg}=${avail_ver}" 2>/dev/null || true
  for f in *_*%3a*.deb; do
    [ -f "$f" ] || continue
    newname=$(echo "$f" | sed 's/%3a/:/g')
    mv "$f" "$newname" 2>/dev/null || true
  done
done < /tmp/pw-all-deps.txt
SCRIPT

  docker cp /tmp/download-debs.sh "$CONTAINER:/tmp/download-debs.sh"
  docker cp "$OUT/playwright-apt-deps.txt" "$CONTAINER:/tmp/apt-deps.txt"
  docker exec "$CONTAINER" bash /tmp/download-debs.sh

  docker cp "$CONTAINER:/tmp/debs" "$BUNDLE_DIR/"
  DEB_COUNT=$(ls -1 "$BUNDLE_DIR/debs"/*.deb 2>/dev/null | wc -l)
  echo "  Downloaded $DEB_COUNT .deb files"

  cp "$OUT/playwright-apt-deps.txt" "$BUNDLE_DIR/apt-deps.txt"
fi

echo "==> Running playwright install chromium"
docker exec "$CONTAINER" bash -c "playwright install chromium"

echo "==> Copying Chromium browser binaries"
docker cp "$CONTAINER:/root/.cache/ms-playwright" "$BUNDLE_DIR/ms-playwright"

PW_VERSION=$(docker exec "$CONTAINER" \
  node -e "console.log(require('/usr/local/lib/node_modules/playwright/package.json').version)" \
  2>/dev/null || echo "unknown")
echo "  playwright version: $PW_VERSION"

cp "$SCRIPT_DIR/install.sh" "$BUNDLE_DIR/"
chmod +x "$BUNDLE_DIR/install.sh"

tar czf "$OUT/${ARTIFACT:-playwright-chromium-offline.tar.gz}" -C "$OUT" playwright-chromium-offline
rm -rf "$BUNDLE_DIR"
echo "==> Built ${ARTIFACT:-playwright-chromium-offline.tar.gz}"

if [ "$COUNT" -gt 0 ]; then
  echo
  echo "  Consider adding these packages to versions.yml apt: section:"
  sed 's/^/    - /' "$OUT/playwright-apt-deps.txt"
fi
