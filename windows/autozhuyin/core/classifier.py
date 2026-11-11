"""Zhuyin-vs-literal classifier with learned corrections. Port of Classifier.swift."""
import json

from .features import DEFAULT_WEIGHTS, dot, literal_features, zhuyin_features

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
    context_weight = 1.5

    def __init__(self, lexicon, english, learned=None, weights=None):
        self.lexicon = lexicon
        self.english = english
        self.learned = learned or LearnedPreferences()
        self.weights = dict(DEFAULT_WEIGHTS)
        if weights:
            self.weights.update(weights)

    @classmethod
    def load_weights(cls, path):
        """Reads a weights JSON file ({"weights": {...}}); returns {} if missing."""
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f).get("weights", {})
        except (OSError, ValueError):
            return {}

    def segment_features(self, seg, is_last, after_other, finishing):
        """(zhuyin features or None, literal features or None) for one segment."""
        seg = list(seg)
        return (zhuyin_features(seg, self.lexicon, is_last, after_other, finishing),
                literal_features(seg, self.english, is_last, after_other, finishing))

    def _scores(self, seg, is_last, after_other, finishing, previous, whole, weights):
        fz, fl = self.segment_features(seg, is_last, after_other, finishing)
        zh = dot(weights, fz) if fz is not None else NEG_INF
        lit = dot(weights, fl) if fl is not None else NEG_INF
        if previous == ZHUYIN:
            zh += self.context_weight
        elif previous == LITERAL:
            lit += self.context_weight
        if whole:
            b = self.learned.bias("".join(seg))
            if b > 0:
                zh += b
            else:
                lit -= b
        return zh, lit

    def classify(self, keys, finishing=False, previous=None):
        """Whole buffer as one segment. Returns (mode, zhuyin_score, literal_score)."""
        zh, lit = self._scores(list(keys), True, False, finishing, previous, True, self.weights)
        return (ZHUYIN if zh >= lit else LITERAL), zh, lit

    def mode(self, keys, finishing=False, previous=None):
        return self.classify(keys, finishing, previous)[0]

    # --- segmentation ---

    def segment(self, keys, finishing=False, previous=None, weights=None):
        """Splits keys into alternating segments: [(start, end, mode)], e.g.
        "ji3hello" -> [(0, 3, zhuyin), (3, 8, literal)]. Dynamic programming over
        split points; each segment is scored by features x weights."""
        weights = weights or self.weights
        keys = list(keys)
        n = len(keys)
        if n == 0:
            return []
        modes = (ZHUYIN, LITERAL)
        best = [[NEG_INF, NEG_INF] for _ in range(n + 1)]
        back = [[-1, -1] for _ in range(n + 1)]
        for i in range(1, n + 1):
            for j in range(i):
                scores = self._scores(keys[j:i], i == n, j > 0, finishing,
                                      previous if j == 0 else None, j == 0 and i == n, weights)
                for m in (0, 1):
                    if scores[m] == NEG_INF:
                        continue
                    if j == 0:
                        total = scores[m]
                    else:
                        if best[j][1 - m] == NEG_INF:
                            continue
                        total = best[j][1 - m] + scores[m]
                    if total > best[i][m]:
                        best[i][m] = total
                        back[i][m] = j
        if best[n][0] == NEG_INF and best[n][1] == NEG_INF:
            return [(0, n, self.mode(keys, finishing, previous))]
        m = 0 if best[n][0] >= best[n][1] else 1
        out, i = [], n
        while i > 0:
            j = back[i][m]
            out.append((j, i, modes[m]))
            i, m = j, 1 - m
        return out[::-1]
