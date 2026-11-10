#!/bin/bash
# Rebuilds Resources/lexicon.txt from the open-source McBopomofo data (MIT License,
# https://github.com/openvanilla/McBopomofo). Only McBopomofo's data files are
# downloaded and read; none of its code is run. Resources/lexicon-seed.txt (the
# hand-written starter lexicon) is appended so its entries stay available.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=build/mcbopomofo-src
if [ -d "$SRC/.git" ]; then
    git -C "$SRC" pull -q --depth 1
else
    rm -rf "$SRC"
    git clone -q --depth 1 --filter=blob:none --sparse https://github.com/openvanilla/McBopomofo.git "$SRC"
    git -C "$SRC" sparse-checkout set Source/Data
fi

python3 -I scripts/convert-mcbopomofo.py "$SRC/Source/Data" Resources/lexicon-seed.txt Resources/lexicon.txt
echo "Rebuild with scripts/install.sh"
