"""Lexicon and Viterbi converter. Port of Lexicon.swift / Converter.swift."""

_TONE_MARKS = set("ˊˇˋ˙")


def _strip_tones(reading):
    return "".join(c for c in reading if c not in _TONE_MARKS)


def _is_bopomofo(s):
    return bool(s) and (0x3105 <= ord(s[0]) <= 0x312F or s[0] == "˙")


class Lexicon:
    """Maps readings ("ㄋㄧˇ-ㄏㄠˇ") to [(phrase, log10 score)], best first."""

    def __init__(self):
        self.exact = {}
        self.toneless = {}
        self.max_phrase_length = 1

    @classmethod
    def from_file(cls, path):
        lex = cls()
        with open(path, encoding="utf-8") as f:
            lex.load(f)
        return lex

    def load(self, lines):
        for line in lines:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            cols = line.split()
            if len(cols) < 2:
                continue
            reading, phrase = (cols[0], cols[1]) if _is_bopomofo(cols[0]) else (cols[1], cols[0])
            if not _is_bopomofo(reading):
                continue
            try:
                score = float(cols[2]) if len(cols) >= 3 else -6.0
            except ValueError:
                score = -6.0
            self.add(reading, phrase, score)
        for table in (self.exact, self.toneless):
            for v in table.values():
                v.sort(key=lambda e: -e[1])

    def add(self, reading, phrase, score):
        syllables = [s[1:] + "˙" if s.startswith("˙") else s for s in reading.split("-")]
        reading = "-".join(syllables)
        self.max_phrase_length = max(self.max_phrase_length, len(syllables))
        entries = self.exact.setdefault(reading, [])
        if not any(p == phrase for p, _ in entries):
            entries.append((phrase, score))
        key = _strip_tones(reading)
        tl = self.toneless.setdefault(key, [])
        for i, (p, s) in enumerate(tl):
            if p == phrase:
                if score > s:
                    tl[i] = (p, score)
                break
        else:
            tl.append((phrase, score))

    def entries(self, syllables):
        if all(s.tone is not None for s in syllables):
            return self.exact.get("-".join(s.reading for s in syllables), [])
        return self.toneless.get("-".join(s.toneless for s in syllables), [])

    def best_score(self, syllable):
        e = self.entries([syllable])
        return e[0][1] if e else None


UNKNOWN_SCORE = -30.0
TONELESS_PENALTY = -1.5


class Converter:
    def __init__(self, lexicon):
        self.lexicon = lexicon

    def _options(self, syllables, i, j, fixed):
        if (i, j) in fixed:
            return [(fixed[(i, j)], 0.0)]
        if any(a < j and i < b for (a, b) in fixed):
            return []
        sl = syllables[i:j]
        penalty = TONELESS_PENALTY if any(s.tone is None for s in sl) else 0.0
        out = [(p, s + penalty) for p, s in self.lexicon.entries(sl)]
        if not out and j - i == 1:
            out = [(sl[0].reading, UNKNOWN_SCORE)]
        return out

    def convert(self, syllables, fixed=None):
        """Returns [((start, end), text)] for the best path. `fixed` maps (start, end) -> text."""
        fixed = fixed or {}
        n = len(syllables)
        if n == 0:
            return []
        max_len = max(1, self.lexicon.max_phrase_length)
        best = [(float("-inf"), None)] * (n + 1)
        best[0] = (0.0, None)
        for j in range(1, n + 1):
            for length in range(1, min(max_len, j) + 1):
                i = j - length
                if best[i][0] == float("-inf"):
                    continue
                for text, score in self._options(syllables, i, j, fixed):
                    total = best[i][0] + score
                    if total > best[j][0]:
                        best[j] = (total, ((i, j), text))
        segs = []
        j = n
        while j > 0 and best[j][1] is not None:
            seg = best[j][1]
            segs.append(seg)
            j = seg[0][0]
        return segs[::-1]

    def candidates(self, syllables, end):
        """[((start, end), text)] for phrases ending at syllable `end`, longest first."""
        if end <= 0 or end > len(syllables):
            return []
        out, seen = [], set()
        for length in range(min(self.lexicon.max_phrase_length, end), 0, -1):
            i = end - length
            for phrase, _ in self.lexicon.entries(syllables[i:end]):
                if phrase not in seen:
                    seen.add(phrase)
                    out.append(((i, end), phrase))
        return out
