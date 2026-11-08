#!/usr/bin/env bash
set -euo pipefail

DEPENDENCY_DIR="${1:?Build dependency directory is required}"
VERSION="2.10.1"
SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
ARCHIVE="$DEPENDENCY_DIR/Sparkle-$VERSION.tar.xz"
SPARKLE_DIR="$DEPENDENCY_DIR/Sparkle-$VERSION"

mkdir -p "$DEPENDENCY_DIR"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --silent --show-error \
        "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
        --output "$ARCHIVE.new"
    mv "$ARCHIVE.new" "$ARCHIVE"
fi
echo "$SHA256  $ARCHIVE" | shasum -a 256 --check --status || {
    rm -f "$ARCHIVE"
    echo 'Sparkle archive checksum mismatch.' >&2
    exit 1
}
if [[ ! -d "$SPARKLE_DIR/Sparkle.framework" ]]; then
    rm -rf "$SPARKLE_DIR.new"
    mkdir -p "$SPARKLE_DIR.new"
    tar -xf "$ARCHIVE" -C "$SPARKLE_DIR.new"
    mv "$SPARKLE_DIR.new" "$SPARKLE_DIR"
fi
printf '%s\n' "$SPARKLE_DIR"
