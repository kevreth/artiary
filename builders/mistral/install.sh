#!/usr/bin/env bash

# Mistral Vibe Offline Installer — x64 Linux only
# Zero internet required after download

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORIGINAL_PATH="${PATH}"

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
    
    # Make available immediately
    export PATH="$HOME/.local/bin:$PATH"
    
    success "uv installed to $uv_dest"
}

function install_vibe() {
    local vibe_pkg
    vibe_pkg=$(ls "$SCRIPT_DIR"/wheels/mistral_vibe-*.whl 2>/dev/null | head -n1)
    local vibe_dir="$SCRIPT_DIR/mistral-vibe"
    
    # Ensure uv is in PATH
    export PATH="$HOME/.local/bin:$PATH"
    
    if [[ -f "$vibe_pkg" ]]; then
        info "Installing from wheel: $vibe_pkg"

        # If you have cached wheels directory, use --find-links
        if [[ -d "$SCRIPT_DIR/wheels" ]]; then
            uv tool install --offline --find-links "$SCRIPT_DIR/wheels" --python 3.13 "$vibe_pkg"
        else
            uv tool install --offline --python 3.13 "$vibe_pkg"
        fi

    elif [[ -d "$vibe_dir" ]]; then
        info "Installing from source directory: $vibe_dir"
        uv tool install --offline --python 3.13 "$vibe_dir"
    else
        error "No mistral-vibe package found in bundle"
        error "Expected: $vibe_pkg or $vibe_dir"
        exit 1
    fi
    
    success "mistral-vibe installed"
}

function verify_installation() {
    local uv_bin_dir
    uv_bin_dir=$(uv tool dir --bin 2>/dev/null || true)
    
    if [[ -n "$(command -v vibe 2>/dev/null)" ]]; then
        success "vibe is available in PATH"
        echo "Run: vibe"
    elif [[ -n "$uv_bin_dir" && -x "$uv_bin_dir/vibe" ]]; then
        warning "vibe installed but not in PATH"
        echo "Add this to your ~/.bashrc or ~/.profile:"
        echo "  export PATH=\"$uv_bin_dir:\$PATH\""
    else
        error "Installation may have failed — vibe not found"
        exit 1
    fi
}

function main() {
    echo "╔════════════════════════════════════╗"
    echo "║   Mistral Vibe OFFLINE Installer   ║"
    echo "║        x64 Linux Target            ║"
    echo "╚════════════════════════════════════╝"
    echo
    
    # Check platform
    if [[ "$(uname -m)" != "x86_64" || "$(uname -s)" != "Linux" ]]; then
        error "This bundle is for x86_64 Linux only"
        exit 1
    fi
    
    # Install uv if missing
    if ! command -v uv &> /dev/null; then
        install_uv
    else
        info "uv already present: $(uv --version)"
    fi
    
    # Install mistral-vibe
    install_vibe
    
    # Verify
    verify_installation
}

main
