#!/bin/bash
# Downloads the PIME installer (LGPL 2.1, https://github.com/EasyIME/PIME) that the
# Windows setup.exe bundles, and checks it against a pinned SHA-256. Prints its path.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=1.3.0-stable
SHA256=6b2e288b95085a52f378f023fb17128f5b1389a3cdae078c7e4d47c1b4e9dc35
OUT="build/downloads/PIME-$VERSION-setup.exe"

mkdir -p build/downloads
[ -s "$OUT" ] || curl -sfL -o "$OUT" "https://github.com/EasyIME/PIME/releases/download/v$VERSION/PIME-$VERSION-setup.exe"
if ! echo "$SHA256  $OUT" | shasum -a 256 -c - >/dev/null; then
    echo "SHA-256 mismatch for $OUT" >&2
    rm -f "$OUT"
    exit 1
fi
echo "$OUT"
