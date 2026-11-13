"""Drives autozhuyin_ibus.AutoZhuyinEngine through a minimal stand-in for
gi.repository.IBus, to catch wrapper bugs without Linux. Run from the repo root:
    python3 -m unittest discover -s linux/tests
"""
import os
import sys
import types
import unittest

LINUX = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(LINUX), "windows"))   # autozhuyin package
sys.path.insert(0, LINUX)


# --- stand-in for gi / IBus (only what the wrapper uses) ---
class Flag(int):
    def __or__(self, o): return Flag(int(self) | int(o))
    def __and__(self, o): return Flag(int(self) & int(o))


IBus = types.SimpleNamespace()
for i, name in enumerate(["BackSpace", "Return", "KP_Enter", "Escape", "Tab", "Up", "Down", "Left",
                          "Right", "space", "Shift_L", "Shift_R", "Delete"]):
    setattr(IBus, "KEY_" + name, 0xff00 + i)
IBus.KEY_space = 0x20
IBus.ModifierType = types.SimpleNamespace(
    SHIFT_MASK=Flag(1), LOCK_MASK=Flag(2), CONTROL_MASK=Flag(4), MOD1_MASK=Flag(8),
    SUPER_MASK=Flag(1 << 26), MOD4_MASK=Flag(64), RELEASE_MASK=Flag(1 << 30))
IBus.keyval_to_unicode = lambda k: chr(k) if 0x20 <= k < 0x7f else "\x00"


class Text:
    def __init__(self, s): self.text, self.attrs = s, None
    @staticmethod
    def new_from_string(s): return Text(s)
    def set_attributes(self, a): self.attrs = a


class AttrList(list):
    pass


class LookupTable:
    def __init__(self): self.items, self.cursor = [], 0
    @staticmethod
    def new(*a): return LookupTable()
    def set_orientation(self, o): pass
    def clear(self): self.items = []
    def append_candidate(self, t): self.items.append(t.text)
    def set_cursor_pos(self, p): self.cursor = p


class Property:
    def __init__(self, **kw): self.label = kw["label"].text
    def set_label(self, t): self.label = t.text
    def set_symbol(self, t): pass


class Engine:
    def __init__(self, *a, **kw):
        self.committed, self.preedit, self.cursor, self.shown = "", "", 0, None
        self.preedit_attrs = None

    def commit_text(self, t): self.committed += t.text
    def update_preedit_text_with_mode(self, t, cursor, visible, mode):
        self.preedit, self.cursor, self.preedit_attrs = t.text, cursor, t.attrs
    def hide_preedit_text(self): self.preedit = ""
    def update_lookup_table(self, table, visible): self.shown = list(table.items)
    def hide_lookup_table(self): self.shown = None
    def register_properties(self, p): pass
    def update_property(self, p): self.mode_label = p.label


IBus.Text, IBus.AttrList, IBus.LookupTable, IBus.Property, IBus.Engine = Text, AttrList, LookupTable, Property, Engine
IBus.PropList = lambda: types.SimpleNamespace(append=lambda p: None)
IBus.attr_underline_new = lambda kind, a, b: ("underline", a, b)
IBus.attr_foreground_new = lambda color, a, b: ("color", a, b)
IBus.AttrUnderline = types.SimpleNamespace(SINGLE=1)
IBus.Orientation = types.SimpleNamespace(VERTICAL=1)
IBus.PropType = types.SimpleNamespace(NORMAL=0)
IBus.PropState = types.SimpleNamespace(UNCHECKED=0)
IBus.PreeditFocusMode = types.SimpleNamespace(COMMIT=1)

gi = types.ModuleType("gi")
gi.require_version = lambda *a: None
repo = types.ModuleType("gi.repository")
repo.IBus, repo.GLib, repo.GObject = IBus, types.SimpleNamespace(), types.SimpleNamespace()
gi.repository = repo
sys.modules["gi"], sys.modules["gi.repository"] = gi, repo

import autozhuyin_ibus  # noqa: E402

M = IBus.ModifierType


def press(e, keys):
    """Types keys; returns the list of 'handled' results."""
    names = {"\n": IBus.KEY_Return, "\b": IBus.KEY_BackSpace, "\t": IBus.KEY_Tab, "←": IBus.KEY_Left,
             "→": IBus.KEY_Right, "↓": IBus.KEY_Down, " ": IBus.KEY_space}
    out = []
    for c in keys:
        kv = names.get(c, ord(c))
        out.append(e.do_process_key_event(kv, 0, Flag(0)))
        e.do_process_key_event(kv, 0, M.RELEASE_MASK)
    return out


class IBusEngineTests(unittest.TestCase):
    def setUp(self):
        self.e = autozhuyin_ibus.AutoZhuyinEngine()

    def test_mixed_sentence(self):
        press(self.e, "ji3 hello world su3cl3 ")
        self.assertEqual(self.e.committed, "我hello world 你好")
        self.assertEqual(self.e.preedit, "")

    def test_preedit_marks_english_blue(self):
        press(self.e, "ji3hello")
        self.assertEqual(self.e.preedit, "我hello")
        self.assertIn(("color", 1, 6), self.e.preedit_attrs)
        self.assertEqual(self.e.cursor, 6)

    def test_space_passes_through_when_idle(self):
        self.assertEqual(press(self.e, " "), [False])

    def test_candidates_and_click(self):
        press(self.e, "su3↓")
        self.assertTrue(self.e.shown)
        second = self.e.shown[1]
        self.e.do_candidate_clicked(1, 1, 0)
        self.assertIsNone(self.e.shown)
        press(self.e, "\n")
        self.assertEqual(self.e.committed, second)

    def test_shift_tap_toggles_english(self):
        self.e.do_process_key_event(IBus.KEY_Shift_L, 0, Flag(0))
        self.e.do_process_key_event(IBus.KEY_Shift_L, 0, M.SHIFT_MASK | M.RELEASE_MASK)
        self.assertEqual(self.e.mode_label, "英文")
        self.assertEqual(press(self.e, "a"), [False])   # goes to the app as typed

    def test_shift_as_modifier_is_not_a_tap(self):
        self.e.do_process_key_event(IBus.KEY_Shift_L, 0, Flag(0))
        self.e.do_process_key_event(ord("A"), 0, M.SHIFT_MASK)
        self.e.do_process_key_event(IBus.KEY_Shift_L, 0, M.SHIFT_MASK | M.RELEASE_MASK)
        self.assertFalse(self.e.engine.english_mode)

    def test_ctrl_shortcut_commits_and_passes(self):
        press(self.e, "su3")
        self.assertFalse(self.e.do_process_key_event(ord("c"), 0, M.CONTROL_MASK))
        self.assertEqual(self.e.committed, "你")

    def test_backtick_symbol(self):
        press(self.e, "`<")
        self.assertEqual(self.e.committed, "，")

    def test_insert_in_middle(self):
        press(self.e, "rup fu4←wu0 \n")
        self.assertEqual(self.e.committed, "今天氣")

    def test_focus_out_resets(self):
        press(self.e, "su3")
        self.e.do_focus_out()
        self.assertEqual(self.e.engine.keys, [])


if __name__ == "__main__":
    unittest.main()
