#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macflix-rebuild-tests.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
mkdir -p "$STAGING_DIR/module-cache"

for test in "$PROJECT_ROOT"/Tests/*.cjs; do node "$test"; done
xcrun swiftc -module-cache-path "$STAGING_DIR/module-cache" \
    "$PROJECT_ROOT/Sources/PlaybackPolicy.swift" "$PROJECT_ROOT/Tests/PlaybackPolicyTests.swift" \
    -o "$STAGING_DIR/PlaybackPolicyTests"
"$STAGING_DIR/PlaybackPolicyTests"

xcrun swiftc -module-cache-path "$STAGING_DIR/module-cache" \
    -framework AVFoundation -framework Network \
    "$PROJECT_ROOT/Sources/MP4AudioStream.swift" "$PROJECT_ROOT/Sources/NativeAudioBridge.swift" \
    "$PROJECT_ROOT/Tests/NativeAudioBridgeTests.swift" -o "$STAGING_DIR/NativeAudioBridgeTests"
"$STAGING_DIR/NativeAudioBridgeTests"

if [[ -f "$PROJECT_ROOT/Tests/fixtures/apple-atmos-init.mp4" && -f "$PROJECT_ROOT/Tests/fixtures/apple-first-fragment.m4s" ]]; then
    xcrun swiftc -module-cache-path "$STAGING_DIR/module-cache" \
        "$PROJECT_ROOT/Sources/MP4AudioStream.swift" "$PROJECT_ROOT/Tests/NativeAudioParserTests.swift" \
        -o "$STAGING_DIR/NativeAudioParserTests"
    "$STAGING_DIR/NativeAudioParserTests" "$PROJECT_ROOT"
else
    printf 'Skipped native parser fixture test: Apple reference fixtures are not present.\n'
fi
