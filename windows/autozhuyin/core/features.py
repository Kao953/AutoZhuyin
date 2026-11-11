"""Segment features for the Zhuyin / literal classifier.

A segment's score in each mode is the dot product of its feature dict with a weight
dict. DEFAULT_WEIGHTS reproduces the original hand-tuned scores; trained weights
(training/train.py → Resources/classifier-weights.json) replace them.

Swift port: Sources/AutoZhuyinCore/Features.swift. Both must produce identical
features; Tests/.../ParityTests checks this against training/parity-fixtures.json.
"""
from . import bopomofo

DEFAULT_WEIGHTS = {
    # Zhuyin
    "zh.bias": 0.5,
    "zh.stray": -5.0,
    "zh.reordered": -0.5,
    "zh.toned_valid_lex": 2.8,
    "zh.toned_valid_nolex": 0.5,
    "zh.toned_invalid": -5.0,
    "zh.pending_prefix": 0.0,
    "zh.pending_invalid": -5.0,
    "zh.untoned_mid_valid": -2.5,
    "zh.untoned_mid_invalid": -5.0,
    "zh.unconfirmed": -2.0,
    "zh.lexscore": 0.0,
    "zh.phrase": 0.0,
    # Literal
    "lit.bias": 0.0,
    "lit.upper": 20.0,
    "lit.num_digits": 0.8,
    "lit.num_others": -1.0,
    "lit.common": 3.0,
    "lit.common_len": 1.0,
    "lit.dict": 1.0,
    "lit.dict_len": 0.6,
    "lit.prefix_common_len": 0.4,
    "lit.prefix_dict_len": 0.2,
    "lit.unknown_score": 1.0,
    "lit.short": 0.0,
    "lit.digits": -1.5,
    "lit.others": -1.5,
    # Segmentation
    "seg.switch": -3.0,
}


def dot(weights, feats):
    return sum(weights.get(k, 0.0) * v for k, v in feats.items())


def _add(f, k, v=1.0):
    f[k] = f.get(k, 0.0) + v


def zhuyin_features(keys, lexicon, is_last=True, after_other=False, finishing=False):
    """Features of `keys` read as Zhuyin, or None if impossible."""
    parse = bopomofo.parse(keys)
    if not is_last and parse.pending is not None:
        return None   # a Zhuyin segment followed by another must end with a tone
    # Pressing space finishes an untoned last syllable as first tone; after a toned
    # syllable it just commits, so it must not count as an extra (stray) tone.
    scored = bopomofo.parse(keys + [" "]) if finishing and is_last and parse.pending is not None else parse
    if scored.foreign_keys > 0 or not scored.syllables:
        return None
    f = {"zh.bias": 1.0}
    if scored.stray_tones:
        _add(f, "zh.stray", scored.stray_tones)
    last = len(scored.syllables) - 1
    toned_run = []
    for i, ps in enumerate(scored.syllables):
        if ps.reordered:
            _add(f, "zh.reordered")
        valid = bopomofo.is_valid(ps.syllable)
        if ps.toned:
            if valid:
                best = lexicon.best_score(ps.syllable)
                if best is not None:
                    _add(f, "zh.toned_valid_lex")
                    _add(f, "zh.lexscore", best + 4.0)
                else:
                    _add(f, "zh.toned_valid_nolex")
                toned_run.append(ps.syllable)
            else:
                _add(f, "zh.toned_invalid")
        elif i == last:
            _add(f, "zh.pending_prefix" if bopomofo.is_valid_prefix(ps.syllable) else "zh.pending_invalid")
        else:
            _add(f, "zh.untoned_mid_valid" if valid else "zh.untoned_mid_invalid")
    # Syllables covered by a multi-syllable lexicon phrase (real Chinese forms words).
    covered = [False] * len(toned_run)
    for i in range(len(toned_run)):
        for n in (2, 3, 4):
            if i + n <= len(toned_run) and lexicon.entries(toned_run[i:i + n]):
                for k in range(i, i + n):
                    covered[k] = True
    if any(covered):
        _add(f, "zh.phrase", sum(covered))
    if is_last and after_other and not finishing and not any(ps.toned for ps in parse.syllables):
        _add(f, "zh.unconfirmed")
    if after_other:
        _add(f, "seg.switch")
    return f


def literal_features(keys, english, is_last=True, after_other=False, finishing=False):
    """Features of `keys` output as typed, or None if impossible."""
    if not keys or " " in keys:
        return None
    complete = (not is_last) or finishing
    f = {"lit.bias": 1.0}
    if after_other:
        _add(f, "seg.switch")
    if any(c.isupper() for c in keys):
        _add(f, "lit.upper")
    letters = "".join(c for c in keys if c.isalpha())
    digits = sum(1 for c in keys if c.isdigit())
    others = len(keys) - len(letters) - digits
    if not letters:
        if digits:
            _add(f, "lit.num_digits", digits)
        if others:
            _add(f, "lit.num_others", others)
        return f
    for k, v in english.word_features(letters, complete or digits > 0).items():
        _add(f, k, v)
    if digits:
        _add(f, "lit.digits", digits)
    non_apostrophe = others - keys.count("'")
    if non_apostrophe:
        _add(f, "lit.others", non_apostrophe)
    return f
