#!/bin/bash
# Increments the version in every place it lives:
#   Resources/Info.plist        CFBundleShortVersionString (x.y.z) and CFBundleVersion (build number)
#   windows/autozhuyin/ime.json "version"
#
# Usage: scripts/bump-version.sh [patch|minor|major]   (default: patch)
# Prints the new version.
set -euo pipefail
cd "$(dirname "$0")/.."

LEVEL="${1:-patch}"
PLIST=Resources/Info.plist
IME=windows/autozhuyin/ime.json

CURRENT="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
IFS=. read -r MAJOR MINOR PATCH <<< "$CURRENT"
case "$LEVEL" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
    *) echo "usage: $0 [patch|minor|major]" >&2; exit 2 ;;
esac
NEW="$MAJOR.$MINOR.$PATCH"
BUILD=$(( $(plutil -extract CFBundleVersion raw "$PLIST") + 1 ))

plutil -replace CFBundleShortVersionString -string "$NEW" "$PLIST"
plutil -replace CFBundleVersion -string "$BUILD" "$PLIST"
# Edit only the version line so the rest of ime.json keeps its formatting.
sed -i '' -E "s/(\"version\"[[:space:]]*:[[:space:]]*\")[^\"]*\"/\1$NEW\"/" "$IME"

grep -q "\"version\": \"$NEW\"" "$IME" || { echo "failed to update $IME" >&2; exit 1; }
echo "$NEW"
