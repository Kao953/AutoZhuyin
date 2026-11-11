#!/usr/bin/env python3
"""Fills windows/autozhuyin/data/ from the shared Mac resources.

- lexicon.txt, english-common.txt, classifier-weights.json: copied from Resources/
- english-dict.txt: filtered from a system word list (default /usr/share/dict/words,
  Webster's 2nd edition, public domain), since Windows has no such file
- english-bigram.json: precomputed letter-bigram table

Usage: build_data.py [word-list]
"""
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WIN = ROOT / "windows"
sys.path.insert(0, str(WIN))

from autozhuyin.core.english import train_bigram  # noqa: E402

data = WIN / "autozhuyin" / "data"
data.mkdir(parents=True, exist_ok=True)
for name in ("lexicon.txt", "english-common.txt", "classifier-weights.json"):
    shutil.copy(ROOT / "Resources" / name, data / name)

word_list = Path(sys.argv[1] if len(sys.argv) > 1 else "/usr/share/dict/words")
words = sorted({w.strip().lower() for w in word_list.read_text(encoding="utf-8").split()
                if len(w.strip()) > 2 and w.strip().isascii() and w.strip().isalpha()})
(data / "english-dict.txt").write_text("\n".join(words) + "\n", encoding="utf-8")

common = {w.strip().lower() for w in (data / "english-common.txt").read_text(encoding="utf-8").splitlines()
          if w.strip() and not w.startswith("#")}
bigram = train_bigram(sorted(common | set(words)), common)
(data / "english-bigram.json").write_text(json.dumps(bigram), encoding="utf-8")

print("data ready: %d dictionary words, %d bigrams" % (len(words), len(bigram["table"])))
