#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

validate_tag() {
    local tag="$1"
    [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
        printf 'Release tags must use vMAJOR.MINOR.PATCH.\n' >&2
        return 1
    }
    [[ "${tag#v}" == "$version" ]] || {
        printf 'Tag %s does not match app version %s.\n' "$tag" "$version" >&2
        return 1
    }
}

if [[ "${1:-}" == '--check-tag' ]]; then
    [[ $# == 2 ]] || { printf 'Usage: %s --check-tag vMAJOR.MINOR.PATCH\n' "$0" >&2; exit 2; }
    validate_tag "$2"
    exit
fi

[[ $# == 1 ]] || { printf 'Usage: %s vMAJOR.MINOR.PATCH\n' "$0" >&2; exit 2; }
release_tag="$1"
validate_tag "$release_tag"
command -v gh >/dev/null || { printf 'GitHub CLI (gh) is required.\n' >&2; exit 1; }
[[ -n "${GH_TOKEN:-}" ]] || { printf 'Set GH_TOKEN to create a draft GitHub release.\n' >&2; exit 1; }

public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist 2>/dev/null || true)"
update_signing=false
sparkle_private_key="${SPARKLE_PRIVATE_KEY:-}"
unset SPARKLE_PRIVATE_KEY
sparkle_private_key="${sparkle_private_key//$'\n'/}"
sparkle_private_key="${sparkle_private_key//$'\r'/}"
if [[ -n "$sparkle_private_key" && -n "$public_key" ]]; then
    if ! derived_key="$(printf '%s' "$sparkle_private_key" | swift -e 'import CryptoKit; import Foundation; let encoded = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines); let seed = Data(base64Encoded: encoded)!; print(try! Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())' 2>/dev/null)"; then
        printf 'SPARKLE_PRIVATE_KEY is not a valid Sparkle EdDSA seed.\n' >&2
        exit 1
    fi
    [[ "$derived_key" == "$public_key" ]] || { printf 'Sparkle signing key does not match SUPublicEDKey.\n' >&2; exit 1; }
    update_signing=true
elif [[ -n "$sparkle_private_key" || -n "$public_key" ]]; then
    printf 'Configure both SPARKLE_PRIVATE_KEY and SUPublicEDKey, or neither, before releasing.\n' >&2
    exit 1
fi

python3 Tests/fetch_reference_fixture.py
bash bin/package_dmg.sh

release_dir="${MACFLIX_RELEASE_DIR:-$PROJECT_ROOT/dist}"
appcast_staging="$(mktemp -d "${TMPDIR:-/tmp}/macflix-appcast.XXXXXX")"
trap 'rm -rf "$appcast_staging"' EXIT
dmg="Macflix-$version-Rebuild-AppleSilicon.dmg"
source="Macflix-$version-Rebuild-Source.zip"
[[ -f "$release_dir/$dmg" && -f "$release_dir/$source" ]] || {
    printf 'Expected release artifacts are missing from %s.\n' "$release_dir" >&2
    exit 1
}
rm -f "$release_dir/appcast.xml"
sparkle_dir="$(bash bin/fetch_sparkle.sh "${MACFLIX_REBUILD_BUILD_DIR:-$PROJECT_ROOT/build}/dependencies")"
public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "${MACFLIX_REBUILD_BUILD_DIR:-$PROJECT_ROOT/build}/Macflix.app/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$update_signing" == true ]]; then
    mkdir -p "$appcast_staging/archives"
    cp "$release_dir/$dmg" "$appcast_staging/archives/$dmg"
    printf '%s' "$sparkle_private_key" | "$sparkle_dir/bin/generate_appcast" --ed-key-file - \
        --download-url-prefix "https://github.com/Suhas-Neramya/macflix/releases/download/$release_tag/" \
        "$appcast_staging/archives"
    [[ -f "$appcast_staging/archives/appcast.xml" ]] || { printf 'Sparkle appcast generation failed.\n' >&2; exit 1; }
    cp "$appcast_staging/archives/appcast.xml" "$release_dir/appcast.xml"
else
    printf 'Sparkle signing is not configured; this release will not publish an update feed.\n'
fi
(
    cd "$release_dir"
    if [[ -f appcast.xml ]]; then
        shasum -a 256 "$dmg" "$source" appcast.xml > SHA256SUMS.new
    else
        shasum -a 256 "$dmg" "$source" > SHA256SUMS.new
    fi
    mv -f SHA256SUMS.new SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)

release_assets=("$release_dir/$dmg" "$release_dir/$source" "$release_dir/SHA256SUMS")
[[ ! -f "$release_dir/appcast.xml" ]] || release_assets+=("$release_dir/appcast.xml")
gh release create "$release_tag" "${release_assets[@]}" \
    --draft --verify-tag --generate-notes --title "Macflix $version"
