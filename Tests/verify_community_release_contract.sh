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

require_fixed "$(<"$makefile")" 'SPARKLE_ACCOUNT ?= ActionHalo' \
    "the default Sparkle Keychain account must use the independent ActionHalo signing key"
require_fixed "$(<"$makefile")" 'APPCAST_NAME = actionhalo-appcast.xml' \
    "the installable ActionHalo feed must not reuse the legacy appcast filename"
require_fixed "$(<"$makefile")" 'LEGACY_SPARKLE_ACCOUNT ?= ActionHaloLegacyMigration' \
    "the informational migration feed must use a separate legacy-key account"
require_fixed "$(<"$makefile")" 'LEGACY_SPARKLE_PUBLIC_KEY = YpDJbUKWW/mYy47N4BULh0vfKr4PGvV5dv5OAGyJrAo=' \
    "the informational migration feed must remain verifiable by existing installations"
require_fixed "$(<"$makefile")" 'LEGACY_APPCAST_NAME = appcast.xml' \
    "legacy installations must keep receiving the informational feed at appcast.xml"
require_fixed "$(<"$makefile")" 'tccutil reset Accessibility com.actionhalo.app' \
    "the development run target must reset the ActionHalo Accessibility identity"

package_recipe="$(target_recipe package)"
release_recipe="$(target_recipe release)"
appcast_recipe="$(target_recipe generate-appcast)"
legacy_appcast_recipe="$(target_recipe generate-legacy-migration-appcast)"
publish_recipe="$(target_recipe publish-release-assets)"
test_recipe="$(target_recipe test)"

for target in package release generate-appcast generate-legacy-migration-appcast publish-release-assets; do
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
require_fixed "$release_recipe" \
    '$(MAKE) generate-legacy-migration-appcast VERSION="$(VERSION)" LEGACY_SPARKLE_ACCOUNT="$(LEGACY_SPARKLE_ACCOUNT)"' \
    "release must generate the separately signed informational migration feed"

require_fixed "$appcast_recipe" 'Tools/verify_release_dmg.sh' \
    "generate-appcast must validate the community DMG before signing it"
require_fixed "$appcast_recipe" '$(SPARKLE_TOOLS)/generate_appcast' \
    "generate-appcast must use Sparkle's appcast generator"
require_fixed "$appcast_recipe" 'CHANGELOG.md' \
    "generate-appcast must derive release notes from the project changelog"
require_fixed "$appcast_recipe" '$(APPCAST_DIR)/$(APP_NAME).md' \
    "generate-appcast must stage release notes with the same basename as the DMG"
require_fixed "$appcast_recipe" '--embed-release-notes' \
    "generate-appcast must embed release notes in the signed feed"
require_fixed "$appcast_recipe" 'Tools/verify_sparkle_appcast.sh' \
    "generate-appcast must cryptographically verify the feed and archive"

require_fixed "$legacy_appcast_recipe" 'Tools/generate_legacy_migration_appcast.sh' \
    "the legacy target must use the audited informational-feed generator"
require_fixed "$legacy_appcast_recipe" '--output "$(LEGACY_APPCAST_PATH)"' \
    "the legacy target must write the old clients' appcast.xml path"
require_fixed "$legacy_appcast_recipe" '--account "$(LEGACY_SPARKLE_ACCOUNT)"' \
    "the legacy target must use the isolated legacy trust-root account"
require_fixed "$legacy_appcast_recipe" '--expected-public-key "$(LEGACY_SPARKLE_PUBLIC_KEY)"' \
    "the legacy target must pin the public key trusted by existing installations"

require_fixed "$publish_recipe" \
    '$(MAKE) generate-appcast VERSION="$(VERSION)" SPARKLE_ACCOUNT="$(SPARKLE_ACCOUNT)"' \
    "publish-release-assets must generate the community appcast without a Team ID"
require_fixed "$publish_recipe" \
    '$(MAKE) generate-legacy-migration-appcast VERSION="$(VERSION)" LEGACY_SPARKLE_ACCOUNT="$(LEGACY_SPARKLE_ACCOUNT)"' \
    "publish-release-assets must regenerate the informational migration feed before upload"
require_fixed "$publish_recipe" '$(BUILD_DIR)/$(DMG_NAME)#$(DMG_NAME)' \
    "publish-release-assets must upload the community DMG"
require_fixed "$publish_recipe" '$(APPCAST_PATH)#$(APPCAST_NAME)' \
    "publish-release-assets must upload the dedicated signed ActionHalo appcast with the DMG"
require_fixed "$publish_recipe" '$(LEGACY_APPCAST_PATH)#$(LEGACY_APPCAST_NAME)' \
    "publish-release-assets must upload the separately signed informational migration feed"
require_fixed "$publish_recipe" 'grep -Fxq "$(LEGACY_APPCAST_NAME)"' \
    "publish-release-assets must refuse to replace an existing informational migration feed"
require_fixed "$publish_recipe" 'LOCAL_LEGACY_APPCAST_DIGEST=' \
    "publish-release-assets must hash the local informational migration feed"
require_fixed "$publish_recipe" 'REMOTE_LEGACY_APPCAST_DIGEST=' \
    "publish-release-assets must read the remote informational migration feed digest"
require_fixed "$publish_recipe" '[ "$${REMOTE_LEGACY_APPCAST_DIGEST}" = "$${LOCAL_LEGACY_APPCAST_DIGEST}" ]' \
    "publish-release-assets must verify the informational migration feed digest before publication"
require_fixed "$test_recipe" 'Tests/verify_legacy_migration_appcast_gate.sh' \
    "make test must exercise the enclosure-free informational migration feed gate"

for target in package release generate-appcast generate-legacy-migration-appcast publish-release-assets; do
    dry_run="$fixture_dir/$target.log"
    make -C "$project_root" --no-print-directory -n "$target" VERSION=9.8.7 \
        SPARKLE_ACCOUNT=CommunityContractTest \
        LEGACY_SPARKLE_ACCOUNT=LegacyCommunityContractTest >"$dry_run"
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
require_fixed "$release_dry_run" 'bash Tools/generate_legacy_migration_appcast.sh' \
    "release dry-run must include the informational migration feed generator"

publish_dry_run="$(<"$fixture_dir/publish-release-assets.log")"
require_fixed "$publish_dry_run" 'gh release upload' \
    "publish dry-run must upload the DMG and both appcasts"
require_fixed "$publish_dry_run" '.build/ActionHalo.dmg#ActionHalo.dmg' \
    "publish dry-run must include the ActionHalo DMG asset"
require_fixed "$publish_dry_run" '.build/actionhalo-appcast.xml#actionhalo-appcast.xml' \
    "publish dry-run must include the installable ActionHalo feed"
require_fixed "$publish_dry_run" '.build/appcast.xml#appcast.xml' \
    "publish dry-run must include the informational migration feed"
require_fixed "$publish_dry_run" 'REMOTE_LEGACY_APPCAST_DIGEST=' \
    "publish dry-run must include remote verification for the informational migration feed"
require_fixed "$publish_dry_run" 'gh release edit' \
    "publish dry-run must publish only after verification"

echo "Community release Makefile contract tests passed."
