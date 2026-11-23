#!/usr/bin/env python3
"""Measures how much "AI 選字" helps: types each sentence of a list with full tones,
converts it with the lexicon alone and with the language-model rerank, and compares both
with the original sentence.

The readings come from the lexicon (longest match, most common reading), so the test is
"the typist typed the right Bopomofo; did the input method pick the right characters?".
The language model scores the K best paths once, at the largest K asked for, and every
(K, λ) pair is then picked from those scores (the k best paths are a prefix of the K best).

    eval_ai.py                                   tune.txt at the shipped settings
    eval_ai.py --set test                        the held-out sentences
    eval_ai.py --k 3 10 30 --lam 0.3 0.6 1 1.5   a grid
    eval_ai.py --model lm-large.bin --lam 2 -v   the 高品質 model, listing every difference

Needs numpy. Tune on tune.txt and only check the result on test.txt, so the defaults
don't just fit the sentences they were chosen on.
"""
import argparse
import math
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "windows"))

from autozhuyin.core import lm                                   # noqa: E402
from autozhuyin.core.lexicon import Converter, Lexicon            # noqa: E402

DATA = ROOT / "windows" / "autozhuyin" / "data"
SETS = Path(__file__).resolve().parent / "eval-sentences"
TONES = {"ˊ": 2, "ˇ": 3, "ˋ": 4, "˙": 5}


class Syllable:
    """What the converter reads from a parsed syllable."""

    def __init__(self, reading):
        self.reading = reading
        self.tone = TONES.get(reading[-1], 1)
        self.toneless = reading[:-1] if reading[-1] in TONES else reading


def readings(lexicon, sentence):
    """The syllables of a sentence, words matched longest first."""
    known = lexicon._readings   # filled by the first reading_of call
    out, i = [], 0
    while i < len(sentence):
        for j in range(min(len(sentence), i + lexicon.max_phrase_length), i, -1):
            word = sentence[i:j]
            r = lexicon.reading_of(word) if j - i == 1 or word in known else None
            if r:
                out += r.split("-")
                i = j
                break
        else:
            raise ValueError(f"no reading for {sentence[i]!r} in {sentence}")
    return [Syllable(r) for r in out]


def char_hits(text, ref):
    return sum(a == b for a, b in zip(text, ref)) if len(text) == len(ref) else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--set", default="tune", help="tune, test, or a file of sentences")
    ap.add_argument("--model", default=str(DATA / "lm.bin"),
                    help="model file (the vocabulary is the bundled lm-vocab.txt, shared by both models)")
    ap.add_argument("--k", type=int, nargs="+", default=[10], help="paths reranked (saver 3, standard 10, quality 30)")
    ap.add_argument("--lam", type=float, nargs="+", default=[0.6], help="weight of the language model")
    ap.add_argument("-v", action="store_true", help="list the sentences where the results differ")
    args = ap.parse_args()

    path = SETS / f"{args.set}.txt" if (SETS / f"{args.set}.txt").exists() else Path(args.set)
    sentences = [s.strip() for s in path.read_text(encoding="utf-8").splitlines() if s.strip()]
    lexicon = Lexicon.from_file(str(DATA / "lexicon.txt"))
    lexicon.reading_of("一")
    converter = Converter(lexicon)
    model = lm.GPT2LanguageModel(args.model, str(DATA / "lm-vocab.txt"))

    k_max = max(args.k)
    rows, lm_time, cpu = [], {k: 0.0 for k in args.k}, time.process_time()
    for ref in sentences:
        syl = readings(lexicon, ref)
        base = "".join(t for _, t in converter.convert(syl))
        paths = converter.kbest(syl, k_max)
        texts = ["".join(t for _, t in segs) for _, segs in paths]
        scores = []
        for k in sorted(args.k):   # time each K on its own: that is what one rerank costs
            start = time.perf_counter()
            scores = model.log_probs(texts[:k])
            lm_time[k] += time.perf_counter() - start
        rows.append((ref, base, [s for s, _ in paths], texts, scores))
    cpu = time.process_time() - cpu

    n_chars = sum(len(r[0]) for r in rows)
    base_chars = sum(char_hits(b, ref) for ref, b, *_ in rows)
    base_whole = sum(b == ref for ref, b, *_ in rows)
    print(f"{path.name}: {len(rows)} 句 {n_chars} 字，模型 {args.model}")
    print(f"只用詞庫          字 {base_chars / n_chars:6.1%}  整句 {base_whole:3d}/{len(rows)}")

    def pick(row, k, lam):
        _, base, lex_scores, texts, lm_scores = row
        if len(texts) <= 1:
            return base
        best = max(range(min(k, len(texts))), key=lambda i: lex_scores[i] * math.log(10) + lam * lm_scores[i])
        return texts[best]

    for k in sorted(args.k):
        for lam in args.lam:
            picked = [pick(r, k, lam) for r in rows]
            chars = sum(char_hits(p, r[0]) for p, r in zip(picked, rows))
            whole = sum(p == r[0] for p, r in zip(picked, rows))
            fixed = sum(p == r[0] != r[1] for p, r in zip(picked, rows))
            broke = sum(r[1] == r[0] != p for p, r in zip(picked, rows))
            print(f"AI K={k:<3d} λ={lam:<4g}  字 {chars / n_chars:6.1%}  整句 {whole:3d}/{len(rows)}"
                  f"  修好 {fixed:2d} 改壞 {broke:2d}  每次 {lm_time[k] / len(rows) * 1000:5.1f} ms")
    print(f"(CPU 時間 {cpu:.1f} 秒)")

    if args.v:
        k, lam = max(args.k), args.lam[-1]
        print(f"\n逐句比較（K={k} λ={lam:g}）")
        for row in rows:
            ref, base = row[0], row[1]
            ai = pick(row, k, lam)
            if ai == base == ref:
                continue
            tag = "AI修好" if ai == ref else "AI改壞" if base == ref else "都錯"
            print(f"[{tag}] {ref}\n   詞庫 {base}\n   AI   {ai}")


if __name__ == "__main__":
    main()
