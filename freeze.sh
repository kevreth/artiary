#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSIONS="$SCRIPT_DIR/versions.yml"
MANIFEST="$SCRIPT_DIR/artifacts/manifest/versions.yml"

sync_manifest() {
  mkdir -p "$(dirname "$MANIFEST")"
  cp "$VERSIONS" "$MANIFEST"
}

echo "==> Freezing image digest..."
TAG=$(yq '.image.node' "$VERSIONS" | sed 's/@sha256:.*//')
DIGEST=$(docker inspect "$TAG" --format '{{index .RepoDigests 0}}' 2>/dev/null | sed 's/.*@//')
if [ -n "$DIGEST" ]; then
  yq -i ".image.node = \"${TAG}@${DIGEST}\"" "$VERSIONS"
  echo "    node: ${TAG}@${DIGEST}"
fi

echo "==> Freezing APT versions..."
PKGS=$(yq '.apt[] | sub("=.*"; "")' "$VERSIONS" | tr '\n' ' ')
docker run --rm "$TAG" sh -c "apt-get update -qq 2>/dev/null && apt-cache show $PKGS" \
  | awk '/^Package:/{pkg=$2} /^Version:/{print pkg "=" $2}' \
  > /tmp/apt-freeze.txt

while IFS= read -r entry; do
  pkg="${entry%%=*}"
  ver="${entry#*=}"
  yq -i "(.apt[] | select(split(\"=\")[0] == \"${pkg}\")) = \"${pkg}=${ver}\"" "$VERSIONS"
  echo "    ${pkg}=${ver}"
done < /tmp/apt-freeze.txt
rm -f /tmp/apt-freeze.txt

echo "==> Freezing npm versions..."
while IFS= read -r pkg; do
  ver=$(npm view "$pkg" version 2>/dev/null)
  [ -n "$ver" ] && yq -i ".npm[\"${pkg}\"] = \"${ver}\"" "$VERSIONS" && echo "    ${pkg}@${ver}"
done < <(yq '.npm | keys[]' "$VERSIONS")

echo "==> Freezing pip versions..."
while IFS= read -r pkg; do
  ver=$(python3 -c "import json, urllib.request; print(json.load(urllib.request.urlopen('https://pypi.org/pypi/$pkg/json'))['info']['version'])" 2>/dev/null)
  [ -n "$ver" ] && yq -i ".pip[\"${pkg}\"] = \"${ver}\"" "$VERSIONS" && echo "    ${pkg}==${ver}"
done < <(yq '.pip // {} | keys[]' "$VERSIONS")

sync_manifest

echo "==> Done. versions.yml updated."
