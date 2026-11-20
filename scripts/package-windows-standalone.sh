#!/bin/bash
# Builds build/AutoZhuyin-Windows-Standalone-<version>-setup.exe: the experimental
# stand-alone text service (no PIME) — TSF DLLs (scripts/build-tsf.sh), an embeddable
# 64-bit Python with numpy, the engine server and the shared Python core.
# Needs mingw-w64 and makensis (brew install mingw-w64 makensis). Run
# scripts/package-windows.sh first: it builds the data files and the icon.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' windows/autozhuyin/ime.json)"
NAME="AutoZhuyin-Windows-Standalone-$VERSION"
OUT="build/$NAME"
PY_TAG=cp312

[ -f windows/autozhuyin/data/lm.bin ] || scripts/package-windows.sh >/dev/null   # data files, model, icon
(cd windows && python3 -m unittest discover -q -s tests -p test_tsf_server.py)
scripts/build-tsf.sh >/dev/null
PY_ZIP="$(scripts/fetch-python-embed.sh)"
[ -d "build/numpy-vendor/$PY_TAG-win_amd64" ] ||
    python3 -I windows/tools/fetch_numpy.py "build/numpy-vendor/$PY_TAG-win_amd64" "$PY_TAG" win_amd64

rm -rf "$OUT"
mkdir -p "$OUT/python" "$OUT/autozhuyin"
cp -R build/tsf/x64 build/tsf/x86 "$OUT/"
unzip -q "$PY_ZIP" -d "$OUT/python"
cp windows/tsf/server.py "$OUT/"
rsync -a --exclude __pycache__ --exclude '*.pyc' windows/autozhuyin/core windows/autozhuyin/data \
    windows/autozhuyin/__init__.py "$OUT/autozhuyin/"
mkdir -p "$OUT/autozhuyin/vendor"
cp -R "build/numpy-vendor/$PY_TAG-win_amd64/$PY_TAG" "$OUT/autozhuyin/vendor/"
for f in THIRD_PARTY_LICENSES.txt licenses/GPL-3.0.txt; do sed 's/$/\r/' "$f" > "$OUT/$(basename "$f")"; done

printf '\xEF\xBB\xBF' | cat - "$OUT/THIRD_PARTY_LICENSES.txt" > build/standalone-license.txt
rm -f "build/$NAME-setup.exe"
makensis -V2 -INPUTCHARSET UTF8 -DVERSION="$VERSION" -DSRC="$PWD/$OUT" \
    -DLICENSE="$PWD/build/standalone-license.txt" -DOUTFILE="$PWD/build/$NAME-setup.exe" windows/tsf/setup.nsi
echo "Built build/$NAME-setup.exe"
