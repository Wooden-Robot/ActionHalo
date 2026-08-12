#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate_script="$project_root/Tools/verify_release_entitlements.sh"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/openfire-entitlements-gate.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

source_entitlements="$fixture_dir/OpenFire.entitlements"
source_info_plist="$fixture_dir/Info.plist"
cp "$project_root/OpenFire.entitlements" "$source_entitlements"
cp "$project_root/Sources/App/Resources/Info.plist" "$source_info_plist"

expect_success() {
    local description="$1"
    shift
    if ! bash "$gate_script" "$@" >"$fixture_dir/output.log" 2>&1; then
        echo "FAIL: $description should succeed"
        cat "$fixture_dir/output.log"
        exit 1
    fi
}

expect_failure() {
    local description="$1"
    shift
    if bash "$gate_script" "$@" >"$fixture_dir/output.log" 2>&1; then
        echo "FAIL: $description should fail"
        cat "$fixture_dir/output.log"
        exit 1
    fi
}

expect_success \
    "the tracked Apple Events permission declarations" \
    --entitlements "$source_entitlements" \
    --info-plist "$source_info_plist"

/usr/libexec/PlistBuddy \
    -c "Set :com.apple.security.automation.apple-events false" \
    "$source_entitlements"
expect_failure \
    "a disabled Apple Events entitlement" \
    --entitlements "$source_entitlements" \
    --info-plist "$source_info_plist"

cp "$project_root/OpenFire.entitlements" "$source_entitlements"
/usr/libexec/PlistBuddy -c "Delete :NSAppleEventsUsageDescription" "$source_info_plist"
expect_failure \
    "a missing Apple Events usage description" \
    --entitlements "$source_entitlements" \
    --info-plist "$source_info_plist"

cp "$project_root/Sources/App/Resources/Info.plist" "$source_info_plist"
/usr/libexec/PlistBuddy -c "Set :NSAppleEventsUsageDescription    " "$source_info_plist"
expect_failure \
    "an empty Apple Events usage description" \
    --entitlements "$source_entitlements" \
    --info-plist "$source_info_plist"

cp "$project_root/Sources/App/Resources/Info.plist" "$source_info_plist"
artifact_app="$fixture_dir/OpenFire.app"
mkdir -p "$artifact_app/Contents/MacOS"
cp /bin/echo "$artifact_app/Contents/MacOS/OpenFire"
cp "$source_info_plist" "$artifact_app/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Add :CFBundleExecutable string OpenFire" \
    "$artifact_app/Contents/Info.plist"
codesign --force --sign - \
    --entitlements "$source_entitlements" \
    "$artifact_app" >/dev/null 2>&1

expect_success \
    "a signed app carrying the required entitlement" \
    --entitlements "$source_entitlements" \
    --info-plist "$source_info_plist" \
    --app "$artifact_app"

codesign --force --sign - "$artifact_app" >/dev/null 2>&1
expect_failure \
    "a signed app that dropped the required entitlement" \
    --entitlements "$source_entitlements" \
    --info-plist "$source_info_plist" \
    --app "$artifact_app"

echo "Release entitlement gate tests passed."
