#!/bin/bash
# Builds build/AutoZhuyin.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

# Use the full Xcode toolchain (the Command Line Tools SDK may be incomplete).
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

CONFIG="${CONFIG:-release}"
APP="build/AutoZhuyin.app"

# Universal binary: runs on both Apple Silicon and Intel Macs.
ARCH_FLAGS=(--arch arm64 --arch x86_64)
xcrun swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --product AutoZhuyin
BIN="$(xcrun swift build -c "$CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)/AutoZhuyin"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AutoZhuyin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/lexicon.txt Resources/english-common.txt Resources/classifier-weights.json "$APP/Contents/Resources/"
cp THIRD_PARTY_LICENSES.txt "$APP/Contents/Resources/"
# Precomputed English dictionary and bigram table (shared with the Windows build).
python3 -I windows/tools/build_data.py >/dev/null
cp windows/autozhuyin/data/english-dict.txt windows/autozhuyin/data/english-bigram.json "$APP/Contents/Resources/"

if [ ! -f build/icon.tiff ]; then
    xcrun swift scripts/make-icon.swift build/icon.tiff
fi
cp build/icon.tiff "$APP/Contents/Resources/icon.tiff"

codesign --force --sign - "$APP"
echo "Built $APP"
