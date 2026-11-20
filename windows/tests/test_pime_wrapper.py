"""Drives autozhuyin_ime.AutoZhuyinTextService through minimal stand-ins for PIME's
`keycodes` and `textService` modules, to catch wrapper bugs without Windows."""
import os
import sys
import types
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
import tempfile  # noqa: E402

os.environ["APPDATA"] = tempfile.mkdtemp(prefix="autozhuyin-test-")   # learned / history files
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

    def showMessage(self, message, duration=3): self.reply["showMessage"] = message
    def addButton(self, button_id, **kw): self.reply.setdefault("addButton", []).append(button_id)
    def removeButton(self, button_id): self.reply.setdefault("removeButton", []).append(button_id)
    def changeButton(self, button_id, **kw): self.reply.setdefault("changeButton", []).append((button_id, kw))

    def setShowCandidates(self, show):
        self.showCandidates = show
        self.reply["showCandidates"] = show


textService.TextService = FakeTextService
textService.COMMAND_LEFT_CLICK, textService.COMMAND_RIGHT_CLICK, textService.COMMAND_MENU = 0, 1, 2
sys.modules["textService"] = textService

from autozhuyin.autozhuyin_ime import AutoZhuyinTextService, _shared_classifier  # noqa: E402

VK = {"\n": 0x0D, "\t": 0x09, " ": 0x20, "\b": 0x08, "↓": 0x28}


class FakeKeyEvent:
    def __init__(self, ch, shift=False, ctrl=False):
        self.keyCode = 0x10 if ch == "⇧" else VK.get(ch, ord(ch.upper()) if ch.isalnum() else 0xBA)
        self.charCode = 0 if ch in ("\n", "\t", "\b", "↓", "⇧") else ord(ch)
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


def tap_shift(svc):
    """Shift down then up with nothing in between, as PIME delivers it."""
    svc.reply = {}
    down = FakeKeyEvent("⇧", shift=True)
    assert not svc.filterKeyDown(down)
    up = FakeKeyEvent("⇧")
    if svc.filterKeyUp(up):
        svc.onKeyUp(up)
    return svc.reply


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
        _shared_classifier().history.clear()
        _shared_classifier().learned.clear()
        self.svc = AutoZhuyinTextService(client=None)
        self.svc.onActivate()

    def test_mixed_sentence(self):
        self.assertEqual(type_text(self.svc, "ji3 hello world su3cl3 "), "我hello world 你好")

    def test_backtick_symbol(self):
        self.assertEqual(type_text(self.svc, "`<"), "，")
        self.assertEqual(type_text(self.svc, "ji3`."), "我。")

    def test_ctrl_semicolon(self):
        self.assertEqual(type_text(self.svc, "ji3"), "")
        eaten, reply = press(self.svc, ";", ctrl=True)
        self.assertTrue(eaten)
        self.assertEqual(reply.get("commitString"), "我；")
        self.assertFalse(press(self.svc, "c", ctrl=True)[0])   # other shortcuts go to the app

    def test_symbol_table(self):
        type_text(self.svc, "` ")
        self.assertTrue(self.svc.reply.get("showCandidates"))
        self.assertEqual(type_text(self.svc, "3"), "、")

    def test_settings_menu(self):
        from autozhuyin import autozhuyin_ime as ime
        self.assertIn("autozhuyin-settings", self.svc.reply["addButton"])
        menu = self.svc.onMenu("autozhuyin-settings")
        texts = [m.get("text") for m in menu]
        self.assertIn("AI 選字：標準", texts)
        self.assertIn("清除學習紀錄", texts)
        self.svc.onCommand(ime.ID_AI_MODE["saver"], 2)
        checked = [m["text"] for m in self.svc.onMenu("autozhuyin-settings") if m.get("checked")]
        self.assertIn("AI 選字：省電", checked)
        self.svc.onCommand(ime.ID_AI_MODE["standard"], 2)
        self.assertIsNone(self.svc.onMenu("other"))

    def test_user_phrases_reload_and_edit(self):
        from autozhuyin import autozhuyin_ime as ime
        os.makedirs(os.path.dirname(ime._USER_PHRASES), exist_ok=True)
        with open(ime._USER_PHRASES, "w", encoding="utf-8") as f:
            f.write("ㄋㄧˇ 妳 -1\n亂寫\n")
        try:
            self.svc.reply = {}
            self.svc.onActivate()
            self.assertEqual(self.svc.reply.get("showMessage"), "自訂詞第 2 行看不懂，請檢查格式")
            self.assertEqual(type_text(self.svc, "su3 "), "妳")
            opened = []
            ime.os.startfile = opened.append
            self.assertIn("編輯自訂詞…", [m.get("text") for m in self.svc.onMenu("autozhuyin-settings")])
            self.svc.onCommand(ime.ID_EDIT_PHRASES, 2)
            self.assertEqual(opened, [ime._USER_PHRASES])
        finally:
            os.remove(ime._USER_PHRASES)
            ime._reload_user_phrases()
            del ime.os.startfile
        self.assertEqual(type_text(self.svc, "su3 "), "你")

    def test_mode_icon_click_toggles_english(self):
        self.svc.reply = {}
        self.svc.onCommand(1, 0)
        self.assertTrue(self.svc.engine.english_mode)
        (button, kw), = self.svc.reply["changeButton"]
        self.assertEqual(button, "windows-mode-icon")
        self.assertTrue(kw["icon"].endswith("icon-en.ico") or kw["icon"].endswith("icon.ico"))
        self.svc.onCommand(1, 0)
        self.assertFalse(self.svc.engine.english_mode)

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


class ShiftTapWrapperTests(unittest.TestCase):
    def setUp(self):
        _shared_classifier().history.clear()
        _shared_classifier().learned.clear()
        self.svc = AutoZhuyinTextService(client=None)
        self.svc.onActivate()

    def test_shift_tap_changes_icon(self):
        tap_shift(self.svc)
        self.assertEqual(self.svc.reply["changeButton"][0][0], "windows-mode-icon")
        tap_shift(self.svc)
        self.assertIn("changeButton", self.svc.reply)

    def test_tap_forces_english_lowercase(self):
        reply = tap_shift(self.svc)
        self.assertEqual(reply.get("showMessage"), "英文")
        self.assertEqual(type_text(self.svc, "ru su "), "ru su ")
        self.assertEqual(tap_shift(self.svc).get("showMessage"), "中英自動")

    def test_shift_with_letter_is_not_a_tap(self):
        self.svc.filterKeyDown(FakeKeyEvent("⇧", shift=True))
        press(self.svc, "H", shift=True)
        up = FakeKeyEvent("⇧")
        self.assertFalse(self.svc.filterKeyUp(up))
        self.assertFalse(self.svc.engine.english_mode)


if __name__ == "__main__":
    unittest.main()
