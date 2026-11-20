"""User phrases: the file model, typed readings and the lexicon overlay (mirror of
UserPhrasesTests in the Swift tests)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from autozhuyin.core import bopomofo  # noqa: E402
from autozhuyin.core.lexicon import Lexicon  # noqa: E402
from autozhuyin.core.user_phrases import Entry, UserPhrases, bad_lines, problem, reading_from_typed  # noqa: E402


class UserPhrasesTests(unittest.TestCase):
    def test_round_trip_keeps_comments(self):
        u = UserPhrases("# 我的詞\nㄗˋ-ㄉㄨㄥˋ 自動 -1\n\n注音 ㄓㄨˋ-ㄧㄣ\n")
        self.assertEqual([e.phrase for e in u.entries], ["自動", "注音"])
        self.assertIsNone(u.entries[1].score)
        self.assertEqual(u.text, "# 我的詞\nㄗˋ-ㄉㄨㄥˋ 自動 -1\n\nㄓㄨˋ-ㄧㄣ 注音\n")
        u.remove(0)
        u.append(Entry("妳好", "ㄋㄧˇ-ㄏㄠˇ"))
        self.assertEqual(u.text, "# 我的詞\n\nㄓㄨˋ-ㄧㄣ 注音\nㄋㄧˇ-ㄏㄠˇ 妳好 -1\n")
        u.replace(0, Entry("註音", "ㄓㄨˋ-ㄧㄣ", -2.5))
        self.assertEqual(u.entries[0], Entry("註音", "ㄓㄨˋ-ㄧㄣ", -2.5))
        self.assertEqual(UserPhrases("").text, "")

    def test_typed_readings(self):
        self.assertEqual(reading_from_typed("y42j/4"), "ㄗˋ-ㄉㄨㄥˋ")
        self.assertEqual(reading_from_typed("ㄗˋㄉㄨㄥˋ"), "ㄗˋ-ㄉㄨㄥˋ")
        self.assertEqual(reading_from_typed("ㄓㄨˋ ㄧㄣ"), "ㄓㄨˋ-ㄧㄣ")
        self.assertEqual(reading_from_typed("ㄐㄧ-ㄚ"), "ㄐㄧ-ㄚ")
        self.assertEqual(reading_from_typed("ㄉㄜ˙"), "ㄉㄜ˙")
        self.assertIsNone(reading_from_typed("hello!"))
        self.assertIsNone(reading_from_typed(""))
        self.assertEqual(problem("自動注音", "ㄗˋ-ㄉㄨㄥˋ"), "注音有 2 個音節，詞有 4 個字")
        self.assertIsNone(problem("自動", "ㄗˋ-ㄉㄨㄥˋ"))
        self.assertEqual(bad_lines("# ok\nㄗˋ-ㄉㄨㄥˋ 自動\n亂寫\nㄗˋ 自動\n"), [3, 4])

    def test_lexicon_user_phrases_override_and_reload(self):
        lex = Lexicon()
        lex.load(["ㄋㄧˇ 你 -2", "ㄋㄧˇ 妳 -3", "ㄏㄠˇ 好 -2", "ㄋㄧˇ-ㄏㄠˇ 你好 -3"])
        ni = [bopomofo.parse(list("su3")).syllables[0].syllable]
        self.assertEqual(lex.entries(ni)[0][0], "你")
        lex.set_user_phrases("ㄋㄧˇ 妳 -1\n")
        self.assertEqual([p for p, _ in lex.entries(ni)], ["妳", "你"])
        self.assertEqual(lex.reading_of("妳好"), "ㄋㄧˇ-ㄏㄠˇ")
        self.assertEqual(lex.reading_of("你好"), "ㄋㄧˇ-ㄏㄠˇ")
        self.assertIsNone(lex.reading_of("貓"))
        lex.set_user_phrases("")
        self.assertEqual([p for p, _ in lex.entries(ni)], ["你", "妳"])
        untoned = [bopomofo.parse(list("su")).syllables[0].syllable]
        self.assertEqual(lex.entries(untoned)[0][0], "你")


if __name__ == "__main__":
    unittest.main()
