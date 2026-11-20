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


if __name__ == "__main__":
    unittest.main()
