"""core.loading: the pickled cache of the parsed lexicon and English model."""
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from autozhuyin.core import bopomofo, loading  # noqa: E402
from autozhuyin.core.lexicon import Lexicon  # noqa: E402

DATA = os.path.join(os.path.dirname(HERE), "autozhuyin", "data")


class LoadingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="autozhuyin-cache-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_cache_matches_parsing_and_is_reused(self):
        cache = os.path.join(self.tmp, "cache")
        t1, t2 = {}, {}
        first = loading.load_lexicon(DATA, cache, t1)
        second = loading.load_lexicon(DATA, cache, t2)
        self.assertFalse(t1["lexicon"][1])
        self.assertTrue(t2["lexicon"][1])
        parsed = Lexicon.from_file(os.path.join(DATA, "lexicon.txt"))
        self.assertEqual(second.exact, parsed.exact)
        self.assertEqual(second.max_phrase_length, parsed.max_phrase_length)
        ni = [bopomofo.parse(list("su3")).syllables[0].syllable]
        self.assertEqual(second.entries(ni), first.entries(ni))
        en1 = loading.load_english(DATA, cache)
        timings = {}
        en2 = loading.load_english(DATA, cache, timings)
        self.assertTrue(timings["english"][1])
        for w in ("hello", "github", "xqzt"):
            self.assertEqual(en1.score(w, True), en2.score(w, True))

    def test_changed_source_rebuilds(self):
        data = os.path.join(self.tmp, "data")
        os.makedirs(data)
        path = os.path.join(data, "lexicon.txt")
        with open(path, "w", encoding="utf-8") as f:
            f.write("ㄋㄧˇ 你 -2\n")
        cache = os.path.join(self.tmp, "cache")
        loading.load_lexicon(data, cache)
        with open(path, "a", encoding="utf-8") as f:
            f.write("ㄋㄧˇ 妳 -3\n")
        timings = {}
        lex = loading.load_lexicon(data, cache, timings)
        self.assertFalse(timings["lexicon"][1])
        self.assertEqual([p for p, _ in lex.exact["ㄋㄧˇ"]], ["你", "妳"])

    def test_damaged_cache_is_ignored(self):
        cache = os.path.join(self.tmp, "cache")
        os.makedirs(cache)
        with open(os.path.join(cache, "lexicon.pickle"), "wb") as f:
            f.write(b"not a pickle")
        timings = {}
        lex = loading.load_lexicon(DATA, cache, timings)
        self.assertFalse(timings["lexicon"][1])
        self.assertTrue(lex.exact)
        loading.load_lexicon(DATA, cache, timings)
        self.assertTrue(timings["lexicon"][1])   # rewritten


if __name__ == "__main__":
    unittest.main()
