""""AI 選字": reranks the converter's best paths with a language model. Port of Reranker.swift.

    score = lexicon score (log10 → ln) + λ · LM log-probability

Typing is never blocked for long: a rerank that runs over its time budget counts as an
overrun, and three in a row pause AI for a minute. `system_state` lets the shell pause
or reduce it when the machine is busy, hot or saving power.

高品質 uses `large_model` (gpt2-base, an optional download) when it is there. It is too
slow to run on each key, so it runs in a background thread: until its result is ready the
small model's is shown, `on_update` announces the result (from that thread), and a commit
waits for it a little (see `choose`). Without the large model 高品質 is the same as 標準.
"""
import math
import threading
import time

OFF, SAVER, STANDARD, QUALITY = "off", "saver", "standard", "quality"
MODES = (OFF, SAVER, STANDARD, QUALITY)
# Paths the small model reranks, and the time budget (seconds) of one rerank (more paths
# than 標準 gave no better results with the small model). numpy is slower than the Mac's
# Accelerate code, so the budgets are larger than in Reranker.swift.
K = {SAVER: 3, STANDARD: 10, QUALITY: 10}
BUDGET = {SAVER: 0.04, STANDARD: 0.08, QUALITY: 0.08}
# Paths and weight for the large model (windows/tools/eval_ai.py: best on both sets).
LARGE_K = 10
LARGE_LAMBDA = 2.0

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
        self._large_model = None
        self.on_update = None        # called from the worker thread when a background rerank finished
        self._cond = threading.Condition()   # guards the large-model state below
        self._large_cache = {}
        self._queued = None          # (key, paths, context, model, generation)
        self._running = None         # key being computed
        self._working = False
        self._generation = 0

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
        with self._cond:
            self._large_cache.clear()
            self._queued = None
            self._generation += 1    # results still running are dropped

    @property
    def large_model(self):
        return self._large_model

    @large_model.setter
    def large_model(self, value):
        self._large_model = value
        self.clear_cache()

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

    def choose(self, converter, syllables, fixed, context, wait=0):
        """The reranked conversion [((start, end), text)], or None for the plain result.
        `wait`: seconds to wait for the large model's result (when committing); 0 shows the
        small model's result meanwhile."""
        mode = self.effective_mode()
        if mode is None or not syllables:
            return None
        key = (mode, context, tuple(s.reading for s in syllables), tuple(sorted(fixed.items())))
        large = self._large_model
        if mode == QUALITY and large is not None:
            chosen = self._choose_large(converter, syllables, fixed, context, key, large, wait)
            if chosen is not None:
                return chosen
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

    # --- large model, in the background ---

    def _choose_large(self, converter, syllables, fixed, context, key, model, wait):
        with self._cond:
            if key in self._large_cache:
                return self._large_cache[key]
            if self._running != key and (self._queued is None or self._queued[0] != key):
                # k-best on this thread: the lexicon may change on it, never in the background.
                paths = converter.kbest(syllables, LARGE_K, fixed)
                if len(paths) <= 1:
                    return paths[0][1] if paths else None
                self._queued = (key, paths, context, model, self._generation)
                if not self._working:
                    self._working = True
                    threading.Thread(target=self._work, daemon=True).start()
            deadline = time.monotonic() + wait
            while wait > 0 and key not in self._large_cache and (
                    self._running == key or (self._queued is not None and self._queued[0] == key)):
                left = deadline - time.monotonic()
                if left <= 0:
                    break
                self._cond.wait(left)
            return self._large_cache.get(key)

    def _work(self):
        """Runs queued jobs one at a time; a newer job replaces one not started yet."""
        while True:
            with self._cond:
                if self._queued is None:
                    self._working = False
                    return
                key, paths, context, model, generation = self._queued
                self._queued = None
                self._running = key
            try:
                lm = model.log_probs(["".join(t for _, t in segs) for _, segs in paths], context)
                best = max(range(len(paths)), key=lambda i: paths[i][0] * math.log(10) + LARGE_LAMBDA * lm[i])
                result = paths[best][1]
            except Exception:   # noqa: BLE001 — a failure just leaves the small model's result
                result = None
            with self._cond:
                self._running = None
                current = generation == self._generation
                if current and result is not None:
                    if len(self._large_cache) >= CACHE_LIMIT:
                        self._large_cache.clear()
                    self._large_cache[key] = result
                self._cond.notify_all()
            if current and result is not None and self.on_update is not None:
                self.on_update()
