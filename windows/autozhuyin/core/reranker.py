""""AI 選字": reranks the converter's best paths with a language model. Port of Reranker.swift.

    score = lexicon score (log10 → ln) + λ · LM log-probability

Typing is never blocked for long: a rerank that runs over its time budget counts as an
overrun, and three in a row pause AI for a minute. `system_state` lets the shell pause
or reduce it when the machine is busy, hot or saving power.
"""
import math
import time

OFF, SAVER, STANDARD, QUALITY = "off", "saver", "standard", "quality"
MODES = (OFF, SAVER, STANDARD, QUALITY)
# Paths reranked, and the time budget (seconds) of one rerank. numpy is slower than
# the Mac's Accelerate code, so the budgets are larger than in Reranker.swift.
K = {SAVER: 3, STANDARD: 10, QUALITY: 30}
BUDGET = {SAVER: 0.04, STANDARD: 0.08, QUALITY: 0.2}

NORMAL, REDUCED, PAUSED = "normal", "reduced", "paused"            # system states
ST_OFF, ST_LOADING, ST_ACTIVE, ST_BUSY, ST_SLOW = "off", "loading", "active", "paused-busy", "paused-slow"

PAUSE_AFTER_OVERRUNS = 3
SLOW_PAUSE = 60.0
CACHE_LIMIT = 512


class Reranker:
    def __init__(self, mode=STANDARD, model=None, now=time.monotonic):
        self._mode = mode
        self._model = model
        self.lam = 0.6
        self.system_state = lambda: NORMAL
        self.now = now
        self.status = ST_OFF
        self._overruns = 0
        self._paused_until = float("-inf")
        self._cache = {}

    @property
    def mode(self):
        return self._mode

    @mode.setter
    def mode(self, value):
        self._mode = value
        self._cache.clear()

    def clear_cache(self):
        """Forgets cached results (the lexicon changed)."""
        self._cache.clear()

    @property
    def model(self):
        return self._model

    @model.setter
    def model(self, value):
        self._model = value
        self._cache.clear()

    def effective_mode(self):
        """The mode used now (after the system state), or None when AI is not used."""
        if self._mode == OFF:
            self.status = ST_OFF
            return None
        if self._model is None:
            self.status = ST_LOADING
            return None
        if self.now() < self._paused_until:
            self.status = ST_SLOW
            return None
        state = self.system_state()
        if state == PAUSED:
            self.status = ST_BUSY
            return None
        self.status = ST_ACTIVE
        return SAVER if state == REDUCED else self._mode

    def choose(self, converter, syllables, fixed, context):
        """The reranked conversion [((start, end), text)], or None for the plain result."""
        mode = self.effective_mode()
        if mode is None or not syllables:
            return None
        key = (mode, context, tuple(s.reading for s in syllables), tuple(sorted(fixed.items())))
        if key in self._cache:
            return self._cache[key]
        paths = converter.kbest(syllables, K[mode], fixed)
        if len(paths) <= 1:
            return paths[0][1] if paths else None
        start = self.now()
        lm = self._model.log_probs(["".join(t for _, t in segs) for _, segs in paths], context)
        best = max(range(len(paths)), key=lambda i: paths[i][0] * math.log(10) + self.lam * lm[i])
        if self.now() - start > BUDGET[mode]:
            # Too slow: use this result (it is computed) but don't cache it, and pause AI
            # after a few overruns in a row.
            self._overruns += 1
            if self._overruns >= PAUSE_AFTER_OVERRUNS:
                self._paused_until = self.now() + SLOW_PAUSE
                self._overruns = 0
                self.status = ST_SLOW
            return paths[best][1]
        self._overruns = 0
        if len(self._cache) >= CACHE_LIMIT:
            self._cache.clear()
        self._cache[key] = paths[best][1]
        return paths[best][1]
