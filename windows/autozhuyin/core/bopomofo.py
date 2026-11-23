"""Dachen (大千) Zhuyin layout, syllable table and keystroke parser.

Python port of Sources/AutoZhuyinCore/{Bopomofo,SyllableTable,ZhuyinParser}.swift.
"""

INITIAL, MEDIAL, FINAL = 0, 1, 2

SYMBOLS = {
    "1": "ㄅ", "q": "ㄆ", "a": "ㄇ", "z": "ㄈ",
    "2": "ㄉ", "w": "ㄊ", "s": "ㄋ", "x": "ㄌ",
    "e": "ㄍ", "d": "ㄎ", "c": "ㄏ",
    "r": "ㄐ", "f": "ㄑ", "v": "ㄒ",
    "5": "ㄓ", "t": "ㄔ", "g": "ㄕ", "b": "ㄖ",
    "y": "ㄗ", "h": "ㄘ", "n": "ㄙ",
    "u": "ㄧ", "j": "ㄨ", "m": "ㄩ",
    "8": "ㄚ", "i": "ㄛ", "k": "ㄜ", ",": "ㄝ",
    "9": "ㄞ", "o": "ㄟ", "l": "ㄠ", ".": "ㄡ",
    "0": "ㄢ", "p": "ㄣ", ";": "ㄤ", "/": "ㄥ", "-": "ㄦ",
}

# Tone number by key; first tone is the space bar.
TONES = {" ": 1, "6": 2, "3": 3, "4": 4, "7": 5}
TONE_MARKS = {1: "", 2: "ˊ", 3: "ˇ", 4: "ˋ", 5: "˙"}

_INITIALS = set("ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ")
_MEDIALS = set("ㄧㄨㄩ")


def is_zhuyin_key(c):
    return c in SYMBOLS or c in TONES


def slot_of(symbol):
    if symbol in _INITIALS:
        return INITIAL
    if symbol in _MEDIALS:
        return MEDIAL
    return FINAL


class Syllable:
    __slots__ = ("slots", "tone")

    def __init__(self, slots=None, tone=None):
        self.slots = list(slots) if slots else [None, None, None]
        self.tone = tone

    def copy(self):
        return Syllable(self.slots, self.tone)

    @property
    def is_empty(self):
        return not any(self.slots)

    @property
    def toneless(self):
        return "".join(s for s in self.slots if s)

    @property
    def reading(self):
        return self.toneless + (TONE_MARKS[self.tone] if self.tone else "")

    def __eq__(self, other):
        return isinstance(other, Syllable) and self.slots == other.slots and self.tone == other.tone

    def __repr__(self):
        return "Syllable(%s)" % self.reading


# --- valid syllables ---------------------------------------------------------

_RAW = """
ㄚ ㄛ ㄜ ㄝ ㄞ ㄟ ㄠ ㄡ ㄢ ㄣ ㄤ ㄥ ㄦ
ㄧ ㄧㄚ ㄧㄛ ㄧㄝ ㄧㄞ ㄧㄠ ㄧㄡ ㄧㄢ ㄧㄣ ㄧㄤ ㄧㄥ
ㄨ ㄨㄚ ㄨㄛ ㄨㄞ ㄨㄟ ㄨㄢ ㄨㄣ ㄨㄤ ㄨㄥ
ㄩ ㄩㄝ ㄩㄢ ㄩㄣ ㄩㄥ
ㄅㄚ ㄅㄛ ㄅㄞ ㄅㄟ ㄅㄠ ㄅㄢ ㄅㄣ ㄅㄤ ㄅㄥ ㄅㄧ ㄅㄧㄝ ㄅㄧㄠ ㄅㄧㄢ ㄅㄧㄣ ㄅㄧㄥ ㄅㄨ
ㄆㄚ ㄆㄛ ㄆㄞ ㄆㄟ ㄆㄠ ㄆㄡ ㄆㄢ ㄆㄣ ㄆㄤ ㄆㄥ ㄆㄧ ㄆㄧㄝ ㄆㄧㄠ ㄆㄧㄢ ㄆㄧㄣ ㄆㄧㄥ ㄆㄨ
ㄇㄚ ㄇㄛ ㄇㄜ ㄇㄞ ㄇㄟ ㄇㄠ ㄇㄡ ㄇㄢ ㄇㄣ ㄇㄤ ㄇㄥ ㄇㄧ ㄇㄧㄝ ㄇㄧㄠ ㄇㄧㄡ ㄇㄧㄢ ㄇㄧㄣ ㄇㄧㄥ ㄇㄨ
ㄈㄚ ㄈㄛ ㄈㄟ ㄈㄡ ㄈㄢ ㄈㄣ ㄈㄤ ㄈㄥ ㄈㄨ
ㄉㄚ ㄉㄜ ㄉㄞ ㄉㄟ ㄉㄠ ㄉㄡ ㄉㄢ ㄉㄣ ㄉㄤ ㄉㄥ ㄉㄧ ㄉㄧㄚ ㄉㄧㄝ ㄉㄧㄠ ㄉㄧㄡ ㄉㄧㄢ ㄉㄧㄥ ㄉㄨ ㄉㄨㄛ ㄉㄨㄟ ㄉㄨㄢ ㄉㄨㄣ ㄉㄨㄥ
ㄊㄚ ㄊㄜ ㄊㄞ ㄊㄠ ㄊㄡ ㄊㄢ ㄊㄤ ㄊㄥ ㄊㄧ ㄊㄧㄝ ㄊㄧㄠ ㄊㄧㄢ ㄊㄧㄥ ㄊㄨ ㄊㄨㄛ ㄊㄨㄟ ㄊㄨㄢ ㄊㄨㄣ ㄊㄨㄥ
ㄋㄚ ㄋㄜ ㄋㄞ ㄋㄟ ㄋㄠ ㄋㄡ ㄋㄢ ㄋㄣ ㄋㄤ ㄋㄥ ㄋㄧ ㄋㄧㄝ ㄋㄧㄠ ㄋㄧㄡ ㄋㄧㄢ ㄋㄧㄣ ㄋㄧㄤ ㄋㄧㄥ ㄋㄨ ㄋㄨㄛ ㄋㄨㄢ ㄋㄨㄥ ㄋㄩ ㄋㄩㄝ
ㄌㄚ ㄌㄛ ㄌㄜ ㄌㄞ ㄌㄟ ㄌㄠ ㄌㄡ ㄌㄢ ㄌㄤ ㄌㄥ ㄌㄧ ㄌㄧㄚ ㄌㄧㄝ ㄌㄧㄠ ㄌㄧㄡ ㄌㄧㄢ ㄌㄧㄣ ㄌㄧㄤ ㄌㄧㄥ ㄌㄨ ㄌㄨㄛ ㄌㄨㄢ ㄌㄨㄣ ㄌㄨㄥ ㄌㄩ ㄌㄩㄝ ㄌㄩㄢ
ㄍㄚ ㄍㄜ ㄍㄞ ㄍㄟ ㄍㄠ ㄍㄡ ㄍㄢ ㄍㄣ ㄍㄤ ㄍㄥ ㄍㄨ ㄍㄨㄚ ㄍㄨㄛ ㄍㄨㄞ ㄍㄨㄟ ㄍㄨㄢ ㄍㄨㄣ ㄍㄨㄤ ㄍㄨㄥ
ㄎㄚ ㄎㄜ ㄎㄞ ㄎㄟ ㄎㄠ ㄎㄡ ㄎㄢ ㄎㄣ ㄎㄤ ㄎㄥ ㄎㄨ ㄎㄨㄚ ㄎㄨㄛ ㄎㄨㄞ ㄎㄨㄟ ㄎㄨㄢ ㄎㄨㄣ ㄎㄨㄤ ㄎㄨㄥ
ㄏㄚ ㄏㄜ ㄏㄞ ㄏㄟ ㄏㄠ ㄏㄡ ㄏㄢ ㄏㄣ ㄏㄤ ㄏㄥ ㄏㄨ ㄏㄨㄚ ㄏㄨㄛ ㄏㄨㄞ ㄏㄨㄟ ㄏㄨㄢ ㄏㄨㄣ ㄏㄨㄤ ㄏㄨㄥ
ㄐㄧ ㄐㄧㄚ ㄐㄧㄝ ㄐㄧㄠ ㄐㄧㄡ ㄐㄧㄢ ㄐㄧㄣ ㄐㄧㄤ ㄐㄧㄥ ㄐㄩ ㄐㄩㄝ ㄐㄩㄢ ㄐㄩㄣ ㄐㄩㄥ
ㄑㄧ ㄑㄧㄚ ㄑㄧㄝ ㄑㄧㄠ ㄑㄧㄡ ㄑㄧㄢ ㄑㄧㄣ ㄑㄧㄤ ㄑㄧㄥ ㄑㄩ ㄑㄩㄝ ㄑㄩㄢ ㄑㄩㄣ ㄑㄩㄥ
ㄒㄧ ㄒㄧㄚ ㄒㄧㄝ ㄒㄧㄠ ㄒㄧㄡ ㄒㄧㄢ ㄒㄧㄣ ㄒㄧㄤ ㄒㄧㄥ ㄒㄩ ㄒㄩㄝ ㄒㄩㄢ ㄒㄩㄣ ㄒㄩㄥ
ㄓ ㄓㄚ ㄓㄜ ㄓㄞ ㄓㄟ ㄓㄠ ㄓㄡ ㄓㄢ ㄓㄣ ㄓㄤ ㄓㄥ ㄓㄨ ㄓㄨㄚ ㄓㄨㄛ ㄓㄨㄞ ㄓㄨㄟ ㄓㄨㄢ ㄓㄨㄣ ㄓㄨㄤ ㄓㄨㄥ
ㄔ ㄔㄚ ㄔㄜ ㄔㄞ ㄔㄠ ㄔㄡ ㄔㄢ ㄔㄣ ㄔㄤ ㄔㄥ ㄔㄨ ㄔㄨㄚ ㄔㄨㄛ ㄔㄨㄞ ㄔㄨㄟ ㄔㄨㄢ ㄔㄨㄣ ㄔㄨㄤ ㄔㄨㄥ
ㄕ ㄕㄚ ㄕㄜ ㄕㄞ ㄕㄟ ㄕㄠ ㄕㄡ ㄕㄢ ㄕㄣ ㄕㄤ ㄕㄥ ㄕㄨ ㄕㄨㄚ ㄕㄨㄛ ㄕㄨㄞ ㄕㄨㄟ ㄕㄨㄢ ㄕㄨㄣ ㄕㄨㄤ
ㄖ ㄖㄜ ㄖㄠ ㄖㄡ ㄖㄢ ㄖㄣ ㄖㄤ ㄖㄥ ㄖㄨ ㄖㄨㄛ ㄖㄨㄟ ㄖㄨㄢ ㄖㄨㄣ ㄖㄨㄥ
ㄗ ㄗㄚ ㄗㄜ ㄗㄞ ㄗㄟ ㄗㄠ ㄗㄡ ㄗㄢ ㄗㄣ ㄗㄤ ㄗㄥ ㄗㄨ ㄗㄨㄛ ㄗㄨㄟ ㄗㄨㄢ ㄗㄨㄣ ㄗㄨㄥ
ㄘ ㄘㄚ ㄘㄜ ㄘㄞ ㄘㄠ ㄘㄡ ㄘㄢ ㄘㄣ ㄘㄤ ㄘㄥ ㄘㄨ ㄘㄨㄛ ㄘㄨㄟ ㄘㄨㄢ ㄘㄨㄣ ㄘㄨㄥ
ㄙ ㄙㄚ ㄙㄜ ㄙㄞ ㄙㄠ ㄙㄡ ㄙㄢ ㄙㄣ ㄙㄤ ㄙㄥ ㄙㄨ ㄙㄨㄛ ㄙㄨㄟ ㄙㄨㄢ ㄙㄨㄣ ㄙㄨㄥ
"""

VALID = set(_RAW.split())
VALID_PREFIXES = {syl[:n] for syl in VALID for n in range(1, len(syl) + 1)}


def _patterns():
    out = set()
    for syl in VALID:
        slots = [None, None, None]
        for ch in syl:
            slots[slot_of(ch)] = ch
        for mask in range(8):
            out.add("".join((slots[i] or "_") if mask & (1 << i) else "_" for i in range(3)))
    return out


_COMPATIBLE = _patterns()


def is_valid(syl):
    return syl.toneless in VALID


def is_valid_prefix(syl):
    return syl.is_empty or syl.toneless in VALID_PREFIXES


def is_compatible(syl):
    """True if some valid syllable has these slots (used for out-of-order typing)."""
    return "".join(s or "_" for s in syl.slots) in _COMPATIBLE


# --- parser ------------------------------------------------------------------

class ParsedSyllable:
    __slots__ = ("syllable", "start", "end", "reordered")

    def __init__(self, syllable, start, end, reordered=False):
        self.syllable = syllable
        self.start = start
        self.end = end
        self.reordered = reordered

    @property
    def toned(self):
        return self.syllable.tone is not None


class ZhuyinParse:
    def __init__(self):
        self.syllables = []
        self.stray_tones = 0
        self.foreign_keys = 0

    @property
    def pending(self):
        if self.syllables and not self.syllables[-1].toned:
            return self.syllables[-1]
        return None

    @property
    def completed(self):
        return self.syllables if self.pending is None else self.syllables[:-1]


def parse(keys, strict=False):
    """Splits keystrokes into syllables (Dachen rules, out-of-order symbols merged). `strict`:
    every syllable gets its tone (要打聲調才出字), so symbols typed over an untoned syllable
    are a correction even when they read alone (ㄒㄧㄥ then ㄩˊ is ㄒㄩㄥˊ, not ㄒㄧㄥ + ㄩˊ)."""
    result = ZhuyinParse()
    current = Syllable()
    start = 0
    reordered = False

    def close(end):
        nonlocal current, start, reordered
        if not current.is_empty:
            result.syllables.append(ParsedSyllable(current, start, end, reordered))
        current = Syllable()
        start = end
        reordered = False

    for i, key in enumerate(keys):
        if key in TONES:
            if current.is_empty:
                result.stray_tones += 1
                start = i + 1
            else:
                prev = result.syllables[-1] if result.syllables else None
                if prev is not None and prev.end == start and not prev.toned and (strict or not is_valid(current)):
                    # Typed over the untoned syllable before it to fix a typo: ㄌㄨㄥ then ㄏ
                    # and a tone is ㄏㄨㄥ, not ㄌㄨㄥ + ㄏ (which is no syllable).
                    merged = prev.syllable.copy()
                    for s, symbol in enumerate(current.slots):
                        if symbol:
                            merged.slots[s] = symbol
                    if is_valid(merged):
                        result.syllables.pop()
                        current, start, reordered = merged, prev.start, True
                current.tone = TONES[key]
                close(i + 1)
        elif key in SYMBOLS:
            symbol = SYMBOLS[key]
            slot = slot_of(symbol)
            later_filled = any(current.slots[s] for s in range(slot + 1, 3))
            if current.slots[slot]:
                close(i)
            elif later_filled:
                merged = current.copy()
                merged.slots[slot] = symbol
                if is_compatible(merged):
                    reordered = True
                else:
                    close(i)
            if current.is_empty:
                start = i
            current.slots[slot] = symbol
        else:
            close(i)
            result.foreign_keys += 1
            start = i + 1
    close(len(keys))
    return result
