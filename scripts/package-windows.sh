#!/bin/bash
# Builds build/AutoZhuyin-Windows-<version>.zip: the PIME input method folder plus
# install/uninstall scripts and a README for testers.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' windows/autozhuyin/ime.json)"
NAME="AutoZhuyin-Windows-$VERSION"
OUT="build/$NAME"

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

(cd build && zip -qr -X "$NAME.zip" "$NAME")
echo "Built build/$NAME.zip"
