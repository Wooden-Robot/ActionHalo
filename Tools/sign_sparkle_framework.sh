#!/bin/bash

set -euo pipefail

fail() {
    echo "❌ $*" >&2
    exit 1
}

framework=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --framework)
            [[ $# -ge 2 ]] || fail "--framework requires a path."
            framework="$2"
            shift 2
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$framework" ]] || fail "--framework is required."
[[ -d "$framework" ]] || fail "Sparkle framework does not exist: $framework"
[[ "$framework" == *.framework ]] || fail "Expected a .framework bundle: $framework"

version_root="$framework/Versions/B"
[[ -d "$version_root" ]] || fail "Unsupported Sparkle framework layout: missing Versions/B."

installer="$version_root/XPCServices/Installer.xpc"
downloader="$version_root/XPCServices/Downloader.xpc"
autoupdate="$version_root/Autoupdate"
updater="$version_root/Updater.app"

for target in "$installer" "$downloader" "$autoupdate" "$updater"; do
    [[ -e "$target" ]] || fail "Required Sparkle helper is missing: $target"
done

common_args=(--force --options runtime --sign -)

# Sparkle's Downloader carries a network-client entitlement. Preserve only its
# entitlement while signing every nested helper from the inside out.
codesign "${common_args[@]}" "$installer"
codesign "${common_args[@]}" --preserve-metadata=entitlements "$downloader"
codesign "${common_args[@]}" "$autoupdate"
codesign "${common_args[@]}" "$updater"
codesign "${common_args[@]}" "$framework"

for target in "$installer" "$downloader" "$autoupdate" "$updater" "$framework"; do
    codesign --verify --strict --verbose=2 "$target"
done
