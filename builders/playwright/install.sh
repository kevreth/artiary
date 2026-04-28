#!/usr/bin/env bash

# Playwright Chromium Offline Installer — x64 Linux only
# Zero internet required. Apt deps must already be installed.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/root/.cache/ms-playwright}"

function info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
function success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
function error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
function warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

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

    if [[ ! -d "$SCRIPT_DIR/ms-playwright" ]]; then
        error "ms-playwright/ not found in bundle at $SCRIPT_DIR"
        exit 1
    fi

    info "Installing Chromium to $BROWSERS_PATH"
    mkdir -p "$BROWSERS_PATH"
    cp -r "$SCRIPT_DIR/ms-playwright/." "$BROWSERS_PATH/"
    success "Chromium installed"

    if [[ "$BROWSERS_PATH" != "/root/.cache/ms-playwright" && "$BROWSERS_PATH" != "$HOME/.cache/ms-playwright" ]]; then
        warning "Non-default install path — set this in your environment:"
        echo "  export PLAYWRIGHT_BROWSERS_PATH=$BROWSERS_PATH"
    fi
}

main
