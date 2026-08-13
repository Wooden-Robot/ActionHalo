#!/bin/bash

set -euo pipefail

fail() {
    echo "❌ $*" >&2
    exit 1
}

appcast=""
archive=""
version=""
download_url=""
sign_update=""
account=""
ed_key_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --appcast)
            [[ $# -ge 2 ]] || fail "--appcast requires a path."
            appcast="$2"
            shift 2
            ;;
        --archive)
            [[ $# -ge 2 ]] || fail "--archive requires a path."
            archive="$2"
            shift 2
            ;;
        --version)
            [[ $# -ge 2 ]] || fail "--version requires X.Y.Z."
            version="$2"
            shift 2
            ;;
        --download-url)
            [[ $# -ge 2 ]] || fail "--download-url requires a URL."
            download_url="$2"
            shift 2
            ;;
        --sign-update)
            [[ $# -ge 2 ]] || fail "--sign-update requires the Sparkle tool path."
            sign_update="$2"
            shift 2
            ;;
        --account)
            [[ $# -ge 2 ]] || fail "--account requires a Keychain account."
            account="$2"
            shift 2
            ;;
        --ed-key-file)
            [[ $# -ge 2 ]] || fail "--ed-key-file requires a private test key path."
            ed_key_file="$2"
            shift 2
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -f "$appcast" ]] || fail "Appcast does not exist: $appcast"
[[ -f "$archive" ]] || fail "Update archive does not exist: $archive"
[[ -x "$sign_update" ]] || fail "Sparkle sign_update is missing or not executable: $sign_update"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Version must use X.Y.Z format."
[[ "$download_url" == https://github.com/Wooden-Robot/OpenFire/releases/download/v"$version"/OpenFire.dmg ]] \
    || fail "Unexpected OpenFire update URL: $download_url"
[[ -z "$account" || -z "$ed_key_file" ]] \
    || fail "Use either --account or --ed-key-file, not both."
[[ -n "$account" || -n "$ed_key_file" ]] \
    || fail "A signing credential is required for cryptographic verification."
if [[ -n "$ed_key_file" ]]; then
    [[ -f "$ed_key_file" ]] || fail "Ed25519 key file does not exist: $ed_key_file"
    credential_args=(--ed-key-file "$ed_key_file")
else
    credential_args=(--account "$account")
fi
command -v xmllint >/dev/null 2>&1 || fail "xmllint is required."

xml_value() {
    xmllint --nonet --xpath "string($1)" "$appcast" 2>/dev/null \
        || fail "Could not parse signed appcast: $appcast"
}

xml_count() {
    xmllint --nonet --xpath "count($1)" "$appcast" 2>/dev/null \
        || fail "Could not parse signed appcast: $appcast"
}

sparkle_namespace='http://www.andymatuschak.org/xml-namespaces/sparkle'
item_path='/*[local-name()="rss" and namespace-uri()=""]/*[local-name()="channel" and namespace-uri()=""]/*[local-name()="item" and namespace-uri()=""]'
version_path="$item_path/*[local-name()=\"version\" and namespace-uri()=\"$sparkle_namespace\"]"
short_version_path="$item_path/*[local-name()=\"shortVersionString\" and namespace-uri()=\"$sparkle_namespace\"]"
enclosure_path="$item_path/*[local-name()=\"enclosure\" and namespace-uri()=\"\"]"
signature_path="$enclosure_path/@*[local-name()=\"edSignature\" and namespace-uri()=\"$sparkle_namespace\"]"

[[ "$(xml_count "$item_path")" == "1" ]] \
    || fail "Appcast must contain exactly one current update."
[[ "$(xml_count "$version_path")" == "1" ]] \
    || fail "Appcast must contain exactly one Sparkle version element."
[[ "$(xml_count "$short_version_path")" == "1" ]] \
    || fail "Appcast must contain exactly one Sparkle short-version element."
[[ "$(xml_count "$enclosure_path")" == "1" ]] \
    || fail "Appcast must contain exactly one update enclosure."
[[ "$(xml_count "$signature_path")" == "1" ]] \
    || fail "Appcast must contain exactly one Sparkle archive signature."

actual_version="$(xml_value "$version_path")"
actual_short_version="$(xml_value "$short_version_path")"
actual_download_url="$(xml_value "$enclosure_path/@url")"
archive_length="$(xml_value "$enclosure_path/@length")"
archive_type="$(xml_value "$enclosure_path/@type")"
archive_signature="$(xml_value "$signature_path")"
actual_archive_length="$(stat -f '%z' "$archive")"

[[ "$actual_version" == "$version" ]] \
    || fail "Appcast version is $actual_version; expected $version."
[[ "$actual_short_version" == "$version" ]] \
    || fail "Appcast short version is $actual_short_version; expected $version."
[[ "$actual_download_url" == "$download_url" ]] \
    || fail "Appcast download URL is $actual_download_url; expected $download_url."
[[ "$archive_type" == "application/octet-stream" ]] \
    || fail "Appcast enclosure has an unexpected MIME type: $archive_type"
[[ "$archive_length" =~ ^[0-9]+$ && "$archive_length" == "$actual_archive_length" ]] \
    || fail "Appcast enclosure length $archive_length does not match archive size $actual_archive_length."
[[ "$archive_signature" =~ ^[A-Za-z0-9+/]{86}==$ ]] \
    || fail "Appcast update enclosure has no well-formed Ed25519 signature."

"$sign_update" "${credential_args[@]}" --verify "$appcast" >/dev/null \
    || fail "Appcast feed signature verification failed."
"$sign_update" "${credential_args[@]}" --verify "$archive" "$archive_signature" >/dev/null \
    || fail "Appcast enclosure signature does not match the update archive."

echo "✅ Sparkle feed and archive signatures verified for $version."
