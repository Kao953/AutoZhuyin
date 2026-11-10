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

    # --- segmentation ---

    segment_penalty = 3.0
    unconfirmed_switch_penalty = 2.0

    def segment(self, keys, finishing=False, previous=None):
        """Splits keys into alternating segments: [(start, end, mode)], e.g.
        "ji3hello" -> [(0, 3, zhuyin), (3, 8, literal)]. Dynamic programming over
        split points; a Zhuyin segment followed by another must end with a tone."""
        keys = list(keys)
        n = len(keys)
        if n == 0:
            return []
        modes = (ZHUYIN, LITERAL)
        best = [[NEG_INF, NEG_INF] for _ in range(n + 1)]
        back = [[-1, -1] for _ in range(n + 1)]
        for i in range(1, n + 1):
            for j in range(i):
                scores = self._segment_scores(keys[j:i], i == n, j > 0, finishing,
                                              previous if j == 0 else None, j == 0 and i == n)
                for m in (0, 1):
                    if scores[m] == NEG_INF:
                        continue
                    if j == 0:
                        total = scores[m]
                    else:
                        if best[j][1 - m] == NEG_INF:
                            continue
                        total = best[j][1 - m] + scores[m] - self.segment_penalty
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

    def _segment_scores(self, seg, is_last, after_other, finishing, previous, whole):
        parse = bopomofo.parse(seg)
        if not is_last and parse.pending is not None:
            zh = NEG_INF
        else:
            zh = self.zhuyin_score(seg + [" "] if finishing and is_last else seg) + self.zhuyin_prior
            if is_last and after_other and not finishing and not any(s.toned for s in parse.syllables):
                zh -= self.unconfirmed_switch_penalty
        lit = self.literal_score(seg, complete=(not is_last) or finishing)
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
