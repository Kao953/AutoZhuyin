#!/bin/bash
# Builds build/AutoZhuyin-Linux-<version>.tar.gz: the IBus engine, the shared Python
# core and data, and install/uninstall scripts (per-user install, no root needed).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' windows/autozhuyin/ime.json)"
NAME="AutoZhuyin-Linux-$VERSION"
OUT="build/$NAME"

[ -s build/lm/lm.bin ] || scripts/fetch-lm.sh >/dev/null     # "AI 選字" model
python3 -I windows/tools/build_data.py
(cd windows && python3 -m unittest discover -q tests)
python3 -m unittest discover -q -s linux/tests

if [ ! -f build/icon.tiff ]; then
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swift scripts/make-icon.swift build/icon.tiff
fi

rm -rf "$OUT" "$OUT.tar.gz"
mkdir -p "$OUT/autozhuyin"
rsync -a --exclude __pycache__ --exclude '*.pyc' \
    windows/autozhuyin/__init__.py windows/autozhuyin/core windows/autozhuyin/data "$OUT/autozhuyin/"
cp linux/autozhuyin_ibus.py linux/phrase_editor.py linux/installer/install.sh linux/installer/uninstall.sh linux/installer/README.txt \
    THIRD_PARTY_LICENSES.txt licenses/GPL-3.0.txt "$OUT/"
mkdir -p "$OUT/tools"
cp windows/tools/fetch_numpy.py "$OUT/tools/"     # install.sh downloads numpy if the system has none
echo "$VERSION" > "$OUT/version.txt"
sips -s format png -z 64 64 build/icon.tiff --out "$OUT/icon.png" >/dev/null
[ -f build/icon-en.tiff ] || DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swift scripts/make-icon.swift build/icon-en.tiff A
sips -s format png -z 64 64 build/icon-en.tiff --out "$OUT/icon-en.png" >/dev/null
chmod +x "$OUT/install.sh" "$OUT/uninstall.sh" "$OUT/autozhuyin_ibus.py" "$OUT/phrase_editor.py"

# Plain ustar without macOS extended attributes, so GNU tar doesn't warn.
(cd build && COPYFILE_DISABLE=1 tar --no-xattrs --format ustar -czf "$NAME.tar.gz" "$NAME")
echo "Built build/$NAME.tar.gz"
