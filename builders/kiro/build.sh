#!/usr/bin/env bash

# Kiro CLI offline bundle builder — x64 Linux only.
#
# The upstream installer (https://cli.kiro.dev/install) resolves a manifest and
# downloads a ~290 MB tarball whose bundled install.sh copies three binaries
# onto PATH and then runs `kiro-cli setup` (network/integration setup we can't
# and don't want to run offline). This builder strips that down to just the
# executables:
#   1. download the pinned headless tarball,
#   2. keep the three real ELF binaries the installer places on PATH
#      (kiro-cli, kiro-cli-chat, kiro-cli-term) — dropping install.sh, README,
#      BUILD-INFO, and the legacy q/qchat wrappers that hardcode ~/.local/bin,
#   3. strip debug symbols (~290 MB -> ~70 MB; these are unstripped Rust release
#      builds),
#   4. repackage so the Docker image consumes them like any other binary
#      artifact (extract + copy to /usr/local/bin) with no install script.

set -euo pipefail

OUT="${OUTPUT_DIR:-.}"
VERSION="${VERSION:?VERSION is required}"
ARTIFACT="${ARTIFACT:-kiro-cli-offline.tar.xz}"

TARBALL="kirocli-x86_64-linux.tar.xz"
URL="https://prod.download.cli.kiro.dev/stable/${VERSION}/${TARBALL}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "  downloading $URL"
curl -fsSL -o "$WORK/$TARBALL" "$URL"
tar xJf "$WORK/$TARBALL" -C "$WORK"

BUNDLE_DIR="$WORK/kiro-cli-offline"
mkdir -p "$BUNDLE_DIR"

for b in kiro-cli kiro-cli-chat kiro-cli-term; do
    cp "$WORK/kirocli/bin/$b" "$BUNDLE_DIR/$b"
    strip --strip-unneeded "$BUNDLE_DIR/$b"
    chmod 755 "$BUNDLE_DIR/$b"
done

mkdir -p "$OUT"
tar cJf "$OUT/$ARTIFACT" -C "$WORK" kiro-cli-offline
echo "  wrote $OUT/$ARTIFACT"
