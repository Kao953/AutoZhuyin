"""English-likeness scoring. Port of EnglishModel.swift.

Windows has no /usr/share/dict/words, so the dictionary ships in data/english-dict.txt,
and the letter-bigram table is precomputed into data/english-bigram.json (training it
in Python at every start would take a couple of seconds).
"""
import bisect
import json
import math
import os


def _read_words(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [w.strip() for w in f if w.strip() and not w.startswith("#")]


class EnglishModel:
    def __init__(self, common_words, dictionary_words=(), bigram=None):
        self.common = {w.lower() for w in common_words if w}
        self.dictionary = {w.lower() for w in dictionary_words if len(w) > 2}
        self.sorted_common = sorted(self.common)
        self.sorted_words = sorted(self.common | self.dictionary)
        if bigram is None:
            bigram = train_bigram(self.sorted_words, self.common)
        self.bigram = bigram["table"]
        self.unseen = bigram["unseen"]

    @classmethod
    def from_files(cls, common_path, dict_path=None, bigram_path=None):
        bigram = None
        if bigram_path and os.path.exists(bigram_path):
            with open(bigram_path, encoding="utf-8") as f:
                bigram = json.load(f)
        return cls(_read_words(common_path), _read_words(dict_path), bigram)

    def is_common(self, w):
        return w.lower() in self.common

    def score(self, word, complete):
        w = word.lower()
        n = float(len(w))
        if not w:
            return 0.0
        if w in self.common:
            return 3 + n
        if w in self.dictionary:
            return 1 + 0.6 * n
        if not complete:
            if _has_prefix(w, self.sorted_common):
                return 0.4 * n
            if _has_prefix(w, self.sorted_words):
                return 0.2 * n
        plaus = self.plausibility(w)
        return min(0.5 * n, max(-2 * n, n * (plaus + 4.2)))

    def word_features(self, word, complete):
        """Feature dict for the classifier (see features.py); score() is their
        dot product with the default weights."""
        w = word.lower()
        n = float(len(w))
        f = {}
        if n <= 2:
            f["lit.short"] = 1.0
        if w in self.common:
            f["lit.common"] = 1.0
            f["lit.common_len"] = n
        elif w in self.dictionary:
            f["lit.dict"] = 1.0
            f["lit.dict_len"] = n
        elif not complete and _has_prefix(w, self.sorted_common):
            f["lit.prefix_common_len"] = n
        elif not complete and _has_prefix(w, self.sorted_words):
            f["lit.prefix_dict_len"] = n
        else:
            plaus = self.plausibility(w)
            f["lit.unknown_score"] = min(0.5 * n, max(-2 * n, n * (plaus + 4.2)))
        return f

    def plausibility(self, w):
        chars = ["^"] + list(w) + ["$"]
        total = sum(self.bigram.get(chars[i - 1] + chars[i], self.unseen) for i in range(1, len(chars)))
        return total / (len(chars) - 1)


def _has_prefix(p, words):
    """True if some word strictly longer than p starts with p."""
    lo = bisect.bisect_left(words, p)
    if lo < len(words) and words[lo] == p:
        lo += 1
    return lo < len(words) and words[lo].startswith(p)


def train_bigram(words, common):
    pair, first = {}, {}
    for w in words:
        if not (w.isascii() and w.isalpha()):
            continue
        weight = 5.0 if w in common else 1.0
        chars = ["^"] + list(w) + ["$"]
        for i in range(1, len(chars)):
            k = chars[i - 1] + chars[i]
            pair[k] = pair.get(k, 0.0) + weight
            first[chars[i - 1]] = first.get(chars[i - 1], 0.0) + weight
    table = {k: math.log2((c + 1) / (first.get(k[0], 0.0) + 27)) for k, c in pair.items()}
    unseen = math.log2(1.0 / (max(first.values(), default=1000) + 27))
    return {"table": table, "unseen": unseen}
