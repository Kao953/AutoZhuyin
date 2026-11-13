"""Remembers the candidates the user picked. Port of UserHistory.swift.

Keys are toneless readings ("ㄊㄧㄢ", "ㄐㄧㄣ-ㄊㄧㄢ"); a picked phrase is boosted only
where the lexicon has it for the reading being converted, so a toneless key is safe.
"""


class UserHistory:
    max_entries = 2000   # (reading, phrase) pairs kept; the least recently used go first
    max_count = 10

    def __init__(self, data=None, on_change=None):
        # reading -> {phrase: [count, last use]}
        self.data = {}
        self.on_change = on_change or (lambda data: None)
        self._clock = 0
        for reading, phrases in (data or {}).items():
            if not isinstance(phrases, dict):
                continue
            for phrase, value in phrases.items():
                try:
                    count, used = int(value[0]), int(value[1])
                except (TypeError, ValueError, IndexError):
                    continue
                self.data.setdefault(reading, {})[phrase] = [count, used]
                self._clock = max(self._clock, used)

    @staticmethod
    def key(syllables):
        return "-".join(s.toneless for s in syllables)

    def record(self, syllables, phrase):
        if not syllables or not phrase:
            return
        self._clock += 1
        entry = self.data.setdefault(self.key(syllables), {}).setdefault(phrase, [0, 0])
        entry[0] = min(self.max_count, entry[0] + 1)
        entry[1] = self._clock
        self._evict()
        self.on_change(self.data)

    def _evict(self):
        pairs = [(v[1], r, p) for r, ps in self.data.items() for p, v in ps.items()]
        if len(pairs) <= self.max_entries:
            return
        pairs.sort()
        for _, r, p in pairs[:len(pairs) - self.max_entries]:
            del self.data[r][p]
            if not self.data[r]:
                del self.data[r]

    def clear(self):
        self.data = {}
        self.on_change(self.data)

    def adjust(self, syllables, entries):
        """Lexicon entries [(phrase, score)] with picked phrases moved to the top: just above
        the best entry, more so the more often they were picked. Returns a new list."""
        picked = self.data.get(self.key(syllables))
        if not picked or not entries:
            return entries
        top = entries[0][1]
        out = [(p, max(s, top + 0.01 + 0.1 * picked[p][0]) if p in picked else s) for p, s in entries]
        out.sort(key=lambda e: -e[1])
        return out
