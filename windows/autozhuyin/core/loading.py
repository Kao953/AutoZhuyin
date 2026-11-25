"""Loads the built-in data (lexicon, English model) fast.

Parsing lexicon.txt (≈170k lines) and english-dict.txt in Python takes a second or more
on a cold Windows start, and it used to run while the app was waiting for the input
method to switch on. The parsed result is kept as a pickle in the user's folder and
reused while the source files are unchanged (same size and date), which is several times
faster. Any problem with the cache just falls back to parsing.
"""
import gc
import os
import pickle
import time

from .english import EnglishModel
from .lexicon import Lexicon

# Bump when the cached state's shape changes.
CACHE_FORMAT = 1


class _GCPaused:
    """Building ~1M small objects triggers many useless GC passes; pause the collector."""

    def __enter__(self):
        self.was = gc.isenabled()
        gc.disable()

    def __exit__(self, *exc):
        if self.was:
            gc.enable()


def _stamp(paths):
    out = []
    for p in paths:
        try:
            st = os.stat(p)
            out.append((os.path.basename(p), st.st_size, st.st_mtime_ns))
        except OSError:
            out.append((os.path.basename(p), None, None))
    return (CACHE_FORMAT, tuple(out))


def cached(cache_path, sources, build):
    """build() → picklable state, reused from cache_path while `sources` are unchanged.
    Returns (state, True if it came from the cache)."""
    stamp = _stamp(sources)
    if cache_path:
        try:
            with open(cache_path, "rb") as f, _GCPaused():
                saved, state = pickle.load(f)
            if saved == stamp:
                return state, True
        except Exception:   # noqa: BLE001 — missing, old or damaged cache: rebuild it
            pass
    with _GCPaused():
        state = build()
    if cache_path:
        tmp = cache_path + ".tmp%d" % os.getpid()
        try:
            os.makedirs(os.path.dirname(cache_path), exist_ok=True)
            with open(tmp, "wb") as f:
                pickle.dump((stamp, state), f, protocol=4)
            os.replace(tmp, cache_path)
        except OSError:
            try:
                os.remove(tmp)
            except OSError:
                pass
    return state, False


def load_lexicon(data_dir, cache_dir=None, timings=None):
    path = os.path.join(data_dir, "lexicon.txt")
    start = time.perf_counter()
    state, hit = cached(cache_dir and os.path.join(cache_dir, "lexicon.pickle"), [path],
                        lambda: Lexicon.from_file(path).state())
    lexicon = Lexicon.from_state(state)
    lexicon.load_emoji(os.path.join(data_dir, "emoji.txt"))
    if timings is not None:
        timings["lexicon"] = (time.perf_counter() - start, hit)
    return lexicon


def load_english(data_dir, cache_dir=None, timings=None):
    paths = [os.path.join(data_dir, name)
             for name in ("english-common.txt", "english-dict.txt", "english-bigram.json")]
    start = time.perf_counter()
    state, hit = cached(cache_dir and os.path.join(cache_dir, "english.pickle"), paths,
                        lambda: EnglishModel.from_files(*paths).state())
    english = EnglishModel.from_state(state)
    if timings is not None:
        timings["english"] = (time.perf_counter() - start, hit)
    return english


def freeze_gc():
    """Moves everything loaded so far out of the collector's reach (Python 3.7+), so the
    big lexicon isn't rescanned by full GC passes while the user types."""
    gc.collect()
    if hasattr(gc, "freeze"):
        gc.freeze()


def log_timings(log_path, timings, limit=16384):
    """Appends one line like "2026-11-22 09:30:01 lexicon 0.12s (cache) english 0.03s (cache)"."""
    parts = []
    for name, value in timings.items():
        if isinstance(value, tuple):
            seconds, hit = value
            parts.append("%s %.2fs%s" % (name, seconds, " (cache)" if hit else ""))
        else:
            parts.append("%s %.2fs" % (name, value))
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + " ".join(parts) + "\n"
    try:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        if os.path.exists(log_path) and os.path.getsize(log_path) > limit:
            with open(log_path, encoding="utf-8", errors="replace") as f:
                keep = f.readlines()[-20:]
            with open(log_path, "w", encoding="utf-8") as f:
                f.writelines(keep)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(line)
    except OSError:
        pass
