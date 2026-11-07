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

python3 Tests/fetch_reference_fixture.py
bash bin/package_dmg.sh

release_dir="${MACFLIX_RELEASE_DIR:-$PROJECT_ROOT/dist}"
dmg="Macflix-$version-Rebuild-AppleSilicon.dmg"
source="Macflix-$version-Rebuild-Source.zip"
[[ -f "$release_dir/$dmg" && -f "$release_dir/$source" ]] || {
    printf 'Expected release artifacts are missing from %s.\n' "$release_dir" >&2
    exit 1
}
(
    cd "$release_dir"
    shasum -a 256 "$dmg" "$source" > SHA256SUMS.new
    mv -f SHA256SUMS.new SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)

gh release create "$release_tag" "$release_dir/$dmg" "$release_dir/$source" "$release_dir/SHA256SUMS" \
    --draft --verify-tag --generate-notes --title "Macflix $version"
