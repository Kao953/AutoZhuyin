"""PIME text service for AutoZhuyin (自動注音).

PIME imports this as `input_methods.autozhuyin.autozhuyin_ime` and creates one
AutoZhuyinTextService per client. All the logic lives in .core (shared with the
tests); this file only translates PIME key events and replies.
"""
import json
import os
import sys
import threading
import time
import traceback

_IMPORT_START = time.perf_counter()

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
from .core import loading
from .core.shift_tap import ShiftTapDetector
from .core.user_phrases import UserPhrasesFile

_HERE = os.path.dirname(os.path.abspath(__file__))
_DATA = os.path.join(_HERE, "data")
_USER_DIR = os.path.join(os.environ.get("APPDATA", _HERE), "PIME", "autozhuyin")
_LEARNED_FILE = os.path.join(_USER_DIR, "learned.json")
_USER_PHRASES = os.path.join(_USER_DIR, "user-phrases.txt")
_HISTORY_FILE = os.path.join(_USER_DIR, "user-history.json")
_CACHE_DIR = os.path.join(_USER_DIR, "cache")
_STARTUP_LOG = os.path.join(_USER_DIR, "startup.log")

_classifier = None
_ai = None
_ai_lock = threading.Lock()
_phrases = None   # UserPhrasesFile
_loaded = threading.Event()   # set when the background load (below) has finished
_load_error = None

ID_MODE_ICON, ID_AUTO_PAUSE, ID_STATUS, ID_CLEAR, ID_EDIT_PHRASES = 1, 2, 3, 4, 5
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


def _load():
    """Loads the lexicon and English model once per PIME server process, in a background
    thread started when PIME imports this module. Activating the input method no longer
    waits for it; the first key does, if it comes before the load has finished."""
    global _classifier, _phrases, _load_error
    timings = {"import": time.perf_counter() - _IMPORT_START}
    start = time.perf_counter()
    try:
        lexicon = loading.load_lexicon(_DATA, _CACHE_DIR, timings)
        phrases = UserPhrasesFile(_USER_PHRASES, lexicon)
        phrases.reload_if_changed()
        english = loading.load_english(_DATA, _CACHE_DIR, timings)
        trained = Classifier.load_weights(os.path.join(_DATA, "classifier-weights.json"))
        _phrases = phrases
        _classifier = Classifier(lexicon, english, LearnedPreferences(_load_json(_LEARNED_FILE), _save_learned),
                                 trained, UserHistory(_load_json(_HISTORY_FILE), _save_history))
        loading.freeze_gc()
    except Exception as e:   # noqa: BLE001 — reported by _shared_classifier
        _load_error = e
        timings["error"] = 0.0
        try:
            os.makedirs(_USER_DIR, exist_ok=True)
            with open(os.path.join(_USER_DIR, "load-error.log"), "a", encoding="utf-8") as f:
                traceback.print_exc(file=f)
        except OSError:
            pass
    finally:
        timings["total"] = time.perf_counter() - start
        loading.log_timings(_STARTUP_LOG, timings)
        _loaded.set()
    if _classifier is not None:
        _shared_ai()   # "AI 選字" model: after the lexicon, so the two don't compete


def _shared_classifier():
    """The shared classifier; waits for the background load if it is still running."""
    _loaded.wait()
    if _classifier is None:
        raise RuntimeError("AutoZhuyin data failed to load: %r" % (_load_error,))
    return _classifier


threading.Thread(target=_load, name="autozhuyin-load", daemon=True).start()


def _reload_user_phrases():
    """Rereads user-phrases.txt if it changed. Returns its bad line numbers, or None."""
    _shared_classifier()
    bad = _phrases.reload_if_changed()
    if bad is not None:
        _shared_ai().reranker.clear_cache()
    return bad


def _shared_ai():
    """"AI 選字": settings and the language model, loaded in the background once."""
    global _ai
    with _ai_lock:
        if _ai is None:
            _ai = AI(_DATA, _USER_DIR)
    return _ai


_SPECIAL = {
    VK_BACK: BACKSPACE, VK_RETURN: ENTER, VK_ESCAPE: ESCAPE, VK_TAB: TAB,  # noqa: F405
    VK_UP: UP, VK_DOWN: DOWN, VK_LEFT: LEFT, VK_RIGHT: RIGHT,  # noqa: F405
}
# Ctrl + these keys gives full-width symbols (engine.handle_control). Virtual-key codes of
# ; ' , . / (VK_OEM_1, VK_OEM_7, VK_OEM_COMMA, VK_OEM_PERIOD, VK_OEM_2).
_CONTROL_KEYS = {0xBA: ";", 0xDE: "'", 0xBC: ",", 0xBE: ".", 0xBF: "/"}


class AutoZhuyinTextService(TextService):
    def __init__(self, client):
        TextService.__init__(self, client)
        self.shift_tap = ShiftTapDetector()
        self._engine = None
        self._check_phrases = False

    @property
    def engine(self):
        """Made on first use (normally the first key), so that creating and activating the
        text service never waits for the lexicon to load."""
        if self._engine is None:
            engine = CompositionEngine(_shared_classifier())
            engine.reranker = _shared_ai().reranker
            self._engine = engine
        return self._engine

    def _english_mode(self):
        return self._engine is not None and self._engine.english_mode

    # --- lifecycle ---

    def onActivate(self):
        TextService.onActivate(self)
        self.setSelKeys("123456789")
        self.customizeUI(candFontSize=16, candPerRow=1, candUseCursor=True)
        # Taskbar IME icon (Windows 8+) and language bar button; both open the settings menu.
        self._icon_english = self._english_mode()
        self.addButton("windows-mode-icon", icon=self._mode_icon(), tooltip=self._mode_tooltip(),
                       commandId=ID_MODE_ICON)
        self.addButton("autozhuyin-settings", icon=_ICON, tooltip="自動注音設定", type="menu")
        if _loaded.is_set():
            self._show_phrase_problems()
        else:
            self._check_phrases = True   # still loading: check on the first key instead

    def _show_phrase_problems(self):
        self._check_phrases = False
        bad = _reload_user_phrases()
        if bad:
            self.showMessage("自訂詞第 %s 行看不懂，請檢查格式" % "、".join(str(n) for n in bad[:5]), 5)

    def onDeactivate(self):
        if self._engine is not None:
            self._engine.reset()
        self.removeButton("windows-mode-icon")
        self.removeButton("autozhuyin-settings")
        TextService.onDeactivate(self)

    # --- taskbar icon: "注" for 中英自動, "A" for English mode ---

    def _mode_icon(self):
        return _ICON_EN if self._english_mode() and os.path.exists(_ICON_EN) else _ICON

    def _mode_tooltip(self):
        return ("英文模式" if self._english_mode() else "中英自動") + "（左鍵切換，右鍵設定）"

    def _update_mode_icon(self):
        if getattr(self, "_icon_english", None) == self._english_mode():
            return
        self._icon_english = self._english_mode()
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
            {"text": "編輯自訂詞…", "id": ID_EDIT_PHRASES},
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
        if commandId == ID_EDIT_PHRASES:
            # Opens in the default editor (Notepad); saved changes load on the next activation.
            os.startfile(_phrases.ensure_exists())
        elif commandId == ID_AUTO_PAUSE:
            ai.set_auto_pause(not ai.auto_pause)
        elif commandId == ID_CLEAR:
            _shared_classifier().learned.clear()
            _shared_classifier().history.clear()
            self.showMessage("已清除學習紀錄", 1)

    def onCompositionTerminated(self, forced):
        # The app ended the composition (focus change, mouse click): the shown text stays.
        if self._engine is not None:
            self._engine.reset()
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
        e = self._engine
        return bool(e is not None and (e.keys or e.candidates))

    def filterKeyDown(self, ev):
        if ev.keyCode == VK_SHIFT:  # noqa: F405
            if ev.isKeyDown(VK_CONTROL) or ev.isKeyDown(VK_MENU):  # noqa: F405
                self.shift_tap.key_pressed()
            else:
                self.shift_tap.shift_down(time.monotonic())
            return False
        self.shift_tap.key_pressed()
        if self._control_key(ev):
            return True
        # Shortcuts (Ctrl/Alt) go to the app.
        if ev.isKeyDown(VK_CONTROL) or ev.isKeyDown(VK_MENU):  # noqa: F405
            return False
        key = self._key(ev)
        if key is None:
            return self._busy()   # swallow other keys (Delete, Home…) while composing
        return self.engine.wants(key)

    def _control_key(self, ev):
        """Ctrl + ; ' , . / (without Alt) → the key, else None."""
        if ev.isKeyDown(VK_CONTROL) and not ev.isKeyDown(VK_MENU):  # noqa: F405
            return _CONTROL_KEYS.get(ev.keyCode)
        return None

    def onKeyDown(self, ev):
        if self._check_phrases:
            self._show_phrase_problems()
        control = self._control_key(ev)
        if control:
            handled, commit = self.engine.handle_control(control)
            self._update(commit)
            return handled
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
