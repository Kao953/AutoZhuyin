"""The user-phrases.txt file. Port of UserPhrases.swift: entries in lexicon format
("ㄗˋ-ㄉㄨㄥˋ-ㄓㄨˋ-ㄧㄣ 自動注音 -1"), other lines (comments, blank lines) kept as they are."""
from . import bopomofo
from .lexicon import _is_bopomofo

# Score for phrases added in the editor: high enough to beat the built-in phrases with
# the same reading (log10 probability; common words are around -3).
DEFAULT_SCORE = -1.0

# Bopomofo symbol or tone mark -> its Dachen key.
_DACHEN_KEY = {symbol: key for key, symbol in bopomofo.SYMBOLS.items()}
_DACHEN_KEY.update({bopomofo.TONE_MARKS[t]: k for k, t in bopomofo.TONES.items() if t != 1})


class Entry:
    __slots__ = ("phrase", "reading", "score")

    def __init__(self, phrase, reading, score=DEFAULT_SCORE):
        self.phrase, self.reading, self.score = phrase, reading, score

    def __eq__(self, other):
        return isinstance(other, Entry) and (self.phrase, self.reading, self.score) == \
            (other.phrase, other.reading, other.score)

    def __repr__(self):
        return "Entry(%r, %r, %r)" % (self.phrase, self.reading, self.score)


def parse_entry(line):
    """One lexicon line: reading and phrase in either order, then an optional score."""
    fields = line.split()
    if len(fields) < 2 or fields[0].startswith("#"):
        return None
    reading, phrase = (fields[0], fields[1]) if _is_bopomofo(fields[0]) else (fields[1], fields[0])
    if not _is_bopomofo(reading):
        return None
    score = None
    if len(fields) >= 3:
        try:
            score = float(fields[2])
        except ValueError:
            return None
    return Entry(phrase, reading, score)


def _format(score):
    return str(int(score)) if score == int(score) else str(score)


class UserPhrases:
    def __init__(self, text=""):
        self.lines = [parse_entry(line) or line for line in text.split("\n")]
        if self.lines and self.lines[-1] == "":
            self.lines.pop()   # the final newline

    @property
    def text(self):
        out = []
        for line in self.lines:
            if isinstance(line, Entry):
                score = "" if line.score is None else " " + _format(line.score)
                out.append("%s %s%s" % (line.reading, line.phrase, score))
            else:
                out.append(line)
        return "\n".join(out) + ("\n" if out else "")

    @property
    def entries(self):
        return [line for line in self.lines if isinstance(line, Entry)]

    def append(self, entry):
        self.lines.append(entry)

    def _line_index(self, index):
        n = -1
        for i, line in enumerate(self.lines):
            if isinstance(line, Entry):
                n += 1
                if n == index:
                    return i
        return None

    def replace(self, index, entry):
        i = self._line_index(index)
        if i is not None:
            self.lines[i] = entry

    def remove(self, index):
        i = self._line_index(index)
        if i is not None:
            del self.lines[i]


def reading_from_typed(typed):
    """The lexicon reading for what was typed: Bopomofo ("ㄗˋ ㄉㄨㄥˋ", "ㄗˋㄉㄨㄥˋ",
    "ㄗˋ-ㄉㄨㄥˋ") or Dachen keys ("y42j/4"). A space or "-" ends a first-tone syllable.
    None if it doesn't read as valid syllables."""
    keys = []
    for c in typed.strip():
        if c in "- 　":
            keys.append(" ")
        elif c in _DACHEN_KEY:
            keys.append(_DACHEN_KEY[c])
        else:
            keys.append(c.lower())
    p = bopomofo.parse(keys)
    if p.foreign_keys or not p.syllables or not all(bopomofo.is_valid(s.syllable) for s in p.syllables):
        return None
    return "-".join(s.syllable.reading for s in p.syllables)


def problem(phrase, reading):
    """Why the entry can't be saved, or None if it is fine."""
    if not phrase:
        return "請輸入詞"
    if any(c.isspace() for c in phrase):
        return "詞裡不能有空白"
    if not reading:
        return "請輸入注音"
    n = len(reading.split("-"))
    if n != len(phrase):
        return "注音有 %d 個音節，詞有 %d 個字" % (n, len(phrase))
    return None


def bad_lines(text):
    """Line numbers (1-based) of lines that are neither entries, comments nor blank, or
    whose reading doesn't match the phrase: shown after the file is edited by hand."""
    out = []
    for n, line in enumerate(text.split("\n"), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        e = parse_entry(stripped)
        if e is None or problem(e.phrase, e.reading):
            out.append(n)
    return out


TEMPLATE = """# 自動注音 自訂詞：一行一個詞，格式是「注音 詞 分數」，例如：
#   ㄗˋ-ㄉㄨㄥˋ-ㄓㄨˋ-ㄧㄣ 自動注音 -1
# 注音的音節用 - 隔開，一聲不用標；分數越大越優先（-1 會排在同讀音的內建詞前面）。
# 存檔後下次切換到輸入法時就會生效。# 開頭的行是註解。
"""


class UserPhrasesFile:
    """Keeps a lexicon's user phrases in step with user-phrases.txt."""

    def __init__(self, path, lexicon):
        self.path = path
        self.lexicon = lexicon
        self._mtime = None

    def _current_mtime(self):
        import os
        try:
            return os.path.getmtime(self.path)
        except OSError:
            return None

    def reload_if_changed(self):
        """Reloads the file if its date changed. Returns the bad line numbers when it was
        reloaded (possibly []), None when nothing changed."""
        mtime = self._current_mtime()
        if mtime == self._mtime:
            return None
        self._mtime = mtime
        try:
            with open(self.path, encoding="utf-8-sig") as f:
                text = f.read()
        except OSError:
            text = ""
        self.lexicon.set_user_phrases(text)
        return bad_lines(text)

    def ensure_exists(self):
        """Creates the file with an explanatory header (for editing it by hand)."""
        import os
        if not os.path.exists(self.path):
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            with open(self.path, "w", encoding="utf-8") as f:
                f.write(TEMPLATE)
        return self.path
