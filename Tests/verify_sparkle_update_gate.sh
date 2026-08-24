#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
gate_script="$project_root/Tools/verify_sparkle_update.sh"
appcast_gate_script="$project_root/Tools/verify_sparkle_appcast.sh"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/actionhalo-sparkle-gate.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

source_plist="$fixture_dir/Info.plist"
resolved_file="$fixture_dir/Package.resolved"
cp "$project_root/Sources/App/Resources/Info.plist" "$source_plist"
cp "$project_root/Package.resolved" "$resolved_file"

expect_failure() {
    local description="$1"
    shift
    if "$@" >"$fixture_dir/failure.log" 2>&1; then
        echo "FAIL: accepted $description" >&2
        exit 1
    fi
}

bash "$gate_script" \
    --info-plist "$source_plist" \
    --package-resolved "$resolved_file" >/dev/null

cp "$project_root/Sources/App/Resources/Info.plist" "$source_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName OpenFire" "$source_plist"
expect_failure "the legacy app name as the public bundle name" \
    bash "$gate_script" --info-plist "$source_plist" --package-resolved "$resolved_file"

cp "$project_root/Sources/App/Resources/Info.plist" "$source_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.actionhalo.app" "$source_plist"
expect_failure "a bundle identifier change during the compatibility transition" \
    bash "$gate_script" --info-plist "$source_plist" --package-resolved "$resolved_file"

cp "$project_root/Sources/App/Resources/Info.plist" "$source_plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleDocumentTypes:1" "$source_plist"
expect_failure "removal of legacy .openfireext document support" \
    bash "$gate_script" --info-plist "$source_plist" --package-resolved "$resolved_file"

cp "$project_root/Sources/App/Resources/Info.plist" "$source_plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL https://example.com/appcast.xml" "$source_plist"
expect_failure "an untrusted appcast URL" \
    bash "$gate_script" --info-plist "$source_plist" --package-resolved "$resolved_file"

cp "$project_root/Sources/App/Resources/Info.plist" "$source_plist"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey attacker-key" "$source_plist"
expect_failure "a replaced update signing key" \
    bash "$gate_script" --info-plist "$source_plist" --package-resolved "$resolved_file"

cp "$project_root/Sources/App/Resources/Info.plist" "$source_plist"
/usr/libexec/PlistBuddy -c "Set :SUVerifyUpdateBeforeExtraction false" "$source_plist"
expect_failure "archive verification disabled" \
    bash "$gate_script" --info-plist "$source_plist" --package-resolved "$resolved_file"

cp "$project_root/Sources/App/Resources/Info.plist" "$source_plist"
/usr/libexec/PlistBuddy -c "Set :SURequireSignedFeed false" "$source_plist"
expect_failure "signed-feed verification disabled" \
    bash "$gate_script" --info-plist "$source_plist" --package-resolved "$resolved_file"

cp "$project_root/Package.resolved" "$resolved_file"
cp "$project_root/Sources/App/Resources/Info.plist" "$source_plist"
plutil -replace pins.0.state.version -string 9.9.9 "$resolved_file"
expect_failure "an unreviewed Sparkle dependency version" \
    bash "$gate_script" --info-plist "$source_plist" --package-resolved "$resolved_file"

cp "$project_root/Package.resolved" "$resolved_file"
plutil -replace pins.0.state.revision -string 0000000000000000000000000000000000000000 "$resolved_file"
expect_failure "an unreviewed Sparkle dependency revision" \
    bash "$gate_script" --info-plist "$source_plist" --package-resolved "$resolved_file"

sign_update="$project_root/.build/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$sign_update" ]] || {
    echo "FAIL: Sparkle sign_update is unavailable; resolve package dependencies first." >&2
    exit 1
}

test_key="$fixture_dir/test-ed25519-private-key"
archive="$fixture_dir/ActionHalo.dmg"
appcast="$fixture_dir/appcast.xml"
printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' >"$test_key"
printf '%s\n' 'deterministic Sparkle archive fixture' >"$archive"
archive_signature="$("$sign_update" --ed-key-file "$test_key" -p "$archive")"
archive_length="$(stat -f '%z' "$archive")"

write_appcast() {
    local output_path="$1"
    local enclosure_length="$2"
    local namespace_uri="${3:-http://www.andymatuschak.org/xml-namespaces/sparkle}"
    cat >"$output_path" <<XML
<?xml version="1.0"?>
<rss xmlns:sparkle="$namespace_uri" version="2.0">
  <channel>
    <item>
      <sparkle:version>1.2.3</sparkle:version>
      <sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
      <enclosure url="https://github.com/Wooden-Robot/ActionHalo/releases/download/v1.2.3/ActionHalo.dmg" length="$enclosure_length" type="application/octet-stream" sparkle:edSignature="$archive_signature"/>
    </item>
  </channel>
</rss>
XML
    "$sign_update" --ed-key-file "$test_key" "$output_path" >/dev/null
}

verify_fixture_appcast() {
    local appcast_path="$1"
    local archive_path="$2"
    bash "$appcast_gate_script" \
        --appcast "$appcast_path" \
        --archive "$archive_path" \
        --version 1.2.3 \
        --download-url https://github.com/Wooden-Robot/ActionHalo/releases/download/v1.2.3/ActionHalo.dmg \
        --sign-update "$sign_update" \
        --ed-key-file "$test_key"
}

write_appcast "$appcast" "$archive_length"
verify_fixture_appcast "$appcast" "$archive" >/dev/null

expect_failure "an appcast whose archive version does not match the release" \
    bash "$appcast_gate_script" \
        --appcast "$appcast" \
        --archive "$archive" \
        --version 1.2.4 \
        --download-url https://github.com/Wooden-Robot/ActionHalo/releases/download/v1.2.4/ActionHalo.dmg \
        --sign-update "$sign_update" \
        --ed-key-file "$test_key"

tampered_feed="$fixture_dir/tampered-feed.xml"
cp "$appcast" "$tampered_feed"
sed -i '' 's/<channel>/<channel><title>Tampered<\/title>/' "$tampered_feed"
expect_failure "an appcast modified after feed signing" \
    verify_fixture_appcast "$tampered_feed" "$archive"

tampered_archive="$fixture_dir/Tampered-ActionHalo.dmg"
cp "$archive" "$tampered_archive"
printf 'X' | dd of="$tampered_archive" bs=1 seek=0 conv=notrunc 2>/dev/null
expect_failure "an archive modified after enclosure signing" \
    verify_fixture_appcast "$appcast" "$tampered_archive"

wrong_length_appcast="$fixture_dir/wrong-length.xml"
write_appcast "$wrong_length_appcast" "$((archive_length + 1))"
expect_failure "an enclosure length that does not match the archive" \
    verify_fixture_appcast "$wrong_length_appcast" "$archive"

wrong_namespace_appcast="$fixture_dir/wrong-namespace.xml"
write_appcast "$wrong_namespace_appcast" "$archive_length" "https://example.invalid/not-sparkle"
expect_failure "Sparkle metadata in an untrusted XML namespace" \
    verify_fixture_appcast "$wrong_namespace_appcast" "$archive"

echo "Sparkle update gate tests passed."
