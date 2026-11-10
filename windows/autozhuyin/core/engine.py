"""Input method state machine. Port of CompositionEngine.swift.

Keys are given as one-character strings, or one of the names in SPECIAL_KEYS.
handle() returns (handled, commit_text_or_None).
The buffer is split into Zhuyin / literal segments, e.g. "ji3hello" -> 我 + hello.
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
        self.fixed = {}          # zhuyin segment start -> {(syl_start, syl_end): text}
        self.candidates = []
        self.candidate_index = 0
        self._candidate_segment_start = 0
        self._previous_mode = None
        self._previous_time = float("-inf")
        self._cache_key = None
        self._cache_value = None

    # --- derived state ---

    @property
    def context(self):
        return self._previous_mode if self.now() - self._previous_time < self.context_window else None

    def _segments(self, keys, finishing=False):
        if not keys:
            return []
        if self.forced_mode:
            return [(0, len(keys), self.forced_mode)]
        ctx = self.context
        cache_key = (tuple(keys), finishing, ctx)
        if cache_key != self._cache_key:
            self._cache_key = cache_key
            self._cache_value = self.classifier.segment(keys, finishing, ctx)
        return self._cache_value

    @property
    def segments(self):
        return self._segments(self.keys)

    @property
    def mode(self):
        segs = self.segments
        return segs[-1][2] if segs else ZHUYIN

    @property
    def showing_candidates(self):
        return bool(self.candidates)

    @property
    def page_start(self):
        return (self.candidate_index // self.page_size) * self.page_size

    def _render(self, seg, final):
        start, end, mode = seg
        seg_keys = self.keys[start:end]
        if mode == LITERAL:
            return "".join(seg_keys)
        p = bopomofo.parse(seg_keys)
        fixed_here = self.fixed.get(start, {})
        syl = [s.syllable for s in (p.syllables if final else p.completed)]
        fx = {k: v for k, v in fixed_here.items() if k[1] <= len(syl)}
        text = "".join(t for _, t in self.converter.convert(syl, fx))
        if not final and p.pending:
            text += p.pending.syllable.reading
        return text

    @property
    def marked_pieces(self):
        segs = self.segments
        return [(self._render(s, i < len(segs) - 1), s[2]) for i, s in enumerate(segs)]

    @property
    def marked_text(self):
        return "".join(t for t, _ in self.marked_pieces)

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
            self.fixed = {k: v for k, v in self.fixed.items() if k < len(self.keys)}
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

    def _last_parse(self, segs):
        if not segs or segs[-1][2] != ZHUYIN:
            return None
        start, end, _ = segs[-1]
        return bopomofo.parse(self.keys[start:end])

    def _handle_character(self, c):
        if c == " ":
            if not self.keys:
                return PASS
            segs = self._segments(self.keys, finishing=True)
            if segs[-1][2] == LITERAL:
                return True, self._commit(segs) + " "
            p = self._last_parse(segs)
            if p is not None and p.pending is not None:
                self.keys.append(" ")
                return CONSUMED
            return True, self._commit(segs)

        composable = bopomofo.is_zhuyin_key(c) or (c.isascii() and c.isalpha()) or (c == "'" and self.keys)
        if composable:
            # ", . / ; -" are Zhuyin symbols but act as punctuation after an English word.
            if self.keys and c in bopomofo.SYMBOLS and not c.isalnum() and self.forced_mode != ZHUYIN:
                with_key = self._segments(self.keys + [c])
                if with_key[-1][2] == LITERAL and not all(k.isdigit() for k in self.keys):
                    return True, self._commit() + c
            self.keys.append(c)
            return CONSUMED

        chinese = (self.context == ZHUYIN) if not self.keys else (self.mode == ZHUYIN)
        committed = self._commit() if self.keys else ""
        punct = FULLWIDTH.get(c, c) if chinese else c
        if not committed and punct == c:
            return PASS
        return True, committed + punct

    # --- candidates (for the last Zhuyin segment) ---

    def _open_candidates(self):
        segs = self.segments
        if not segs or segs[-1][2] != ZHUYIN:
            return
        start, end, _ = segs[-1]
        syl = [s.syllable for s in bopomofo.parse(self.keys[start:end]).completed]
        if not syl:
            return
        self.candidates = self.converter.candidates(syl, len(syl))
        self._candidate_segment_start = start
        self.candidate_index = 0

    def page(self):
        """Candidates on the current page and the cursor within it."""
        start = self.page_start
        return [t for _, t in self.candidates[start:start + self.page_size]], self.candidate_index - start

    def select_candidate(self, index):
        if not 0 <= index < len(self.candidates):
            return
        rng, text = self.candidates[index]
        here = {k: v for k, v in self.fixed.get(self._candidate_segment_start, {}).items()
                if not (k[0] < rng[1] and rng[0] < k[1])}
        here[rng] = text
        self.fixed[self._candidate_segment_start] = here
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

    def _commit(self, segs=None):
        segs = segs if segs is not None else self.segments
        text = "".join(self._render(s, True) for s in segs)
        if self.forced_mode:
            self.classifier.learned.record("".join(self.keys), self.forced_mode)
        self._previous_mode = segs[-1][2] if segs else None
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
