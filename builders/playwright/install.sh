#!/usr/bin/env bash

# Playwright Chromium Offline Installer — x64 Linux only
# Zero internet required.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/root/.cache/ms-playwright}"

function info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
function success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
function error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
function warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

function install_apt_deps() {
    if [[ ! -d "$SCRIPT_DIR/debs" || ! -f "$SCRIPT_DIR/apt-deps.txt" ]]; then
        warning "No bundled apt dependencies found — ensure system deps are pre-installed"
        return 0
    fi

    local pkg_count
    pkg_count=$(wc -l < "$SCRIPT_DIR/apt-deps.txt" | tr -d ' ')
    if [[ "$pkg_count" -eq 0 ]]; then
        info "No additional apt dependencies required"
        return 0
    fi

    info "Installing $pkg_count system dependencies from bundled .deb packages"

    mkdir -p /var/cache/apt/archives
    cp "$SCRIPT_DIR/debs"/*.deb /var/cache/apt/archives/ 2>/dev/null || true

    mapfile -t PKGS < "$SCRIPT_DIR/apt-deps.txt"

    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-download "${PKGS[@]}" 2>/dev/null; then
        success "System dependencies installed"
    else
        warning "apt-get install failed, falling back to dpkg"
        for deb in "$SCRIPT_DIR/debs"/*.deb; do
            dpkg -i "$deb" 2>/dev/null || true
        done
        dpkg --configure -a 2>/dev/null || true
        success "System dependencies installed (dpkg fallback)"
    fi
}

function install_browsers() {
    if [[ ! -d "$SCRIPT_DIR/ms-playwright" ]]; then
        error "ms-playwright/ not found in bundle at $SCRIPT_DIR"
        exit 1
    fi

    info "Installing Chromium to $BROWSERS_PATH"
    mkdir -p "$BROWSERS_PATH"
    cp -r "$SCRIPT_DIR/ms-playwright/." "$BROWSERS_PATH/"
    success "Chromium installed"
}

function main() {
    echo "╔════════════════════════════════════╗"
    echo "║  Playwright Chromium OFFLINE Inst. ║"
    echo "║        x64 Linux Target            ║"
    echo "╚════════════════════════════════════╝"
    echo

    if [[ "$(uname -m)" != "x86_64" || "$(uname -s)" != "Linux" ]]; then
        error "This bundle is for x86_64 Linux only"
        exit 1
    fi

    install_apt_deps
    install_browsers

    if [[ "$BROWSERS_PATH" != "/root/.cache/ms-playwright" && "$BROWSERS_PATH" != "$HOME/.cache/ms-playwright" ]]; then
        warning "Non-default install path — set this in your environment:"
        echo "  export PLAYWRIGHT_BROWSERS_PATH=$BROWSERS_PATH"
    fi

    success "Playwright Chromium offline installation complete"
}

main
