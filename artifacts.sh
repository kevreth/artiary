#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/artifacts"
APT_DIR="$ROOT/apt"
NPM_DIR="$ROOT/npm"
PIP_DIR="$ROOT/pip"
IMG_DIR="$ROOT/images"
SCR_DIR="$ROOT/scripts"
MANIFEST_DIR="$ROOT/manifest"

mkdir -p "$APT_DIR" "$NPM_DIR" "$PIP_DIR" "$IMG_DIR" "$SCR_DIR" "$MANIFEST_DIR"

VERSIONS="$SCRIPT_DIR/versions.yml"

sync_manifest() {
  cp "$VERSIONS" "$MANIFEST_DIR/versions.yml"
}

sync_manifest

BASE_IMAGE=$(yq '.image.node' "$VERSIONS")
IMAGE_TAR="$IMG_DIR/node.tar"

# Check if Docker is available
DOCKER_AVAILABLE=false
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  DOCKER_AVAILABLE=true
fi

# Check if sudo works for filesystem operations
SUDO_AVAILABLE=false
if command -v sudo >/dev/null 2>&1; then
  test_file="$APT_DIR/.sudo_test_$$"
  if sudo -n touch "$test_file" >/dev/null 2>&1 && sudo -n rm -f "$test_file" >/dev/null 2>&1; then
    SUDO_AVAILABLE=true
  fi
fi

echo "==> Fetching base image"
if [ ! -f "$IMAGE_TAR" ]; then
  if [ "$DOCKER_AVAILABLE" = true ]; then
    docker pull "$BASE_IMAGE"
    docker save -o "$IMAGE_TAR" "$BASE_IMAGE"
  else
    echo "  WARNING: Docker not available, cannot fetch base image"
  fi
fi

mapfile -t APT_PACKAGES < <(yq '.apt[] | sub("=.*"; "")' "$VERSIONS")

echo "==> Fetching APT packages"

if [ "$SUDO_AVAILABLE" = true ]; then
  LISTS_DIR="$APT_DIR/lists"
  mkdir -p "$LISTS_DIR/partial"
  chmod 755 "$LISTS_DIR" "$LISTS_DIR/partial"

  # Derive the Debian release from the image name (e.g. node:24-trixie → trixie)
  DISTRO=$(yq '.image.node' "$VERSIONS" | grep -oE 'trixie|bookworm|bullseye|buster|sid' | head -1)

  SOURCES_LIST=$(mktemp)
  APT_CONF=$(mktemp)
  trap "rm -f $SOURCES_LIST $APT_CONF" EXIT

  cat > "$SOURCES_LIST" << EOF
deb http://deb.debian.org/debian ${DISTRO} main
deb http://deb.debian.org/debian-security ${DISTRO}-security main
deb http://deb.debian.org/debian ${DISTRO}-updates main
EOF

  cat > "$APT_CONF" << EOF
Dir::Etc::sourcelist "$SOURCES_LIST";
Dir::Etc::sourceparts "/dev/null";
Dir::State::lists "$LISTS_DIR/";
APT::Sandbox::User "root";
EOF

  chmod 644 "$SOURCES_LIST" "$APT_CONF"

  sudo apt-get -c "$APT_CONF" update -qq
  sudo chown -R "$(id -u):$(id -g)" "$LISTS_DIR"

  # Resolve all recursive deps against the target distro
  {
    for pkg in "${APT_PACKAGES[@]}"; do
      apt-cache -c "$APT_CONF" depends --recurse --no-recommends --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances "$pkg" \
        2>/dev/null | grep '^\w' | grep -v '^<'
    done
  } | sort -u > "$APT_DIR/pkglist.txt"

  cd "$APT_DIR"
  before=$(ls ./*.deb 2>/dev/null | wc -l)
  while read -r pkg; do
    base="${pkg%%:*}"
    if ! ls "${base}"_*.deb &>/dev/null; then
      apt-get -c "$APT_CONF" download "$pkg" 2>/dev/null || true
    fi
  done < pkglist.txt
  after=$(ls ./*.deb 2>/dev/null | wc -l)
  new=$((after - before))
  [ "$new" -gt 0 ] && echo "  Downloaded $new packages"

  rm -f "$APT_DIR/pkglist.txt"
else
  echo "  WARNING: sudo not available, skipping apt package fetch"
  echo "  (using existing cached packages in $APT_DIR)"
fi

echo "==> Fetching npm packages"

if [ "$DOCKER_AVAILABLE" = true ]; then
  docker image inspect "$BASE_IMAGE" > /dev/null 2>&1 || docker load -i "$IMAGE_TAR"

  while IFS= read -r spec; do
    pkg_name="${spec%@*}"
    pkg_ver="${spec##*@}"
    tgz="$NPM_DIR/$(echo "$pkg_name" | sed 's|^@||; s|/|-|g')-${pkg_ver}.tgz"
    if [ ! -f "$tgz" ]; then
      echo "  $spec"
      CONTAINER=$(docker run -d "$BASE_IMAGE" sleep 600)
      docker exec "$CONTAINER" npm install -g --prefix /opt/npm-global "$spec"
      tmpdir=$(mktemp -d)
      docker cp "$CONTAINER:/opt/npm-global" "$tmpdir/"
      tar czf "$tgz" -C "$tmpdir" npm-global
      rm -rf "$tmpdir"
      docker rm -f "$CONTAINER"
    fi
  done < <(yq '.npm | to_entries[] | .key + "@" + .value' "$VERSIONS")
elif command -v npm >/dev/null 2>&1; then
  echo "  Docker not available; using host npm as fallback"
  while IFS= read -r spec; do
    pkg_name="${spec%@*}"
    pkg_ver="${spec##*@}"
    tgz="$NPM_DIR/$(echo "$pkg_name" | sed 's|^@||; s|/|-|g')-${pkg_ver}.tgz"
    if [ ! -f "$tgz" ]; then
      echo "  $spec"
      tmpdir=$(mktemp -d)
      npm install -g --prefix "$tmpdir/npm-global" "$spec"
      tar czf "$tgz" -C "$tmpdir" npm-global
      rm -rf "$tmpdir"
    fi
  done < <(yq '.npm | to_entries[] | .key + "@" + .value' "$VERSIONS")
else
  echo "  WARNING: Docker and npm not available, skipping npm packages"
fi

echo "==> Fetching pip packages"

if command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
  while IFS= read -r spec; do
    echo "  $spec"
    python3 -m pip download -d "$PIP_DIR" "$spec" 2>/dev/null || echo "  WARNING: failed to download $spec"
  done < <(yq '.pip // {} | to_entries[] | .key + "==" + .value' "$VERSIONS")
else
  echo "  WARNING: python3 or pip not available, skipping pip packages"
fi

echo "==> Fetching scripts"

while IFS= read -r name; do
  version=$(yq ".scripts.${name}.version" "$VERSIONS")
  url=$(yq ".scripts.${name}.url // \"\"" "$VERSIONS")
  build=$(yq ".scripts.${name}.build // \"\"" "$VERSIONS")

  if [ -n "$url" ] && [ "$url" != "null" ]; then
    url=$(echo "$url" | sed "s/\${version}/${version}/g")
    out="$SCR_DIR/${name}-${version}"
    [ -f "$out" ] || curl -fsSL -o "$out" "$url"

  elif [ -n "$build" ] && [ "$build" != "null" ]; then
    artifact=$(yq ".scripts.${name}.artifact" "$VERSIONS")
    OUT_DIR="$ROOT/builders/$name"
    mkdir -p "$OUT_DIR"
    out="$OUT_DIR/$artifact"
    if [ ! -f "$out" ]; then
      echo "  $name"
      BUILD_DIR="$SCRIPT_DIR/$(dirname "$build")"
      (cd "$BUILD_DIR" && OUTPUT_DIR="$OUT_DIR" bash "$(basename "$build")")
    fi
  fi
done < <(yq '.scripts | keys[]' "$VERSIONS")

sync_manifest

echo "==> Done"
