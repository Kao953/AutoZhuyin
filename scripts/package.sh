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

# The "AI 高品質模型" option: no files, its script downloads the model (scripts/pkg-lm).
chmod +x scripts/pkg-lm/postinstall
pkgbuild --nopayload \
    --scripts scripts/pkg-lm \
    --identifier "com.autozhuyin.lm-large.pkg" \
    --version "$VERSION" \
    "$WORK/AutoZhuyin-lm.pkg"

# Distribution wrapper: both architectures (hostArchitectures), so Apple Silicon Macs don't
# ask for Rosetta, and the installation type page always shows the optional model.
cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>自動注音 AutoZhuyin</title>
    <options customize="always" require-scripts="false" hostArchitectures="x86_64,arm64"/>
    <domains enable_localSystem="true"/>
    <choices-outline>
        <line choice="app"/>
        <line choice="lm"/>
    </choices-outline>
    <choice id="app" title="自動注音" description="輸入法本身（必要）。" start_enabled="false" start_selected="true">
        <pkg-ref id="$ID"/>
    </choice>
    <choice id="lm" title="AI 高品質模型（下載約 200 MB）" start_selected="false"
            description="AI 選字更準（錯字約少四成），但多佔約 400 MB 記憶體。勾選後安裝時會下載，並把 AI 選字設為「高品質」。之後也可以在輸入法選單下載或移除。">
        <pkg-ref id="com.autozhuyin.lm-large.pkg"/>
    </choice>
    <pkg-ref id="$ID" version="$VERSION" onConclusion="none">AutoZhuyin-component.pkg</pkg-ref>
    <pkg-ref id="com.autozhuyin.lm-large.pkg" version="$VERSION" onConclusion="none">AutoZhuyin-lm.pkg</pkg-ref>
</installer-gui-script>
XML
productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" "$OUT"

echo "Built $OUT"
