#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate_script="$project_root/Tools/verify_release_version.sh"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/openfire-version-gate.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

source_plist="$fixture_dir/Info.plist"
artifact_plist="$fixture_dir/Artifact-Info.plist"
cp "$project_root/Sources/App/Resources/Info.plist" "$source_plist"
cp "$source_plist" "$artifact_plist"

set_version() {
    local plist_path="$1"
    local version="$2"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist_path"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $version" "$plist_path"
}

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

set_version "$source_plist" "0.3.21"
set_version "$artifact_plist" "0.3.21"

expect_success \
    "an exact release tag matching source and artifact versions" \
    --tag "v0.3.21" \
    --info-plist "$source_plist" \
    --artifact-plist "$artifact_plist"

expect_success \
    "an explicit release version without a tag" \
    --version "0.3.21" \
    --info-plist "$source_plist"

expect_failure \
    "a release without an exact tag or explicit version" \
    --info-plist "$source_plist"

expect_failure \
    "an explicit version that disagrees with the exact tag" \
    --version "0.3.20" \
    --tag "v0.3.21" \
    --info-plist "$source_plist"

set_version "$source_plist" "0.3.20"
expect_failure \
    "a source Info.plist version mismatch" \
    --version "0.3.21" \
    --info-plist "$source_plist"

set_version "$source_plist" "0.3.21"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 42" "$source_plist"
expect_failure \
    "a source bundle build version mismatch" \
    --version "0.3.21" \
    --info-plist "$source_plist"

set_version "$source_plist" "0.3.21"
set_version "$artifact_plist" "0.3.20"
expect_failure \
    "a packaged artifact version mismatch" \
    --version "0.3.21" \
    --info-plist "$source_plist" \
    --artifact-plist "$artifact_plist"

expect_failure \
    "a malformed release version" \
    --version "release-0.3.21" \
    --info-plist "$source_plist"

expect_failure \
    "a release tag without the required v prefix" \
    --tag "0.3.21" \
    --info-plist "$source_plist"

tagged_repo="$fixture_dir/tagged-repo"
mkdir -p "$tagged_repo"
git -C "$tagged_repo" init -q
git -C "$tagged_repo" config user.name "OpenFire Tests"
git -C "$tagged_repo" config user.email "openfire-tests@example.invalid"
cp "$source_plist" "$tagged_repo/Info.plist"
git -C "$tagged_repo" add Info.plist
git -C "$tagged_repo" commit -q -m "fixture"
git -C "$tagged_repo" tag nightly

if ! (
    cd "$tagged_repo"
    bash "$gate_script" \
        --version "0.3.21" \
        --tags-at-head \
        --info-plist "$source_plist"
) >"$fixture_dir/output.log" 2>&1; then
    echo "FAIL: an unrelated tag must not block an explicit release version"
    cat "$fixture_dir/output.log"
    exit 1
fi

git -C "$tagged_repo" tag v0.3.21
if ! (
    cd "$tagged_repo"
    bash "$gate_script" \
        --tags-at-head \
        --info-plist "$source_plist"
) >"$fixture_dir/output.log" 2>&1; then
    echo "FAIL: one exact release tag at HEAD should succeed"
    cat "$fixture_dir/output.log"
    exit 1
fi

git -C "$tagged_repo" tag v0.3.22
if (
    cd "$tagged_repo"
    bash "$gate_script" \
        --version "0.3.21" \
        --tags-at-head \
        --info-plist "$source_plist"
) >"$fixture_dir/output.log" 2>&1; then
    echo "FAIL: multiple release tags at HEAD should fail"
    cat "$fixture_dir/output.log"
    exit 1
fi

echo "Release version gate tests passed."
