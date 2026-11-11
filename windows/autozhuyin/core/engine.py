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

# An English word that is also a common one-syllable Chinese reading ("up " = ㄧㄣ 因)
# is not committed on space; the next word decides ("up jo4" = 因為, "up the" = up the).
HOLD_MIN_SCORE = -3.5

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
        # English mode, toggled by a Shift tap when nothing is being typed: keys go straight
        # to the app (no composition, no underline) until Shift is tapped again.
        self.english_mode = False
        self.fixed = {}          # zhuyin segment start -> {(syl_start, syl_end): text}
        self.candidates = []
        self.candidate_index = 0
        self._candidate_segment_start = 0
        # Composition cursor for choosing candidates: index into _cursor_stops(), None = end.
        self.cursor = None
        # Index of a held space (see HOLD_MIN_SCORE), or None.
        self.held = None
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
        held = self.held if self.held is not None and self.held < len(keys) and keys[self.held] == " " else None
        cache_key = (tuple(keys), finishing, ctx, held)
        if cache_key != self._cache_key:
            self._cache_key = cache_key
            if held is None:
                self._cache_value = self.classifier.segment(keys, finishing, ctx)
            else:
                self._cache_value = self._held_segments(keys, held, finishing)
        return self._cache_value

    def _held_segments(self, keys, held, finishing):
        """The held word is Chinese if the words typed after it start with Chinese."""
        rest = keys[held + 1:]
        base = held + 1
        rest_segs = [(a + base, b + base, m) for a, b, m in self.classifier.segment(rest, finishing, None)]
        if rest_segs and rest_segs[0][2] == ZHUYIN:
            return [(0, rest_segs[0][1], ZHUYIN)] + rest_segs[1:]
        return [(0, base, LITERAL)] + rest_segs

    def _is_ambiguous_word(self, keys):
        """Whether keys + space also read as a common Chinese syllable (see HOLD_MIN_SCORE)."""
        if not all(k.isascii() and k.isalpha() for k in keys):
            return False
        p = bopomofo.parse(list(keys) + [" "])
        if p.pending is not None or len(p.syllables) != 1:
            return False
        entries = self.classifier.lexicon.entries([s.syllable for s in p.syllables])
        return bool(entries) and entries[0][1] >= HOLD_MIN_SCORE

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

    def _flip(self):
        """Forces the whole buffer into the other mode (a correction that is learned)."""
        self.forced_mode = LITERAL if self.mode == ZHUYIN else ZHUYIN

    def wants(self, key):
        """Whether handle(key) would consume the key, without changing state."""
        if self.candidates or key == SHIFT_TAP:
            return True
        if self.english_mode and not self.keys:
            return False   # English mode: everything goes to the app as typed
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
            if self.held is not None and len(self.keys) <= self.held:
                self.held = None
            self.fixed = {k: v for k, v in self.fixed.items() if k < len(self.keys)}
            if not self.keys:
                self.forced_mode = None
                self.fixed = {}
            return CONSUMED
        if key == ENTER:
            if not self.keys:
                return PASS
            return True, self._commit()
        if key == ESCAPE:
            if not self.keys:
                return PASS
            self.reset()
            return CONSUMED
        if key == TAB:
            if not self.keys:
                return PASS
            self._flip()
            return CONSUMED
        if key == SHIFT_TAP:
            if not self.keys:
                # Toggle English mode; it stays on until the next Shift tap.
                self.english_mode = not self.english_mode
                self._previous_mode = LITERAL if self.english_mode else None
                self._previous_time = self.now()
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
        if self.english_mode and not self.keys:
            return PASS   # English mode: every key goes to the app as typed
        if c == " ":
            if not self.keys:
                return PASS
            segs = self._segments(self.keys, finishing=True)
            if segs[-1][2] == LITERAL:
                if (self.held is None and len(segs) == 1 and not self.forced_mode
                        and self._is_ambiguous_word(self.keys)):
                    self.held = len(self.keys)
                    self.keys.append(" ")
                    return CONSUMED
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
        self.held = None
        self.cursor = None
        self.forced_mode = None
        self.fixed = {}
        self.candidates = []
