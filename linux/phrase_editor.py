#!/usr/bin/python3
"""User phrase editor for the IBus version ("編輯自訂詞…" in the IBus menu): a GTK 3
window, run as its own process so it can be typed into with AutoZhuyin itself.
Same behavior as the Mac editor (Sources/AutoZhuyin/PhraseEditor.swift): every change
is saved to user-phrases.txt at once, and the engine reloads the file on the next focus.

    phrase_editor.py <user-phrases.txt> <lexicon.txt>
"""
import os
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from autozhuyin.core.lexicon import Lexicon  # noqa: E402
from autozhuyin.core.user_phrases import DEFAULT_SCORE, Entry, UserPhrases, problem, reading_from_typed  # noqa: E402

HINT = "打好詞會自動填入常用讀音，可以再修改。選字時自訂詞會排在最前面。"


def spaced(reading):
    """"ㄗˋ-ㄉㄨㄥˋ" → "ㄗˋ ㄉㄨㄥˋ", easier to read and edit."""
    return reading.replace("-", " ")


class PhraseEditor(Gtk.Window):
    def __init__(self, path, lexicon_path):
        super().__init__(title="自動注音：自訂詞")
        self.path = path
        self.lexicon = Lexicon.from_file(lexicon_path)
        try:
            with open(path, encoding="utf-8-sig") as f:
                self.phrases = UserPhrases(f.read())
        except OSError:
            self.phrases = UserPhrases()
        self.lexicon.set_user_phrases(self.phrases.text)
        self.reading_is_suggested = False

        self.set_default_size(520, 460)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=16)
        self.add(box)

        row = Gtk.Box(spacing=8)
        self.phrase_entry = Gtk.Entry(placeholder_text="詞，例如：自動注音", width_chars=14)
        self.reading_entry = Gtk.Entry(placeholder_text="注音：ㄗˋ ㄉㄨㄥˋ… 或大千鍵位 y42j/4…", hexpand=True)
        add = Gtk.Button(label="加入")
        self.phrase_entry.connect("changed", self.on_phrase_changed)
        self.reading_entry.connect("changed", lambda *_: setattr(self, "reading_is_suggested", False))
        for widget in (self.phrase_entry, self.reading_entry):
            widget.connect("activate", self.on_add)
        add.connect("clicked", self.on_add)
        row.pack_start(self.phrase_entry, False, False, 0)
        row.pack_start(self.reading_entry, True, True, 0)
        row.pack_start(add, False, False, 0)
        box.pack_start(row, False, False, 0)

        self.message = Gtk.Label(label=HINT, xalign=0)
        box.pack_start(self.message, False, False, 0)

        self.store = Gtk.ListStore(str, str)
        self.view = Gtk.TreeView(model=self.store)
        self.view.get_selection().set_mode(Gtk.SelectionMode.MULTIPLE)
        for column, title in enumerate(("詞", "注音")):
            cell = Gtk.CellRendererText(editable=True)
            cell.connect("edited", self.on_cell_edited, column)
            self.view.append_column(Gtk.TreeViewColumn(title, cell, text=column))
        scroll = Gtk.ScrolledWindow(vexpand=True)
        scroll.add(self.view)
        box.pack_start(scroll, True, True, 0)

        bottom = Gtk.Box(spacing=8)
        self.remove_button = Gtk.Button(label="刪除", sensitive=False)
        self.remove_button.connect("clicked", self.on_remove)
        self.view.get_selection().connect(
            "changed", lambda sel: self.remove_button.set_sensitive(sel.count_selected_rows() > 0))
        folder = Gtk.Button(label="打開所在資料夾")
        folder.connect("clicked", self.on_open_folder)
        bottom.pack_start(self.remove_button, False, False, 0)
        bottom.pack_end(folder, False, False, 0)
        box.pack_start(bottom, False, False, 0)

        self.reload_view()
        self.connect("destroy", Gtk.main_quit)

    # --- messages ---

    def show_hint(self, text=HINT):
        self.message.set_markup(GLib.markup_escape_text(text))

    def show_problem(self, text):
        self.message.set_markup('<span foreground="red">%s</span>' % GLib.markup_escape_text(text))
        Gtk.Widget.error_bell(self)

    # --- editing ---

    def on_phrase_changed(self, entry):
        if not self.reading_entry.get_text() or self.reading_is_suggested:
            reading = self.lexicon.reading_of(entry.get_text().strip())
            self.reading_entry.set_text(spaced(reading) if reading else "")
            self.reading_is_suggested = True   # set after set_text: "changed" clears it

    def entry_from(self, phrase, typed, score):
        """The entry typed in, or None after showing what's wrong."""
        phrase = phrase.strip()
        reading = reading_from_typed(typed)
        if reading is None and typed.strip():
            self.show_problem("看不懂這個注音：%s" % typed)
            return None
        reading = reading or ""
        why = problem(phrase, reading)
        if why:
            self.show_problem(why)
            return None
        return Entry(phrase, reading, score)

    def on_add(self, *_):
        new = self.entry_from(self.phrase_entry.get_text(), self.reading_entry.get_text(), DEFAULT_SCORE)
        if new is None:
            return
        for i, e in enumerate(self.phrases.entries):
            if e.phrase == new.phrase and e.reading == new.reading:
                self.show_problem("已經有「%s」了" % new.phrase)
                self.select(i)
                return
        self.phrases.append(new)
        self.save()
        self.select(len(self.phrases.entries) - 1)
        self.phrase_entry.set_text("")
        self.reading_entry.set_text("")
        self.reading_is_suggested = False
        self.show_hint("已加入「%s」" % new.phrase)
        self.phrase_entry.grab_focus()

    def on_cell_edited(self, cell, path, text, column):
        row = int(path)
        old = self.phrases.entries[row]
        new = self.entry_from(text if column == 0 else old.phrase,
                              text if column == 1 else old.reading, old.score)
        if new is None:
            return   # the cell keeps the old value
        if new != old:
            self.phrases.replace(row, new)
            self.save()
        self.show_hint()

    def on_remove(self, *_):
        _, paths = self.view.get_selection().get_selected_rows()
        for path in sorted((p.get_indices()[0] for p in paths), reverse=True):
            self.phrases.remove(path)
        self.save()

    def on_open_folder(self, *_):
        if not os.path.exists(self.path):
            self.save()
        Gtk.show_uri_on_window(self, "file://" + os.path.dirname(self.path), Gtk.get_current_event_time())

    def select(self, row):
        self.view.get_selection().unselect_all()
        self.view.get_selection().select_path(Gtk.TreePath.new_from_indices([row]))
        self.view.scroll_to_cell(Gtk.TreePath.new_from_indices([row]), None, False, 0, 0)

    def reload_view(self):
        self.store.clear()
        for e in self.phrases.entries:
            self.store.append([e.phrase, spaced(e.reading)])

    def save(self):
        self.reload_view()
        self.lexicon.set_user_phrases(self.phrases.text)
        try:
            os.makedirs(os.path.dirname(self.path), exist_ok=True)
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(self.phrases.text)
            os.replace(tmp, self.path)
        except OSError as e:
            self.show_problem("無法儲存：%s" % e)


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    window = PhraseEditor(argv[0], argv[1])
    window.show_all()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
