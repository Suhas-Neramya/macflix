#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${MACFLIX_REBUILD_BUILD_DIR:-$PROJECT_ROOT/build}"
SIGNING_IDENTITY="${MACFLIX_SIGNING_IDENTITY:--}"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macflix-rebuild.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_BUNDLE="$STAGING_DIR/Macflix.app"

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$BUILD_DIR/module-cache"
printf 'Building Macflix 0.2.3 for Apple silicon, macOS 14 or later...\n'
xcrun swiftc -O -swift-version 5 -warnings-as-errors \
    -target arm64-apple-macosx14.0 -parse-as-library \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -framework Cocoa -framework WebKit -framework AVFoundation -framework Network \
    "$PROJECT_ROOT"/Sources/*.swift -o "$APP_BUNDLE/Contents/MacOS/Macflix"

for resource in MacflixIcon.icns MultichannelAudio.js NativeAudioBridge.js AudioDiagnostics.js Playback.js; do
    cp "$PROJECT_ROOT/Resources/$resource" "$APP_BUNDLE/Contents/Resources/$resource"
done
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_ROOT/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --force --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

# Replace only this rebuild's generated app bundle; never touch /Applications.
rm -rf "$BUILD_DIR/Macflix.app"
ditto --norsrc --noextattr "$APP_BUNDLE" "$BUILD_DIR/Macflix.app"
codesign --verify --deep --strict "$BUILD_DIR/Macflix.app"
printf 'Built: %s\n' "$BUILD_DIR/Macflix.app"
