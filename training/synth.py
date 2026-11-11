"""Synthetic typing data for the Zhuyin / literal classifier.

Each example is what sits in the input buffer when the user commits it, with the
intended mode of every key:
    {"keys": "ji3hello", "labels": "zzzlllll", "finishing": True, "kind": "zh+en"}
labels: "z" = Zhuyin, "l" = literal.  finishing: committed with space (True) or Enter.

Chinese comes from lexicon phrases sampled by frequency and converted to Dachen keys;
English from the common-word list and the dictionary. Real typing commits English at
a space, so a buffer holds at most one English word next to Chinese.
"""
import random

from common import core

bopomofo = core.bopomofo

KEY_OF = {sym: key for key, sym in bopomofo.SYMBOLS.items()}
TONE_KEY = {"ˊ": "6", "ˇ": "3", "ˋ": "4", "˙": "7"}


def reading_to_keys(reading):
    """'ㄋㄧˇ-ㄏㄠˇ' -> 'su3cl3'; first tone -> space. None if not typeable."""
    out = []
    for syl in reading.split("-"):
        tone = " "
        if syl and syl[-1] in TONE_KEY:
            tone = TONE_KEY[syl[-1]]
            syl = syl[:-1]
        if not syl or syl not in bopomofo.VALID:
            return None
        out.append("".join(KEY_OF[c] for c in syl) + tone)
    return "".join(out)


def _is_cjk(s):
    return all(0x4E00 <= ord(c) <= 0x9FFF for c in s)


class Generator:
    def __init__(self, lexicon_path, common_path, dict_path, seed=0):
        self.rng = random.Random(seed)
        phrases, weights = [], []
        with open(lexicon_path, encoding="utf-8") as f:
            for line in f:
                cols = line.split()
                if len(cols) != 3 or line.startswith("#") or not _is_cjk(cols[1]):
                    continue
                n = cols[0].count("-") + 1
                if n > 4:
                    continue
                keys = reading_to_keys(cols[0])
                if keys is None:
                    continue
                phrases.append((cols[1], keys))
                weights.append(10 ** (float(cols[2]) * 0.6))   # tempered frequency
        self.phrases = phrases
        self.phrase_cum = _cumulative(weights)
        self.common = [w.strip() for w in open(common_path, encoding="utf-8")
                       if w.strip() and not w.startswith("#")]
        self.dict_words = [w.strip() for w in open(dict_path, encoding="utf-8")
                           if 3 <= len(w.strip()) <= 9]

    # --- pieces ---

    def chinese(self):
        n = self.rng.choice([1, 1, 2, 2, 3])
        picked = self.rng.choices(self.phrases, cum_weights=self.phrase_cum, k=n)
        return "".join(keys for _, keys in picked)

    def english(self):
        w = self.rng.choice(self.common) if self.rng.random() < 0.75 else self.rng.choice(self.dict_words)
        if self.rng.random() < 0.1:
            w = w[:1].upper() + w[1:]
        return w

    def number(self):
        r = self.rng.random()
        if r < 0.4:
            return str(self.rng.randint(0, 9999))
        if r < 0.7:
            return str(self.rng.choice([2023, 2024, 2025, 2026, 100, 50, 10, 30]))
        return "%d.%d" % (self.rng.randint(0, 99), self.rng.randint(0, 9))

    # --- examples ---

    def example(self):
        r = self.rng.random()
        if r < 0.40:
            parts, kind = [("z", self.chinese())], "zh"
        elif r < 0.65:
            parts, kind = [("l", self.english())], "en"
        elif r < 0.80:
            parts, kind = [("z", self.chinese()), ("l", self.english())], "zh+en"
        elif r < 0.93:
            parts, kind = [("l", self.english()), ("z", self.chinese())], "en+zh"
        elif r < 0.96:
            parts, kind = [("z", self.chinese()), ("l", self.english()), ("z", self.chinese())], "zh+en+zh"
        else:
            parts, kind = [("l", self.number())], "num"
        keys = "".join(p for _, p in parts)
        labels = "".join(m * len(p) for m, p in parts)
        if parts[-1][0] == "l":
            finishing = True     # English / numbers end with a space
        else:
            # Chinese ends with Enter, or space after a finished (toned) syllable.
            finishing = keys[-1] != " " and self.rng.random() < 0.5
        return {"keys": keys, "labels": labels, "finishing": finishing, "kind": kind}

    def prefix_of(self, ex):
        """The buffer while still typing: a random cut, not finishing."""
        cut = self.rng.randint(1, len(ex["keys"]) - 1) if len(ex["keys"]) > 1 else 1
        return {"keys": ex["keys"][:cut], "labels": ex["labels"][:cut], "finishing": False,
                "kind": ex["kind"] + "/prefix"}


def _cumulative(ws):
    out, t = [], 0.0
    for w in ws:
        t += w
        out.append(t)
    return out


def gold_segments(labels):
    """'zzzlll' -> [(0, 3, 'zhuyin'), (3, 6, 'literal')]"""
    segs, start = [], 0
    for i in range(1, len(labels) + 1):
        if i == len(labels) or labels[i] != labels[start]:
            segs.append((start, i, core.ZHUYIN if labels[start] == "z" else core.LITERAL))
            start = i
    return segs
