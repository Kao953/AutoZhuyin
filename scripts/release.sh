#!/bin/bash
# One-step release: bump the version, run all tests, build all installers, then
# commit the version change and tag it. The notes under "## 未發佈" in CHANGELOG.md
# become this version's section (and the GitHub Release description).
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

# What changed, for CHANGELOG.md and the GitHub Release.
if ! awk '/^## 未發佈/ {s=1; next} /^## / {s=0} s && /^- / {n++} END {exit !n}' CHANGELOG.md; then
    echo "CHANGELOG.md has no notes under \"## 未發佈\"; write what changed there first." >&2
    exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

VERSION="$(scripts/bump-version.sh "$LEVEL")"
echo "==> Version $VERSION"
sed -i '' "s/^## 未發佈.*/## v$VERSION（$(date +%Y-%m-%d)）/" CHANGELOG.md

restore() {
    echo "Release failed; reverting the version bump." >&2
    git checkout -- Resources/Info.plist windows/autozhuyin/ime.json CHANGELOG.md
}
trap restore ERR

echo "==> Swift tests"
xcrun swift test -q 2>&1 | tail -3
echo "==> Packaging (runs the Python tests too)"
scripts/package.sh >/dev/null
scripts/package-windows.sh >/dev/null
scripts/package-windows-standalone.sh >/dev/null
scripts/package-linux.sh >/dev/null
if [ -n "${ANDROID_HOME:-}" ]; then
    scripts/package-android.sh >/dev/null
else
    echo "    (ANDROID_HOME not set: skipping Android; GitHub Actions builds it)"
fi

trap - ERR
git add Resources/Info.plist windows/autozhuyin/ime.json CHANGELOG.md
git commit -q -m "Release v$VERSION"
git tag -a "v$VERSION" -m "AutoZhuyin v$VERSION"
echo "==> Tagged v$VERSION"
FILES=("build/AutoZhuyin-$VERSION.pkg" "build/AutoZhuyin-Windows-$VERSION-setup.exe"
       "build/AutoZhuyin-Windows-$VERSION.zip" "build/AutoZhuyin-Windows-Standalone-$VERSION-setup.exe"
       "build/AutoZhuyin-Linux-$VERSION.tar.gz")
ls -lh "${FILES[@]}"
shasum -a 256 "${FILES[@]}"

if [ "$PUSH" = 1 ]; then
    git push origin HEAD "v$VERSION"
else
    echo "Push with: git push origin HEAD v$VERSION"
fi
