#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate_script="$project_root/Tools/verify_github_draft_release.sh"
fake_gh_dir="$project_root/Tests/fixtures/fake-gh-release-gate"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/openfire-github-release-gate.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

repository="$fixture_dir/repository"
mkdir -p "$repository"
git -C "$repository" init -q
git -C "$repository" config user.name "OpenFire Tests"
git -C "$repository" config user.email "openfire-tests@example.invalid"
printf 'release fixture\n' >"$repository/release.txt"
git -C "$repository" add release.txt
git -C "$repository" commit -q -m "release fixture"
local_head="$(git -C "$repository" rev-parse HEAD)"
tag_object_sha="1111111111111111111111111111111111111111"

expect_success() {
    local description="$1"
    shift
    if ! env \
        PATH="$fake_gh_dir:$PATH" \
        GH_REPO="SomeFork/OpenFire" \
        GH_HOST="example.invalid" \
        FAKE_GH_REF_SHA="$local_head" \
        "$@" \
        bash "$gate_script" --version 1.2.3 --repository "$repository" \
        >"$fixture_dir/output.log" 2>&1; then
        echo "FAIL: $description should succeed"
        cat "$fixture_dir/output.log"
        exit 1
    fi
}

expect_failure() {
    local description="$1"
    shift
    if env \
        PATH="$fake_gh_dir:$PATH" \
        GH_REPO="SomeFork/OpenFire" \
        GH_HOST="example.invalid" \
        FAKE_GH_REF_SHA="$local_head" \
        "$@" \
        bash "$gate_script" --version 1.2.3 --repository "$repository" \
        >"$fixture_dir/output.log" 2>&1; then
        echo "FAIL: $description should fail"
        cat "$fixture_dir/output.log"
        exit 1
    fi
}

expect_success \
    "a lightweight remote tag at local HEAD and a matching draft Release"

expect_success \
    "an annotated remote tag peeled to local HEAD" \
    FAKE_GH_REF_TYPE=tag \
    FAKE_GH_REF_SHA="$tag_object_sha" \
    FAKE_GH_TAG_TARGET_SHA="$local_head"

expect_failure \
    "a remote tag peeled to a different commit" \
    FAKE_GH_REF_SHA=2222222222222222222222222222222222222222

expect_failure \
    "an annotated tag that does not ultimately point to a commit" \
    FAKE_GH_REF_TYPE=tag \
    FAKE_GH_REF_SHA="$tag_object_sha" \
    FAKE_GH_TAG_TARGET_TYPE=tree \
    FAKE_GH_TAG_TARGET_SHA=2222222222222222222222222222222222222222

expect_failure \
    "a Release with a mismatched tag_name" \
    FAKE_GH_RELEASE_TAG_NAME=v1.2.4

expect_failure \
    "a published Release" \
    FAKE_GH_RELEASE_DRAFT=false

expect_failure \
    "a prerelease draft" \
    FAKE_GH_RELEASE_PRERELEASE=true

publish_recipe="$(sed -n '/^publish-release-assets:/,/^[[:alnum:]_-][[:alnum:]_-]*:/p' "$project_root/Makefile")"
gate_count="$(printf '%s\n' "$publish_recipe" | grep -c 'Tools/verify_github_draft_release.sh' || true)"
upload_line="$(printf '%s\n' "$publish_recipe" | grep 'gh release upload')"
edit_line="$(printf '%s\n' "$publish_recipe" | grep 'gh release edit')"
[[ "$gate_count" -ge 2 ]] || {
    echo "FAIL: publish-release-assets must verify the GitHub draft before upload and again before publication"
    exit 1
}
printf '%s\n' "$upload_line" | grep -F -- '--repo "github.com/Wooden-Robot/OpenFire"' >/dev/null || {
    echo "FAIL: gh release upload must pin Wooden-Robot/OpenFire with --repo"
    exit 1
}
printf '%s\n' "$edit_line" | grep -F -- '--repo "github.com/Wooden-Robot/OpenFire"' >/dev/null || {
    echo "FAIL: gh release edit must pin Wooden-Robot/OpenFire with --repo"
    exit 1
}

echo "GitHub Release gate tests passed."
