#!/usr/bin/env bash
set -euo pipefail

# Standalone diagnostic APK: no Gradle changes, no dependency downloads, no production packaging.
fixture_source="$(cd "$(dirname "$0")" && pwd)"
fixture_sdk="${ANDROID_SDK_ROOT:-/Users/woodenrobot/Library/Android/sdk}"
fixture_java="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
fixture_output="${1:-/private/tmp/actionhalo-telegram-copy-fixture}"
fixture_build_tools="$fixture_sdk/build-tools/36.0.0"
fixture_android_jar="$fixture_sdk/platforms/android-36/android.jar"
mkdir -p "$fixture_output/classes" "$fixture_output/dex"
"$fixture_java/bin/javac" --release 8 -encoding UTF-8 -classpath "$fixture_android_jar" -d "$fixture_output/classes" "$fixture_source/CopyFixtureActivity.java"
"$fixture_java/bin/jar" cf "$fixture_output/fixture.jar" -C "$fixture_output/classes" .
JAVA_HOME="$fixture_java" "$fixture_build_tools/d8" --lib "$fixture_android_jar" --min-api 26 --output "$fixture_output/dex" "$fixture_output/fixture.jar"
"$fixture_build_tools/aapt2" link --manifest "$fixture_source/AndroidManifest.xml" -I "$fixture_android_jar" -o "$fixture_output/unsigned.apk"
zip -j -q "$fixture_output/unsigned.apk" "$fixture_output/dex/classes.dex"
"$fixture_build_tools/zipalign" -f 4 "$fixture_output/unsigned.apk" "$fixture_output/aligned.apk"
if [[ ! -e "$fixture_output/fixture.keystore" ]]; then
  "$fixture_java/bin/keytool" -genkeypair -keystore "$fixture_output/fixture.keystore" -storepass android -keypass android -alias fixture -dname "CN=Temporary Telegram Copy Fixture" -keyalg RSA -keysize 2048 -validity 30 -noprompt
fi
JAVA_HOME="$fixture_java" "$fixture_build_tools/apksigner" sign --ks "$fixture_output/fixture.keystore" --ks-key-alias fixture --ks-pass pass:android --key-pass pass:android --out "$fixture_output/telegram-copy-fixture.apk" "$fixture_output/aligned.apk"
JAVA_HOME="$fixture_java" "$fixture_build_tools/apksigner" verify "$fixture_output/telegram-copy-fixture.apk"
printf '%s\n' "$fixture_output/telegram-copy-fixture.apk"
