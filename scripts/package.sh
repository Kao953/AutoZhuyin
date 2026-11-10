#!/bin/bash
# Builds build/AutoZhuyin-<version>.pkg: a universal (Apple Silicon + Intel) installer
# that puts AutoZhuyin.app into /Library/Input Methods for all users.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
ID="com.autozhuyin.inputmethod.pkg"
STAGE="build/pkgroot"
WORK="build/pkgwork"
OUT="build/AutoZhuyin-$VERSION.pkg"

rm -rf "$STAGE" "$WORK"
mkdir -p "$STAGE" "$WORK"
cp -R build/AutoZhuyin.app "$STAGE/"
chmod +x scripts/pkg/postinstall

# Always install to /Library/Input Methods, even if another copy exists elsewhere.
pkgbuild --analyze --root "$STAGE" "$WORK/component.plist" > "$WORK/analyze.log"
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"

pkgbuild --root "$STAGE" \
    --component-plist "$WORK/component.plist" \
    --install-location "/Library/Input Methods" \
    --scripts scripts/pkg \
    --identifier "$ID" \
    --version "$VERSION" \
    "$WORK/AutoZhuyin-component.pkg"

# Distribution wrapper: productbuild declares both architectures (hostArchitectures), so
# Apple Silicon Macs don't ask for Rosetta. Add an installer title.
productbuild --synthesize --package "$WORK/AutoZhuyin-component.pkg" "$WORK/distribution.xml"
grep -q 'hostArchitectures="x86_64,arm64"' "$WORK/distribution.xml" \
    || sed -i '' 's#<options #<options hostArchitectures="x86_64,arm64" #' "$WORK/distribution.xml"
sed -i '' 's#<options #<title>自動注音 AutoZhuyin</title>\
    <options #' "$WORK/distribution.xml"
productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" "$OUT"

echo "Built $OUT"
