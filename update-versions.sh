#!/bin/bash
set -euo pipefail

VERSIONS_FILE="versions.yml"

usage() {
  cat <<'EOF'
Usage: update-versions.sh [OPTIONS]

Check for outdated packages in versions.yml and update them.

OPTIONS:
  -i, --interactive    Interactive mode (fzf/menu to select packages)
  -u, --update-all     Update all outdated packages without prompting
  -h, --help           Show this help message.

EXAMPLES:
  ./update-versions.sh              # List outdated packages
  ./update-versions.sh -i           # Interactive selection (fzf)
  ./update-versions.sh -u           # Update all outdated packages
EOF
}

warn() {
  echo "WARNING: $*" >&2
}

check_docker_image() {
  local base current image_name tag repo token digest
  base=$(yq '.image.base' "$VERSIONS_FILE")
  current=$(yq '.image.version // ""' "$VERSIONS_FILE")
  image_name=$(echo "$base" | cut -d: -f1)
  tag=$(echo "$base" | cut -d: -f2-)

  if [[ ! "$image_name" =~ / ]]; then
    repo="library/$image_name"
  else
    repo="$image_name"
  fi

  token=$(curl -fsS --max-time 10 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
    | jq -er '.token') || return 1
  digest=$(curl -fsSI --max-time 10 -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" \
    | grep -i "docker-content-digest" | awk '{print $2}' | tr -d '\r') || return 1

  if [ -n "$digest" ] && [ "$current" != "$digest" ]; then
    echo "image|image.base|$current -> $digest"
  fi
}

check_npm_packages() {
  local entries latest
  entries=$(yq '.npm // {} | to_entries[] | .key + "|" + (.value | tostring)' "$VERSIONS_FILE") || return 1

  while IFS='|' read -r pkg current; do
    [ -z "$pkg" ] && continue
    latest=$(npm view "$pkg" version) || return 1
    if [ -n "$latest" ] && [ "$current" != "$latest" ]; then
      echo "npm|$pkg|$current -> $latest"
    fi
  done <<< "$entries"
}

check_pip_packages() {
  local entries latest
  entries=$(yq '.pip // {} | to_entries[] | .key + "|" + (.value | tostring)' "$VERSIONS_FILE") || return 1

  while IFS='|' read -r pkg current; do
    [ -z "$pkg" ] && continue
    latest=$(curl -fsS --max-time 10 "https://pypi.org/pypi/$pkg/json" | jq -er '.info.version') || return 1
    if [ -n "$latest" ] && [ "$current" != "$latest" ]; then
      echo "pip|$pkg|$current -> $latest"
    fi
  done <<< "$entries"
}

check_script_packages() {
  local entries latest
  entries=$(yq '.scripts // {} | to_entries[] | .key + "|" + (.value.version | tostring)' "$VERSIONS_FILE") || return 1

  while IFS='|' read -r script current; do
    [ -z "$script" ] && continue
    latest=""

    case "$script" in
      claude)
        latest=$(curl -fsS --max-time 10 https://downloads.claude.ai/claude-code-releases/latest) || return 1
        ;;
      gh)
        latest=$(curl -fsS --max-time 10 "https://api.github.com/repos/cli/cli/releases/latest" | jq -er '.tag_name' | sed 's/^v//') || return 1
        ;;
      yq)
        latest=$(curl -fsS --max-time 10 "https://api.github.com/repos/mikefarah/yq/releases/latest" | jq -er '.tag_name' | sed 's/^v//') || return 1
        ;;
      jq)
        latest=$(curl -fsS --max-time 10 "https://api.github.com/repos/jqlang/jq/releases/latest" | jq -er '.tag_name' | sed 's/^jq-//') || return 1
        ;;
      goose)
        latest=$(curl -fsS --max-time 10 "https://api.github.com/repos/aaif-goose/goose/releases/latest" | jq -er '.tag_name' | sed 's/^v//') || return 1
        ;;
      copilot)
        latest=$(curl -fsS --max-time 10 "https://api.github.com/repos/github/copilot-cli/releases/latest" | jq -er '.tag_name' | sed 's/^v//') || return 1
        ;;
      factory-droid)
        latest=$(curl -fsS --max-time 10 https://app.factory.ai/cli | grep -o 'VER="[^"]*"' | cut -d'"' -f2) || return 1
        ;;
      kimi)
        latest=$(curl -fsS --max-time 10 "https://pypi.org/pypi/kimi-cli/json" | jq -er '.info.version') || return 1
        ;;
      mistral)
        latest=$(curl -fsS --max-time 10 "https://pypi.org/pypi/mistral-vibe/json" | jq -er '.info.version') || return 1
        ;;
      yarn)
        latest=$(curl -fsS --max-time 10 "https://api.github.com/repos/yarnpkg/berry/releases/latest" | jq -er '.tag_name' | sed 's/^v//;s/^@yarnpkg\/cli\///') || return 1
        ;;
    esac

    if [ -n "$latest" ] && [ "$current" != "$latest" ]; then
      echo "script|$script|$current -> $latest"
    fi
  done <<< "$entries"
}

collect_outdated() {
  local had_errors=0

  echo "Checking Docker image..." >&2
  if ! check_docker_image; then
    warn "failed to check Docker image"
    had_errors=1
  fi

  echo "Checking NPM packages..." >&2
  if ! check_npm_packages; then
    warn "failed to check NPM packages"
    had_errors=1
  fi

  echo "Checking PIP packages..." >&2
  if ! check_pip_packages; then
    warn "failed to check PIP packages"
    had_errors=1
  fi

  echo "Checking script packages..." >&2
  if ! check_script_packages; then
    warn "failed to check script packages"
    had_errors=1
  fi

  return "$had_errors"
}

format_outdated() {
  local items="$1"
  if [ -z "$items" ]; then
    return
  fi

  printf "%-10s %-40s %s\n" "TYPE" "PACKAGE" "UPDATE"
  printf "%-10s %-40s %s\n" "----" "-------" "------"

  echo "$items" | while IFS='|' read -r type name versions; do
    [ -z "$type" ] && continue
    local current latest
    current=$(echo "$versions" | awk '{print $1}')
    latest=$(echo "$versions" | awk '{print $NF}')
    printf "%-10s %-40s %s -> %s\n" "$type" "$name" "$current" "$latest"
  done
}

update_versions() {
  local selections="$1"

  echo "$selections" | while IFS='|' read -r type name versions; do
    [ -z "$type" ] && continue
    local latest
    latest=$(echo "$versions" | awk '{print $NF}')

    case "$type" in
      image)
        yq -i ".image.version = \"$latest\"" "$VERSIONS_FILE"
        ;;
      npm)
        yq -i ".npm[\"$name\"] = \"$latest\"" "$VERSIONS_FILE"
        ;;
      pip)
        yq -i ".pip[\"$name\"] = \"$latest\"" "$VERSIONS_FILE"
        ;;
      script)
        yq -i ".scripts.$name.version = \"$latest\"" "$VERSIONS_FILE"
        ;;
    esac

    echo "  Updated $type/$name: $latest"
  done
}

select_packages_fzf() {
  local items="$1"
  echo "$items" | fzf --multi \
    --header="Select packages to update (TAB toggle, ENTER confirm)"
}

select_packages_menu() {
  local items="$1"
  local lines
  mapfile -t lines <<< "$items"

  if [ ${#lines[@]} -eq 0 ]; then
    return
  fi

  echo "Select packages to update:"
  local i
  for ((i=0; i<${#lines[@]}; i++)); do
    local type name versions
    IFS='|' read -r type name versions <<< "${lines[$i]}"
    echo "  $((i+1))) $type/$name: $versions"
  done

  echo ""
  echo "Enter numbers to update (e.g., 1,3,5 or 'all'):"
  read -r input

  if [ "$input" = "all" ]; then
    echo "$items"
    return
  fi

  local selected=""
  local num
  for num in $(echo "$input" | tr ',' ' '); do
    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#lines[@]} ]; then
      selected="$selected${lines[$((num-1))]}"$'\n'
    fi
  done

  echo -n "$selected"
}

select_packages() {
  local items="$1"

  if command -v fzf &>/dev/null; then
    select_packages_fzf "$items"
  else
    select_packages_menu "$items"
  fi
}

main() {
  local interactive=false
  local update_all=false
  local had_check_errors=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      -i|--interactive) interactive=true ;;
      -u|--update-all) update_all=true ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
    shift
  done

  local outdated
  if ! outdated=$(collect_outdated); then
    had_check_errors=true
  fi

  if [ -z "$outdated" ]; then
    if [ "$had_check_errors" = true ]; then
      echo "Version check failed for one or more sources."
      exit 1
    fi
    echo "All packages are up to date!"
    exit 0
  fi

  echo ""
  format_outdated "$outdated"
  echo ""

  if [ "$had_check_errors" = true ]; then
    warn "some version sources could not be checked; results may be incomplete"
  fi

  local to_update=""

  if [ "$update_all" = true ]; then
    to_update="$outdated"
  elif [ "$interactive" = true ]; then
    to_update=$(select_packages "$outdated")
  else
    echo "Run with -i for interactive selection or -u to update all."
    exit 0
  fi

  if [ -z "$to_update" ]; then
    echo "No packages selected for update."
    exit 0
  fi

  echo "Updating packages..."
  update_versions "$to_update"

  echo ""
  echo "Done! Run 'make fetch' to download new artifacts."
}

main "$@"
