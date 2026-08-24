#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
generator="$project_root/Tools/generate_legacy_migration_appcast.sh"
fixture_directory="$(mktemp -d)"
trap 'rm -rf "$fixture_directory"' EXIT

fake_generate_keys="$fixture_directory/generate_keys"
fake_sign_update="$fixture_directory/sign_update"
expected_public_key="legacy-public-key"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '[[ "$*" == "--account LegacyMigration -p" ]]' \
    'printf "%s\\n" "legacy-public-key"' > "$fake_generate_keys"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'file="${!#}"' \
    'if [[ " $* " == *" --verify "* ]]; then' \
    '    grep -Fq "<!-- sparkle-signatures:" "$file"' \
    '    exit 0' \
    'fi' \
    '[[ " $* " == *" --account LegacyMigration "* ]]' \
    'printf "%s\\n" "<!-- sparkle-signatures:" "edSignature: fixture" "length: 1" "-->" >> "$file"' > "$fake_sign_update"

chmod +x "$fake_generate_keys" "$fake_sign_update"

output="$fixture_directory/appcast.xml"
bash "$generator" \
    --version 1.2.3 \
    --output "$output" \
    --sign-update "$fake_sign_update" \
    --generate-keys "$fake_generate_keys" \
    --account LegacyMigration \
    --expected-public-key "$expected_public_key"

xmllint --noout "$output"
grep -Fq '<sparkle:version>1.2.3</sparkle:version>' "$output"
grep -Fq '<sparkle:informationalUpdate></sparkle:informationalUpdate>' "$output"
grep -Fq '<link>https://github.com/Wooden-Robot/ActionHalo/releases/latest/download/ActionHalo.dmg</link>' "$output"
grep -Fq 'OpenFire 不再支持自动升级到 ActionHalo' "$output"
grep -Fq '一次性导入兼容设置、转换旧插件' "$output"
grep -Fq '已有 ActionHalo 数据不会被覆盖' "$output"
grep -Fq '插件执行信任需要重新确认' "$output"
grep -Fq 'plugin execution trust must be confirmed again' "$output"
grep -Fq '<!-- sparkle-signatures:' "$output"
if grep -Fq '<enclosure' "$output"; then
    echo "FAIL: legacy migration appcast must never contain an installable enclosure" >&2
    exit 1
fi

if bash "$generator" \
    --version invalid \
    --output "$fixture_directory/invalid.xml" \
    --sign-update "$fake_sign_update" \
    --generate-keys "$fake_generate_keys" \
    --account LegacyMigration \
    --expected-public-key "$expected_public_key" >/dev/null 2>&1; then
    echo "FAIL: invalid versions must be rejected" >&2
    exit 1
fi

if bash "$generator" \
    --version 1.2.3 \
    --output "$fixture_directory/wrong-key.xml" \
    --sign-update "$fake_sign_update" \
    --generate-keys "$fake_generate_keys" \
    --account LegacyMigration \
    --expected-public-key wrong-key >/dev/null 2>&1; then
    echo "FAIL: a mismatched legacy signing key must be rejected" >&2
    exit 1
fi

echo "PASS: legacy clients receive a signed informational migration notice with a direct ActionHalo DMG link"
