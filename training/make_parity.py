#!/usr/bin/env python3
"""Writes training/parity-fixtures.json: segmentations produced by the Python core
with the current weights. The Swift tests (ParityTests) must produce the same ones,
which keeps the two implementations in sync. Re-run after changing features or weights.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import DATA, WEIGHTS_PATH, core, load_models  # noqa: E402
from synth import Generator  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "parity-fixtures.json")

HAND_PICKED = ["ji3hello", "hellosu3cl3", "su3cl3github", "ji3hel", "2;3", "2.5", "uvl3", "so", "up",
               "u4", "183", "2024", "Hello", "don't", "mp3", "ji3emailsu3cl3", "rup wu0 wu0 fu4cp3cl3"]


def main():
    lexicon, english = load_models()
    clf = core.Classifier(lexicon, english, weights=core.Classifier.load_weights(WEIGHTS_PATH))
    gen = Generator(os.path.join(DATA, "lexicon.txt"), os.path.join(DATA, "english-common.txt"),
                    os.path.join(DATA, "english-dict.txt"), seed=7)
    cases = [(k, f) for k in HAND_PICKED for f in (False, True)]
    while len(cases) < 400:
        ex = gen.example()
        if len(ex["keys"]) <= 28:
            cases.append((ex["keys"], ex["finishing"]))
            cases.append((gen.prefix_of(ex)["keys"], False))
    fixtures = [{"keys": k, "finishing": f,
                 "segments": [[s, e, m] for s, e, m in clf.segment(list(k), f)]} for k, f in cases]
    with open(OUT, "w", encoding="utf-8") as fh:
        json.dump(fixtures, fh, ensure_ascii=False, indent=0)
    print("wrote %d fixtures to %s" % (len(fixtures), OUT))


if __name__ == "__main__":
    main()
