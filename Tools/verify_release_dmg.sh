#!/usr/bin/env bash

set -euo pipefail

fail() {
    echo "❌ $*" >&2
    exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
dmg=""
version=""
info_plist="$project_root/Sources/App/Resources/Info.plist"
package_resolved="$project_root/Package.resolved"
entitlements="$project_root/ActionHalo.entitlements"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg)
            [[ $# -ge 2 ]] || fail "--dmg requires a path."
            dmg="$2"
            shift 2
            ;;
        --version)
            [[ $# -ge 2 ]] || fail "--version requires X.Y.Z."
            version="$2"
            shift 2
            ;;
        --info-plist)
            [[ $# -ge 2 ]] || fail "--info-plist requires a path."
            info_plist="$2"
            shift 2
            ;;
        --package-resolved)
            [[ $# -ge 2 ]] || fail "--package-resolved requires a path."
            package_resolved="$2"
            shift 2
            ;;
        --entitlements)
            [[ $# -ge 2 ]] || fail "--entitlements requires a path."
            entitlements="$2"
            shift 2
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -f "$dmg" ]] || fail "Release DMG does not exist: $dmg"
[[ -f "$entitlements" ]] || fail "Release entitlements do not exist: $entitlements"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must use X.Y.Z format."
hdiutil verify "$dmg" >/dev/null \
    || fail "Community release DMG filesystem verification failed."

mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/actionhalo-release-dmg.XXXXXX")"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        if ! hdiutil detach "$mount_dir" -quiet >/dev/null 2>&1; then
            hdiutil detach "$mount_dir" -force -quiet >/dev/null 2>&1 || true
        fi
    fi
    rmdir "$mount_dir" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mounted=true
hdiutil attach "$dmg" -readonly -nobrowse -mountpoint "$mount_dir" >/dev/null \
    || fail "Could not mount release DMG read-only."
mounted_app="$mount_dir/ActionHalo.app"
[[ -d "$mounted_app" ]] || fail "Release DMG does not contain ActionHalo.app at its root."
[[ ! -L "$mounted_app" ]] || fail "Release DMG ActionHalo.app must not be a symbolic link."

bash "$script_dir/verify_release_version.sh" \
    --version "$version" \
    --info-plist "$info_plist" \
    --artifact-plist "$mounted_app/Contents/Info.plist" >/dev/null
bash "$script_dir/verify_sparkle_update.sh" \
    --info-plist "$info_plist" \
    --package-resolved "$package_resolved" \
    --app "$mounted_app" \
    --require-ad-hoc >/dev/null
bash "$script_dir/verify_release_entitlements.sh" \
    --entitlements "$entitlements" \
    --info-plist "$info_plist" \
    --app "$mounted_app" >/dev/null

echo "✅ Ad-hoc community DMG and contained ActionHalo.app verified for $version."
