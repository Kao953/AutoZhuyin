"""Zhuyin-vs-literal classifier with learned corrections. Port of Classifier.swift."""
from . import bopomofo

ZHUYIN = "zhuyin"
LITERAL = "literal"

NEG_INF = float("-inf")


class LearnedPreferences:
    """Per key-sequence corrections. Positive weight = prefers Zhuyin."""

    def __init__(self, weights=None, on_change=None):
        self.weights = dict(weights or {})
        self._on_change = on_change or (lambda w: None)

    def record(self, keys, mode):
        delta = 1 if mode == ZHUYIN else -1
        self.weights[keys] = max(-3, min(3, self.weights.get(keys, 0) + delta))
        self._on_change(self.weights)

    def clear(self):
        self.weights = {}
        self._on_change(self.weights)

    def bias(self, keys):
        return self.weights.get(keys, 0) * 4.0


class Classifier:
    zhuyin_prior = 0.5
    context_weight = 1.5

    def __init__(self, lexicon, english, learned=None):
        self.lexicon = lexicon
        self.english = english
        self.learned = learned or LearnedPreferences()

    def classify(self, keys, finishing=False, previous=None):
        """Returns (mode, zhuyin_score, literal_score)."""
        keys = list(keys)
        zh = self.zhuyin_score(keys + [" "] if finishing else keys) + self.zhuyin_prior
        lit = self.literal_score(keys, complete=finishing)
        if previous == ZHUYIN:
            zh += self.context_weight
        elif previous == LITERAL:
            lit += self.context_weight
        b = self.learned.bias("".join(keys))
        if b > 0:
            zh += b
        else:
            lit -= b
        return (ZHUYIN if zh >= lit else LITERAL), zh, lit

    def mode(self, keys, finishing=False, previous=None):
        return self.classify(keys, finishing, previous)[0]

    def zhuyin_score(self, keys):
        p = bopomofo.parse(keys)
        if p.foreign_keys > 0 or not p.syllables:
            return NEG_INF
        s = -5.0 * p.stray_tones
        last = len(p.syllables) - 1
        for i, ps in enumerate(p.syllables):
            if ps.reordered:
                s -= 0.5
            valid = bopomofo.is_valid(ps.syllable)
            if ps.toned:
                if valid:
                    s += 2 + (0.8 if self.lexicon.best_score(ps.syllable) is not None else -1.5)
                else:
                    s -= 5
            elif i == last:
                s += 0 if bopomofo.is_valid_prefix(ps.syllable) else -5
            else:
                s += -2.5 if valid else -5
        return s

    def literal_score(self, keys, complete):
        if not keys or " " in keys:
            return NEG_INF
        score = 0.0
        if any(c.isupper() for c in keys):
            score += 20
        letters = "".join(c for c in keys if c.isalpha())
        digits = sum(1 for c in keys if c.isdigit())
        others = len(keys) - len(letters) - digits
        if not letters:
            return score + 0.8 * digits - 1.0 * others
        score += self.english.score(letters, complete or digits > 0)
        score -= 1.5 * digits
        apostrophes = keys.count("'")
        score -= 1.5 * (others - apostrophes)
        return score
