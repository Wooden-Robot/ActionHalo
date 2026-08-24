#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  verify_release_entitlements.sh --entitlements PATH --info-plist PATH [--app PATH]

The source entitlements must permit Apple Events automation and the source
Info.plist must explain that access. When --app is provided, its signature and
packaged Info.plist are checked for the same release requirements.
USAGE
}

fail() {
    echo "❌ $*" >&2
    exit 1
}

source_entitlements=""
source_info_plist=""
artifact_app=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --entitlements)
            [[ $# -ge 2 ]] || fail "--entitlements requires a path."
            source_entitlements="$2"
            shift 2
            ;;
        --info-plist)
            [[ $# -ge 2 ]] || fail "--info-plist requires a path."
            source_info_plist="$2"
            shift 2
            ;;
        --app)
            [[ $# -ge 2 ]] || fail "--app requires a path."
            artifact_app="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$source_entitlements" ]] || fail "--entitlements is required."
[[ -n "$source_info_plist" ]] || fail "--info-plist is required."

verify_entitlements() {
    local plist_path="$1"
    local description="$2"
    local automation_allowed

    [[ -f "$plist_path" ]] || fail "$description does not exist: $plist_path"
    plutil -lint "$plist_path" >/dev/null 2>&1 \
        || fail "$description is not a valid property list: $plist_path"
    automation_allowed="$(
        /usr/libexec/PlistBuddy \
            -c "Print :com.apple.security.automation.apple-events" \
            "$plist_path" 2>/dev/null
    )" || fail "$description does not declare com.apple.security.automation.apple-events."
    [[ "$automation_allowed" == "true" ]] \
        || fail "$description must enable com.apple.security.automation.apple-events."
}

verify_info_plist() {
    local plist_path="$1"
    local description="$2"
    local usage_description

    [[ -f "$plist_path" ]] || fail "$description does not exist: $plist_path"
    plutil -lint "$plist_path" >/dev/null 2>&1 \
        || fail "$description is not a valid property list: $plist_path"
    usage_description="$(
        /usr/libexec/PlistBuddy \
            -c "Print :NSAppleEventsUsageDescription" \
            "$plist_path" 2>/dev/null
    )" || fail "$description does not declare NSAppleEventsUsageDescription."
    [[ "$usage_description" =~ [^[:space:]] ]] \
        || fail "$description has an empty NSAppleEventsUsageDescription."
}

verify_entitlements "$source_entitlements" "Source entitlements"
verify_info_plist "$source_info_plist" "Source Info.plist"

if [[ -n "$artifact_app" ]]; then
    [[ -d "$artifact_app" ]] || fail "Packaged app does not exist: $artifact_app"
    codesign --verify --deep --strict "$artifact_app" >/dev/null 2>&1 \
        || fail "Packaged app signature is invalid: $artifact_app"

    artifact_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/actionhalo-entitlements.XXXXXX")"
    trap 'rm -rf "$artifact_temp_dir"' EXIT
    artifact_entitlements="$artifact_temp_dir/entitlements.plist"
    if ! codesign --display --xml --entitlements - "$artifact_app" \
        >"$artifact_entitlements" 2>"$artifact_temp_dir/codesign.log"; then
        fail "Could not read packaged app entitlements: $artifact_app"
    fi

    verify_entitlements "$artifact_entitlements" "Packaged app entitlements"
    verify_info_plist \
        "$artifact_app/Contents/Info.plist" \
        "Packaged app Info.plist"
fi

echo "✅ Release Apple Events permissions verified."
