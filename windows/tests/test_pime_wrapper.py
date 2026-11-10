"""Drives autozhuyin_ime.AutoZhuyinTextService through minimal stand-ins for PIME's
`keycodes` and `textService` modules, to catch wrapper bugs without Windows."""
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

# --- stand-ins for PIME modules (only what the wrapper uses) ---
keycodes = types.ModuleType("keycodes")
for name, code in dict(VK_BACK=0x08, VK_TAB=0x09, VK_RETURN=0x0D, VK_SHIFT=0x10, VK_CONTROL=0x11,
                       VK_MENU=0x12, VK_CAPITAL=0x14, VK_ESCAPE=0x1B, VK_SPACE=0x20, VK_LEFT=0x25,
                       VK_UP=0x26, VK_RIGHT=0x27, VK_DOWN=0x28).items():
    setattr(keycodes, name, code)
sys.modules["keycodes"] = keycodes

textService = types.ModuleType("textService")


class FakeTextService:
    def __init__(self, client):
        self.client = client
        self.showCandidates = False
        self.reply = {}

    def onActivate(self): pass
    def onDeactivate(self): pass
    def onCompositionTerminated(self, forced): pass
    def setSelKeys(self, k): self.reply["setSelKeys"] = k
    def customizeUI(self, **kw): self.reply["customizeUI"] = kw
    def setCommitString(self, s): self.reply["commitString"] = s
    def setCompositionString(self, s): self.reply["compositionString"] = s
    def setCompositionCursor(self, p): self.reply["compositionCursor"] = p
    def setCandidateList(self, c): self.reply["candidateList"] = c
    def setCandidateCursor(self, p): self.reply["candidateCursor"] = p

    def setShowCandidates(self, show):
        self.showCandidates = show
        self.reply["showCandidates"] = show


textService.TextService = FakeTextService
sys.modules["textService"] = textService

from autozhuyin.autozhuyin_ime import AutoZhuyinTextService  # noqa: E402

VK = {"\n": 0x0D, "\t": 0x09, " ": 0x20, "\b": 0x08, "↓": 0x28}


class FakeKeyEvent:
    def __init__(self, ch, shift=False, ctrl=False):
        self.keyCode = VK.get(ch, ord(ch.upper()) if ch.isalnum() else 0xBA)
        self.charCode = 0 if ch in ("\n", "\t", "\b", "↓") else ord(ch)
        self.keyStates = [0] * 256
        if shift:
            self.keyStates[0x10] = 0x80
        if ctrl:
            self.keyStates[0x11] = 0x80

    def isKeyDown(self, code): return bool(self.keyStates[code] & 0x80)
    def isKeyToggled(self, code): return bool(self.keyStates[code] & 1)
    def isPrintableChar(self): return self.charCode > 0x1F and self.charCode != 0x7F


def press(svc, ch, **kw):
    """Simulates PIME: filterKeyDown, then onKeyDown if filtered. Returns (eaten, reply)."""
    svc.reply = {}
    ev = FakeKeyEvent(ch, **kw)
    if not svc.filterKeyDown(ev):
        return False, {}
    svc.onKeyDown(ev)
    return True, svc.reply


def type_text(svc, text):
    out = ""
    for ch in text:
        eaten, reply = press(svc, ch)
        if not eaten:
            out += ch if ch not in VK or ch == " " else ""
        out += reply.get("commitString", "")
    return out


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.svc = AutoZhuyinTextService(client=None)
        self.svc.onActivate()

    def test_mixed_sentence(self):
        self.assertEqual(type_text(self.svc, "ji3 hello world su3cl3 "), "我hello world 你好")

    def test_composition_shown(self):
        type_text(self.svc, "su3c")
        self.assertEqual(self.svc.reply["compositionString"], "你ㄏ")
        self.assertEqual(self.svc.reply["compositionCursor"], 2)

    def test_idle_keys_pass_through(self):
        self.assertFalse(press(self.svc, " ")[0])
        self.assertFalse(press(self.svc, "\n")[0])
        self.assertFalse(press(self.svc, "c", ctrl=True)[0])

    def test_candidates_reply(self):
        type_text(self.svc, "su3")
        eaten, reply = press(self.svc, "↓")
        self.assertTrue(eaten)
        self.assertTrue(reply["showCandidates"])
        self.assertIn("妳", reply["candidateList"])
        self.assertLessEqual(len(reply["candidateList"]), 9)
        n = reply["candidateList"].index("妳") + 1
        eaten, reply = press(self.svc, str(n))
        self.assertFalse(reply["showCandidates"])
        self.assertEqual(type_text(self.svc, "\n"), "妳")

    def test_shift_letter_is_english(self):
        out = ""
        for ch in "Hi":
            eaten, reply = press(self.svc, ch, shift=ch.isupper())
            out += reply.get("commitString", "")
        eaten, reply = press(self.svc, " ")
        self.assertEqual(out + reply.get("commitString", ""), "Hi ")


if __name__ == "__main__":
    unittest.main()
