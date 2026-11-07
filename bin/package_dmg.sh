#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${MACFLIX_REBUILD_BUILD_DIR:-$PROJECT_ROOT/build}"
RELEASE_DIR="${MACFLIX_RELEASE_DIR:-$PROJECT_ROOT/dist}"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$PROJECT_ROOT/Resources/Info.plist")"
DMG_NAME="Macflix-$APP_VERSION-Rebuild-AppleSilicon.dmg"
SOURCE_NAME="Macflix-$APP_VERSION-Rebuild-Source.zip"
OUTPUT="$RELEASE_DIR/$DMG_NAME"
SOURCE_OUTPUT="$RELEASE_DIR/$SOURCE_NAME"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macflix-rebuild-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

bash "$PROJECT_ROOT/bin/run_tests.sh"
bash "$PROJECT_ROOT/bin/build_and_bundle.sh"
mkdir -p "$STAGING_DIR/volume" "$RELEASE_DIR"
ditto --norsrc --noextattr "$BUILD_DIR/Macflix.app" "$STAGING_DIR/volume/Macflix.app"
ln -s /Applications "$STAGING_DIR/volume/Applications"
codesign --verify --deep --strict "$STAGING_DIR/volume/Macflix.app"
hdiutil create -volname Macflix -srcfolder "$STAGING_DIR/volume" \
    -format UDZO -fs HFS+ "$STAGING_DIR/Macflix.dmg"
hdiutil verify "$STAGING_DIR/Macflix.dmg"

SOURCE_DIR="$STAGING_DIR/source/Macflix-$APP_VERSION-Rebuild"
mkdir -p "$SOURCE_DIR/Tests"
for folder in Sources Resources bin; do cp -R "$PROJECT_ROOT/$folder" "$SOURCE_DIR/$folder"; done
for folder in .github docs; do
    [[ ! -d "$PROJECT_ROOT/$folder" ]] || cp -R "$PROJECT_ROOT/$folder" "$SOURCE_DIR/$folder"
done
for test in "$PROJECT_ROOT"/Tests/*; do
    [[ -f "$test" ]] && cp "$test" "$SOURCE_DIR/Tests/"
done
cp "$PROJECT_ROOT/LICENSE" "$SOURCE_DIR/LICENSE"
cp "$PROJECT_ROOT/.gitignore" "$SOURCE_DIR/.gitignore"
cp "$PROJECT_ROOT/README.md" "$SOURCE_DIR/README.md"
cp "$PROJECT_ROOT/RELEASE.md" "$SOURCE_DIR/RELEASE.md"
ditto -c -k --norsrc --noextattr --keepParent "$SOURCE_DIR" "$STAGING_DIR/$SOURCE_NAME"

# Publish only completed, verified versioned outputs.
cp "$STAGING_DIR/Macflix.dmg" "$OUTPUT.new"
mv -f "$OUTPUT.new" "$OUTPUT"
cp "$STAGING_DIR/$SOURCE_NAME" "$SOURCE_OUTPUT.new"
mv -f "$SOURCE_OUTPUT.new" "$SOURCE_OUTPUT"
printf 'Installer: %s\n' "$OUTPUT"
printf 'Source: %s\n' "$SOURCE_OUTPUT"
