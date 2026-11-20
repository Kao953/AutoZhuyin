#!/bin/bash
# Builds build/AutoZhuyin-Android-<version>.apk (runs the Kotlin core tests first).
#
# Needs JDK 17+ and the Android SDK (ANDROID_HOME). The shared data comes from
# windows/tools/build_data.py; build it on macOS so the English dictionary is the same
# Webster's word list the other versions use.
#
# Release signing, from the environment:
#   ANDROID_KEYSTORE  ANDROID_KEYSTORE_PASSWORD  ANDROID_KEY_ALIAS  ANDROID_KEY_PASSWORD
# Without them a debug-signed AutoZhuyin-Android-<version>-debug.apk is built: fine for
# testing, but it cannot update (or be updated by) a release-signed install.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(python3 -c 'import re,sys; print(re.search(r"<key>CFBundleShortVersionString</key>\s*<string>([^<]*)", open("Resources/Info.plist").read()).group(1))')"
[ -f windows/autozhuyin/data/english-dict.txt ] || python3 windows/tools/build_data.py

cd android
./gradlew --no-daemon -q :core:test
if [ -n "${ANDROID_KEYSTORE:-}" ]; then
    ./gradlew --no-daemon -q :app:assembleRelease
    APK=app/build/outputs/apk/release/app-release.apk
    OUT="../build/AutoZhuyin-Android-$VERSION.apk"
else
    echo "ANDROID_KEYSTORE not set: building a debug-signed APK" >&2
    ./gradlew --no-daemon -q :app:assembleDebug
    APK=app/build/outputs/apk/debug/app-debug.apk
    OUT="../build/AutoZhuyin-Android-$VERSION-debug.apk"
fi
mkdir -p ../build
cp "$APK" "$OUT"
echo "$OUT"
