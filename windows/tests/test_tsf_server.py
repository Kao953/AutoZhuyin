"""Tests for the stand-alone text service's engine server (windows/tsf/server.py):
the request/reply protocol the TSF DLL speaks, without a named pipe."""
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "tsf"))

import server  # noqa: E402
from test_core import make_engine  # noqa: E402


def parse(reply):
    out = {"cand": []}
    for line in reply.split("\n"):
        name, _, value = line.partition("=")
        value = value.replace("\\n", "\n").replace("\\\\", "\\")
        if name == "cand":
            out["cand"].append(value)
        else:
            out[name] = value
    return out


class TSFServerTests(unittest.TestCase):
    def setUp(self):
        self.s = server.Session(make_engine().classifier)

    def type(self, keys):
        out = ""
        for k in keys:
            r = parse(self.s.request("key\t" + k))
            out += r["commit"]
        return out, r

    def test_typing_and_commit(self):
        out, r = self.type(["s", "u", "3", "c", "l"])
        self.assertEqual(out, "")
        self.assertEqual(r["preedit"], "你ㄏㄠ")
        self.assertEqual(r["cursor"], "3")
        out, r = self.type(["3", " "])
        self.assertEqual(out, "你好")
        self.assertEqual(r["preedit"], "")

    def test_test_does_not_change_state(self):
        self.assertEqual(parse(self.s.request("test\t "))["handled"], "0")   # idle space goes to the app
        self.assertEqual(parse(self.s.request("test\ta"))["handled"], "1")
        self.assertEqual(parse(self.s.request("test\tBS"))["handled"], "0")
        self.assertEqual(self.s.engine.keys, [])

    def test_candidates_and_select(self):
        self.type(["s", "u", "3"])
        r = parse(self.s.request("key\tDOWN"))
        self.assertIn("妳", r["cand"])
        self.assertEqual(r["candsel"], "0")
        r = parse(self.s.request("select\t%d" % r["cand"].index("妳")))
        self.assertEqual(r["preedit"], "妳")
        self.assertEqual(parse(self.s.request("key\tENTER"))["commit"], "妳")

    def test_flip_last_commit(self):
        out, _ = self.type(list("so "))
        self.assertEqual(out, "so ")
        self.assertEqual(parse(self.s.request("flippable"))["text"], "so ")
        r = parse(self.s.request("flip"))
        self.assertEqual(r["handled"], "1")
        self.assertNotIn("s", r["commit"])
        self.assertEqual(parse(self.s.request("flippable"))["text"], r["commit"])   # Tab again flips back
        self.s.request("forget")
        self.assertEqual(parse(self.s.request("flippable"))["text"], "")
        self.assertEqual(parse(self.s.request("flip"))["handled"], "0")
        self.type(list("so "))
        self.s.request("test\tTAB")                 # passed on to the app
        self.assertEqual(parse(self.s.request("flippable"))["text"], "")

    def test_control_shift_and_reset(self):
        self.assertEqual(parse(self.s.request("testctrl\t."))["handled"], "1")
        self.assertEqual(parse(self.s.request("testctrl\tc"))["handled"], "0")
        self.assertEqual(parse(self.s.request("ctrl\t."))["commit"], "。")
        self.assertEqual(parse(self.s.request("shift"))["english"], "1")
        self.assertEqual(parse(self.s.request("shift"))["english"], "0")
        self.type(["s", "u"])
        self.s.request("reset")
        self.assertEqual(self.s.engine.keys, [])
        self.assertEqual(parse(self.s.request("bogus"))["handled"], "0")


    def test_english_button_commits_and_toggles(self):
        self.type(["s", "u", "3"])
        r = parse(self.s.request("english"))
        self.assertEqual((r["commit"], r["preedit"], r["english"]), ("你", "", "1"))
        self.assertEqual(parse(self.s.request("english"))["english"], "0")


class TSFServerMenuTests(unittest.TestCase):
    def setUp(self):
        import tempfile
        from autozhuyin.core.ai import AI
        from autozhuyin.core.user_phrases import UserPhrasesFile
        self.user = tempfile.mkdtemp()
        self.ai = AI(tempfile.mkdtemp(), self.user, background=False)
        classifier = make_engine().classifier
        phrases = UserPhrasesFile(os.path.join(self.user, "user-phrases.txt"), classifier.lexicon)
        self.s = server.Session(classifier, self.ai, phrases)

    def items(self):
        """[(id, flags, text)] of the menu; None for a separator."""
        out = []
        for line in self.s.request("menu").split("\n"):
            if line.startswith("item="):
                parts = line[5:].split("\t")
                out.append((int(parts[0]), parts[1], parts[2]) if len(parts) == 3 else None)
        return out

    def test_menu_and_mode_command(self):
        from autozhuyin.core import menu
        items = self.items()
        self.assertIn((menu.ID_AI_MODE["standard"], "c", "AI 選字：標準"), items)
        self.assertIn(None, items)
        self.assertTrue(any(i and "d" in i[1] for i in items))   # the status line
        r = parse(self.s.request("command\t%d" % menu.ID_AI_MODE["saver"]))
        self.assertEqual(r["message"], "AI 選字：省電")
        self.assertIn((menu.ID_AI_MODE["saver"], "c", "AI 選字：省電"), self.items())

    def test_require_tones_applies_to_every_session(self):
        from autozhuyin.core import menu
        other = server.Session(self.s.classifier, self.ai)
        other.request("test\ta")
        before = other.engine.require_tones
        self.s.request("command\t%d" % menu.ID_REQUIRE_TONES)
        other.request("test\ta")
        self.assertEqual(other.engine.require_tones, not before)

    def test_edit_phrases_opens_the_file(self):
        from autozhuyin.core import menu
        opened = []
        server.os.startfile = opened.append
        try:
            self.s.request("command\t%d" % menu.ID_EDIT_PHRASES)
        finally:
            del server.os.startfile
        self.assertEqual(opened, [os.path.join(self.user, "user-phrases.txt")])


if __name__ == "__main__":
    unittest.main()
