#!/bin/bash
# One-step release: bump the version, run all tests, build both installers, then
# commit the version change and tag it.
#
# Usage: scripts/release.sh [patch|minor|major] [--push]   (default: patch)
#   --push  also pushes the commit and tag to origin
set -euo pipefail
cd "$(dirname "$0")/.."

LEVEL=patch
PUSH=0
for arg in "$@"; do
    case "$arg" in
        patch|minor|major) LEVEL="$arg" ;;
        --push) PUSH=1 ;;
        *) echo "usage: $0 [patch|minor|major] [--push]" >&2; exit 2 ;;
    esac
done

if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree has uncommitted changes; commit them first." >&2
    exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION="$(scripts/bump-version.sh "$LEVEL")"
echo "==> Version $VERSION"

restore() {
    echo "Release failed; reverting the version bump." >&2
    git checkout -- Resources/Info.plist windows/autozhuyin/ime.json
}
trap restore ERR

echo "==> Swift tests"
xcrun swift test -q 2>&1 | tail -3
echo "==> Packaging (runs the Python tests too)"
scripts/package.sh >/dev/null
scripts/package-windows.sh >/dev/null

trap - ERR
git add Resources/Info.plist windows/autozhuyin/ime.json
git commit -q -m "Release v$VERSION"
git tag -a "v$VERSION" -m "AutoZhuyin v$VERSION"
echo "==> Tagged v$VERSION"
ls -lh "build/AutoZhuyin-$VERSION.pkg" "build/AutoZhuyin-Windows-$VERSION.zip"
shasum -a 256 "build/AutoZhuyin-$VERSION.pkg" "build/AutoZhuyin-Windows-$VERSION.zip"

if [ "$PUSH" = 1 ]; then
    git push origin HEAD "v$VERSION"
else
    echo "Push with: git push origin HEAD v$VERSION"
fi
