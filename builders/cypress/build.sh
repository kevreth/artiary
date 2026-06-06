#!/usr/bin/env bash
set -euo pipefail

# Cypress offline bundle builder.
#
# The cypress npm package downloads its platform binary (an Electron app)
# separately from the JS package, into a cache folder keyed by version
# (<cache>/<version>/Cypress/Cypress). That binary is the artifact we save here
# so the container never has to download it. We install cypress in a container
# built from the resolved base image, drive `cypress install` to populate a
# pinned cache folder, then bundle that cache for offline restoration.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUTPUT_DIR:-.}"
BUNDLE_DIR="$OUT/cypress-offline"
VERSIONS="${ARTIARY_VERSIONS:-${XDG_DATA_HOME:-$HOME/.local/share}/artiary/versions.yml}"
BASE_IMAGE=$(yq '.image.base' "$VERSIONS")

# Deterministic, $HOME-independent cache path captured inside the container.
CACHE_DIR="/opt/cypress-cache"

# The cypress npm spec — pinned when VERSION is resolved, floating otherwise.
if [ -n "${VERSION:-}" ] && [ "${VERSION:-}" != "null" ]; then
  CYPRESS_SPEC="cypress@${VERSION}"
else
  CYPRESS_SPEC="cypress"
fi

mkdir -p "$BUNDLE_DIR"

CONTAINER=$(docker run -d -e "CYPRESS_CACHE_FOLDER=$CACHE_DIR" "$BASE_IMAGE" sleep 600)
trap "docker rm -f $CONTAINER >/dev/null 2>&1" EXIT

echo "==> Installing $CYPRESS_SPEC in container"
docker exec "$CONTAINER" npm install -g "$CYPRESS_SPEC"

echo "==> Downloading Cypress platform binary into $CACHE_DIR"
# Explicit + idempotent: guarantees the binary is fetched even if the npm
# postinstall hook was skipped (e.g. CYPRESS_INSTALL_BINARY in the environment).
docker exec "$CONTAINER" cypress install

CY_VERSION=$(docker exec "$CONTAINER" \
  node -e "console.log(require('/usr/local/lib/node_modules/cypress/package.json').version)" \
  2>/dev/null || echo "unknown")
echo "  cypress version: $CY_VERSION"

echo "==> Copying Cypress binary cache"
docker cp "$CONTAINER:$CACHE_DIR" "$BUNDLE_DIR/cypress-cache"

cp "$SCRIPT_DIR/install.sh" "$BUNDLE_DIR/"
chmod +x "$BUNDLE_DIR/install.sh"

tar czf "$OUT/${ARTIFACT:-cypress-offline.tar.gz}" -C "$OUT" cypress-offline
rm -rf "$BUNDLE_DIR"
echo "==> Built ${ARTIFACT:-cypress-offline.tar.gz}"
