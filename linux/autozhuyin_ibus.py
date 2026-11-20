#!/usr/bin/env python3
"""IBus engine for AutoZhuyin (自動注音) on Linux.

All the logic lives in autozhuyin.core (shared with Windows and the tests); this file
only translates IBus key events and draws the preedit / candidate table.

Run modes:
  autozhuyin_ibus.py --ibus       started by ibus-daemon (from the component XML)
  autozhuyin_ibus.py [--activate] started by the user/autostart: registers the engine
                                  itself if ibus-daemon does not know it, and with
                                  --activate makes it the current input method
"""
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
# numpy for "AI 選字", downloaded by install.sh when the system has none.
_VENDOR = os.path.join(HERE, "vendor", "cp%d%d" % sys.version_info[:2])
if os.path.isdir(_VENDOR):
    sys.path.insert(1, _VENDOR)

import gi  # noqa: E402

gi.require_version("IBus", "1.0")
from gi.repository import GLib, GObject, IBus  # noqa: E402

import autozhuyin  # noqa: E402
from autozhuyin.core.ai import AI, MODE_NAMES  # noqa: E402
from autozhuyin.core.history import UserHistory  # noqa: E402
from autozhuyin.core.reranker import MODES  # noqa: E402
from autozhuyin.core.classifier import LITERAL, Classifier, LearnedPreferences  # noqa: E402
from autozhuyin.core.engine import (  # noqa: E402
    BACKSPACE, DOWN, ENTER, ESCAPE, LEFT, RIGHT, SHIFT_TAP, TAB, UP, CompositionEngine,
)
from autozhuyin.core.english import EnglishModel  # noqa: E402
from autozhuyin.core.lexicon import Lexicon  # noqa: E402
from autozhuyin.core.shift_tap import ShiftTapDetector  # noqa: E402

ENGINE_NAME = "autozhuyin"
BUS_NAME = "org.freedesktop.IBus.AutoZhuyin"
VERSION = "0.0.0"

_DATA = os.path.join(os.path.dirname(os.path.abspath(autozhuyin.__file__)), "data")
_USER_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "autozhuyin")
_LEARNED_FILE = os.path.join(_USER_DIR, "learned.json")
_USER_PHRASES = os.path.join(_USER_DIR, "user-phrases.txt")
_HISTORY_FILE = os.path.join(_USER_DIR, "user-history.json")

try:
    with open(os.path.join(HERE, "version.txt"), encoding="utf-8") as _f:
        VERSION = _f.read().strip() or VERSION
except OSError:
    pass

_classifier = None
_ai = None


def shared_ai():
    """"AI 選字": settings and the language model, loaded in the background once."""
    global _ai
    if _ai is None:
        _ai = AI(_DATA, _USER_DIR)
    return _ai


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


def shared_classifier():
    """Loads the lexicon and English model once per process."""
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


_SPECIAL = {
    IBus.KEY_BackSpace: BACKSPACE, IBus.KEY_Return: ENTER, IBus.KEY_KP_Enter: ENTER,
    IBus.KEY_Escape: ESCAPE, IBus.KEY_Tab: TAB,
    IBus.KEY_Up: UP, IBus.KEY_Down: DOWN, IBus.KEY_Left: LEFT, IBus.KEY_Right: RIGHT,
}
_SHIFT_KEYS = (IBus.KEY_Shift_L, IBus.KEY_Shift_R)
_SHORTCUT_MASK = (IBus.ModifierType.CONTROL_MASK | IBus.ModifierType.MOD1_MASK
                  | IBus.ModifierType.SUPER_MASK | IBus.ModifierType.MOD4_MASK)
_LITERAL_COLOR = 0x1E64DC   # blue hint for English segments


class AutoZhuyinEngine(IBus.Engine):
    __gtype_name__ = "AutoZhuyinEngine"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._setup()

    def _setup(self):
        if getattr(self, "engine", None) is not None:
            return
        self.engine = CompositionEngine(shared_classifier())
        self.engine.reranker = shared_ai().reranker
        self.shift_tap = ShiftTapDetector()
        self._caps = 0   # client capabilities (do_set_capabilities)
        self.table = IBus.LookupTable.new(self.engine.page_size, 0, True, False)
        self.table.set_orientation(IBus.Orientation.VERTICAL)
        self.mode_prop = IBus.Property(
            key="mode", prop_type=IBus.PropType.NORMAL,
            label=IBus.Text.new_from_string("中英自動"),
            symbol=IBus.Text.new_from_string("自"),
            tooltip=IBus.Text.new_from_string("單按 Shift 切換英文模式"),
            sensitive=True, visible=True, state=IBus.PropState.UNCHECKED)
        # "AI 選字" menu: modes (radio), auto-pause (toggle), status, clear learned data.
        ai = shared_ai()
        self.ai_props = {}
        sub = IBus.PropList()
        for mode in MODES:
            prop = IBus.Property(
                key="ai." + mode, prop_type=IBus.PropType.RADIO,
                label=IBus.Text.new_from_string("AI 選字：" + MODE_NAMES[mode]),
                tooltip=IBus.Text.new_from_string(""), sensitive=True, visible=True,
                state=IBus.PropState.CHECKED if ai.reranker.mode == mode else IBus.PropState.UNCHECKED)
            self.ai_props[mode] = prop
            sub.append(prop)
        self.pause_prop = IBus.Property(
            key="ai.autopause", prop_type=IBus.PropType.TOGGLE,
            label=IBus.Text.new_from_string("系統忙碌時自動暫停 AI"),
            tooltip=IBus.Text.new_from_string(""), sensitive=True, visible=True,
            state=IBus.PropState.CHECKED if ai.auto_pause else IBus.PropState.UNCHECKED)
        self.status_prop = IBus.Property(
            key="ai.status", prop_type=IBus.PropType.NORMAL,
            label=IBus.Text.new_from_string(ai.status_text()),
            tooltip=IBus.Text.new_from_string(""), sensitive=False, visible=True,
            state=IBus.PropState.UNCHECKED)
        self.clear_prop = IBus.Property(
            key="clear", prop_type=IBus.PropType.NORMAL,
            label=IBus.Text.new_from_string("清除學習紀錄"),
            tooltip=IBus.Text.new_from_string(""), sensitive=True, visible=True,
            state=IBus.PropState.UNCHECKED)
        for prop in (self.pause_prop, self.status_prop, self.clear_prop):
            sub.append(prop)
        self.ai_menu = IBus.Property(
            key="ai", prop_type=IBus.PropType.MENU,
            label=IBus.Text.new_from_string("設定"),
            tooltip=IBus.Text.new_from_string("AI 選字與學習紀錄"),
            sensitive=True, visible=True, state=IBus.PropState.UNCHECKED, sub_props=sub)
        self.props = IBus.PropList()
        self.props.append(self.mode_prop)
        self.props.append(self.ai_menu)

    # --- keys ---

    def do_process_key_event(self, keyval, keycode, state):
        self._setup()
        released = bool(state & IBus.ModifierType.RELEASE_MASK)

        # Shift pressed and released alone: English mode (or flip the current word).
        if keyval in _SHIFT_KEYS:
            now = time.monotonic()
            if not released:
                if state & _SHORTCUT_MASK:
                    self.shift_tap.key_pressed()
                else:
                    self.shift_tap.shift_down(now)
                return False
            if self.shift_tap.shift_up(now):
                self.engine.handle(SHIFT_TAP)
                self._update(None)
                self._update_mode()
            return False
        if released:
            return False
        self.shift_tap.key_pressed()

        # Ctrl + ; ' , . / → full-width ；、，。？
        if state & _SHORTCUT_MASK == IBus.ModifierType.CONTROL_MASK:
            result = self.engine.handle_control(IBus.keyval_to_unicode(keyval))
            if result:
                self._update(result[1])
                return True

        # Shortcuts (Ctrl/Alt/Super) go to the app; commit any composition first.
        if state & _SHORTCUT_MASK:
            if self.engine.keys:
                self._update(self.engine.commit_all())
            return False

        key = self._key(keyval, state)
        if key is None:
            self.engine.forget_last_commit()
            return self._busy()   # swallow other keys (Delete, Home…) while composing
        # Tab right after a commit: retype it in the other mode, if it is still before the caret.
        if key == TAB and self._flip_last_commit():
            return True
        if not self.engine.wants(key):
            self.engine.forget_last_commit()
            return False
        handled, commit = self.engine.handle(key)
        self._update(commit)
        return handled

    def _key(self, keyval, state):
        if keyval in _SPECIAL:
            return _SPECIAL[keyval]
        if keyval == IBus.KEY_space:
            return " "
        code = IBus.keyval_to_unicode(keyval)
        if not code or not code.isprintable():
            return None
        # Caps Lock without Shift: keep Zhuyin working by using lowercase.
        if state & IBus.ModifierType.LOCK_MASK and not state & IBus.ModifierType.SHIFT_MASK:
            code = code.lower()
        return code

    def _flip_last_commit(self):
        old = self.engine.flippable_text
        if not old or not self._caps & IBus.Capabilite.SURROUNDING_TEXT:
            return False
        text, cursor, anchor = self.get_surrounding_text()
        if cursor != anchor or not text.get_text()[:cursor].endswith(old):
            return False
        new = self.engine.flip_last_commit()
        self.delete_surrounding_text(-len(old), len(old))
        self._update(new)
        return True

    def _busy(self):
        return bool(self.engine.keys or self.engine.candidates)

    # --- candidate panel (mouse) ---

    def do_candidate_clicked(self, index, button, state):
        self._update(self.engine.select_candidate(self.engine.page_start + index))

    def do_page_up(self):
        return self._move_candidate(-self.engine.page_size)

    def do_page_down(self):
        return self._move_candidate(self.engine.page_size)

    def do_cursor_up(self):
        return self._move_candidate(-1)

    def do_cursor_down(self):
        return self._move_candidate(1)

    def _move_candidate(self, delta):
        if not self.engine.candidates:
            return False
        e = self.engine
        e.candidate_index = max(0, min(len(e.candidates) - 1, e.candidate_index + delta))
        self._update(None)
        return True

    # --- settings menu ---

    def do_property_activate(self, prop_name, state):
        self._setup()
        ai = shared_ai()
        if prop_name.startswith("ai.") and prop_name[3:] in MODES:
            if state == IBus.PropState.CHECKED:
                ai.set_mode(prop_name[3:])
        elif prop_name == "ai.autopause":
            ai.set_auto_pause(state == IBus.PropState.CHECKED)
        elif prop_name == "clear":
            shared_classifier().learned.clear()
            shared_classifier().history.clear()
        self._refresh_ai_props()

    def _refresh_ai_props(self):
        ai = shared_ai()
        for mode, prop in self.ai_props.items():
            prop.set_state(IBus.PropState.CHECKED if ai.reranker.mode == mode else IBus.PropState.UNCHECKED)
            self.update_property(prop)
        self.pause_prop.set_state(IBus.PropState.CHECKED if ai.auto_pause else IBus.PropState.UNCHECKED)
        self.update_property(self.pause_prop)
        self.status_prop.set_label(IBus.Text.new_from_string(ai.status_text()))
        self.update_property(self.status_prop)

    # --- lifecycle ---

    def do_set_capabilities(self, caps):
        self._caps = caps

    def do_focus_in(self):
        self._setup()
        self.get_surrounding_text()   # IBus only sends the app's text once an engine asks
        self.register_properties(self.props)
        self._update_mode()
        self._refresh_ai_props()

    def do_focus_out(self):
        self._setup()
        # PreeditFocusMode.COMMIT: IBus commits the shown text itself on focus out.
        self.engine.reset()
        self.engine.forget_last_commit()
        self.hide_lookup_table()

    def do_reset(self):
        self._setup()
        self.engine.reset()
        self.engine.forget_last_commit()
        self.hide_preedit_text()
        self.hide_lookup_table()

    def do_disable(self):
        self.do_reset()

    # --- drawing ---

    def _update(self, commit):
        if commit:
            self.commit_text(IBus.Text.new_from_string(commit))
        pieces = self.engine.marked_pieces
        text = "".join(t for t, _ in pieces)
        if text:
            ibus_text = IBus.Text.new_from_string(text)
            attrs = IBus.AttrList()
            attrs.append(IBus.attr_underline_new(IBus.AttrUnderline.SINGLE, 0, len(text)))
            pos = 0
            for piece, mode in pieces:
                if mode == LITERAL and piece:
                    attrs.append(IBus.attr_foreground_new(_LITERAL_COLOR, pos, pos + len(piece)))
                pos += len(piece)
            ibus_text.set_attributes(attrs)
            self.update_preedit_text_with_mode(ibus_text, self.engine.cursor_offset, True,
                                               IBus.PreeditFocusMode.COMMIT)
        else:
            self.hide_preedit_text()

        if self.engine.candidates:
            self.table.clear()
            for _, candidate in self.engine.candidates:
                self.table.append_candidate(IBus.Text.new_from_string(candidate))
            self.table.set_cursor_pos(self.engine.candidate_index)
            self.update_lookup_table(self.table, True)
        else:
            self.hide_lookup_table()

    def _update_mode(self):
        english = self.engine.english_mode
        self.mode_prop.set_label(IBus.Text.new_from_string("英文" if english else "中英自動"))
        self.mode_prop.set_symbol(IBus.Text.new_from_string("英" if english else "自"))
        icon = os.path.join(HERE, "icon-en.png" if english else "icon.png")
        if os.path.exists(icon):
            self.mode_prop.set_icon(icon)      # panels that show property icons
        self.update_property(self.mode_prop)


# --- process setup ---

def make_component(exec_path):
    component = IBus.Component(
        name=BUS_NAME, description="自動注音 AutoZhuyin", version=VERSION,
        license="Private", author="AutoZhuyin", homepage="",
        command_line=f"{sys.executable} {exec_path} --ibus", textdomain="")
    icon = os.path.join(HERE, "icon.png")
    component.add_engine(IBus.EngineDesc(
        name=ENGINE_NAME, longname="自動注音", description="大千注音＋英文，自動判斷中英",
        language="zh_TW", license="Private", author="AutoZhuyin",
        icon=icon if os.path.exists(icon) else "", layout="us", symbol="自", rank=0))
    return component


def main(argv):
    IBus.init()
    bus = IBus.Bus()
    loop = GLib.MainLoop()
    started_by_ibus = "--ibus" in argv
    activate = "--activate" in argv
    factory = None

    def on_connected(*_):
        nonlocal factory
        factory = IBus.Factory.new(bus.get_connection())
        factory.add_engine(ENGINE_NAME, GObject.type_from_name("AutoZhuyinEngine"))
        if started_by_ibus:
            bus.request_name(BUS_NAME, 0)
        else:
            known = any(e.get_name() == ENGINE_NAME for e in bus.list_engines())
            if not known:
                bus.register_component(make_component(os.path.abspath(__file__)))
            if activate:
                bus.set_global_engine(ENGINE_NAME)

    def on_disconnected(*_):
        if started_by_ibus:
            loop.quit()
        # Otherwise wait: IBus.Bus reconnects (and emits "connected") when ibus-daemon restarts.

    bus.connect("connected", on_connected)
    bus.connect("disconnected", on_disconnected)
    shared_classifier()   # load data before the first key
    if bus.is_connected():
        on_connected()
    elif started_by_ibus:
        print("autozhuyin: cannot connect to ibus-daemon", file=sys.stderr)
        return 1
    loop.run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
