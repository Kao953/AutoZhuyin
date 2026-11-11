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
from autozhuyin.core.engine import DOWN, ENTER, LEFT, RIGHT, SHIFT_TAP, TAB, BACKSPACE, CompositionEngine  # noqa: E402
from autozhuyin.core.shift_tap import ShiftTapDetector  # noqa: E402
from autozhuyin.core.english import EnglishModel  # noqa: E402
from autozhuyin.core.lexicon import Converter, Lexicon  # noqa: E402

DATA = os.path.join(os.path.dirname(HERE), "autozhuyin", "data")
_start = time.time()
LEX = Lexicon.from_file(os.path.join(DATA, "lexicon.txt"))
ENG = EnglishModel.from_files(os.path.join(DATA, "english-common.txt"),
                              os.path.join(DATA, "english-dict.txt"),
                              os.path.join(DATA, "english-bigram.json"))
WEIGHTS = Classifier.load_weights(os.path.join(DATA, "classifier-weights.json"))
LOAD_TIME = time.time() - _start


def readings(keys):
    return [s.syllable.reading for s in bopomofo.parse(list(keys)).syllables]


def convert(keys):
    syl = [s.syllable for s in bopomofo.parse(list(keys)).syllables]
    return "".join(t for _, t in Converter(LEX).convert(syl))


def make_engine():
    return CompositionEngine(Classifier(LEX, ENG, weights=WEIGHTS))


def type_keys(s, e):
    out = ""
    for c in s:
        key = {"\n": ENTER, "\t": TAB, "⇧": SHIFT_TAP, "←": LEFT, "→": RIGHT, "↓": DOWN}.get(c, c)
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
    c = Classifier(LEX, ENG, weights=WEIGHTS)

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
        c = Classifier(LEX, ENG, learned, WEIGHTS)
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

    def test_tone_then_space_stays_chinese(self):
        self.assertEqual(len(type_keys("u4 ", make_engine())), 1)

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


class ShiftTapTests(unittest.TestCase):
    def test_toggles_english_mode(self):
        e = make_engine()
        self.assertEqual(type_keys("⇧ru su ", e), "ru su ")
        self.assertTrue(e.english_mode)
        self.assertEqual(e.marked_text, "")
        self.assertEqual(e.handle(ENTER), (False, None))
        self.assertTrue(e.english_mode)
        self.assertEqual(type_keys("⇧su3cl3\n", e), "你好")
        self.assertFalse(e.english_mode)

    def test_tap_twice_cancels(self):
        self.assertEqual(type_keys("⇧⇧su3cl3\n", make_engine()), "你好")

    def test_mid_word_flips_and_learns(self):
        e = make_engine()
        type_keys("so", e)
        e.handle(SHIFT_TAP)
        self.assertEqual(e.mode, ZHUYIN)
        self.assertFalse(e.english_mode)
        type_keys("\n", e)
        self.assertEqual(e.classifier.learned.weights["so"], 1)

    def test_english_mode_not_learned(self):
        e = make_engine()
        type_keys("⇧hello ", e)
        self.assertEqual(e.classifier.learned.weights, {})

    def test_backspace_goes_to_app(self):
        e = make_engine()
        e.handle(SHIFT_TAP)
        self.assertEqual(e.handle(BACKSPACE), (False, None))
        self.assertTrue(e.english_mode)

    def test_detector(self):
        d = ShiftTapDetector()
        d.shift_down(0)
        self.assertTrue(d.shift_up(0.1))
        d.shift_down(1)
        d.key_pressed()
        self.assertFalse(d.shift_up(1.1))
        d.shift_down(2)
        self.assertFalse(d.shift_up(3))


class CursorTests(unittest.TestCase):
    def test_moves_and_clamps(self):
        e = make_engine()
        type_keys("rup wu0 wu0 fu4", e)
        self.assertEqual(e.cursor_offset, 4)
        type_keys("←", e)
        self.assertEqual(e.cursor_offset, 3)
        type_keys("←←←←", e)
        self.assertEqual(e.cursor_offset, 1)
        type_keys("→→→→", e)
        self.assertEqual(e.cursor_offset, 4)

    def test_choose_candidate_in_the_middle(self):
        e = make_engine()
        type_keys("rup wu0 wu0 fu4←←↓", e)
        self.assertTrue(e.showing_candidates)
        self.assertTrue(all(r[1] == 2 for r, _ in e.candidates))
        e.select_candidate([t for _, t in e.candidates].index("添"))
        self.assertEqual(type_keys("\n", e), "今添天氣")

    def test_typing_returns_cursor_to_end(self):
        e = make_engine()
        type_keys("rup wu0 ←", e)
        self.assertEqual(e.cursor_offset, 1)
        type_keys("wu0 ", e)
        self.assertEqual(e.cursor_offset, len(e.marked_text))

    def test_candidates_for_chinese_before_english(self):
        e = make_engine()
        type_keys("su3cl3hello↓", e)
        self.assertTrue(e.showing_candidates)


class FirstToneAfterEnglishTests(unittest.TestCase):
    def test_first_tone_after_english(self):
        for keys in ["ru", "t", "gj", "vup", "tj", "el"]:
            e = make_engine()
            self.assertEqual(type_keys("hello " + keys + " ", e), "hello ", keys)
            self.assertEqual(len(e.marked_text), 1, keys)


class HeldWordTests(unittest.TestCase):
    def test_next_word_decides(self):
        cases = {"up jo4 ": "因為", "up the ": "up the ", "pick up the ": "pick up the ",
                 "up\n": "up", "i love ": "i love "}
        for keys, want in cases.items():
            self.assertEqual(type_keys(keys, make_engine()), want, keys)

    def test_held_word_stays_composing(self):
        e = make_engine()
        self.assertEqual(type_keys("up ", e), "")
        self.assertEqual(e.marked_text, "up ")
        e.handle(BACKSPACE)
        self.assertEqual(e.marked_text, "up")
        self.assertEqual(type_keys(" the ", e), "up the ")


class BacktickSymbolTests(unittest.TestCase):
    def test_forced_symbols(self):
        cases = {"`<": "，", "`.": "。", "`?": "？", "`;": "；", "`[": "「",
                 "hello`,": "hello，", "su3cl3`.": "你好。", "```\n": "```"}
        for keys, want in cases.items():
            self.assertEqual(type_keys(keys, make_engine()), want, keys)

    def test_plain_backtick(self):
        e = make_engine()
        self.assertEqual(type_keys("`", e), "")
        self.assertEqual(e.marked_text, "`")
        self.assertEqual(type_keys("ls` ", e), "`ls` ")

    def test_escape_cancels(self):
        e = make_engine()
        type_keys("su3`", e)
        e.handle(BACKSPACE)
        self.assertEqual(e.marked_text, "你")


if __name__ == "__main__":
    unittest.main()
