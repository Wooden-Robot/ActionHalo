#!/usr/bin/env bash

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
makefile="$project_root/Makefile"
sparkle_signer="$project_root/Tools/sign_sparkle_framework.sh"
sparkle_signer_contents="$(<"$sparkle_signer")"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/actionhalo-community-release-contract.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

target_recipe() {
    local target="$1"
    awk -v target="$target" '
        $0 ~ "^" target ":" { in_target = 1 }
        in_target && $0 !~ "^" target ":" && $0 ~ /^[[:alnum:]_-]+:/ { exit }
        in_target { print }
    ' "$makefile"
}

require_fixed() {
    local text="$1"
    local expected="$2"
    local description="$3"
    grep -Fq -- "$expected" <<<"$text" || fail "$description"
}

reject_pattern() {
    local text="$1"
    local pattern="$2"
    local description="$3"
    if grep -Eiq -- "$pattern" <<<"$text"; then
        fail "$description"
    fi
}

require_fixed "$(<"$makefile")" 'SPARKLE_ACCOUNT ?= OpenFire' \
    "the default Sparkle Keychain account must preserve the existing signing key"

package_recipe="$(target_recipe package)"
release_recipe="$(target_recipe release)"
appcast_recipe="$(target_recipe generate-appcast)"
publish_recipe="$(target_recipe publish-release-assets)"

for target in package release generate-appcast publish-release-assets; do
    recipe="$(target_recipe "$target")"
    reject_pattern \
        "$recipe" \
        'Developer[[:space:]]+ID|DEVELOPER_TEAM_ID|CODESIGN_IDENTITY|NOTARYTOOL_PROFILE|notarytool|stapler|--expected-team-id|--require-developer-id' \
        "$target must remain independent of Developer ID, Team ID, and Apple notarization"
done

main_app_signing_line="$(
    grep -E 'codesign .*\$\(APP_DIR\)' <<<"$package_recipe" \
        | grep -v -- '--verify' \
        | head -n 1
)"
[[ -n "$main_app_signing_line" ]] || fail "package must sign the main app"
require_fixed "$main_app_signing_line" '--force' \
    "the main app signing command must replace any stale signature"
require_fixed "$main_app_signing_line" '--entitlements "$(APP_ENTITLEMENTS)"' \
    "the ad-hoc main app must retain the Apple Events entitlement"
require_fixed "$main_app_signing_line" '--sign -' \
    "the main app must use an explicit ad-hoc signature"
reject_pattern "$main_app_signing_line" '--options([=[:space:]]+)runtime' \
    "the ad-hoc main app must not enable Hardened Runtime because its Sparkle helpers have no matching Team ID"

require_fixed "$package_recipe" \
    'Tools/sign_sparkle_framework.sh --framework "$(APP_FRAMEWORKS)/Sparkle.framework"' \
    "package must sign Sparkle's nested helpers before signing the main app"
require_fixed "$package_recipe" '--require-ad-hoc' \
    "package must verify that the finished app and Sparkle components are ad-hoc signed"
require_fixed "$sparkle_signer_contents" 'common_args=(--force --options runtime --sign -)' \
    "Sparkle helpers must remain ad-hoc signed with Hardened Runtime"

require_fixed "$release_recipe" '$(MAKE) package' \
    "release must build the ad-hoc community package"
require_fixed "$release_recipe" \
    '$(MAKE) generate-appcast VERSION="$(VERSION)" SPARKLE_ACCOUNT="$(SPARKLE_ACCOUNT)"' \
    "release must generate the Ed25519-signed Sparkle appcast"

require_fixed "$appcast_recipe" 'Tools/verify_release_dmg.sh' \
    "generate-appcast must validate the community DMG before signing it"
require_fixed "$appcast_recipe" '$(SPARKLE_TOOLS)/generate_appcast' \
    "generate-appcast must use Sparkle's appcast generator"
require_fixed "$appcast_recipe" 'Tools/verify_sparkle_appcast.sh' \
    "generate-appcast must cryptographically verify the feed and archive"

require_fixed "$publish_recipe" \
    '$(MAKE) generate-appcast VERSION="$(VERSION)" SPARKLE_ACCOUNT="$(SPARKLE_ACCOUNT)"' \
    "publish-release-assets must generate the community appcast without a Team ID"
require_fixed "$publish_recipe" '$(BUILD_DIR)/$(DMG_NAME)#$(DMG_NAME)' \
    "publish-release-assets must upload the community DMG"
require_fixed "$publish_recipe" '$(APPCAST_PATH)#appcast.xml' \
    "publish-release-assets must upload the signed appcast with the DMG"

for target in package release generate-appcast publish-release-assets; do
    dry_run="$fixture_dir/$target.log"
    make -C "$project_root" --no-print-directory -n "$target" VERSION=9.8.7 \
        SPARKLE_ACCOUNT=CommunityContractTest >"$dry_run"
    dry_output="$(<"$dry_run")"
    reject_pattern \
        "$dry_output" \
        'Developer[[:space:]]+ID|DEVELOPER_TEAM_ID|CODESIGN_IDENTITY|NOTARYTOOL_PROFILE|notarytool|stapler|--expected-team-id|--require-developer-id' \
        "$target dry-run unexpectedly depends on Developer ID, Team ID, or notarization"
done

package_dry_run="$(<"$fixture_dir/package.log")"
dry_main_app_signing_line="$(
    grep -E 'codesign .*\.build/ActionHalo\.app' <<<"$package_dry_run" \
        | grep -v -- '--verify' \
        | head -n 1
)"
[[ -n "$dry_main_app_signing_line" ]] || fail "package dry-run must sign .build/ActionHalo.app"
require_fixed "$dry_main_app_signing_line" '--entitlements "ActionHalo.entitlements"' \
    "package dry-run must retain the main app entitlements"
require_fixed "$dry_main_app_signing_line" '--sign -' \
    "package dry-run must use ad-hoc signing for the main app"
reject_pattern "$dry_main_app_signing_line" '--options([=[:space:]]+)runtime' \
    "package dry-run must not enable Hardened Runtime on the ad-hoc main app"

release_dry_run="$(<"$fixture_dir/release.log")"
require_fixed "$release_dry_run" 'bash Tools/sign_sparkle_framework.sh' \
    "release dry-run must include Sparkle helper signing"
require_fixed "$release_dry_run" '.build/artifacts/sparkle/Sparkle/bin/generate_appcast' \
    "release dry-run must include appcast generation"

publish_dry_run="$(<"$fixture_dir/publish-release-assets.log")"
require_fixed "$publish_dry_run" 'gh release upload' \
    "publish dry-run must upload the DMG and appcast"
require_fixed "$publish_dry_run" 'gh release edit' \
    "publish dry-run must publish only after verification"

echo "Community release Makefile contract tests passed."
