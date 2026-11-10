"""Tests for the Python core (mirror of the Swift tests). Run from windows/:
    python3 tools/build_data.py && python3 -m unittest discover tests
"""
import os
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from autozhuyin.core import bopomofo  # noqa: E402
from autozhuyin.core.classifier import LITERAL, ZHUYIN, Classifier, LearnedPreferences  # noqa: E402
from autozhuyin.core.engine import DOWN, ENTER, TAB, CompositionEngine  # noqa: E402
from autozhuyin.core.english import EnglishModel  # noqa: E402
from autozhuyin.core.lexicon import Converter, Lexicon  # noqa: E402

DATA = os.path.join(os.path.dirname(HERE), "autozhuyin", "data")
_start = time.time()
LEX = Lexicon.from_file(os.path.join(DATA, "lexicon.txt"))
ENG = EnglishModel.from_files(os.path.join(DATA, "english-common.txt"),
                              os.path.join(DATA, "english-dict.txt"),
                              os.path.join(DATA, "english-bigram.json"))
LOAD_TIME = time.time() - _start


def readings(keys):
    return [s.syllable.reading for s in bopomofo.parse(list(keys)).syllables]


def convert(keys):
    syl = [s.syllable for s in bopomofo.parse(list(keys)).syllables]
    return "".join(t for _, t in Converter(LEX).convert(syl))


def make_engine():
    return CompositionEngine(Classifier(LEX, ENG))


def type_keys(s, e):
    out = ""
    for c in s:
        key = ENTER if c == "\n" else TAB if c == "\t" else c
        handled, commit = e.handle(key)
        if commit is not None:
            out += commit
        elif not handled:
            out += c
    return out


class ParserTests(unittest.TestCase):
    def test_ni_hao(self):
        self.assertEqual(readings("su3cl3"), ["ㄋㄧˇ", "ㄏㄠˇ"])

    def test_space_is_first_tone(self):
        self.assertEqual(readings("wu0 "), ["ㄊㄧㄢ"])

    def test_pending(self):
        p = bopomofo.parse(list("su3c"))
        self.assertEqual(len(p.completed), 1)
        self.assertEqual(p.pending.syllable.reading, "ㄏ")

    def test_out_of_order(self):
        for keys in ("uvl3", "vlu3", "ulv3"):
            p = bopomofo.parse(list(keys))
            self.assertEqual([s.syllable.reading for s in p.syllables], ["ㄒㄧㄠˇ"], keys)
            self.assertTrue(p.syllables[0].reordered)
        self.assertFalse(bopomofo.parse(list("vul3")).syllables[0].reordered)
        self.assertEqual(len(bopomofo.parse(list("me")).syllables), 2)


class ConverterTests(unittest.TestCase):
    def test_phrase(self):
        self.assertEqual(convert("su3cl3"), "你好")

    def test_sentence(self):
        self.assertEqual(convert("rup wu0 wu0 fu4cp3cl3"), "今天天氣很好")

    def test_tone_omission(self):
        self.assertEqual(convert("jiap7"), "我們")

    def test_load_time(self):
        print("\nlexicon + english load: %.2fs" % LOAD_TIME)
        self.assertLess(LOAD_TIME, 5)


class ClassifierTests(unittest.TestCase):
    c = Classifier(LEX, ENG)

    def test_zhuyin(self):
        for s in ["su3cl3", "ji3", "cl3", "ru ", "u ", "fu ", "183", "2k7", "5j/ "]:
            self.assertEqual(self.c.mode(list(s)), ZHUYIN, s)
        for s in ["ru", "ji", "fu"]:
            self.assertEqual(self.c.mode(list(s), finishing=True), ZHUYIN, s)

    def test_english(self):
        for s in ["hello", "the", "is", "ok", "github", "Swift", "2024", "so", "go", "me",
                  "no", "a", "an", "up", "i", "meeting", "email", "push"]:
            self.assertEqual(self.c.mode(list(s), finishing=True), LITERAL, s)

    def test_learning(self):
        learned = LearnedPreferences()
        c = Classifier(LEX, ENG, learned)
        self.assertEqual(c.mode(list("so"), finishing=True), LITERAL)
        learned.record("so", ZHUYIN)
        self.assertEqual(c.mode(list("so"), finishing=True), ZHUYIN)


class EngineTests(unittest.TestCase):
    def test_mixed_sentence(self):
        self.assertEqual(type_keys("ji3 hello world su3cl3 ", make_engine()), "我hello world 你好")

    def test_marked_text(self):
        e = make_engine()
        type_keys("su3c", e)
        self.assertEqual(e.marked_text, "你ㄏ")
        type_keys("l3", e)
        self.assertEqual(e.marked_text, "你好")

    def test_enter_commits_english(self):
        self.assertEqual(type_keys("github\n", make_engine()), "github")

    def test_tab_learns(self):
        e = make_engine()
        type_keys("so", e)
        self.assertEqual(e.mode, LITERAL)
        e.handle(TAB)
        self.assertEqual(e.mode, ZHUYIN)
        type_keys("\n", e)
        self.assertEqual(e.classifier.learned.weights["so"], 1)

    def test_punctuation(self):
        self.assertEqual(type_keys("hello, ", make_engine()), "hello, ")
        self.assertEqual(type_keys("su3cl3?", make_engine()), "你好？")

    def test_candidates(self):
        e = make_engine()
        type_keys("su3", e)
        e.handle(DOWN)
        self.assertTrue(e.showing_candidates)
        idx = [t for _, t in e.candidates].index("妳")
        e.select_candidate(idx)
        self.assertEqual(type_keys("\n", e), "妳")

    def test_digit_initials(self):
        e = make_engine()
        type_keys("2;3", e)
        self.assertEqual(len(e.marked_text), 1)
        self.assertEqual(type_keys("2j/ \n", make_engine()), "東")
        self.assertEqual(type_keys("2.5\n", make_engine()), "2.5")

    def test_out_of_order_converts(self):
        self.assertEqual(type_keys("uvl3\n", make_engine()), "小")


class MixedSegmentTests(unittest.TestCase):
    def run_keys(self, s):
        e = make_engine()
        return type_keys(s, e), e.marked_text

    def test_chinese_then_english(self):
        self.assertEqual(self.run_keys("ji3hello ")[0], "我hello ")
        self.assertEqual(self.run_keys("su3cl3github\n")[0], "你好github")
        self.assertEqual(self.run_keys("ji3hel")[1], "我hel")

    def test_english_then_chinese(self):
        self.assertEqual(self.run_keys("hellosu3cl3 ")[0], "hello你好")
        self.assertEqual(self.run_keys("oksu3cl3\n")[0], "ok你好")

    def test_three_segments(self):
        self.assertEqual(self.run_keys("ji3emailsu3cl3\n")[0], "我email你好")

    def test_single_language_unchanged(self):
        self.assertEqual(self.run_keys("rup wu0 wu0 fu4cp3cl3\n")[0], "今天天氣很好")
        self.assertEqual(self.run_keys("helloworld\n")[0], "helloworld")
        self.assertEqual(self.run_keys("meeting ")[0], "meeting ")
        self.assertEqual(len(self.run_keys("183\n")[0]), 1)

    def test_speed(self):
        e = make_engine()
        start = time.time()
        for c in "ji3emailsu3cl3rup wu0 wu0 fu4":
            e.handle(c)
            e.marked_text
        per_key = (time.time() - start) / 30
        print("\nper key: %.1f ms" % (per_key * 1000))
        self.assertLess(per_key, 0.05)


if __name__ == "__main__":
    unittest.main()
