#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  verify_release_version.sh [--version X.Y.Z] [--tag vX.Y.Z] \
    --info-plist PATH [--artifact-plist PATH]

At least one of --version or --tag must be provided. When both are present,
they must resolve to the same version. The source and optional packaged
Info.plist files must use that version for both CFBundleShortVersionString
and CFBundleVersion.
USAGE
}

fail() {
    echo "❌ $*" >&2
    exit 1
}

explicit_version=""
release_tag=""
info_plist=""
artifact_plist=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail "--version requires a value."
            explicit_version="$2"
            shift 2
            ;;
        --tag)
            [[ $# -ge 2 ]] || fail "--tag requires a value."
            release_tag="$2"
            shift 2
            ;;
        --info-plist)
            [[ $# -ge 2 ]] || fail "--info-plist requires a path."
            info_plist="$2"
            shift 2
            ;;
        --artifact-plist)
            [[ $# -ge 2 ]] || fail "--artifact-plist requires a path."
            artifact_plist="$2"
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

normalize_explicit_version() {
    local candidate="$1"
    [[ "$candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "Release version must use X.Y.Z format: $1"
    printf '%s' "$candidate"
}

normalize_release_tag() {
    local candidate="$1"
    [[ "$candidate" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fail "Release tag must use vX.Y.Z format: $1"
    printf '%s' "${candidate#v}"
}

normalized_version=""
normalized_tag=""

if [[ -n "$explicit_version" ]]; then
    normalized_version="$(normalize_explicit_version "$explicit_version")"
fi
if [[ -n "$release_tag" ]]; then
    normalized_tag="$(normalize_release_tag "$release_tag")"
fi

if [[ -z "$normalized_version" && -z "$normalized_tag" ]]; then
    fail "release requires an exact vX.Y.Z tag or an explicit VERSION=X.Y.Z."
fi
if [[ -n "$normalized_version" && -n "$normalized_tag" && "$normalized_version" != "$normalized_tag" ]]; then
    fail "Explicit version $normalized_version does not match tag $release_tag."
fi

release_version="${normalized_version:-$normalized_tag}"
[[ -n "$info_plist" ]] || fail "--info-plist is required."

verify_plist() {
    local plist_path="$1"
    local description="$2"
    local marketing_version
    local build_version

    [[ -f "$plist_path" ]] || fail "$description does not exist: $plist_path"
    marketing_version="$(
        /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist_path" 2>/dev/null
    )" || fail "$description has no CFBundleShortVersionString: $plist_path"
    build_version="$(
        /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist_path" 2>/dev/null
    )" || fail "$description has no CFBundleVersion: $plist_path"

    [[ "$marketing_version" == "$release_version" ]] \
        || fail "$description CFBundleShortVersionString is $marketing_version; expected $release_version."
    [[ "$build_version" == "$release_version" ]] \
        || fail "$description CFBundleVersion is $build_version; expected $release_version."
}

verify_plist "$info_plist" "Source Info.plist"
if [[ -n "$artifact_plist" ]]; then
    verify_plist "$artifact_plist" "Packaged app Info.plist"
fi

echo "✅ Release version verified: $release_version"
