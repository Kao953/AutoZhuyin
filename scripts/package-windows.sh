#!/bin/bash
# Builds build/AutoZhuyin-Windows-<version>.zip: the PIME input method folder plus
# install/uninstall scripts and a README for testers.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' windows/autozhuyin/ime.json)"
NAME="AutoZhuyin-Windows-$VERSION"
OUT="build/$NAME"

[ -s build/lm/lm.bin ] || scripts/fetch-lm.sh >/dev/null     # "AI 選字" model
python3 -I windows/tools/build_data.py
(cd windows && python3 -m unittest discover -q tests)

# Icon: render the Mac icon to PNG and wrap it in an .ico (PNG-in-ICO, Vista+).
if [ ! -f build/icon.tiff ]; then
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" xcrun swift scripts/make-icon.swift build/icon.tiff
fi
sips -s format png -z 32 32 build/icon.tiff --out build/icon-32.png >/dev/null
python3 -I windows/tools/png_to_ico.py build/icon-32.png windows/autozhuyin/icon.ico

rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT"
rsync -a --exclude __pycache__ --exclude '*.pyc' windows/autozhuyin "$OUT/"

# Windows tools expect CRLF line endings in .bat files.
for f in install.bat uninstall.bat README.txt; do
    sed 's/$/\r/' "windows/installer/$f" > "$OUT/$f"
done
# Third-party notices: next to the installer and inside the installed folder.
sed 's/$/\r/' THIRD_PARTY_LICENSES.txt > "$OUT/THIRD_PARTY_LICENSES.txt"
cp "$OUT/THIRD_PARTY_LICENSES.txt" "$OUT/autozhuyin/"
sed 's/$/\r/' licenses/GPL-3.0.txt > "$OUT/autozhuyin/GPL-3.0.txt"

# numpy for "AI 選字", for both Pythons PIME ships (1.3: 3.8, 2.x: 3.15; both 32-bit).
for tag in cp38 cp315; do
    [ -d "build/numpy-vendor/$tag" ] || python3 -I windows/tools/fetch_numpy.py build/numpy-vendor "$tag" win32
done
mkdir -p "$OUT/autozhuyin/vendor"
cp -R build/numpy-vendor/cp38 build/numpy-vendor/cp315 "$OUT/autozhuyin/vendor/"

(cd build && zip -qr -X "$NAME.zip" "$NAME")
echo "Built build/$NAME.zip"
