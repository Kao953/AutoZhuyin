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

SYSTEM_APP="/Library/Input Methods/AutoZhuyin.app"
if [ -d "$SYSTEM_APP" ]; then
    OLD="$(plutil -extract CFBundleShortVersionString raw "$SYSTEM_APP/Contents/Info.plist" 2>/dev/null || echo '?')"
    echo
    echo "WARNING: a system-wide copy (v$OLD, installed from the .pkg) exists at:"
    echo "  $SYSTEM_APP"
    echo "macOS runs that copy instead of this one. Install the new .pkg"
    echo "(scripts/package.sh), or remove it with:"
    echo "  sudo rm -rf \"$SYSTEM_APP\" && pkill -x AutoZhuyin"
fi

echo
echo "Installed to $DEST/AutoZhuyin.app"
echo "First install: System Settings → Keyboard → Text Input → Edit… → + → 繁體中文 → 自動注音"
echo "(If it does not appear, log out and back in once.)"
