#!/usr/bin/env bash

set -euo pipefail

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
    || fail "Community releases require an explicit VERSION=X.Y.Z."
git -C "$repository" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || fail "Release verification must run inside a Git work tree."

worktree_state="$(git -C "$repository" status --porcelain --untracked-files=all)"
[[ -z "$worktree_state" ]] \
    || fail "Community releases require a clean work tree; commit every source and release-script change first."

expected_tag="v$version"
matching_tags=()
while IFS= read -r tag; do
    [[ -n "$tag" ]] && matching_tags+=("$tag")
done < <(git -C "$repository" tag --points-at HEAD | sed -nE '/^v[0-9]+\.[0-9]+\.[0-9]+$/p')

[[ "${#matching_tags[@]}" -eq 1 ]] \
    || fail "Community releases require exactly one vX.Y.Z tag at HEAD."
[[ "${matching_tags[0]}" == "$expected_tag" ]] \
    || fail "HEAD tag ${matching_tags[0]} does not match VERSION=$version."

echo "✅ Release repository state verified at $expected_tag."
