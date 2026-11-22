#!/bin/bash
# Updates Resources/lexicon.txt from the latest McBopomofo data, shows what changed,
# regenerates the parity fixtures, runs the Swift and Python tests, and commits
# after you confirm. Then release as usual: scripts/release.sh patch --push
#
# Usage: scripts/update-lexicon.sh [-y]   (-y: commit without asking)
#
# Run on a Mac: the parity fixtures depend on the macOS English word list
# (/usr/share/dict/words), which is what the GitHub Actions tests use.
set -euo pipefail
cd "$(dirname "$0")/.."

YES=0
for arg in "$@"; do
    case "$arg" in
        -y) YES=1 ;;
        *) echo "usage: $0 [-y]" >&2; exit 2 ;;
    esac
done

[ "$(uname)" = Darwin ] || { echo "Run this on a Mac (the parity fixtures depend on the macOS word list)." >&2; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
    echo "Working tree has uncommitted changes; commit them first." >&2
    exit 1
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CHANGED=(Resources/lexicon.txt training/parity-fixtures.json)

mkdir -p build
cp Resources/lexicon.txt build/lexicon-old.txt

restore() {
    echo "Failed; reverting the lexicon and fixtures." >&2
    git checkout -- "${CHANGED[@]}"
}
trap restore ERR

echo "==> Fetching McBopomofo data"
scripts/import-mcbopomofo.sh >/dev/null
UPSTREAM="$(git -C build/mcbopomofo-src log -1 --format='%h (%cs)')"
echo "    McBopomofo $UPSTREAM"

if cmp -s build/lexicon-old.txt Resources/lexicon.txt; then
    trap - ERR
    echo "Lexicon is already up to date."
    exit 0
fi

echo "==> Changes"
python3 -I - build/lexicon-old.txt Resources/lexicon.txt <<'EOF'
import sys

def load(path):
    entries = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            cols = line.split()
            if len(cols) == 3 and not line.startswith("#"):
                entries[(cols[0], cols[1])] = float(cols[2])
    return entries

old, new = load(sys.argv[1]), load(sys.argv[2])
added = sorted(new.keys() - old.keys(), key=lambda k: -new[k])
removed = sorted(old.keys() - new.keys(), key=lambda k: -old[k])
changed = sorted((k for k in old.keys() & new.keys() if abs(old[k] - new[k]) >= 0.05),
                 key=lambda k: -abs(old[k] - new[k]))
print("    %d entries -> %d: %d added, %d removed, %d with a different score"
      % (len(old), len(new), len(added), len(removed), len(changed)))

def show(title, keys, fmt, limit=15):
    if keys:
        print("    %s (most common first):" % title)
        for k in keys[:limit]:
            print("      " + fmt(k))
        if len(keys) > limit:
            print("      ... and %d more" % (len(keys) - limit))

show("Added", added, lambda k: "%s %s  %.2f" % (k[1], k[0], new[k]))
show("Removed", removed, lambda k: "%s %s  %.2f" % (k[1], k[0], old[k]))
show("Score changed", changed, lambda k: "%s %s  %.2f -> %.2f" % (k[1], k[0], old[k], new[k]))
EOF

echo "==> Regenerating parity fixtures"
python3 -I windows/tools/build_data.py >/dev/null
python3 training/make_parity.py | sed 's/^/    /'

echo "==> Swift tests"
xcrun swift test -q 2>&1 | tail -3
echo "==> Python tests"
(cd windows && python3 -m unittest discover -q tests)
trap - ERR
echo
git diff --stat -- "${CHANGED[@]}"
if [ "$YES" = 0 ]; then
    read -r -p "Commit the new lexicon? [y/N] " answer
    case "$answer" in
        y|Y) ;;
        *) echo "Not committed. Revert with: git checkout -- ${CHANGED[*]}"; exit 0 ;;
    esac
fi
git add "${CHANGED[@]}"
git commit -q -m "Update lexicon from McBopomofo $UPSTREAM"
echo "==> Committed. Release with: scripts/release.sh patch --push"
