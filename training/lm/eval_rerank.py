"""Measures how much language-model reranking improves Zhuyin → Chinese conversion.

For each test sentence: turn the text into Dachen keystrokes (via the lexicon's
readings), convert with the current Viterbi converter (baseline), take the K best
paths, and rerank them with  lexicon score + λ · LM log-probability.

Usage (needs numpy and the model in build/models/ckip-gpt2-tiny):
    python training/lm/eval_rerank.py build/lm-eval/chat.txt build/lm-eval/wiki.txt
"""
import heapq
import math
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "windows"))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from autozhuyin.core import bopomofo  # noqa: E402
from autozhuyin.core.lexicon import Converter, Lexicon  # noqa: E402
from gpt2 import GPT2  # noqa: E402

KEY_OF = {sym: key for key, sym in bopomofo.SYMBOLS.items()}
TONE_KEY = {"ˊ": "6", "ˇ": "3", "ˋ": "4", "˙": "7"}
LN10 = math.log(10)


def reading_keys(reading):
    out = []
    for syl in reading.split("-"):
        tone = " "
        for ch in syl:
            if ch in TONE_KEY:
                tone = TONE_KEY[ch]
            else:
                out.append(KEY_OF[ch])
        out.append(tone)
    return out


def build_reverse(lex):
    best = {}
    for reading, entries in lex.exact.items():
        for phrase, score in entries:
            if phrase not in best or score > best[phrase][1]:
                best[phrase] = (reading, score)
    return best


def text_to_keys(text, reverse, max_len):
    """Most likely segmentation of the text into lexicon phrases → keystrokes."""
    n = len(text)
    best = [(-math.inf, None)] * (n + 1)
    best[0] = (0.0, None)
    for j in range(1, n + 1):
        for i in range(max(0, j - max_len), j):
            if best[i][0] == -math.inf:
                continue
            hit = reverse.get(text[i:j])
            if hit:
                s = best[i][0] + hit[1]
                if s > best[j][0]:
                    best[j] = (s, (i, hit[0]))
    if best[n][1] is None:
        return None
    readings, j = [], n
    while j > 0:
        i, r = best[j][1]
        readings.append(r)
        j = i
    keys = []
    for r in reversed(readings):
        keys += reading_keys(r)
    return keys


def kbest(conv, syllables, k):
    """K best (score, text) paths through the converter's lattice (scores in log10)."""
    n = len(syllables)
    max_len = max(1, conv.lexicon.max_phrase_length)
    beams = [[] for _ in range(n + 1)]
    beams[0] = [(0.0, "")]
    for j in range(1, n + 1):
        cand = []
        for length in range(1, min(max_len, j) + 1):
            i = j - length
            if not beams[i]:
                continue
            for text, score in conv._options(syllables, i, j, {}):
                for s, t in beams[i]:
                    cand.append((s + score, t + text))
        beams[j] = heapq.nlargest(k, cand, key=lambda e: e[0])
    return beams[n]


def char_errors(a, b):
    return sum(x != y for x, y in zip(a, b)) + abs(len(a) - len(b))


def main(paths, k=10):
    lex = Lexicon.from_file(os.path.join(ROOT, "windows/autozhuyin/data/lexicon.txt"))
    conv = Converter(lex)
    lm = GPT2(os.path.join(ROOT, "build/models/ckip-gpt2-tiny"))
    reverse = build_reverse(lex)

    cases = []
    for path in paths:
        for line in open(path, encoding="utf-8"):
            text = line.strip().replace("，", "").replace("、", "")
            if not text:
                continue
            keys = text_to_keys(text, reverse, lex.max_phrase_length)
            if keys is None:
                continue
            syl = [s.syllable for s in bopomofo.parse(keys).syllables]
            paths_k = kbest(conv, syl, k)
            t0 = time.time()
            lm_scores = [lm.logprob(t) for _, t in paths_k]
            cases.append((os.path.basename(path), text, paths_k, lm_scores, time.time() - t0))

    def evaluate(lam, subset):
        chars = errs = sent_ok = 0
        for _, text, paths_k, lm_scores, _ in subset:
            best = max(range(len(paths_k)), key=lambda i: paths_k[i][0] * LN10 + lam * lm_scores[i])
            out = paths_k[best][1]
            e = char_errors(out, text)
            chars += len(text)
            errs += e
            sent_ok += e == 0
        return 1 - errs / chars, sent_ok / len(subset)

    lams = [0, 0.1, 0.2, 0.3, 0.5, 0.7, 1.0, 1.5, 2.0]
    for name in sorted({c[0] for c in cases}):
        sub = [c for c in cases if c[0] == name]
        oracle = sum(any(t == c[1] for _, t in c[2]) for c in sub) / len(sub)
        print(f"\n== {name}: {len(sub)} sentences, top-{k} contains the answer: {oracle:.1%}")
        for lam in lams:
            ca, sa = evaluate(lam, sub)
            print(f"  λ={lam:<4} char acc {ca:.2%}  sentence acc {sa:.1%}" + ("   (baseline)" if lam == 0 else ""))
    ms = sum(c[4] for c in cases) / len(cases) * 1000
    print(f"\nLM time per sentence (top-{k}): {ms:.1f} ms")
    return cases


if __name__ == "__main__":
    main(sys.argv[1:])
