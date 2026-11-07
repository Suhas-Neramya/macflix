#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOSITORY_ROOT="$(cd "$PROJECT_ROOT/.." && pwd)"
BUILD_DIR="${MACFLIX_REBUILD_BUILD_DIR:-$PROJECT_ROOT/build}"
OUTPUT="$REPOSITORY_ROOT/Releases/Macflix-0.2.2-Rebuild-AppleSilicon.dmg"
SOURCE_OUTPUT="$REPOSITORY_ROOT/Releases/Macflix-0.2.2-Rebuild-Source.zip"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macflix-rebuild-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

bash "$PROJECT_ROOT/bin/run_tests.sh"
bash "$PROJECT_ROOT/bin/build_and_bundle.sh"
mkdir -p "$STAGING_DIR/volume" "$REPOSITORY_ROOT/Releases"
ditto --norsrc --noextattr "$BUILD_DIR/Macflix.app" "$STAGING_DIR/volume/Macflix.app"
ln -s /Applications "$STAGING_DIR/volume/Applications"
codesign --verify --deep --strict "$STAGING_DIR/volume/Macflix.app"
hdiutil create -volname Macflix -srcfolder "$STAGING_DIR/volume" \
    -format UDZO -fs HFS+ "$STAGING_DIR/Macflix.dmg"
hdiutil verify "$STAGING_DIR/Macflix.dmg"

SOURCE_DIR="$STAGING_DIR/source/Macflix-0.2.2-Rebuild"
mkdir -p "$SOURCE_DIR/Tests"
for folder in Sources Resources bin; do cp -R "$PROJECT_ROOT/$folder" "$SOURCE_DIR/$folder"; done
for test in "$PROJECT_ROOT"/Tests/*; do
    [[ -f "$test" ]] && cp "$test" "$SOURCE_DIR/Tests/"
done
cp "$PROJECT_ROOT/LICENSE" "$SOURCE_DIR/LICENSE"
cp "$PROJECT_ROOT/.gitignore" "$SOURCE_DIR/.gitignore"
cp "$PROJECT_ROOT/README.md" "$SOURCE_DIR/README.md"
ditto -c -k --norsrc --noextattr --keepParent "$SOURCE_DIR" "$STAGING_DIR/Macflix-0.2.2-Rebuild-Source.zip"

# Publish only completed, verified versioned outputs.
cp "$STAGING_DIR/Macflix.dmg" "$OUTPUT.new"
mv -f "$OUTPUT.new" "$OUTPUT"
cp "$STAGING_DIR/Macflix-0.2.2-Rebuild-Source.zip" "$SOURCE_OUTPUT.new"
mv -f "$SOURCE_OUTPUT.new" "$SOURCE_OUTPUT"
printf 'Installer: %s\n' "$OUTPUT"
printf 'Source: %s\n' "$SOURCE_OUTPUT"
