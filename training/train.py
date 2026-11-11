#!/usr/bin/env python3
"""Learns the classifier weights from synthetic typing data (averaged structured
perceptron over the same segmentation DP the input method runs) and reports
accuracy against the hand-tuned defaults.

Usage (from the repo root, after windows/tools/build_data.py):
    python3 training/train.py                 # train, evaluate, write Resources/classifier-weights.json
    python3 training/train.py --eval-only     # just evaluate the current weights file
"""
import argparse
import datetime
import json
import os
import random
import sys
import time
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from common import DATA, WEIGHTS_PATH, core, load_models  # noqa: E402
from synth import Generator, gold_segments  # noqa: E402

MAX_KEYS = 28
FIXED = {"lit.upper"}   # hard rule (Shift = English), not learned


def make_set(gen, n):
    out = []
    while len(out) < 2 * n:
        ex = gen.example()
        if len(ex["keys"]) > MAX_KEYS:
            continue
        out.append(ex)
        if len(ex["keys"]) > 1:
            out.append(gen.prefix_of(ex))
    return out


def labels_of(segs, n):
    lab = [""] * n
    for s, e, m in segs:
        for i in range(s, e):
            lab[i] = "z" if m == core.ZHUYIN else "l"
    return "".join(lab)


def seg_features(clf, keys, segs, finishing, previous):
    """Summed features of a segmentation, or None if any segment is impossible."""
    total = defaultdict(float)
    n = len(keys)
    for idx, (s, e, m) in enumerate(segs):
        fz, fl = clf.segment_features(keys[s:e], e == n, idx > 0, finishing, previous if idx == 0 else None)
        f = fz if m == core.ZHUYIN else fl
        if f is None:
            return None
        for k, v in f.items():
            total[k] += v
    return total


def evaluate(clf, weights, data):
    by_kind = defaultdict(lambda: [0, 0])
    for ex in data:
        segs = clf.segment(list(ex["keys"]), ex["finishing"], ex["previous"], weights)
        ok = labels_of(segs, len(ex["keys"])) == ex["labels"]
        kind = "prefix" if ex["kind"].endswith("/prefix") else ex["kind"]
        for k in (kind, "after-other") if _after_other(ex) else (kind,):
            by_kind[k][0] += ok
            by_kind[k][1] += 1
    commit = [v for k, v in by_kind.items() if k not in ("prefix", "after-other")]
    summary = {
        "commit": sum(c for c, _ in commit) / max(1, sum(t for _, t in commit)),
        "prefix": by_kind["prefix"][0] / max(1, by_kind["prefix"][1]),
        "by_kind": {k: round(c / t, 4) for k, (c, t) in sorted(by_kind.items())},
    }
    return summary


def _after_other(ex):
    """Committed buffer whose first segment differs from the text typed just before."""
    if ex["kind"].endswith("/prefix") or ex["previous"] is None:
        return False
    first = core.ZHUYIN if ex["labels"][0] == "z" else core.LITERAL
    return ex["previous"] != first


def show(name, s):
    kinds = "  ".join("%s %.1f%%" % (k, 100 * v) for k, v in s["by_kind"].items())
    print("%-9s commit %.2f%%  typing %.2f%%   [%s]" % (name, 100 * s["commit"], 100 * s["prefix"], kinds))


def train(clf, data, epochs, lr, seed):
    rng = random.Random(seed)
    w = dict(clf.weights)
    total = defaultdict(float)
    steps = 0
    for epoch in range(epochs):
        rng.shuffle(data)
        mistakes = 0
        t0 = time.time()
        for ex in data:
            keys = list(ex["keys"])
            pred = clf.segment(keys, ex["finishing"], ex["previous"], w)
            if labels_of(pred, len(keys)) != ex["labels"]:
                gold = gold_segments(ex["labels"])
                fg = seg_features(clf, keys, gold, ex["finishing"], ex["previous"])
                fp = seg_features(clf, keys, pred, ex["finishing"], ex["previous"])
                if fg is not None and fp is not None:
                    mistakes += 1
                    scale = lr * (0.5 if ex["kind"].endswith("/prefix") else 1.0)
                    for k in set(fg) | set(fp):
                        if k not in FIXED:
                            w[k] = w.get(k, 0.0) + scale * (fg.get(k, 0.0) - fp.get(k, 0.0))
            steps += 1
            for k, v in w.items():
                total[k] += v
        print("epoch %d: %d updates (%.0fs)" % (epoch + 1, mistakes, time.time() - t0), flush=True)
    return {k: round(v / steps, 4) for k, v in total.items()}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--train", type=int, default=3000, help="full examples (plus as many prefixes)")
    ap.add_argument("--test", type=int, default=1500)
    ap.add_argument("--epochs", type=int, default=6)
    ap.add_argument("--lr", type=float, default=0.1)
    ap.add_argument("--eval-only", action="store_true")
    args = ap.parse_args()

    lexicon, english = load_models()
    paths = (os.path.join(DATA, "lexicon.txt"), os.path.join(DATA, "english-common.txt"),
             os.path.join(DATA, "english-dict.txt"))
    test = make_set(Generator(*paths, seed=2), args.test)

    clf = core.Classifier(lexicon, english)   # default (hand-tuned) weights
    show("default", evaluate(clf, clf.weights, test))
    if os.path.exists(WEIGHTS_PATH):
        current = dict(clf.weights)
        current.update(core.Classifier.load_weights(WEIGHTS_PATH))
        show("current", evaluate(clf, current, test))
    if args.eval_only:
        return

    data = make_set(Generator(*paths, seed=1), args.train)
    print("training on %d buffers (%d test)" % (len(data), len(test)), flush=True)
    learned = train(clf, data, args.epochs, args.lr, seed=3)
    result = evaluate(clf, learned, test)
    show("learned", result)

    with open(WEIGHTS_PATH, "w", encoding="utf-8") as f:
        json.dump({
            "about": "AutoZhuyin classifier weights, learned by training/train.py",
            "trained": datetime.date.today().isoformat(),
            "examples": len(data),
            "test_accuracy": {"commit": round(result["commit"], 4), "typing": round(result["prefix"], 4)},
            "weights": dict(sorted(learned.items())),
        }, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print("wrote", WEIGHTS_PATH)


if __name__ == "__main__":
    main()
