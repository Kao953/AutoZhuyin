#!/bin/bash
# Downloads the embeddable 64-bit Python that the stand-alone Windows text service runs
# its engine server with, checked against a pinned SHA-256. Prints its path.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=3.12.10
SHA256=4acbed6dd1c744b0376e3b1cf57ce906f9dc9e95e68824584c8099a63025a3c3
OUT="build/downloads/python-$VERSION-embed-amd64.zip"

mkdir -p build/downloads
[ -s "$OUT" ] || curl -sfL -o "$OUT" "https://www.python.org/ftp/python/$VERSION/python-$VERSION-embed-amd64.zip"
if ! echo "$SHA256  $OUT" | shasum -a 256 -c - >/dev/null; then
    echo "SHA-256 mismatch for $OUT" >&2
    rm -f "$OUT"
    exit 1
fi
echo "$OUT"
