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
SHIFT_TAP = "<shift-tap>"   # Shift pressed and released on its own
SPECIAL_KEYS = {BACKSPACE, ENTER, ESCAPE, TAB, UP, DOWN, LEFT, RIGHT, SHIFT_TAP}

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
        # True when forced_mode corrects the classifier (learned on commit); False when the
        # user forced English before typing (Shift tap on an empty buffer).
        self._forced_is_correction = False
        self.fixed = {}          # zhuyin segment start -> {(syl_start, syl_end): text}
        self.candidates = []
        self.candidate_index = 0
        self._candidate_segment_start = 0
        # Composition cursor for choosing candidates: index into _cursor_stops(), None = end.
        self.cursor = None
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

    def _convertible(self, seg, final):
        """(syllables converted to Chinese, pending Bopomofo) for a Zhuyin segment."""
        start, end, _ = seg
        p = bopomofo.parse(self.keys[start:end])
        if final:
            return [s.syllable for s in p.syllables], ""
        return [s.syllable for s in p.completed], (p.pending.syllable.reading if p.pending else "")

    def _conversion(self, seg, final):
        syl, pending = self._convertible(seg, final)
        fx = {k: v for k, v in self.fixed.get(seg[0], {}).items() if k[1] <= len(syl)}
        return self.converter.convert(syl, fx), pending

    def _render(self, seg, final):
        start, end, mode = seg
        if mode == LITERAL:
            return "".join(self.keys[start:end])
        converted, pending = self._conversion(seg, final)
        return "".join(t for _, t in converted) + pending

    # --- cursor ---

    def _cursor_stops(self):
        """[(segment index, syllables before the stop)] for every Zhuyin syllable."""
        segs = self.segments
        out = []
        for i, seg in enumerate(segs):
            if seg[2] == ZHUYIN:
                n = len(self._convertible(seg, i < len(segs) - 1)[0])
                out.extend((i, k) for k in range(1, n + 1))
        return out

    @property
    def cursor_offset(self):
        """Cursor position in marked_text (characters)."""
        pieces = self.marked_pieces
        stops = self._cursor_stops()
        if self.cursor is None or not 0 <= self.cursor < len(stops):
            return sum(len(t) for t, _ in pieces)
        seg_index, local = stops[self.cursor]
        offset = sum(len(t) for t, _ in pieces[:seg_index])
        segs = self.segments
        for (a, b), text in self._conversion(segs[seg_index], seg_index < len(segs) - 1)[0]:
            if b <= local:
                offset += len(text)
            elif a < local:
                offset += min(local - a, len(text))
        return offset

    def _move_cursor(self, delta):
        stops = self._cursor_stops()
        if not stops:
            return
        nxt = (len(stops) - 1 if self.cursor is None else self.cursor) + delta
        self.cursor = None if nxt >= len(stops) - 1 else max(0, nxt)

    @property
    def marked_pieces(self):
        segs = self.segments
        return [(self._render(s, i < len(segs) - 1), s[2]) for i, s in enumerate(segs)]

    @property
    def marked_text(self):
        return "".join(t for t, _ in self.marked_pieces)

    # --- key handling ---

    @property
    def english_armed(self):
        """True while the user has forced English for the next word (Shift tap). In this
        mode keys go straight to the app with no composition (no underline)."""
        return not self.keys and self.forced_mode == LITERAL and not self._forced_is_correction

    def _end_direct_english(self):
        if self.english_armed:
            self.forced_mode = None
            self._previous_mode = LITERAL
            self._previous_time = self.now()

    def _flip(self):
        self.forced_mode = LITERAL if self.mode == ZHUYIN else ZHUYIN
        self._forced_is_correction = True

    def wants(self, key):
        """Whether handle(key) would consume the key, without changing state."""
        if self.candidates or key == SHIFT_TAP or self.english_armed:
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
            self.cursor = None
            self.keys.pop()
            self.fixed = {k: v for k, v in self.fixed.items() if k < len(self.keys)}
            if not self.keys:
                # A Shift-tap "next word is English" stays armed; a correction is dropped.
                if self._forced_is_correction:
                    self.forced_mode = None
                    self._forced_is_correction = False
                self.fixed = {}
            return CONSUMED
        if key == ENTER:
            if not self.keys:
                self._end_direct_english()
                return PASS
            return True, self._commit()
        if key == ESCAPE:
            if not self.keys:
                self._end_direct_english()
                return PASS
            self.reset()
            return CONSUMED
        if key == TAB:
            if not self.keys:
                self._end_direct_english()
                return PASS
            self._flip()
            return CONSUMED
        if key == SHIFT_TAP:
            if not self.keys:
                # Next word is English, typed as-is. Tap again to cancel.
                self.forced_mode = None if self.forced_mode == LITERAL else LITERAL
                self._forced_is_correction = False
            else:
                self._flip()
            return CONSUMED
        if key == DOWN:
            if not self.keys:
                return PASS
            self._open_candidates()
            return CONSUMED
        if key in (LEFT, RIGHT):
            if not self.keys:
                return PASS
            self._move_cursor(-1 if key == LEFT else 1)
            return CONSUMED
        if key == UP:
            return CONSUMED if self.keys else PASS
        return self._handle_character(key)

    def _last_parse(self, segs):
        if not segs or segs[-1][2] != ZHUYIN:
            return None
        start, end, _ = segs[-1]
        return bopomofo.parse(self.keys[start:end])

    def _handle_character(self, c):
        self.cursor = None   # typing always continues at the end
        if self.english_armed:
            # Forced English: insert directly. Space ends the word; other symbols end it too.
            if c == " ":
                self._end_direct_english()
                return True, " "
            if c.isascii() and (c.isalnum() or c in "'.,-/;"):
                return True, c
            self._end_direct_english()
            return PASS
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
        """Candidates for the phrase ending at the cursor (default: the last syllable)."""
        stops = self._cursor_stops()
        if not stops:
            return
        seg_index, local = stops[min(len(stops) - 1 if self.cursor is None else self.cursor, len(stops) - 1)]
        segs = self.segments
        seg = segs[seg_index]
        syl = self._convertible(seg, seg_index < len(segs) - 1)[0]
        self.candidates = self.converter.candidates(syl, local)
        self._candidate_segment_start = seg[0]
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
        if self.forced_mode and self._forced_is_correction:
            self.classifier.learned.record("".join(self.keys), self.forced_mode)
        self._previous_mode = segs[-1][2] if segs else None
        self._previous_time = self.now()
        self.reset()
        return text

    def commit_all(self):
        return self._commit() if self.keys else ""

    def reset(self):
        self.keys = []
        self.cursor = None
        self.forced_mode = None
        self._forced_is_correction = False
        self.fixed = {}
        self.candidates = []
