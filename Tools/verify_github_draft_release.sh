#!/usr/bin/env bash

set -euo pipefail

readonly github_host="github.com"
readonly github_repository="Wooden-Robot/ActionHalo"

fail() {
    echo "❌ $*" >&2
    exit 1
}

version=""
repository="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -ge 2 ]] || fail "--version requires X.Y.Z."
            version="$2"
            shift 2
            ;;
        --repository)
            [[ $# -ge 2 ]] || fail "--repository requires a path."
            repository="$2"
            shift 2
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || fail "GitHub Release verification requires an explicit X.Y.Z version."
command -v gh >/dev/null 2>&1 \
    || fail "GitHub CLI is required. Install and authenticate gh first."
git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "GitHub Release verification must run against a Git work tree."

local_head="$(git -C "$repository" rev-parse --verify 'HEAD^{commit}')" \
    || fail "Could not resolve the local HEAD commit."
[[ "$local_head" =~ ^[0-9a-fA-F]{40}$ ]] \
    || fail "Local HEAD did not resolve to a 40-character commit ID."
local_head="$(printf '%s' "$local_head" | tr '[:upper:]' '[:lower:]')"

github_api() {
    local endpoint="$1"
    local jq_filter="$2"
    local response=""

    if ! response="$(gh api "$endpoint" --hostname "$github_host" --jq "$jq_filter")"; then
        fail "GitHub API request failed for $endpoint."
    fi
    printf '%s' "$response"
}

release_tag="v$version"
ref_state="$(github_api \
    "repos/$github_repository/git/ref/tags/$release_tag" \
    '[.object.type, .object.sha] | @tsv')"
IFS=$'\t' read -r object_type object_sha <<< "$ref_state"

peel_depth=0
while [[ "$object_type" == "tag" ]]; do
    peel_depth=$((peel_depth + 1))
    [[ "$peel_depth" -le 16 ]] \
        || fail "Remote tag $release_tag exceeds the annotated-tag peel limit."
    [[ "$object_sha" =~ ^[0-9a-fA-F]{40}$ ]] \
        || fail "Remote tag $release_tag returned an invalid tag-object ID."

    tag_state="$(github_api \
        "repos/$github_repository/git/tags/$object_sha" \
        '[.object.type, .object.sha] | @tsv')"
    IFS=$'\t' read -r object_type object_sha <<< "$tag_state"
done

[[ "$object_type" == "commit" ]] \
    || fail "Remote tag $release_tag does not ultimately point to a commit."
[[ "$object_sha" =~ ^[0-9a-fA-F]{40}$ ]] \
    || fail "Remote tag $release_tag returned an invalid commit ID."
remote_commit="$(printf '%s' "$object_sha" | tr '[:upper:]' '[:lower:]')"
[[ "$remote_commit" == "$local_head" ]] \
    || fail "Remote tag $release_tag resolves to $remote_commit, but local HEAD is $local_head."

release_state="$(github_api \
    "repos/$github_repository/releases/tags/$release_tag" \
    '[.tag_name, (.draft | tostring), (.prerelease | tostring)] | @tsv')"
IFS=$'\t' read -r remote_tag_name is_draft is_prerelease <<< "$release_state"

[[ "$remote_tag_name" == "$release_tag" ]] \
    || fail "GitHub Release tag_name must be exactly $release_tag."
[[ "$is_draft" == "true" ]] \
    || fail "$release_tag must remain a draft Release until verified assets are uploaded."
[[ "$is_prerelease" == "false" ]] \
    || fail "$release_tag must not be marked as a prerelease."

echo "✅ GitHub draft Release and remote tag verified for $github_repository@$release_tag."
