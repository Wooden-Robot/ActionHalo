#!/bin/bash

set -euo pipefail

fail() {
    echo "❌ $*" >&2
    exit 1
}

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
info_plist=""
artifact_app=""
require_ad_hoc=false
package_resolved="$project_root/Package.resolved"
expected_feed_url="https://github.com/Wooden-Robot/ActionHalo/releases/latest/download/actionhalo-appcast.xml"
expected_public_key="PEn1mxr6DuGIBoGHNbx21ZANmnIi6gr/kBaaYRcKTTY="
expected_sparkle_version="2.9.4"
expected_sparkle_revision="b6496a74a087257ef5e6da1c5b29a447a60f5bd7"
expected_app_name="ActionHalo"
expected_bundle_identifier="com.actionhalo.app"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --info-plist)
            [[ $# -ge 2 ]] || fail "--info-plist requires a path."
            info_plist="$2"
            shift 2
            ;;
        --app)
            [[ $# -ge 2 ]] || fail "--app requires a path."
            artifact_app="$2"
            shift 2
            ;;
        --require-ad-hoc)
            require_ad_hoc=true
            shift
            ;;
        --package-resolved)
            [[ $# -ge 2 ]] || fail "--package-resolved requires a path."
            package_resolved="$2"
            shift 2
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$info_plist" ]] || fail "--info-plist is required."
[[ -f "$info_plist" ]] || fail "Info.plist does not exist: $info_plist"
[[ -f "$package_resolved" ]] || fail "Package.resolved does not exist: $package_resolved"

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null \
        || fail "$1 is missing $2."
}

plist_key_exists() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" >/dev/null 2>&1
}

verify_plist() {
    local plist_path="$1"
    local description="$2"
    local feed_url
    local public_key
    local automatic_checks
    local automatic_install
    local verify_before_extraction
    local require_signed_feed
    local failure_expiration
    local bundle_name
    local bundle_display_name
    local bundle_executable
    local bundle_identifier
    local legacy_identity
    local signing_identifier

    feed_url="$(plist_value "$plist_path" SUFeedURL)"
    public_key="$(plist_value "$plist_path" SUPublicEDKey)"
    automatic_checks="$(plist_value "$plist_path" SUEnableAutomaticChecks)"
    automatic_install="$(plist_value "$plist_path" SUAutomaticallyUpdate)"
    verify_before_extraction="$(plist_value "$plist_path" SUVerifyUpdateBeforeExtraction)"
    require_signed_feed="$(plist_value "$plist_path" SURequireSignedFeed)"
    failure_expiration="$(plist_value "$plist_path" SUSignedFeedFailureExpirationInterval)"
    bundle_name="$(plist_value "$plist_path" CFBundleName)"
    bundle_display_name="$(plist_value "$plist_path" CFBundleDisplayName)"
    bundle_executable="$(plist_value "$plist_path" CFBundleExecutable)"
    bundle_identifier="$(plist_value "$plist_path" CFBundleIdentifier)"

    [[ "$feed_url" == "$expected_feed_url" ]] \
        || fail "$description has an unexpected Sparkle feed URL: $feed_url"
    [[ "$public_key" == "$expected_public_key" ]] \
        || fail "$description does not contain the pinned ActionHalo update key."
    [[ "$automatic_checks" == "true" ]] \
        || fail "$description must enable automatic update checks by default."
    [[ "$automatic_install" == "false" ]] \
        || fail "$description must require an explicit user install action."
    [[ "$verify_before_extraction" == "true" ]] \
        || fail "$description must verify updates before extraction."
    [[ "$require_signed_feed" == "true" ]] \
        || fail "$description must require signed appcasts."
    [[ "$failure_expiration" == "0" ]] \
        || fail "$description must not expire signed-feed verification failures."
    [[ "$bundle_name" == "$expected_app_name" ]] \
        || fail "$description has an unexpected CFBundleName: $bundle_name"
    [[ "$bundle_display_name" == "$expected_app_name" ]] \
        || fail "$description has an unexpected CFBundleDisplayName: $bundle_display_name"
    [[ "$bundle_executable" == "$expected_app_name" ]] \
        || fail "$description has an unexpected CFBundleExecutable: $bundle_executable"
    [[ "$bundle_identifier" == "$expected_bundle_identifier" ]] \
        || fail "$description has an unexpected bundle identifier: $bundle_identifier"
    legacy_identity="$(plutil -convert xml1 -o - "$plist_path" | grep -Ei 'openfire|com\.openfire' || true)"
    [[ -z "$legacy_identity" ]] \
        || fail "$description still contains a legacy OpenFire identity."
    [[ "$(plist_value "$plist_path" 'CFBundleDocumentTypes:0:CFBundleTypeExtensions:0')" == "actionhaloext" ]] \
        || fail "$description does not register the canonical .actionhaloext package."
    [[ "$(plist_value "$plist_path" 'CFBundleDocumentTypes:0:CFBundleTypeName')" == "ActionHalo Extension" ]] \
        || fail "$description has an unexpected ActionHalo document type name."
    [[ "$(plist_value "$plist_path" 'CFBundleDocumentTypes:0:LSItemContentTypes:0')" == "com.actionhalo.extension" ]] \
        || fail "$description does not register the canonical ActionHalo extension UTI."
    ! plist_key_exists "$plist_path" 'CFBundleDocumentTypes:0:CFBundleTypeExtensions:1' \
        || fail "$description registers more than one extension for ActionHalo documents."
    ! plist_key_exists "$plist_path" 'CFBundleDocumentTypes:0:LSItemContentTypes:1' \
        || fail "$description registers more than one UTI for ActionHalo documents."
    ! plist_key_exists "$plist_path" 'CFBundleDocumentTypes:1' \
        || fail "$description registers a non-ActionHalo document type."
    [[ "$(plist_value "$plist_path" 'UTExportedTypeDeclarations:0:UTTypeIdentifier')" == "com.actionhalo.extension" ]] \
        || fail "$description does not export the canonical ActionHalo extension UTI."
    [[ "$(plist_value "$plist_path" 'UTExportedTypeDeclarations:0:UTTypeDescription')" == "ActionHalo Extension Package" ]] \
        || fail "$description has an unexpected ActionHalo UTI description."
    [[ "$(plist_value "$plist_path" 'UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0')" == "actionhaloext" ]] \
        || fail "$description does not export the canonical .actionhaloext filename extension."
    ! plist_key_exists "$plist_path" 'UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:1' \
        || fail "$description exports more than one filename extension for the ActionHalo UTI."
    ! plist_key_exists "$plist_path" 'UTExportedTypeDeclarations:1' \
        || fail "$description exports a non-ActionHalo UTI."
}

sparkle_pin_index=""
pin_index=0
while resolved_identity="$(plutil -extract "pins.$pin_index.identity" raw "$package_resolved" 2>/dev/null)"; do
    if [[ "$resolved_identity" == "sparkle" ]]; then
        [[ -z "$sparkle_pin_index" ]] || fail "Package.resolved contains multiple Sparkle pins."
        sparkle_pin_index="$pin_index"
    fi
    pin_index=$((pin_index + 1))
done
[[ -n "$sparkle_pin_index" ]] || fail "Package.resolved has no Sparkle dependency pin."
resolved_version="$(plutil -extract "pins.$sparkle_pin_index.state.version" raw "$package_resolved" 2>/dev/null)" \
    || fail "Could not read the Sparkle dependency version from $package_resolved."
resolved_revision="$(plutil -extract "pins.$sparkle_pin_index.state.revision" raw "$package_resolved" 2>/dev/null)" \
    || fail "Could not read the Sparkle dependency revision from $package_resolved."
[[ "$resolved_version" == "$expected_sparkle_version" ]] \
    || fail "Sparkle is $resolved_version; expected $expected_sparkle_version."
[[ "$resolved_revision" == "$expected_sparkle_revision" ]] \
    || fail "Sparkle revision is $resolved_revision; expected $expected_sparkle_revision."

verify_plist "$info_plist" "Source Info.plist"

if [[ -n "$artifact_app" ]]; then
    [[ -d "$artifact_app" ]] || fail "Packaged app does not exist: $artifact_app"
    artifact_plist="$artifact_app/Contents/Info.plist"
    executable="$artifact_app/Contents/MacOS/ActionHalo"
    framework="$artifact_app/Contents/Frameworks/Sparkle.framework"
    sparkle_license="$artifact_app/Contents/Resources/ThirdPartyLicenses/Sparkle.txt"

    [[ -f "$artifact_plist" ]] || fail "Packaged Info.plist is missing."
    [[ -x "$executable" ]] || fail "Packaged ActionHalo executable is missing."
    [[ -d "$framework" ]] || fail "Packaged Sparkle.framework is missing."
    [[ -f "$sparkle_license" ]] || fail "Packaged Sparkle license notice is missing."
    grep -Fq 'Copyright (c) 2006-2013 Andy Matuschak.' "$sparkle_license" \
        || fail "Packaged Sparkle license notice is invalid."
    [[ -L "$framework/Versions/Current" ]] \
        || fail "Sparkle.framework version symlinks were not preserved."

    verify_plist "$artifact_plist" "Packaged Info.plist"
    [[ "$(plist_value "$framework/Versions/B/Resources/Info.plist" CFBundleShortVersionString)" == "$expected_sparkle_version" ]] \
        || fail "Packaged Sparkle.framework has an unexpected version."

    codesign --verify --deep --strict "$artifact_app" >/dev/null 2>&1 \
        || fail "Packaged app signature is invalid."
    otool -L "$executable" | grep -Fq "@rpath/Sparkle.framework/Versions/B/Sparkle" \
        || fail "ActionHalo is not linked to the embedded Sparkle framework through @rpath."
    otool -l "$executable" | grep -A2 LC_RPATH | grep -Fq "@executable_path/../Frameworks" \
        || fail "ActionHalo does not contain the embedded-framework runtime search path."

    executable_arches="$(lipo -archs "$executable")"
    [[ " $executable_arches " == *" x86_64 "* && " $executable_arches " == *" arm64 "* ]] \
        || fail "Packaged ActionHalo executable is not universal: $executable_arches"

    framework_arches="$(lipo -archs "$framework/Versions/B/Sparkle")"
    [[ " $framework_arches " == *" x86_64 "* && " $framework_arches " == *" arm64 "* ]] \
        || fail "Packaged Sparkle.framework is not universal: $framework_arches"

    if [[ "$require_ad_hoc" == true ]]; then
        signing_metadata="$(codesign -dv --verbose=4 "$artifact_app" 2>&1)" \
            || fail "Could not inspect packaged app signing metadata."
        grep -Eq '^Signature=adhoc$' <<<"$signing_metadata" \
            || fail "Community release app must use an ad-hoc code signature."
        grep -Eq '^TeamIdentifier=not set$' <<<"$signing_metadata" \
            || fail "Community release app must not carry an Apple Team identity."
        signing_identifier="$(sed -n 's/^Identifier=//p' <<<"$signing_metadata")"
        [[ "$signing_identifier" == "$expected_bundle_identifier" ]] \
            || fail "Release code-signing identifier is $signing_identifier; expected $expected_bundle_identifier."
        [[ "$(plist_value "$artifact_plist" CFBundleIdentifier)" == "$expected_bundle_identifier" ]] \
            || fail "Release app has an unexpected bundle identifier."
        ! grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$signing_metadata" \
            || fail "Ad-hoc ActionHalo must not enable Hardened Runtime because Library Validation blocks its separately ad-hoc-signed Sparkle framework."

        signed_items=(
            "$framework/Versions/B/XPCServices/Installer.xpc"
            "$framework/Versions/B/XPCServices/Downloader.xpc"
            "$framework/Versions/B/Autoupdate"
            "$framework/Versions/B/Updater.app"
            "$framework"
        )
        expected_identifiers=(
            "org.sparkle-project.InstallerLauncher"
            "org.sparkle-project.DownloaderService"
            "Autoupdate-"
            "org.sparkle-project.Sparkle.Updater"
            "org.sparkle-project.Sparkle"
        )
        signed_executables=(
            "$framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
            "$framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
            "$framework/Versions/B/Autoupdate"
            "$framework/Versions/B/Updater.app/Contents/MacOS/Updater"
            "$framework/Versions/B/Sparkle"
        )
        signed_index=0
        for signed_item in "${signed_items[@]}"; do
            nested_metadata="$(codesign -dv --verbose=4 "$signed_item" 2>&1)" \
                || fail "Could not inspect Sparkle component signing metadata: $signed_item"
            codesign --verify --strict --all-architectures "$signed_item" >/dev/null 2>&1 \
                || fail "Sparkle component code signature is invalid: $signed_item"
            grep -Eq '^Signature=adhoc$' <<<"$nested_metadata" \
                || fail "Sparkle component must use an ad-hoc code signature: $signed_item"
            grep -Eq '^TeamIdentifier=not set$' <<<"$nested_metadata" \
                || fail "Sparkle component must not carry an Apple Team identity: $signed_item"
            grep -Eq '^CodeDirectory .*flags=.*runtime' <<<"$nested_metadata" \
                || fail "Sparkle component is not signed with Hardened Runtime: $signed_item"

            nested_identifier="$(sed -n 's/^Identifier=//p' <<<"$nested_metadata")"
            expected_identifier="${expected_identifiers[$signed_index]}"
            if [[ "$expected_identifier" == "Autoupdate-" ]]; then
                [[ "$nested_identifier" == Autoupdate-* ]] \
                    || fail "Sparkle Autoupdate has an unexpected signing identifier: $nested_identifier"
            else
                [[ "$nested_identifier" == "$expected_identifier" ]] \
                    || fail "Sparkle component has an unexpected signing identifier: $nested_identifier"
            fi

            nested_arches="$(lipo -archs "${signed_executables[$signed_index]}")"
            [[ " $nested_arches " == *" x86_64 "* && " $nested_arches " == *" arm64 "* ]] \
                || fail "Sparkle component is not universal: ${signed_executables[$signed_index]} ($nested_arches)"
            signed_index=$((signed_index + 1))
        done
    fi
fi

echo "✅ Sparkle update configuration verified."
