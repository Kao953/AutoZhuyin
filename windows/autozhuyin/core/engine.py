"""Input method state machine. Port of CompositionEngine.swift.

Keys are given as one-character strings, or one of the names in SPECIAL_KEYS.
handle() returns (handled, commit_text_or_None).
"""
import time

from . import bopomofo
from .classifier import LITERAL, ZHUYIN
from .lexicon import Converter

BACKSPACE, ENTER, ESCAPE, TAB = "<backspace>", "<enter>", "<escape>", "<tab>"
UP, DOWN, LEFT, RIGHT = "<up>", "<down>", "<left>", "<right>"
SPECIAL_KEYS = {BACKSPACE, ENTER, ESCAPE, TAB, UP, DOWN, LEFT, RIGHT}

FULLWIDTH = {
    "<": "，", ">": "。", "?": "？", "!": "！", ":": "：", '"': "「", "(": "（", ")": "）",
    "{": "『", "}": "』", "[": "「", "]": "」", "~": "～", "_": "——",
}

PASS = (False, None)
CONSUMED = (True, None)


class CompositionEngine:
    page_size = 9
    context_window = 20.0

    def __init__(self, classifier, now=time.monotonic):
        self.classifier = classifier
        self.converter = Converter(classifier.lexicon)
        self.now = now
        self.keys = []
        self.forced_mode = None
        self.fixed = {}
        self.candidates = []
        self.candidate_index = 0
        self._previous_mode = None
        self._previous_time = float("-inf")

    # --- derived state ---

    @property
    def context(self):
        return self._previous_mode if self.now() - self._previous_time < self.context_window else None

    @property
    def mode(self):
        return self.forced_mode or self.classifier.mode(self.keys, previous=self.context)

    @property
    def showing_candidates(self):
        return bool(self.candidates)

    @property
    def page_start(self):
        return (self.candidate_index // self.page_size) * self.page_size

    def _parse(self):
        return bopomofo.parse(self.keys)

    def _valid_fixed(self, p):
        n = len(p.completed)
        return {k: v for k, v in self.fixed.items() if k[1] <= n}

    @property
    def marked_text(self):
        if not self.keys:
            return ""
        if self.mode == LITERAL:
            return "".join(self.keys)
        p = self._parse()
        done = self.converter.convert([s.syllable for s in p.completed], self._valid_fixed(p))
        pending = p.pending.syllable.reading if p.pending else ""
        return "".join(t for _, t in done) + pending

    def _zhuyin_commit_text(self):
        p = self._parse()
        segs = self.converter.convert([s.syllable for s in p.syllables], self._valid_fixed(p))
        return "".join(t for _, t in segs)

    # --- key handling ---

    def wants(self, key):
        """Whether handle(key) would consume the key, without changing state."""
        if self.candidates:
            return True
        if key in SPECIAL_KEYS:
            return bool(self.keys)
        if self.keys:
            return True
        if key == " ":
            return False
        if bopomofo.is_zhuyin_key(key) or (key.isascii() and key.isalpha()):
            return True
        return self.context == ZHUYIN and key in FULLWIDTH

    def handle(self, key):
        if self.candidates:
            return self._handle_candidate_key(key)
        if key == BACKSPACE:
            if not self.keys:
                return PASS
            self.keys.pop()
            self.fixed = self._valid_fixed(self._parse())
            if not self.keys:
                self.forced_mode = None
                self.fixed = {}
            return CONSUMED
        if key == ENTER:
            return (True, self._commit()) if self.keys else PASS
        if key == ESCAPE:
            if not self.keys:
                return PASS
            self.reset()
            return CONSUMED
        if key == TAB:
            if not self.keys:
                return PASS
            self.forced_mode = LITERAL if self.mode == ZHUYIN else ZHUYIN
            return CONSUMED
        if key == DOWN:
            if not self.keys:
                return PASS
            self._open_candidates()
            return CONSUMED
        if key in (UP, LEFT, RIGHT):
            return CONSUMED if self.keys else PASS
        return self._handle_character(key)

    def _handle_character(self, c):
        if c == " ":
            if not self.keys:
                return PASS
            decided = self.forced_mode or self.classifier.mode(self.keys, finishing=True, previous=self.context)
            if decided == LITERAL:
                return True, self._commit(LITERAL) + " "
            if self._parse().pending is not None:
                self.keys.append(" ")
                return CONSUMED
            return True, self._commit(ZHUYIN)

        composable = bopomofo.is_zhuyin_key(c) or (c.isascii() and c.isalpha()) or (c == "'" and self.keys)
        if composable:
            # ", . / ; -" are Zhuyin symbols but act as punctuation after an English word.
            if self.keys and c in bopomofo.SYMBOLS and not c.isalnum() and self.forced_mode != ZHUYIN:
                with_key = self.forced_mode or self.classifier.mode(self.keys + [c], previous=self.context)
                if with_key == LITERAL and not all(k.isdigit() for k in self.keys):
                    return True, self._commit(LITERAL) + c
            self.keys.append(c)
            return CONSUMED

        chinese = (self.context == ZHUYIN) if not self.keys else (self.mode == ZHUYIN)
        committed = self._commit() if self.keys else ""
        punct = FULLWIDTH.get(c, c) if chinese else c
        if not committed and punct == c:
            return PASS
        return True, committed + punct

    # --- candidates ---

    def _open_candidates(self):
        p = self._parse()
        if self.mode != ZHUYIN or not p.completed:
            return
        syl = [s.syllable for s in p.completed]
        self.candidates = self.converter.candidates(syl, len(syl))
        self.candidate_index = 0

    def page(self):
        """Candidates on the current page and the cursor within it."""
        start = self.page_start
        return [t for _, t in self.candidates[start:start + self.page_size]], self.candidate_index - start

    def select_candidate(self, index):
        if not 0 <= index < len(self.candidates):
            return
        rng, text = self.candidates[index]
        self.fixed = {k: v for k, v in self.fixed.items() if not (k[0] < rng[1] and rng[0] < k[1])}
        self.fixed[rng] = text
        self.candidates = []

    def _handle_candidate_key(self, key):
        if len(key) == 1 and key.isdigit() and key != "0":
            self.select_candidate(self.page_start + int(key) - 1)
        elif key in (" ", ENTER):
            self.select_candidate(self.candidate_index)
        elif key in (DOWN, RIGHT):
            self.candidate_index = min(len(self.candidates) - 1, self.candidate_index + 1)
        elif key in (UP, LEFT):
            self.candidate_index = max(0, self.candidate_index - 1)
        elif key in (ESCAPE, BACKSPACE):
            self.candidates = []
        return CONSUMED

    # --- commit ---

    def _commit(self, decided=None):
        m = decided or self.mode
        text = "".join(self.keys) if m == LITERAL else self._zhuyin_commit_text()
        if self.forced_mode:
            self.classifier.learned.record("".join(self.keys), self.forced_mode)
        self._previous_mode = m
        self._previous_time = self.now()
        self.reset()
        return text

    def commit_all(self):
        return self._commit() if self.keys else ""

    def reset(self):
        self.keys = []
        self.forced_mode = None
        self.fixed = {}
        self.candidates = []
