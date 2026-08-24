#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 --version X.Y.Z --output PATH --sign-update PATH --generate-keys PATH --account NAME --expected-public-key KEY" >&2
}

version=""
output=""
sign_update=""
generate_keys=""
account=""
expected_public_key=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            version="${2:-}"
            shift 2
            ;;
        --output)
            output="${2:-}"
            shift 2
            ;;
        --sign-update)
            sign_update="${2:-}"
            shift 2
            ;;
        --generate-keys)
            generate_keys="${2:-}"
            shift 2
            ;;
        --account)
            account="${2:-}"
            shift 2
            ;;
        --expected-public-key)
            expected_public_key="${2:-}"
            shift 2
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
   [[ -z "$output" || -z "$account" || -z "$expected_public_key" ]] ||
   [[ ! -x "$sign_update" || ! -x "$generate_keys" ]]; then
    usage
    exit 2
fi

signing_public_key="$("$generate_keys" --account "$account" -p)"
if [[ "$signing_public_key" != "$expected_public_key" ]]; then
    echo "Legacy migration feed signing key does not match the existing installation trust root." >&2
    exit 1
fi

output_directory="${output%/*}"
if [[ "$output_directory" == "$output" ]]; then
    output_directory="."
fi
mkdir -p "$output_directory"

temporary_directory="$(mktemp -d)"
unsigned_appcast="$temporary_directory/appcast.xml"
trap 'rm -rf "$temporary_directory"' EXIT

printf '%s\n' \
    '<?xml version="1.0" encoding="utf-8"?>' \
    '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">' \
    '  <channel>' \
    '    <title>ActionHalo Migration Notice</title>' \
    '    <item>' \
    '      <title>ActionHalo requires a fresh installation</title>' \
    '      <link>https://github.com/Wooden-Robot/ActionHalo/releases/latest/download/ActionHalo.dmg</link>' \
    "      <sparkle:version>$version</sparkle:version>" \
    "      <sparkle:shortVersionString>$version</sparkle:shortVersionString>" \
    '      <sparkle:informationalUpdate></sparkle:informationalUpdate>' \
    '      <description sparkle:format="markdown"><![CDATA[' \
    '## ActionHalo 需要全新安装' \
    '' \
    'OpenFire 不再支持自动升级到 ActionHalo。请下载最新版安装包并启动 ActionHalo；新 App 会一次性导入兼容设置、转换旧插件，然后提示你将旧版移到废纸篓。已有 ActionHalo 数据不会被覆盖，插件执行信任需要重新确认。' \
    '' \
    '点击“了解更多”会直接下载最新版 ActionHalo.dmg。' \
    '' \
    '## ActionHalo requires a fresh installation' \
    '' \
    'OpenFire can no longer update automatically to ActionHalo. Download and launch the latest ActionHalo; the new app imports compatible settings, converts old plugins once, then offers to move the old app to the Trash. Existing ActionHalo data is preserved and plugin execution trust must be confirmed again.' \
    '' \
    'Click “Learn More” to download the latest ActionHalo.dmg directly.' \
    ']]></description>' \
    '    </item>' \
    '  </channel>' \
    '</rss>' > "$unsigned_appcast"

"$sign_update" \
    --account "$account" \
    --disable-signing-warning \
    "$unsigned_appcast"
"$sign_update" --account "$account" --verify "$unsigned_appcast"

mv "$unsigned_appcast" "$output"
echo "Created signed legacy migration notice at $output"
