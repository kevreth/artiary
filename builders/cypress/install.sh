#!/usr/bin/env bash

# Cypress Offline Installer — x64 Linux only
# Zero internet required.
#
# Restores the bundled Cypress binary cache and repairs the execute bit that
# extraction drops (the binary at <cache>/<version>/Cypress/Cypress must be
# executable for `cypress verify` to pass). With the matching version present
# in the cache folder, a later `yarn install` / `cypress install` skips the
# network download entirely.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DEST="${CYPRESS_CACHE_FOLDER:-$HOME/.cache/Cypress}"

function info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
function success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
function error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
function warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

function install_binary() {
    if [[ ! -d "$SCRIPT_DIR/cypress-cache" ]]; then
        error "cypress-cache/ not found in bundle at $SCRIPT_DIR"
        exit 1
    fi

    info "Installing Cypress binary cache to $CACHE_DEST"
    mkdir -p "$CACHE_DEST"
    cp -r "$SCRIPT_DIR/cypress-cache/." "$CACHE_DEST/"

    # Extraction can drop the execute bit on the Electron binary; restore it.
    chmod -R u+x "$CACHE_DEST"
    success "Cypress binary installed"
}

function main() {
    echo "╔════════════════════════════════════╗"
    echo "║     Cypress OFFLINE Installer      ║"
    echo "║        x64 Linux Target            ║"
    echo "╚════════════════════════════════════╝"
    echo

    if [[ "$(uname -m)" != "x86_64" || "$(uname -s)" != "Linux" ]]; then
        error "This bundle is for x86_64 Linux only"
        exit 1
    fi

    install_binary

    if [[ "$CACHE_DEST" != "$HOME/.cache/Cypress" && "$CACHE_DEST" != "/root/.cache/Cypress" ]]; then
        warning "Non-default cache path — set this in your environment:"
        echo "  export CYPRESS_CACHE_FOLDER=$CACHE_DEST"
    fi

    success "Cypress offline installation complete"
}

main
