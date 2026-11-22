"""Input method state machine. Port of CompositionEngine.swift.

Keys are given as one-character strings, or one of the names in SPECIAL_KEYS.
handle() returns (handled, commit_text_or_None).
The buffer is split into Zhuyin / literal segments, e.g. "ji3hello" -> 我 + hello.
"""
import time

from . import bopomofo
from .classifier import LITERAL, ZHUYIN
from .features import dot
from .lexicon import Converter

BACKSPACE, ENTER, ESCAPE, TAB = "<backspace>", "<enter>", "<escape>", "<tab>"
UP, DOWN, LEFT, RIGHT = "<up>", "<down>", "<left>", "<right>"
SHIFT_TAP = "<shift-tap>"   # Shift pressed and released on its own
SPECIAL_KEYS = {BACKSPACE, ENTER, ESCAPE, TAB, UP, DOWN, LEFT, RIGHT, SHIFT_TAP}

FULLWIDTH = {
    "<": "，", ">": "。", "?": "？", "!": "！", ":": "：", '"': "「", "(": "（", ")": "）",
    "{": "『", "}": "』", "[": "「", "]": "」", "~": "～", "_": "——", "\\": "、",
}

# The first word of a composition that also reads as Zhuyin is not committed as English
# on space; the next word decides ("up jo4" = 因為, "up the" = up the, "no su3" = no 你).
# Right after English text only common one-syllable readings are held (up = 因, url = 教),
# so normal English typing is not delayed.
HOLD_MIN_SCORE = -3.5

# "`" then one of these keys always gives the full-width symbol, whatever the context.
# "`" followed by anything else is just a backtick (so ``` still works).
BACKTICK = "`"
SYMBOLS = {
    ",": "，", "<": "，", ".": "。", ">": "。", "/": "？", "?": "？", ";": "；", ":": "：",
    "'": "、", "\\": "、", '"': "「", "[": "「", "]": "」", "{": "『", "}": "』",
    "(": "（", ")": "）", "!": "！", "~": "～", "-": "——", "_": "——", "=": "＝",
}

# Ctrl + key → full-width symbol, whatever the context.
CONTROL_SYMBOLS = {";": "；", "'": "、", ",": "，", ".": "。", "/": "？"}

# "`" then space (or ↓): every full-width symbol, most used first.
SYMBOL_TABLE = [
    "，", "。", "、", "；", "：", "？", "！", "「", "」",
    "『", "』", "（", "）", "《", "》", "〈", "〉", "…",
    "——", "～", "・", "【", "】", "〔", "〕", "＂", "＇",
    "＋", "－", "×", "÷", "＝", "≠", "≦", "≧", "％",
    "＃", "＆", "＊", "＠", "／", "＼", "｜", "＿", "※",
    "○", "●", "△", "▲", "□", "■", "☆", "★", "◎",
    "→", "←", "↑", "↓", "℃", "°", "√", "∞", "　",
]

PASS = (False, None)
CONSUMED = (True, None)


class CompositionEngine:
    page_size = 9
    context_window = 20.0

    def __init__(self, classifier, now=time.monotonic):
        self.classifier = classifier
        self.converter = Converter(classifier.lexicon, classifier.history)
        self.now = now
        self.keys = []
        self.forced_mode = None
        self.forced_count = 0
        # English mode, toggled by a Shift tap when nothing is being typed: keys go straight
        # to the app (no composition, no underline) until Shift is tapped again.
        self.english_mode = False
        self.backtick = False    # "`" typed; the next key may be a forced symbol
        # A Shift-punctuation typed with nothing composed, not sent yet: full-width or not is
        # only a guess from the context, so Tab (or a Shift tap) switches "<" ↔ "，" first.
        # Any other key sends it.
        self.punct = None
        self._punct_fullwidth = False
        self._punct_flipped = False
        self.fixed = {}          # zhuyin segment start -> {(syl_start, syl_end): text}
        self.candidates = []
        self.symbol_table = False   # candidates are the "`" + space symbol table
        self.candidate_index = 0
        self._candidate_segment_start = 0
        # Composition cursor: a key index into self.keys (None = at the end). ← → move it
        # between syllables; ↓ opens candidates for the phrase before it; typing there
        # inserts a syllable (kept in self.inserting until its tone key, then spliced in).
        self.cursor = None
        self.inserting = []
        # Index of a held space (see HOLD_MIN_SCORE), or None.
        self.held = None
        self.reranker = None     # "AI 選字" (reranker.Reranker); None = lexicon only
        self._recent_text = ""   # last characters committed: context for the reranker
        # The last commit by space, until the next key: Tab right after it retypes the same
        # keys in the other mode (an after-the-fact correction, learned like a Tab flip). Not
        # after Enter: that confirms the text, and Tab next is completion or indenting.
        # (keys, text, mode, recent_text) or None.
        self._last_commit = None
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
        if rest_segs and rest_segs[0][2] == ZHUYIN and self._held_reads_as_chinese(keys, held, rest_segs[0][1], finishing):
            return [(0, rest_segs[0][1], ZHUYIN)] + rest_segs[1:]
        return [(0, base, LITERAL)] + rest_segs

    def _held_reads_as_chinese(self, keys, held, end, finishing):
        """Chinese all the way to `end` vs. the held English word followed by Chinese."""
        c, w, ctx = self.classifier, self.classifier.weights, self.context
        is_last = end == len(keys)
        zh_whole = c.segment_features(keys[:end], is_last, False, finishing, ctx)[0]
        word = c.segment_features(keys[:held], False, False, True, ctx)[1]
        zh_rest = c.segment_features(keys[held + 1:end], is_last, True, finishing, None)[0]
        if zh_whole is None:
            return False
        if word is None or zh_rest is None:
            return True
        return dot(w, zh_whole) >= dot(w, word) + dot(w, zh_rest)

    def _is_ambiguous_word(self, keys):
        """Whether keys + space also read as a common Chinese syllable (see HOLD_MIN_SCORE).
        Any Dachen keys count, not only letters: "0" is ㄢ (安), "5j;" is ㄓㄨㄤ (裝)."""
        if not all(bopomofo.is_zhuyin_key(k) for k in keys):
            return False
        p = bopomofo.parse(list(keys) + [" "])
        if p.pending is not None or not p.syllables or p.stray_tones or p.foreign_keys:
            return False
        best = []
        for ps in p.syllables:
            entries = self.classifier.lexicon.entries([ps.syllable])
            if not entries:
                return False
            best.append(entries[0][1])
        if self.context != LITERAL:
            return True    # first word: hold anything that reads as Zhuyin
        return len(best) == 1 and best[0] >= HOLD_MIN_SCORE

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
        if self.reranker is not None:
            chosen = self.reranker.choose(self.converter, syl, fx, self._rerank_context())
            if chosen is not None:
                return chosen, pending
        return self.converter.convert(syl, fx), pending

    def _rerank_context(self):
        return self._recent_text if self.now() - self._previous_time < self.context_window else ""

    def _render(self, seg, final):
        start, end, mode = seg
        if mode == LITERAL:
            return "".join(self.keys[start:end])
        converted, pending = self._conversion(seg, final)
        return "".join(t for _, t in converted) + pending

    # --- cursor ---

    def _syllable_ends(self, seg):
        """Absolute key index after each syllable of a Zhuyin segment."""
        return [seg[0] + ps.end for ps in bopomofo.parse(self.keys[seg[0]:seg[1]]).syllables]

    def _cursor_positions(self):
        """Key indices the cursor can stop at: after every Zhuyin syllable and at every
        segment boundary, but never before the first Chinese character (there would be
        nothing to pick candidates for)."""
        out, ends = {len(self.keys)}, []
        for seg in self.segments:
            out.add(seg[1])
            if seg[2] == ZHUYIN:
                ends += self._syllable_ends(seg)
        out.update(ends)
        first = min(ends) if ends else len(self.keys)
        return sorted(p for p in out if p >= first)

    def _stop_at(self, pos):
        """(segment index, syllables before pos) for the Zhuyin segment pos is in."""
        segs = self.segments
        for i, seg in enumerate(segs):
            if seg[2] == ZHUYIN and seg[0] < pos <= seg[1]:
                n = len(self._convertible(seg, i < len(segs) - 1)[0])
                local = sum(1 for e in self._syllable_ends(seg) if e <= pos)
                return (i, min(local, n)) if local else None
        return None

    def _candidate_stop(self):
        """Where ↓ opens candidates: before the cursor, or the last syllable."""
        if self.cursor is not None:
            return self._stop_at(self.cursor)
        segs = self.segments
        for i in range(len(segs) - 1, -1, -1):
            if segs[i][2] == ZHUYIN:
                n = len(self._convertible(segs[i], i < len(segs) - 1)[0])
                if n:
                    return i, n
        return None

    def _base_cursor_offset(self):
        """Cursor position in the rendered segments (without the syllable being inserted)."""
        pieces = self._segment_pieces()
        if self.cursor is None:
            return sum(len(t) for t, _ in pieces)
        segs = self.segments
        for i, seg in enumerate(segs):
            if not seg[0] < self.cursor <= seg[1]:
                continue
            offset = sum(len(t) for t, _ in pieces[:i])
            if seg[2] == LITERAL:
                return offset + self.cursor - seg[0]
            stop = self._stop_at(self.cursor)
            local = stop[1] if stop else 0
            for (a, b), text in self._conversion(seg, i < len(segs) - 1)[0]:
                if b <= local:
                    offset += len(text)
                elif a < local:
                    offset += min(local - a, len(text))
            return offset
        return 0

    @property
    def cursor_offset(self):
        """Cursor position in marked_text (characters)."""
        return self._base_cursor_offset() + len(self._inserting_text()) + len(self._punct_text())

    def _move_cursor(self, delta):
        self.inserting = []
        stops = self._cursor_positions()
        here = len(self.keys) if self.cursor is None else self.cursor
        if delta < 0:
            before = [p for p in stops if p < here]
            nxt = before[-1] if before else here
        else:
            after = [p for p in stops if p > here]
            nxt = after[0] if after else here
        self.cursor = None if nxt >= len(self.keys) else nxt

    def _inserting_text(self):
        if not self.inserting:
            return ""
        return "".join(ps.syllable.reading for ps in bopomofo.parse(self.inserting).syllables)

    # --- editing in the middle ---

    def _trim_fixed(self, pos):
        """Keeps picked phrases that end at or before key index pos (they don't move)."""
        kept = {}
        for seg in self.segments:
            picks = self.fixed.get(seg[0])
            if not picks or seg[2] != ZHUYIN:
                continue
            if seg[1] <= pos:
                kept[seg[0]] = picks
            elif seg[0] < pos:
                ends = self._syllable_ends(seg)
                here = {r: t for r, t in picks.items() if r[1] <= len(ends) and ends[r[1] - 1] <= pos}
                if here:
                    kept[seg[0]] = here
        self.fixed = kept

    def _splice(self, new_keys):
        """Inserts keys at the cursor and moves the cursor after them."""
        pos = self.cursor
        self._trim_fixed(pos)
        self.keys[pos:pos] = new_keys
        if self.held is not None and self.held >= pos:
            self.held += len(new_keys)
        self.cursor = pos + len(new_keys)
        if self.cursor >= len(self.keys):
            self.cursor = None

    def _delete_before_cursor(self):
        """Backspace in the middle: removes the syllable (or literal key) before the cursor."""
        pos = self.cursor
        start = pos - 1
        for seg in self.segments:
            if seg[2] == ZHUYIN and seg[0] < pos <= seg[1]:
                for ps in bopomofo.parse(self.keys[seg[0]:seg[1]]).syllables:
                    if seg[0] + ps.end == pos:
                        start = seg[0] + ps.start
        self._trim_fixed(start)
        del self.keys[start:pos]
        if self.held is not None:
            if start <= self.held < pos:
                self.held = None
            elif self.held >= pos:
                self.held -= pos - start
        self.cursor = start
        if not self.keys:
            self.reset()

    def _insert_key(self, c):
        """Typing with the cursor in the middle: compose one syllable, splice it in on its tone."""
        if c == " ":
            if not self.inserting:
                return True, self._commit()
            self._splice(self.inserting + [" "])
            self.inserting = []
            return CONSUMED
        self.inserting.append(c)
        p = bopomofo.parse(self.inserting)
        if p.stray_tones or p.foreign_keys:
            self.inserting.pop()   # a tone with nothing to attach to
            return CONSUMED
        if p.syllables and p.syllables[-1].toned and len(p.syllables) == 1:
            self._splice(self.inserting)
            self.inserting = []
        elif len(p.syllables) > 1:
            # A new syllable started without a tone: splice the first one as it is.
            first = p.syllables[0].end
            self._splice(self.inserting[:first])
            self.inserting = self.inserting[first:]
        return CONSUMED

    @property
    def marked_pieces(self):
        pieces = self._segment_pieces()
        if self.inserting:
            # Show the syllable being inserted at the cursor.
            at, out, done = self._base_cursor_offset(), [], False
            for text, mode in pieces:
                if not done and at <= len(text):
                    out += [(text[:at], mode), (self._inserting_text(), ZHUYIN), (text[at:], mode)]
                    done = True
                else:
                    out.append((text, mode))
                    at -= len(text)
            pieces = [(t, m) for t, m in out if t]
        if self.backtick:
            pieces.append((BACKTICK, LITERAL))
        if self.punct:
            pieces.append((self._punct_text(), ZHUYIN if self._punct_fullwidth else LITERAL))
        return pieces

    def _segment_pieces(self):
        segs = self.segments
        return [(self._render(s, i < len(segs) - 1), s[2]) for i, s in enumerate(segs)]

    @property
    def marked_text(self):
        return "".join(t for t, _ in self.marked_pieces)

    # --- key handling ---

    def _flip(self):
        """Forces the whole buffer into the other mode (a correction that is learned)."""
        self.forced_mode = LITERAL if self.mode == ZHUYIN else ZHUYIN
        self.forced_count = len(self.keys)   # that word is learned, not what is typed after it

    def wants(self, key):
        """Whether handle(key) would consume the key, without changing state."""
        if self.candidates or key == SHIFT_TAP or self.backtick or self.punct or self.inserting:
            return True
        if self.english_mode and not self.keys:
            return False   # English mode: everything goes to the app as typed
        if key in SPECIAL_KEYS:
            return bool(self.keys)
        if key == BACKTICK:
            return True
        if self.keys:
            return True
        if key == " ":
            return False
        if bopomofo.is_zhuyin_key(key) or (key.isascii() and key.isalpha()):
            return True
        return key in FULLWIDTH

    def handle(self, key):
        self._last_commit = None
        if self.candidates:
            return self._handle_candidate_key(key)
        if self.backtick:
            return self._after_backtick(key)
        if self.punct:
            return self._after_punct(key)
        if self.inserting and key in (BACKSPACE, ESCAPE):
            if key == BACKSPACE:
                self.inserting.pop()
            else:
                self.inserting = []
            return CONSUMED
        if key == BACKSPACE:
            if not self.keys:
                return PASS
            if self.cursor is not None:
                if self.cursor > 0:
                    self._delete_before_cursor()
                return CONSUMED
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
            if self.inserting:
                self._splice(self.inserting)
                self.inserting = []
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
            if not self.inserting:
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

    def _after_backtick(self, key):
        self.backtick = False
        if key in (ESCAPE, BACKSPACE):
            return CONSUMED
        # After English ("`ls` "), space keeps the backtick literal (Markdown code).
        opens_table = key == DOWN or (key == " " and (not self.keys or self.mode == ZHUYIN))
        committed = self._commit() if self.keys else ""
        if key in SYMBOLS:
            return True, committed + SYMBOLS[key]
        if opens_table:
            self._open_symbol_table()
            return True, committed or None
        # Not a symbol: the backtick was meant literally; then handle the key as usual.
        handled, more = self.handle(key)
        if not handled and len(key) == 1:
            handled, more = True, key
        return handled, committed + BACKTICK + (more or "")

    def _punct_text(self):
        if not self.punct:
            return ""
        return FULLWIDTH.get(self.punct, self.punct) if self._punct_fullwidth else self.punct

    def _after_punct(self, key):
        if key in (TAB, SHIFT_TAP):
            self._punct_fullwidth = not self._punct_fullwidth
            self._punct_flipped = not self._punct_flipped
            return CONSUMED
        if key in (ESCAPE, BACKSPACE):
            self.punct = None
            return CONSUMED
        fullwidth = self._punct_fullwidth
        text = self._commit_punct()
        # Space sends it like a word: half-width gets the space too.
        if key == " ":
            return True, text + ("" if fullwidth else " ")
        handled, more = self.handle(key)
        if not handled and len(key) == 1:
            handled, more = True, key
        return handled, text + (more or "")

    def _commit_punct(self):
        """Sends the held punctuation. A switch with Tab says which language is being typed,
        so the next punctuation is guessed the same way."""
        text = self._punct_text()
        if text and self._punct_flipped:
            self._previous_mode = ZHUYIN if self._punct_fullwidth else LITERAL
            self._previous_time = self.now()
        self.punct = None
        return text

    def _last_parse(self, segs):
        if not segs or segs[-1][2] != ZHUYIN:
            return None
        start, end, _ = segs[-1]
        return bopomofo.parse(self.keys[start:end])

    def _handle_character(self, c):
        if self.cursor is not None and self.keys and (c == " " or bopomofo.is_zhuyin_key(c)):
            return self._insert_key(c)
        if self.inserting:
            self._splice(self.inserting)
            self.inserting = []
        self.cursor = None   # anything else continues at the end
        if self.english_mode and not self.keys:
            return PASS   # English mode: every key goes to the app as typed
        if c == BACKTICK:
            self.backtick = True
            return CONSUMED
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
                return True, self._commit_flippable(segs)
            p = self._last_parse(segs)
            if p is not None and p.pending is not None:
                self.keys.append(" ")
                return CONSUMED
            return True, self._commit_flippable(segs)

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
        if not self.keys and c in FULLWIDTH:
            # Nothing typed before it to tell: hold it so Tab can switch it.
            self.punct, self._punct_fullwidth, self._punct_flipped = c, chinese, False
            return CONSUMED
        committed = self._commit() if self.keys else ""
        punct = FULLWIDTH.get(c, c) if chinese else c
        if not committed and punct == c:
            return PASS
        return True, committed + punct

    # --- candidates (for the last Zhuyin segment) ---

    def _open_candidates(self):
        """Candidates for the phrase ending at the cursor (default: the last syllable)."""
        stop = self._candidate_stop()
        if stop is None:
            return
        seg_index, local = stop
        segs = self.segments
        seg = segs[seg_index]
        syl = self._convertible(seg, seg_index < len(segs) - 1)[0]
        self.candidates = self.converter.candidates(syl, local)
        self._candidate_segment_start = seg[0]
        self.candidate_index = 0
        self.symbol_table = False

    def _open_symbol_table(self):
        self.candidates = [((0, 0), s) for s in SYMBOL_TABLE]
        self.candidate_index = 0
        self.symbol_table = True

    def handle_control(self, key):
        """Ctrl + ; ' , . / → ；、，。？ (commits any composition first). None: not one of
        them, the key is a shortcut for the app."""
        symbol = CONTROL_SYMBOLS.get(key)
        if symbol is None:
            return None
        self._last_commit = None
        self.candidates = []
        self.backtick = False
        if self.inserting:
            self._splice(self.inserting)
            self.inserting = []
        committed = self._commit_punct() + (self._commit() if self.keys else "")
        return True, committed + symbol

    def page(self):
        """Candidates on the current page and the cursor within it."""
        start = self.page_start
        return [t for _, t in self.candidates[start:start + self.page_size]], self.candidate_index - start

    def select_candidate(self, index):
        """Picks a candidate. Returns the text to commit when it comes from the symbol table."""
        if not 0 <= index < len(self.candidates):
            return None
        self._last_commit = None
        rng, text = self.candidates[index]
        if self.symbol_table:
            self.candidates = []
            self.symbol_table = False
            return text
        here = {k: v for k, v in self.fixed.get(self._candidate_segment_start, {}).items()
                if not (k[0] < rng[1] and rng[0] < k[1])}
        here[rng] = text
        self.fixed[self._candidate_segment_start] = here
        self.candidates = []
        return None

    def _handle_candidate_key(self, key):
        commit = None
        if len(key) == 1 and key.isdigit() and key != "0":
            commit = self.select_candidate(self.page_start + int(key) - 1)
        elif key in (" ", ENTER):
            commit = self.select_candidate(self.candidate_index)
        elif key in (DOWN, RIGHT):
            self.candidate_index = min(len(self.candidates) - 1, self.candidate_index + 1)
        elif key in (UP, LEFT):
            self.candidate_index = max(0, self.candidate_index - 1)
        elif key in (ESCAPE, BACKSPACE):
            self.candidates = []
            self.symbol_table = False
        return True, commit

    # --- commit ---

    def _commit(self, segs=None):
        segs = segs if segs is not None else self.segments
        text = "".join(self._render(s, True) for s in segs)
        self._remember_picks(segs)
        self._recent_text = (self._rerank_context() + text)[-20:]
        if self.forced_mode:
            self.classifier.learned.record("".join(self.keys[:self.forced_count]), self.forced_mode)
        self._previous_mode = segs[-1][2] if segs else None
        self._previous_time = self.now()
        self.reset()
        return text

    def _commit_flippable(self, segs=None):
        """Commits on space and remembers it for an after-the-fact Tab flip. English gets the
        space too."""
        segs = segs if segs is not None else self.segments
        typed, context = list(self.keys), self._recent_text
        mode = segs[-1][2] if segs else ZHUYIN
        text = self._commit(segs) + (" " if mode == LITERAL else "")
        # Only Dachen keys can be reread as Zhuyin ("Hello" or "C++" cannot).
        can_flip = mode == ZHUYIN or all(k == " " or bopomofo.is_zhuyin_key(k) for k in typed)
        self._last_commit = (typed, text, mode, context) if can_flip else None
        return text

    @property
    def flippable_text(self):
        """The text Tab would replace: the last commit, if nothing has been typed since. The
        shell checks that the app's text before the caret still ends with it, then calls
        flip_last_commit(); otherwise Tab goes through handle() as usual."""
        return self._last_commit[1] if self._last_commit else None

    def flip_last_commit(self):
        """Retypes the last commit in the other mode and learns the correction. Returns the
        text to put in place of flippable_text. Tab again flips it back."""
        if not self._last_commit or not self._last_commit[0]:
            return None
        keys, _, mode, context = self._last_commit
        self.reset()
        self.keys = list(keys)
        self._recent_text = context
        if mode == ZHUYIN:
            while self.keys and self.keys[-1] == " ":
                self.keys.pop()   # first-tone spaces aren't English
        self.forced_mode = LITERAL if mode == ZHUYIN else ZHUYIN
        self.forced_count = len(self.keys)
        return self._commit_flippable()

    def forget_last_commit(self):
        """A key the engine didn't see (the shell passed it on): no flip after it."""
        self._last_commit = None

    def _remember_picks(self, segs):
        """Candidates the user picked are remembered and come first next time."""
        for i, seg in enumerate(segs):
            picks = self.fixed.get(seg[0])
            if seg[2] != ZHUYIN or not picks:
                continue
            syl = self._convertible(seg, True)[0]
            for (a, b), text in picks.items():
                if b <= len(syl):
                    self.classifier.history.record(syl[a:b], text)

    def commit_all(self):
        self._last_commit = None
        return self._commit_punct() + (self._commit() if self.keys else "")

    def reset(self):
        self.keys = []
        self.inserting = []
        self.held = None
        self.backtick = False
        self.punct = None
        self.cursor = None
        self.forced_mode = None
        self.fixed = {}
        self.candidates = []
        self.symbol_table = False
