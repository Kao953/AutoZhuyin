"""PIME text service for AutoZhuyin (自動注音).

PIME imports this as `input_methods.autozhuyin.autozhuyin_ime` and creates one
AutoZhuyinTextService per client. All the logic lives in .core (shared with the
tests); this file only translates PIME key events and replies.
"""
import json
import os
import sys
import time

# numpy for "AI 選字" is bundled per Python version (PIME 1.3 has 3.8, PIME 2 has 3.15).
_VENDOR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor",
                       "cp%d%d" % sys.version_info[:2])
if os.path.isdir(_VENDOR) and _VENDOR not in sys.path:
    sys.path.insert(0, _VENDOR)

from keycodes import *  # noqa: F401,F403  (VK_* constants, provided by PIME)
from textService import COMMAND_LEFT_CLICK, COMMAND_MENU, TextService  # noqa: F401

from .core.ai import AI, MODE_NAMES
from .core.history import UserHistory
from .core.reranker import MODES
from .core.classifier import Classifier, LearnedPreferences
from .core.engine import BACKSPACE, DOWN, ENTER, ESCAPE, LEFT, RIGHT, SHIFT_TAP, TAB, UP, CompositionEngine
from .core.english import EnglishModel
from .core.lexicon import Lexicon
from .core.shift_tap import ShiftTapDetector

_HERE = os.path.dirname(os.path.abspath(__file__))
_DATA = os.path.join(_HERE, "data")
_USER_DIR = os.path.join(os.environ.get("APPDATA", _HERE), "PIME", "autozhuyin")
_LEARNED_FILE = os.path.join(_USER_DIR, "learned.json")
_USER_PHRASES = os.path.join(_USER_DIR, "user-phrases.txt")
_HISTORY_FILE = os.path.join(_USER_DIR, "user-history.json")

_classifier = None
_ai = None

ID_MODE_ICON, ID_AUTO_PAUSE, ID_STATUS, ID_CLEAR = 1, 2, 3, 4
ID_AI_MODE = {mode: 10 + i for i, mode in enumerate(MODES)}   # 10..13
_ICON = os.path.join(_HERE, "icon.ico")
_ICON_EN = os.path.join(_HERE, "icon-en.ico")     # shown while English mode is on


def _save_json(path, data):
    try:
        os.makedirs(_USER_DIR, exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
    except OSError:
        pass


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save_learned(weights):
    _save_json(_LEARNED_FILE, weights)


def _save_history(data):
    _save_json(_HISTORY_FILE, data)


def _shared_classifier():
    """Loads the lexicon and English model once per PIME server process."""
    global _classifier
    if _classifier is None:
        lexicon = Lexicon.from_file(os.path.join(_DATA, "lexicon.txt"))
        if os.path.exists(_USER_PHRASES):
            with open(_USER_PHRASES, encoding="utf-8") as f:
                lexicon.load(f)
        english = EnglishModel.from_files(
            os.path.join(_DATA, "english-common.txt"),
            os.path.join(_DATA, "english-dict.txt"),
            os.path.join(_DATA, "english-bigram.json"),
        )
        trained = Classifier.load_weights(os.path.join(_DATA, "classifier-weights.json"))
        _classifier = Classifier(lexicon, english, LearnedPreferences(_load_json(_LEARNED_FILE), _save_learned),
                                 trained, UserHistory(_load_json(_HISTORY_FILE), _save_history))
    return _classifier


def _shared_ai():
    """"AI 選字": settings and the language model, loaded in the background once."""
    global _ai
    if _ai is None:
        _ai = AI(_DATA, _USER_DIR)
    return _ai


_SPECIAL = {
    VK_BACK: BACKSPACE, VK_RETURN: ENTER, VK_ESCAPE: ESCAPE, VK_TAB: TAB,  # noqa: F405
    VK_UP: UP, VK_DOWN: DOWN, VK_LEFT: LEFT, VK_RIGHT: RIGHT,  # noqa: F405
}


class AutoZhuyinTextService(TextService):
    def __init__(self, client):
        TextService.__init__(self, client)
        self.engine = CompositionEngine(_shared_classifier())
        self.shift_tap = ShiftTapDetector()
        self.engine.reranker = _shared_ai().reranker

    # --- lifecycle ---

    def onActivate(self):
        TextService.onActivate(self)
        self.setSelKeys("123456789")
        self.customizeUI(candFontSize=16, candPerRow=1, candUseCursor=True)
        # Taskbar IME icon (Windows 8+) and language bar button; both open the settings menu.
        self._icon_english = self.engine.english_mode
        self.addButton("windows-mode-icon", icon=self._mode_icon(), tooltip=self._mode_tooltip(),
                       commandId=ID_MODE_ICON)
        self.addButton("autozhuyin-settings", icon=_ICON, tooltip="自動注音設定", type="menu")

    def onDeactivate(self):
        self.engine.reset()
        self.removeButton("windows-mode-icon")
        self.removeButton("autozhuyin-settings")
        TextService.onDeactivate(self)

    # --- taskbar icon: "注" for 中英自動, "A" for English mode ---

    def _mode_icon(self):
        return _ICON_EN if self.engine.english_mode and os.path.exists(_ICON_EN) else _ICON

    def _mode_tooltip(self):
        return ("英文模式" if self.engine.english_mode else "中英自動") + "（左鍵切換，右鍵設定）"

    def _update_mode_icon(self):
        if getattr(self, "_icon_english", None) == self.engine.english_mode:
            return
        self._icon_english = self.engine.english_mode
        self.changeButton("windows-mode-icon", icon=self._mode_icon(), tooltip=self._mode_tooltip())

    # --- menu (AI 選字 settings) ---

    def onMenu(self, buttonId):
        if buttonId not in ("windows-mode-icon", "autozhuyin-settings"):
            return None
        ai = _shared_ai()
        items = [{"text": "AI 選字：" + MODE_NAMES[m], "id": ID_AI_MODE[m], "checked": ai.reranker.mode == m}
                 for m in MODES]
        items += [
            {},
            {"text": "系統忙碌時自動暫停 AI", "id": ID_AUTO_PAUSE, "checked": ai.auto_pause},
            {"text": ai.status_text(), "id": ID_STATUS, "enabled": False},
            {},
            {"text": "清除學習紀錄", "id": ID_CLEAR},
        ]
        return items

    def onCommand(self, commandId, commandType):
        ai = _shared_ai()
        if commandId == ID_MODE_ICON and commandType == COMMAND_LEFT_CLICK and not self.engine.keys:
            self.engine.handle(SHIFT_TAP)    # left click: English mode on / off
            self._update_mode_icon()
            self.showMessage("英文" if self.engine.english_mode else "中英自動", 1)
            return
        for mode, cid in ID_AI_MODE.items():
            if commandId == cid:
                ai.set_mode(mode)
                self.showMessage("AI 選字：" + MODE_NAMES[mode], 1)
                return
        if commandId == ID_AUTO_PAUSE:
            ai.set_auto_pause(not ai.auto_pause)
        elif commandId == ID_CLEAR:
            _shared_classifier().learned.clear()
            _shared_classifier().history.clear()
            self.showMessage("已清除學習紀錄", 1)

    def onCompositionTerminated(self, forced):
        # The app ended the composition (focus change, mouse click): the shown text stays.
        self.engine.reset()
        if self.showCandidates:
            self.setShowCandidates(False)
        TextService.onCompositionTerminated(self, forced)

    # --- keys ---

    def _key(self, ev):
        if ev.keyCode in _SPECIAL:
            return _SPECIAL[ev.keyCode]
        if ev.keyCode == VK_SPACE:  # noqa: F405
            return " "
        if not ev.isPrintableChar():
            return None
        c = chr(ev.charCode)
        # Caps Lock without Shift: keep Zhuyin working by using lowercase.
        if ev.isKeyToggled(VK_CAPITAL) and not ev.isKeyDown(VK_SHIFT):  # noqa: F405
            c = c.lower()
        return c

    def _busy(self):
        return bool(self.engine.keys or self.engine.candidates)

    def filterKeyDown(self, ev):
        if ev.keyCode == VK_SHIFT:  # noqa: F405
            if ev.isKeyDown(VK_CONTROL) or ev.isKeyDown(VK_MENU):  # noqa: F405
                self.shift_tap.key_pressed()
            else:
                self.shift_tap.shift_down(time.monotonic())
            return False
        self.shift_tap.key_pressed()
        # Shortcuts (Ctrl/Alt) go to the app.
        if ev.isKeyDown(VK_CONTROL) or ev.isKeyDown(VK_MENU):  # noqa: F405
            return False
        key = self._key(ev)
        if key is None:
            return self._busy()   # swallow other keys (Delete, Home…) while composing
        return self.engine.wants(key)

    def onKeyDown(self, ev):
        key = self._key(ev)
        if key is None:
            return self._busy()
        handled, commit = self.engine.handle(key)
        self._update(commit)
        return handled

    def filterKeyUp(self, ev):
        # Shift pressed and released alone: next word is English (or flip the current one).
        if ev.keyCode == VK_SHIFT:  # noqa: F405
            return self.shift_tap.shift_up(time.monotonic())
        return False

    def onKeyUp(self, ev):
        if ev.keyCode != VK_SHIFT:  # noqa: F405
            return False
        self.engine.handle(SHIFT_TAP)
        self._update(None)
        self._update_mode_icon()
        if not self.engine.keys:
            self.showMessage("英文" if self.engine.english_mode else "中英自動", 1)
        return True

    # --- replies ---

    def _update(self, commit):
        if commit:
            self.setCommitString(commit)
        marked = self.engine.marked_text
        self.setCompositionString(marked)
        self.setCompositionCursor(self.engine.cursor_offset)
        if self.engine.showing_candidates:
            page, cursor = self.engine.page()
            self.setCandidateList(page)
            self.setCandidateCursor(cursor)
            self.setShowCandidates(True)
        elif self.showCandidates:
            self.setShowCandidates(False)
