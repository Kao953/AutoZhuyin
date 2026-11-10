#!/bin/bash
# Builds and installs AutoZhuyin into ~/Library/Input Methods, restarting any running copy.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
DEST="$HOME/Library/Input Methods"
mkdir -p "$DEST"

# The running server keeps the old binary; kill it so macOS relaunches the new one.
pkill -x AutoZhuyin || true
rm -rf "$DEST/AutoZhuyin.app"
cp -R build/AutoZhuyin.app "$DEST/"
"$DEST/AutoZhuyin.app/Contents/MacOS/AutoZhuyin" --register

echo
echo "Installed to $DEST/AutoZhuyin.app"
echo "First install: System Settings → Keyboard → Text Input → Edit… → + → 繁體中文 → 自動注音"
echo "(If it does not appear, log out and back in once.)"
