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

BASE_IMG=$(yq '.image.base' "$VERSIONS" | tr -d '"')
VER=$(yq '.image.version // ""' "$VERSIONS" | tr -d '"')
BASE_IMAGE="${BASE_IMG}${VER:+@$VER}"
IMAGE_TAR="$IMG_DIR/$(echo "$BASE_IMG" | tr ':' '-')${VER:+-${VER#sha256:}}.tar"

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

# Prune old image tarballs
for f in "$IMG_DIR"/*.tar; do
  [ -f "$f" ] || continue
  [ "$f" = "$IMAGE_TAR" ] && continue
  rm -f "$f"
done

mapfile -t APT_PACKAGES < <(yq '.apt[] | sub("=.*"; "")' "$VERSIONS" | tr -d '"')

echo "==> Fetching APT packages"

if [ "$SUDO_AVAILABLE" = true ]; then
  LISTS_DIR="$APT_DIR/lists"
  mkdir -p "$LISTS_DIR/partial"
  chmod 755 "$LISTS_DIR" "$LISTS_DIR/partial"

  # Derive the Debian release from the image name (e.g. node:24-trixie → trixie)
  DISTRO=$(yq '.image.base' "$VERSIONS" | tr -d '"' | grep -oE 'trixie|bookworm|bullseye|buster|sid' | head -1)

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
    avail_ver=$(apt-cache -c "$APT_CONF" show "$pkg" 2>/dev/null | \
      awk 'BEGIN{v=""} /^Version:/{v=$2} /^Filename:/{print v; exit}')
    [ -z "$avail_ver" ] && continue
    deb_ver=$(echo "$avail_ver" | sed 's/:/%3a/g')
    ls "${base}_${deb_ver}_"*.deb &>/dev/null && continue
    apt-get -c "$APT_CONF" download "${pkg}=${avail_ver}" 2>/dev/null || true
  done < pkglist.txt
  after=$(ls ./*.deb 2>/dev/null | wc -l)
  new=$((after - before))
  [ "$new" -gt 0 ] && echo "  Downloaded $new packages"

  rm -f "$APT_DIR/pkglist.txt"

  # Prune old apt .deb files not in current dependency tree
  keep_pkg_args=()
  for pkg in "${APT_PACKAGES[@]}"; do
    keep_pkg_args+=("$pkg")
  done
  if [ ${#keep_pkg_args[@]} -gt 0 ]; then
    TMP_LIST=$(mktemp)
    for pkg in "${keep_pkg_args[@]}"; do
      apt-cache -c "$APT_CONF" depends --recurse --no-recommends --no-suggests \
        --no-conflicts --no-breaks --no-replaces --no-enhances "$pkg" \
        2>/dev/null | grep '^\w' | grep -v '^<'
    done | sort -u > "$TMP_LIST"
    for f in "$APT_DIR"/*.deb; do
      [ -f "$f" ] || continue
      base=$(dpkg-deb -f "$f" Package 2>/dev/null || echo "$f" | sed 's/_.*//')
      grep -q "^${base}$" "$TMP_LIST" || rm -f "$f"
    done
    rm -f "$TMP_LIST"
  fi
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
  done < <(yq '.npm | to_entries[] | .key + "@" + .value' "$VERSIONS" | tr -d '"')
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
  done < <(yq '.npm | to_entries[] | .key + "@" + .value' "$VERSIONS" | tr -d '"')
else
  echo "  WARNING: Docker and npm not available, skipping npm packages"
fi

# Prune old npm tarballs
while IFS= read -r spec; do
  pkg_name="${spec%@*}"
  pkg_ver="${spec##*@}"
  tgz="$NPM_DIR/$(echo "$pkg_name" | sed 's|^@||; s|/|-|g')-${pkg_ver}.tgz"
  keep+=("$tgz")
done < <(yq '.npm | to_entries[] | .key + "@" + .value' "$VERSIONS" | tr -d '"')
for f in "$NPM_DIR"/*.tgz; do
  [ -f "$f" ] || continue
  found=false
  for k in "${keep[@]}"; do [ "$f" = "$k" ] && { found=true; break; }; done
  $found || rm -f "$f"
done

echo "==> Fetching pip packages"

if command -v python3 >/dev/null 2>&1 && python3 -m pip --version >/dev/null 2>&1; then
  while IFS= read -r spec; do
    before=$(ls "$PIP_DIR" | wc -l)
    python3 -m pip download -d "$PIP_DIR" -q "$spec" >/dev/null 2>&1 || echo "  WARNING: failed to download $spec"
    after=$(ls "$PIP_DIR" | wc -l)
    [ "$after" -gt "$before" ] && echo "  $spec"
  done < <(yq '.pip // {} | to_entries[] | .key + "==" + .value' "$VERSIONS" | tr -d '"')
else
  echo "  WARNING: python3 or pip not available, skipping pip packages"
fi

# Prune old pip packages
TMP_PIP=$(mktemp -d)
pip_specs=()
while IFS= read -r spec; do
  pip_specs+=("$spec")
done < <(yq '.pip // {} | to_entries[] | .key + "==" + .value' "$VERSIONS" | tr -d '"')
if [ ${#pip_specs[@]} -gt 0 ]; then
  for spec in "${pip_specs[@]}"; do
    python3 -m pip download -d "$TMP_PIP" -q "$spec" >/dev/null 2>&1 || true
  done
  for f in "$PIP_DIR"/*; do
    [ -f "$f" ] || continue
    base_f=$(basename "$f")
    [ -f "$TMP_PIP/$base_f" ] || rm -f "$f"
  done
fi
rm -rf "$TMP_PIP"

echo "==> Fetching scripts"

while IFS= read -r name; do
  version=$(yq ".scripts[\"${name}\"].version" "$VERSIONS" | tr -d '"')
  url=$(yq ".scripts[\"${name}\"].url // \"\"" "$VERSIONS" | tr -d '"')
  build=$(yq ".scripts[\"${name}\"].build // \"\"" "$VERSIONS" | tr -d '"')

  if [ -n "$url" ] && [ "$url" != "null" ]; then
    url=$(echo "$url" | sed "s/\${version}/${version}/g")
    out="$SCR_DIR/${name}-${version}"
    [ -f "$out" ] || curl -fsSL -o "$out" "$url"

  elif [ -n "$build" ] && [ "$build" != "null" ]; then
    artifact=$(yq ".scripts[\"${name}\"].artifact" "$VERSIONS" | tr -d '"')
    OUT_DIR="$ROOT/builders/$name"
    mkdir -p "$OUT_DIR"
    out="$OUT_DIR/$artifact"
    if [ ! -f "$out" ]; then
      echo "  $name"
      BUILD_DIR="$SCRIPT_DIR/$(dirname "$build")"
      (cd "$BUILD_DIR" && OUTPUT_DIR="$OUT_DIR" bash "$(basename "$build")")
    fi
  fi
done < <(yq '.scripts | keys[]' "$VERSIONS" | tr -d '"')

# Prune old scripts
keep_scr=()
while IFS= read -r name; do
  version=$(yq ".scripts[\"${name}\"].version" "$VERSIONS" | tr -d '"')
  url=$(yq ".scripts[\"${name}\"].url // \"\"" "$VERSIONS" | tr -d '"')
  build=$(yq ".scripts[\"${name}\"].build // \"\"" "$VERSIONS" | tr -d '"')
  if [ -n "$url" ] && [ "$url" != "null" ]; then
    keep_scr+=("$SCR_DIR/${name}-${version}")
  elif [ -n "$build" ] && [ "$build" != "null" ]; then
    artifact=$(yq ".scripts[\"${name}\"].artifact" "$VERSIONS" | tr -d '"')
    keep_scr+=("$ROOT/builders/$name/$artifact")
  fi
done < <(yq '.scripts | keys[]' "$VERSIONS" | tr -d '"')
for f in "$SCR_DIR"/*; do
  [ -f "$f" ] || continue
  found=false
  for k in "${keep_scr[@]}"; do [ "$f" = "$k" ] && { found=true; break; }; done
  $found || rm -f "$f"
done
for name in "$ROOT/builders"/*; do
  [ -d "$name" ] || continue
  bname=$(basename "$name")
  artifact=$(yq ".scripts[\"${bname}\"].artifact // \"\"" "$VERSIONS" | tr -d '"')
  for f in "$name"/*; do
    [ -f "$f" ] || continue
    [ -n "$artifact" ] && [ "$(basename "$f")" = "$artifact" ] && continue
    rm -f "$f"
  done
done

sync_manifest

echo "==> Done"
