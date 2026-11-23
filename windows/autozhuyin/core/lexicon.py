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
        # User phrases (set_user_phrases), kept apart so they can be replaced while running.
        # They override a built-in entry for the same phrase and reading.
        self.user = {}
        self._toneless = None      # built on first use (only untoned syllables need it)
        self._readings = None      # phrase -> (reading, score), for reading_of
        self.max_phrase_length = 1

    @classmethod
    def from_file(cls, path):
        lex = cls()
        with open(path, encoding="utf-8") as f:
            lex.load(f)
        return lex

    def state(self):
        """The built-in entries as plain data (for core.loading's cache)."""
        return {"exact": self.exact, "max_phrase_length": self.max_phrase_length}

    @classmethod
    def from_state(cls, state):
        lex = cls()
        lex.exact = state["exact"]
        lex.max_phrase_length = state["max_phrase_length"]
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
        for v in self.exact.values():
            if len(v) > 1:
                v.sort(key=lambda e: -e[1])
        self._toneless = None
        self._readings = None

    def set_user_phrases(self, text):
        """Replaces the user phrases (user-phrases.txt, lexicon format)."""
        parsed = Lexicon()
        parsed.load(text.splitlines())
        self.user = parsed.exact
        self.max_phrase_length = max(self.max_phrase_length, parsed.max_phrase_length)
        self._toneless = None
        self._readings = None

    def _merged(self, key, built_in):
        mine = self.user.get(key)
        if not mine:
            return built_in
        phrases = {p for p, _ in mine}
        return sorted(mine + [e for e in built_in if e[0] not in phrases], key=lambda e: -e[1])

    def reading_of(self, phrase):
        """The most likely reading of a phrase: its own entry if the lexicon has one,
        otherwise the most common reading of each character. None if a character has none."""
        if self._readings is None:
            index = {}
            for source in (self.exact, self.user):
                for reading, entries in source.items():
                    for p, score in entries:
                        if p not in index or score > index[p][1]:
                            index[p] = (reading, score)
            self._readings = index
        if phrase in self._readings:
            return self._readings[phrase][0]
        out = []
        for c in phrase:
            r = self._readings.get(c)
            if r is None or "-" in r[0]:
                return None
            out.append(r[0])
        return "-".join(out) or None

    def add(self, reading, phrase, score):
        syllables = [s[1:] + "˙" if s.startswith("˙") else s for s in reading.split("-")]
        reading = "-".join(syllables)
        self.max_phrase_length = max(self.max_phrase_length, len(syllables))
        entries = self.exact.setdefault(reading, [])
        if not any(p == phrase for p, _ in entries):
            entries.append((phrase, score))
        self._toneless = None
        self._readings = None

    @property
    def toneless(self):
        """Index ignoring tones: toneless reading -> [(phrase, best score)], best first."""
        if self._toneless is None:
            best = {}
            for reading, entries in list(self.exact.items()) + list(self.user.items()):
                bucket = best.setdefault(_strip_tones(reading), {})
                for phrase, score in entries:
                    if score > bucket.get(phrase, float("-inf")):
                        bucket[phrase] = score
            self._toneless = {k: sorted(v.items(), key=lambda e: -e[1]) for k, v in best.items()}
        return self._toneless

    def entries(self, syllables):
        if all(s.tone is not None for s in syllables):
            key = "-".join(s.reading for s in syllables)
            return self._merged(key, self.exact.get(key, []))
        return self.toneless.get("-".join(s.toneless for s in syllables), [])

    def best_score(self, syllable):
        e = self.entries([syllable])
        return e[0][1] if e else None


UNKNOWN_SCORE = -30.0
TONELESS_PENALTY = -1.5


class Converter:
    def __init__(self, lexicon, history=None):
        self.lexicon = lexicon
        self.history = history   # UserHistory: picked candidates come first
        # Syllables typed without a tone stay as Bopomofo (no characters, no candidates) until
        # the tone is typed.
        self.require_tones = False

    def _entries(self, syllables):
        if self.require_tones and any(s.tone is None for s in syllables):
            return []
        entries = self.lexicon.entries(syllables)
        return self.history.adjust(syllables, entries) if self.history else entries

    def _options(self, syllables, i, j, fixed):
        if (i, j) in fixed:
            return [(fixed[(i, j)], 0.0)]
        if any(a < j and i < b for (a, b) in fixed):
            return []
        sl = syllables[i:j]
        penalty = TONELESS_PENALTY if any(s.tone is None for s in sl) else 0.0
        out = [(p, s + penalty) for p, s in self._entries(sl)]
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

    def kbest(self, syllables, k, fixed=None):
        """The k best paths [(log10 score, [((start, end), text)])], best first."""
        fixed = fixed or {}
        n = len(syllables)
        if n == 0 or k <= 0:
            return []
        max_len = max(1, self.lexicon.max_phrase_length)
        beams = [[] for _ in range(n + 1)]
        beams[0] = [(0.0, [])]
        for j in range(1, n + 1):
            cand = []
            for length in range(1, min(max_len, j) + 1):
                i = j - length
                if not beams[i]:
                    continue
                for text, score in self._options(syllables, i, j, fixed):
                    for s, segs in beams[i]:
                        cand.append((s + score, segs + [((i, j), text)]))
            cand.sort(key=lambda e: -e[0])
            beams[j] = cand[:k]
        return beams[n]

    def candidates(self, syllables, end):
        """[((start, end), text)] for phrases ending at syllable `end`, longest first."""
        if end <= 0 or end > len(syllables):
            return []
        out, seen = [], set()
        for length in range(min(self.lexicon.max_phrase_length, end), 0, -1):
            i = end - length
            for phrase, _ in self._entries(syllables[i:end]):
                if phrase not in seen:
                    seen.add(phrase)
                    out.append(((i, end), phrase))
        # Last, the Bopomofo itself, for writing about it ("ㄤ", "ㄤˊ").
        syl = syllables[end - 1]
        for text in dict.fromkeys((syl.toneless, syl.reading)):
            if text and text not in seen:
                seen.add(text)
                out.append(((end - 1, end), text))
        return out
