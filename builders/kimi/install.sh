#!/usr/bin/env bash

# Kimi CLI Offline Installer — x64 Linux only
# Zero internet required after download

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

function info() { echo -e "${BLUE}[INFO]${NC} $1"; }
function success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
function error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
function warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

function install_uv() {
    local uv_src="$SCRIPT_DIR/uv"
    local uv_dest="$HOME/.local/bin/uv"

    if [[ ! -f "$uv_src" ]]; then
        error "Missing bundled uv binary at $uv_src"
        exit 1
    fi

    mkdir -p "$(dirname "$uv_dest")"
    cp "$uv_src" "$uv_dest"
    chmod +x "$uv_dest"

    export PATH="$HOME/.local/bin:$PATH"

    success "uv installed to $uv_dest"
}

function install_kimi() {
    local kimi_pkg
    kimi_pkg=$(ls "$SCRIPT_DIR"/wheels/kimi_cli-*.whl 2>/dev/null | head -n1)

    export PATH="$HOME/.local/bin:$PATH"

    if [[ -z "$kimi_pkg" ]]; then
        error "No kimi-cli wheel found in $SCRIPT_DIR/wheels/"
        exit 1
    fi

    info "Installing from wheel: $kimi_pkg"
    uv tool install --offline --find-links "$SCRIPT_DIR/wheels" --python 3.13 "$kimi_pkg"

    success "kimi-cli installed"
}

function verify_installation() {
    local uv_bin_dir
    uv_bin_dir=$(uv tool dir --bin 2>/dev/null || true)

    if [[ -n "$(command -v kimi 2>/dev/null)" ]]; then
        success "kimi is available in PATH"
        echo "Run: kimi"
    elif [[ -n "$uv_bin_dir" && -x "$uv_bin_dir/kimi" ]]; then
        warning "kimi installed but not in PATH"
        echo "Add this to your ~/.bashrc or ~/.profile:"
        echo "  export PATH=\"$uv_bin_dir:\$PATH\""
    else
        error "Installation may have failed — kimi not found"
        exit 1
    fi
}

function main() {
    echo "╔════════════════════════════════════╗"
    echo "║     Kimi CLI OFFLINE Installer     ║"
    echo "║        x64 Linux Target            ║"
    echo "╚════════════════════════════════════╝"
    echo

    if [[ "$(uname -m)" != "x86_64" || "$(uname -s)" != "Linux" ]]; then
        error "This bundle is for x86_64 Linux only"
        exit 1
    fi

    if ! command -v uv &> /dev/null; then
        install_uv
    else
        info "uv already present: $(uv --version)"
    fi

    install_kimi

    verify_installation
}

main
