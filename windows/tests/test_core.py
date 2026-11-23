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
from autozhuyin.core.engine import DOWN, ENTER, ESCAPE, LEFT, RIGHT, SHIFT_TAP, TAB, BACKSPACE, CompositionEngine  # noqa: E402
from autozhuyin.core.shift_tap import ShiftTapDetector  # noqa: E402
from autozhuyin.core.english import EnglishModel  # noqa: E402
from autozhuyin.core.lexicon import Converter, Lexicon  # noqa: E402
from autozhuyin.core.history import UserHistory  # noqa: E402

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
        key = {"\n": ENTER, "\t": TAB, "⇧": SHIFT_TAP, "←": LEFT, "→": RIGHT, "↓": DOWN, "\b": BACKSPACE, "\x1b": ESCAPE}.get(c, c)
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

    def test_typed_over(self):
        """An initial typed again before the tone replaces the one before: ㄌㄨㄥ ㄏ ˊ = ㄏㄨㄥˊ."""
        def readings(keys):
            return [s.syllable.reading for s in bopomofo.parse(list(keys)).syllables]
        self.assertEqual(readings("xj/c "), ["ㄏㄨㄥ"])
        self.assertEqual(readings("su3xj/c6"), ["ㄋㄧˇ", "ㄏㄨㄥˊ"])
        self.assertTrue(bopomofo.parse(list("xj/c ")).syllables[0].reordered)
        # Only when the symbol alone is no syllable: these stay as they were.
        self.assertEqual(readings("xj/cj3"), ["ㄌㄨㄥ", "ㄏㄨˇ"])
        self.assertEqual(readings("5kg4"), ["ㄓㄜ", "ㄕˋ"])     # 這是, first tone omitted
        self.assertEqual(readings("xj/ c "), ["ㄌㄨㄥ", "ㄏ"])   # the first one had its tone
        self.assertEqual(readings("xj/v "), ["ㄌㄨㄥ", "ㄒ"])     # ㄒㄨㄥ is no syllable either

    def test_bopomofo_candidates(self):
        """The Bopomofo itself comes last among the candidates."""
        e = make_engine()
        type_keys(";6", e)
        e.handle(DOWN)
        texts = [t for _, t in e.candidates]
        self.assertEqual(texts[-2:], ["ㄤ", "ㄤˊ"])
        e.select_candidate(len(texts) - 1)
        self.assertEqual(type_keys("\n", e), "ㄤˊ")
        e = make_engine()
        type_keys("ji3/ ", e)
        e.handle(DOWN)
        self.assertEqual([t for _, t in e.candidates].count("ㄥ"), 1)   # first tone: no mark, once

    def test_strict_typed_over(self):
        """要打聲調才出字: every syllable has its tone, so anything typed over an untoned one corrects it."""
        def strict(keys):
            return [s.syllable.reading for s in bopomofo.parse(list(keys), strict=True).syllables]
        self.assertEqual(strict("vu/m6"), ["ㄒㄩㄥˊ"])               # ㄒㄧㄥ, ㄩ over ㄧ
        self.assertEqual(strict("cj/; "), ["ㄏㄨㄤ"])                # ㄏㄨㄥ, ㄤ over ㄥ
        self.assertEqual(strict("xj/cj/3"), ["ㄏㄨㄥˇ"])             # the whole syllable typed again
        self.assertEqual(strict("j04u "), ["ㄨㄢˋ", "ㄧ"])            # 萬一 with its tones
        self.assertEqual(strict("xj/v "), ["ㄌㄨㄥ", "ㄒ"])            # ㄒㄨㄥ is no syllable: kept apart

        def typed(keys, on):
            e = make_engine()
            e.require_tones = on
            return type_keys(keys, e)
        self.assertEqual(typed("vu/m6\n", True), "雄")
        self.assertEqual(typed("su3vu/m6\n", True), "你雄")
        self.assertEqual(typed("j04u \n", True), "萬一")
        self.assertEqual(len(typed("vu/m6\n", False)), 2)   # not strict: two characters, as before
        self.assertEqual(typed("su3cpu3\n", True), "你ㄏㄣ以")   # untoned stays Bopomofo (ㄏㄧㄣ is no syllable)
        self.assertEqual(typed("su3cpcl3\n", True), "你好")      # ㄏㄣ typed over with ㄏㄠˇ
        self.assertEqual(typed("su3cpcl3\n", False), "你很好")

    def test_typed_over_converts(self):
        self.assertEqual(type_keys("xj/c \n", make_engine()), "轟")


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

    def test_flip_last_commit(self):
        """Tab right after a commit retypes it in the other mode and learns the correction."""
        e = make_engine()
        self.assertEqual(type_keys("so ", e), "so ")
        self.assertEqual(e.flippable_text, "so ")
        zh = e.flip_last_commit()
        self.assertNotIn("s", zh)
        self.assertEqual(e.classifier.learned.weights["so"], 1)
        self.assertEqual(e.flippable_text, zh)      # Tab again flips it back
        self.assertEqual(e.flip_last_commit(), "so ")
        self.assertEqual(type_keys("su3cl3 ", e), "你好")
        self.assertEqual(e.flip_last_commit(), "su3cl3 ")
        self.assertEqual(len(type_keys("ji  ", e)), 1)
        self.assertEqual(e.flip_last_commit(), "ji ")
        # Not after Enter: Tab next is completion ("cd shell" ⏎ Tab in a terminal).
        self.assertEqual(type_keys("shell\n", e), "shell")
        self.assertIsNone(e.flippable_text)

    def test_flip_last_commit_limits(self):
        e = make_engine()
        type_keys("hello a", e)
        self.assertIsNone(e.flippable_text)
        e.commit_all()
        type_keys("Hello ", e)
        self.assertIsNone(e.flippable_text)        # capitals aren't Dachen keys
        type_keys("so ", e)
        e.handle(LEFT)
        self.assertIsNone(e.flippable_text)
        self.assertEqual(e.handle(TAB), (False, None))
        type_keys("so ", e)
        e.handle_control(".")
        self.assertIsNone(e.flippable_text)

    def test_tab_learns(self):
        e = make_engine()
        type_keys("so", e)
        self.assertEqual(e.mode, LITERAL)
        e.handle(TAB)
        self.assertEqual(e.mode, ZHUYIN)
        type_keys("\n", e)
        self.assertEqual(e.classifier.learned.weights["so"], 1)

    def test_tab_flips_the_last_segment(self):
        """Tab flips only the last segment; what is before it stays, and only that word is learned."""
        e = make_engine()
        type_keys("ji3so\t", e)
        self.assertEqual(e.segments, [(0, 3, ZHUYIN), (3, 5, ZHUYIN)])
        self.assertTrue(e.marked_text.startswith("我"))
        self.assertEqual(type_keys("\n", e), "我內")
        self.assertEqual(e.classifier.learned.weights, {"so": 1})
        self.assertEqual(type_keys("ji3so\t\t\n", make_engine()), "我so")   # Tab again flips it back
        # In Chinese, the last character: 我要 Tab is 我ul4; an untoned tail is flipped as a whole.
        self.assertEqual(type_keys("ji3ul4\t\n", make_engine()), "我ul4")
        self.assertEqual(type_keys("ji3ul4\t\t\n", make_engine()), "我要")
        self.assertEqual(type_keys("su3cl3\t\n", make_engine()), "你cl3")
        e = make_engine()
        e.require_tones = True
        type_keys("ji3ul4fm4test\t", e)
        self.assertEqual(e.segments[-1], (9, 13, ZHUYIN))
        e = make_engine()
        type_keys("ji3so\t\b\b", e)                 # the flipped word deleted: no flip left
        self.assertIsNone(e.forced_mode)
        self.assertEqual(e.marked_text, "我")

    def test_punctuation(self):
        self.assertEqual(type_keys("hello, ", make_engine()), "hello, ")
        self.assertEqual(type_keys("su3cl3?\n", make_engine()), "你好？")

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
        self.assertEqual(e.cursor_offset, 1)   # stops after the first character
        type_keys("→→→→", e)
        self.assertEqual(e.cursor_offset, 4)

    def test_choose_candidate_in_the_middle(self):
        e = make_engine()
        type_keys("rup wu0 wu0 fu4←←↓", e)
        self.assertTrue(e.showing_candidates)
        self.assertTrue(all(r[1] == 2 for r, _ in e.candidates))
        e.select_candidate([t for _, t in e.candidates].index("添"))
        self.assertEqual(type_keys("\n", e), "今添天氣")

    def test_english_returns_cursor_to_end(self):
        e = make_engine()
        type_keys("rup wu0 ←", e)
        self.assertEqual(e.cursor_offset, 1)
        type_keys("?", e)
        self.assertEqual(e.marked_text, "今天？")
        self.assertEqual(e.cursor_offset, 3)


class InsertInMiddleTests(unittest.TestCase):
    def test_insert_syllable(self):
        e = make_engine()
        type_keys("rup fu4←wu", e)
        self.assertEqual(e.marked_text, "今ㄊㄧ氣")
        self.assertEqual(e.cursor_offset, 3)
        type_keys("0 ", e)
        self.assertEqual(e.marked_text, "今天氣")
        self.assertEqual(e.cursor_offset, 2)
        self.assertEqual(type_keys("\n", e), "今天氣")

    def test_cursor_stops_after_first_character(self):
        e = make_engine()
        type_keys("su3cl3←←←", e)
        self.assertEqual(e.cursor_offset, 1)
        type_keys("ji3\n", e)
        self.assertEqual(e.marked_text, "")

    def test_no_stop_before_first_chinese(self):
        e = make_engine()
        type_keys("hello ji3←←", e)   # "hello " held, then 我: nothing to pick before 我
        type_keys("↓", e)
        self.assertTrue(e.showing_candidates)

    def test_backspace_deletes_character_before_cursor(self):
        e = make_engine()
        type_keys("rup wu0 wu0 fu4←←\b", e)
        self.assertEqual(e.marked_text, "今天氣")
        self.assertEqual(e.cursor_offset, 1)

    def test_backspace_at_end_deletes_whole_character(self):
        e = make_engine()
        type_keys("rup wu0 \b", e)
        self.assertEqual(e.marked_text, "今")          # 天 goes at once, not just its tone
        type_keys("wu\b", e)
        self.assertEqual(e.marked_text, "今ㄊ")        # Bopomofo still being typed: one key
        type_keys("\b\b", e)
        self.assertEqual(e.marked_text, "")

    def test_backspace_inside_inserted_syllable(self):
        e = make_engine()
        type_keys("rup fu4←wu\b", e)
        self.assertEqual(e.marked_text, "今ㄊ氣")

    def test_keeps_picked_phrase_before_cursor(self):
        e = make_engine()
        type_keys("rup wu0 ↓", e)
        e.select_candidate([t for _, t in e.candidates].index("添"))
        type_keys("fu4←wu0 ", e)   # insert 天 between 添 and 氣
        self.assertEqual(e.marked_text[:3], "今添天")

    def test_candidates_for_chinese_before_english(self):
        e = make_engine()
        type_keys("su3cl3hello↓", e)
        self.assertTrue(e.showing_candidates)


class FirstToneAfterEnglishTests(unittest.TestCase):
    def test_first_tone_after_english(self):
        for keys in ["ru", "t", "gj", "vup", "tj", "el"]:
            e = make_engine()
            out = type_keys("hello " + keys + " \n", e)
            self.assertEqual(out[:6], "hello ", keys)
            self.assertEqual(len(out), 7, keys)          # one Chinese character after it
            self.assertFalse(out[6].isascii(), keys)


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

    def _engine(self, learned):
        return CompositionEngine(Classifier(LEX, ENG, learned, weights=WEIGHTS))

    def test_held_word_with_digit_keys(self):
        """Words with digits / punctuation keys are held too: "0 " is 安, "5j; " is 裝."""
        learned = LearnedPreferences({"0": -2})   # "0" once learned as a number
        self.assertEqual(type_keys("0 5j; \n", self._engine(learned)), "安裝")
        self.assertEqual(type_keys("0 \n", self._engine(learned)), "0 ")

    def test_tab_overrides_learned(self):
        """One Tab undoes a wrong learned preference, and only the word flipped is learned."""
        learned = LearnedPreferences({"0": -2})
        self.assertEqual(type_keys("0\t 5j; \n", self._engine(learned)), "安裝")
        self.assertEqual(learned.weights["0"], 1)
        self.assertNotIn("0 5j; ", learned.weights)
        self.assertEqual(type_keys("hello 0 5j; \n", self._engine(learned)), "hello 安裝")


class BacktickSymbolTests(unittest.TestCase):
    def test_backslash_is_dunhao(self):
        self.assertEqual(type_keys("ji3\\\n", make_engine()), "我、")
        self.assertEqual(type_keys("hello\\", make_engine()), "hello\\")

    def test_control_symbols(self):
        e = make_engine()
        type_keys("ji3", e)
        self.assertEqual(e.handle_control(";"), (True, "我；"))
        self.assertEqual(e.handle_control("'"), (True, "、"))
        self.assertIsNone(e.handle_control("c"))

    def test_symbol_table(self):
        e = make_engine()
        self.assertEqual(type_keys("ji3` ", e), "我")
        self.assertTrue(e.symbol_table)
        self.assertEqual(type_keys("4", e), "；")
        self.assertEqual(type_keys("`↓↓\n", e), "。")
        type_keys("` \x1b", e)   # Esc closes the table
        self.assertFalse(e.candidates)
        self.assertEqual(type_keys("su3 ", e), "你")

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


def punct_choices_index(e, text):
    return [t for _, t in e.candidates].index(text)


class HeldPunctuationTests(unittest.TestCase):
    """A Shift-punctuation typed with nothing composed waits for the next key; Tab switches it."""
    def test_tab_switches(self):
        e = make_engine()
        self.assertEqual(type_keys("<", e), "")
        self.assertEqual(e.marked_text, "<")
        self.assertEqual(e.cursor_offset, 1)
        type_keys("\t", e)
        self.assertEqual(e.marked_text, "，")
        type_keys("⇧", e)
        self.assertEqual(e.marked_text, "<")
        self.assertFalse(e.english_mode)
        self.assertEqual(type_keys("\tsu3", e), "，")
        self.assertEqual(e.marked_text, "你")

    def test_guess_from_context(self):
        self.assertEqual(type_keys("ji3 <\n", make_engine()), "我，")
        self.assertEqual(type_keys("ji3 !\t\n", make_engine()), "我!")
        self.assertEqual(type_keys("ji3<\n", make_engine()), "我，")
        self.assertEqual(type_keys("hello!", make_engine()), "hello!")   # after English: sent at once
        self.assertEqual(type_keys("hello\\", make_engine()), "hello\\")

    def test_space_sends_it(self):
        self.assertEqual(type_keys("! ", make_engine()), "! ")
        self.assertEqual(type_keys("ji3 ! ", make_engine()), "我！")

    def test_switch_is_remembered(self):
        """The switch says which language is being typed: the next punctuation follows it."""
        self.assertEqual(type_keys("<\t>\n", make_engine()), "，。")

    def test_backspace_cancels(self):
        e = make_engine()
        self.assertEqual(type_keys("(\b", e), "")
        self.assertEqual(e.marked_text, "")

    def test_held_after_chinese(self):
        """After Chinese it waits too, after the composition; the next key sends both."""
        e = make_engine()
        self.assertEqual(type_keys("ji3[", e), "")
        self.assertEqual(e.marked_text, "我「")
        self.assertEqual(type_keys("su3", e), "我「")
        self.assertEqual(e.marked_text, "你")
        self.assertEqual(type_keys("ji3<\t\n", make_engine()), "我<")
        self.assertEqual(type_keys("ji3(\b\n", make_engine()), "我")

    def test_enter_sends_it_only(self):
        """Enter sends the punctuation like a composition, without a new line."""
        e = make_engine()
        type_keys("!", e)
        self.assertEqual(e.handle(ENTER), (True, "!"))

    def test_down_picks_another(self):
        e = make_engine()
        type_keys("ji3[", e)
        e.handle(DOWN)
        self.assertTrue(e.showing_candidates)
        texts, index = e.page()
        self.assertEqual(texts[:4], ["「", "『", "（", "【"])
        self.assertEqual(texts[index], "「")
        type_keys("2", e)
        self.assertFalse(e.showing_candidates)
        self.assertEqual(e.marked_text, "我『")   # picked, not sent yet
        self.assertEqual(type_keys("\n", e), "我『")

    def test_choices(self):
        from autozhuyin.core.engine import punct_choices
        self.assertEqual(punct_choices("{")[0], "『")
        self.assertEqual(punct_choices("{")[-1], "{")
        self.assertEqual(len(set(punct_choices("("))), len(punct_choices("(")))
        self.assertEqual(punct_choices(")")[:2], ["）", "」"])
        self.assertIn("、", punct_choices("<"))

    def test_tab_after_a_pick(self):
        e = make_engine()
        type_keys("ji3 ", e)
        type_keys("(", e)
        e.handle(DOWN)
        e.select_candidate(punct_choices_index(e, "【"))
        self.assertEqual(e.marked_text, "【")
        type_keys("\t", e)
        self.assertEqual(e.marked_text, "(")
        type_keys("\t", e)
        self.assertEqual(e.marked_text, "（")

    def test_wants(self):
        e = make_engine()
        self.assertTrue(e.wants("<"))
        type_keys("<", e)
        self.assertTrue(e.wants(ENTER))
        self.assertTrue(e.wants(TAB))

    def test_commit_all(self):
        e = make_engine()
        type_keys("ji3 ?", e)
        self.assertEqual(e.commit_all(), "？")
        type_keys("?", e)
        self.assertEqual(e.handle_control(","), (True, "？，"))


class FirstWordHoldTests(unittest.TestCase):
    """The first word is not committed as English on space if it also reads as Zhuyin."""
    def test_next_word_decides(self):
        cases = {"el ji3 ": "高我", "no su3cl3 ": "no 你好", "ok ji3 ": "ok 我",
                 "i love you ": "i love you ", "up the ": "up the "}
        for keys, want in cases.items():
            self.assertEqual(type_keys(keys, make_engine()), want, keys)

    def test_not_held_after_english(self):
        e = make_engine()
        self.assertEqual(type_keys("hello world ", e), "hello world ")
        self.assertEqual(type_keys("so ", e), "so ")   # right after English: commits at once


class UserHistoryTests(unittest.TestCase):
    def setUp(self):
        self.saved = []
        self.c = Classifier(LEX, ENG, weights=WEIGHTS, history=UserHistory(on_change=self.saved.append))

    def pick(self, keys, phrase):
        e = CompositionEngine(self.c)
        type_keys(keys + "↓", e)
        e.select_candidate([t for _, t in e.candidates].index(phrase))
        return type_keys("\n", e)

    def test_picked_candidate_comes_first(self):
        self.assertEqual(type_keys("wu0 \n", CompositionEngine(self.c)), "天")
        self.assertEqual(self.pick("wu0 ", "添"), "添")
        self.assertEqual(type_keys("wu0 \n", CompositionEngine(self.c)), "添")
        e = CompositionEngine(self.c)
        type_keys("wu0 ↓", e)
        self.assertEqual(e.candidates[0][1], "添")
        self.assertEqual(self.saved[-1], {"ㄊㄧㄢ": {"添": [1, 1]}})

    def test_phrases_still_win(self):
        self.pick("wu0 ", "添")
        self.assertEqual(type_keys("rup wu0 \n", CompositionEngine(self.c)), "今天")

    def test_most_picked_wins(self):
        self.pick("wu0 ", "添")
        self.pick("wu0 ", "添")
        self.pick("wu0 ", "天")
        self.assertEqual(type_keys("wu0 \n", CompositionEngine(self.c)), "添")

    def test_round_trip_and_clear(self):
        self.pick("wu0 ", "添")
        h = UserHistory(self.saved[-1])
        self.assertEqual(h.data, {"ㄊㄧㄢ": {"添": [1, 1]}})
        h.record([bopomofo.parse(list("wu0 ")).syllables[0].syllable], "天")
        self.assertEqual(h.data["ㄊㄧㄢ"]["天"], [1, 2])
        h.clear()
        self.assertEqual(h.data, {})

    def test_evicts_least_recent(self):
        h = UserHistory()
        h.max_entries = 2
        syl = [bopomofo.parse(list("wu0 ")).syllables[0].syllable]
        for p in ["天", "添", "田"]:
            h.record(syl, p)
        self.assertEqual(set(h.data["ㄊㄧㄢ"]), {"添", "田"})


class FakeLM:
    """Likes one string; `on_call` can advance a fake clock."""
    def __init__(self, liked):
        self.liked, self.calls, self.on_call = liked, 0, lambda: None

    def log_probs(self, texts, context=""):
        self.calls += len(texts)
        self.on_call()
        return [0.0 if self.liked in t else -50.0 for t in texts]


class RerankerTests(unittest.TestCase):
    def engine(self, reranker):
        e = make_engine()
        e.reranker = reranker
        return e

    def test_rerank_picks_what_the_model_likes(self):
        from autozhuyin.core.reranker import Reranker, ST_ACTIVE
        self.assertEqual(type_keys("wu0 \n", self.engine(None)), "天")
        r = Reranker("standard", FakeLM("添"))
        self.assertEqual(type_keys("wu0 \n", self.engine(r)), "添")
        self.assertEqual(r.status, ST_ACTIVE)

    def test_off_and_loading_use_the_lexicon(self):
        from autozhuyin.core.reranker import Reranker, ST_LOADING, ST_OFF
        off = Reranker("off", FakeLM("添"))
        self.assertEqual(type_keys("wu0 \n", self.engine(off)), "天")
        self.assertEqual(off.status, ST_OFF)
        loading = Reranker("standard", None)
        self.assertEqual(type_keys("wu0 \n", self.engine(loading)), "天")
        self.assertEqual(loading.status, ST_LOADING)

    def test_paused_and_reduced(self):
        from autozhuyin.core.reranker import PAUSED, REDUCED, Reranker, ST_BUSY
        r = Reranker("standard", FakeLM("添"))
        r.system_state = lambda: PAUSED
        self.assertEqual(type_keys("wu0 \n", self.engine(r)), "天")
        self.assertEqual(r.status, ST_BUSY)
        lm = FakeLM("添")
        r = Reranker("quality", lm)
        r.system_state = lambda: REDUCED
        type_keys("wu0 \n", self.engine(r))
        self.assertLessEqual(lm.calls, 3)

    def test_slow_model_is_paused(self):
        from autozhuyin.core.reranker import Reranker, ST_SLOW
        clock = [0.0]
        lm = FakeLM("添")
        lm.on_call = lambda: clock.__setitem__(0, clock[0] + 1)   # every batch takes a "second"
        r = Reranker("standard", lm, now=lambda: clock[0])
        for _ in range(3):
            type_keys("wu0 \n", self.engine(r))
        self.assertEqual(r.status, ST_SLOW)
        lm.on_call = lambda: None
        self.assertEqual(type_keys("wu0 \n", self.engine(r)), "天")   # paused
        clock[0] += 61
        self.assertEqual(type_keys("wu0 \n", self.engine(r)), "添")   # back after a minute

    def marked(self, e):
        return "".join(t for t, _ in e.marked_pieces)

    def test_large_model_is_used_when_committing(self):
        from autozhuyin.core.reranker import Reranker
        r = Reranker("quality", FakeLM("天"))
        r.large_model = FakeLM("添")
        self.assertEqual(type_keys("wu0 \n", self.engine(r)), "添")

    def test_large_model_runs_in_the_background(self):
        import threading
        from autozhuyin.core.reranker import Reranker
        r = Reranker("quality", FakeLM("天"))
        large, gate, updated = FakeLM("添"), threading.Event(), threading.Event()
        large.on_call = gate.wait
        r.large_model = large
        r.on_update = updated.set
        e = self.engine(r)
        type_keys("wu0 ", e)
        self.assertEqual(self.marked(e), "天")    # the small model's result meanwhile
        gate.set()
        self.assertTrue(updated.wait(5))
        self.assertEqual(self.marked(e), "添")

    def test_commit_does_not_wait_long_for_the_large_model(self):
        import threading
        import time
        from autozhuyin.core.engine import CompositionEngine
        from autozhuyin.core.reranker import Reranker
        r = Reranker("quality", FakeLM("天"))
        large, gate = FakeLM("添"), threading.Event()
        large.on_call = gate.wait
        r.large_model = large
        start = time.monotonic()
        self.assertEqual(type_keys("wu0 \n", self.engine(r)), "天")
        self.assertLess(time.monotonic() - start, CompositionEngine.COMMIT_WAIT + 0.5)
        gate.set()

    def test_quality_without_the_large_model_is_standard(self):
        from autozhuyin.core.reranker import Reranker
        r = Reranker("quality", FakeLM("添"))
        self.assertEqual(type_keys("wu0 \n", self.engine(r)), "添")

    def test_kbest_first_is_viterbi(self):
        syl = [s.syllable for s in bopomofo.parse(list("rup wu0 wu0 fu4")).syllables]
        conv = Converter(LEX)
        best = conv.kbest(syl, 5)
        self.assertEqual("".join(t for _, t in best[0][1]), "".join(t for _, t in conv.convert(syl)))
        self.assertEqual(len(best), 5)


class RealModelTests(unittest.TestCase):
    """Needs numpy and data/lm.bin (scripts/fetch-lm.sh, tools/build_data.py); skipped otherwise."""
    def test_fixes_homophones(self):
        from autozhuyin.core import lm
        from autozhuyin.core.reranker import Reranker
        path = os.path.join(DATA, "lm.bin")
        if not lm.available() or not os.path.exists(path):
            self.skipTest("needs numpy and the model")
        model = lm.GPT2LanguageModel(path, os.path.join(DATA, "lm-vocab.txt"))
        self.assertAlmostEqual(model.log_prob("他在家"), -14.329, delta=0.05)
        self.assertGreater(model.log_prob("好耶"), model.log_prob("好䱒"))   # 䱒 is not in the vocabulary
        cases = {"w8 ql32k71u3ji3dj94cp32ji ": "他跑得比我快很多", "fu/3su3y94gji u h4cl3a87": "請你再說一次好嗎"}
        for keys, want in cases.items():
            self.assertNotEqual(type_keys(keys + "\n", make_engine()), want)
            e = make_engine()
            e.reranker = Reranker("standard", model)
            self.assertEqual(type_keys(keys + "\n", e), want)


class AISettingsTests(unittest.TestCase):
    def test_settings_round_trip_and_status(self):
        import tempfile
        from autozhuyin.core.ai import AI
        user = tempfile.mkdtemp()
        ai = AI(tempfile.mkdtemp(), user, background=False)    # no model files here
        self.assertTrue(ai.error)                               # "需要 numpy" or "AI 模型未安裝"
        self.assertEqual(ai.status_text(), ai.error)
        ai.set_mode("saver")
        ai.set_auto_pause(False)
        again = AI(tempfile.mkdtemp(), user, background=False)
        self.assertEqual(again.reranker.mode, "saver")
        self.assertFalse(again.auto_pause)

    def download(self, ai, content):
        """Runs the 高品質 model download from a local file instead of GitHub."""
        import hashlib
        import pathlib
        import tempfile
        import threading
        from unittest import mock
        from autozhuyin.core import ai as ai_module
        src = pathlib.Path(tempfile.mkdtemp()) / "lm-large.bin"
        src.write_bytes(content)
        done = threading.Event()
        with mock.patch.object(ai_module, "LARGE_URL", src.as_uri()), \
                mock.patch.object(ai_module, "LARGE_SHA256", hashlib.sha256(b"model").hexdigest()):
            ai.large_menu_clicked(on_done=done.set)
            self.assertTrue(done.wait(5))

    def test_large_model_download_and_remove(self):
        import tempfile
        from autozhuyin.core.ai import AI
        ai = AI(tempfile.mkdtemp(), tempfile.mkdtemp(), background=False)
        self.assertIn("下載高品質模型", ai.large_menu_text())
        self.download(ai, b"model")
        self.assertTrue(ai.large_installed)
        self.assertIn("移除高品質模型", ai.large_menu_text())
        ai.large_menu_clicked()
        self.assertFalse(ai.large_installed)

    def test_large_model_download_is_checked(self):
        import os
        import tempfile
        from autozhuyin.core.ai import AI
        ai = AI(tempfile.mkdtemp(), tempfile.mkdtemp(), background=False)
        self.download(ai, b"broken")
        self.assertFalse(ai.large_installed)
        self.assertFalse(os.path.exists(ai.large_path + ".part"))
        self.assertIn("不完整", ai.large_menu_text())


if __name__ == "__main__":
    unittest.main()
