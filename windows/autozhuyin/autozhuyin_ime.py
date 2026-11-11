"""PIME text service for AutoZhuyin (自動注音).

PIME imports this as `input_methods.autozhuyin.autozhuyin_ime` and creates one
AutoZhuyinTextService per client. All the logic lives in .core (shared with the
tests); this file only translates PIME key events and replies.
"""
import json
import os

from keycodes import *  # noqa: F401,F403  (VK_* constants, provided by PIME)
from textService import TextService

from .core.classifier import Classifier, LearnedPreferences
from .core.engine import BACKSPACE, DOWN, ENTER, ESCAPE, LEFT, RIGHT, TAB, UP, CompositionEngine
from .core.english import EnglishModel
from .core.lexicon import Lexicon

_HERE = os.path.dirname(os.path.abspath(__file__))
_DATA = os.path.join(_HERE, "data")
_USER_DIR = os.path.join(os.environ.get("APPDATA", _HERE), "PIME", "autozhuyin")
_LEARNED_FILE = os.path.join(_USER_DIR, "learned.json")
_USER_PHRASES = os.path.join(_USER_DIR, "user-phrases.txt")

_classifier = None


def _save_learned(weights):
    try:
        os.makedirs(_USER_DIR, exist_ok=True)
        with open(_LEARNED_FILE, "w", encoding="utf-8") as f:
            json.dump(weights, f, ensure_ascii=False)
    except OSError:
        pass


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
        weights = {}
        try:
            with open(_LEARNED_FILE, encoding="utf-8") as f:
                weights = json.load(f)
        except (OSError, ValueError):
            pass
        trained = Classifier.load_weights(os.path.join(_DATA, "classifier-weights.json"))
        _classifier = Classifier(lexicon, english, LearnedPreferences(weights, _save_learned), trained)
    return _classifier


_SPECIAL = {
    VK_BACK: BACKSPACE, VK_RETURN: ENTER, VK_ESCAPE: ESCAPE, VK_TAB: TAB,  # noqa: F405
    VK_UP: UP, VK_DOWN: DOWN, VK_LEFT: LEFT, VK_RIGHT: RIGHT,  # noqa: F405
}


class AutoZhuyinTextService(TextService):
    def __init__(self, client):
        TextService.__init__(self, client)
        self.engine = CompositionEngine(_shared_classifier())

    # --- lifecycle ---

    def onActivate(self):
        TextService.onActivate(self)
        self.setSelKeys("123456789")
        self.customizeUI(candFontSize=16, candPerRow=1, candUseCursor=True)

    def onDeactivate(self):
        self.engine.reset()
        TextService.onDeactivate(self)

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

    # --- replies ---

    def _update(self, commit):
        if commit:
            self.setCommitString(commit)
        marked = self.engine.marked_text
        self.setCompositionString(marked)
        self.setCompositionCursor(len(marked))
        if self.engine.showing_candidates:
            page, cursor = self.engine.page()
            self.setCandidateList(page)
            self.setCandidateCursor(cursor)
            self.setShowCandidates(True)
        elif self.showCandidates:
            self.setShowCandidates(False)
