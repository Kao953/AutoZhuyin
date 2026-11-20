"""Engine server for the stand-alone Windows text service (experimental, no PIME).

The TSF DLL (windows/tsf/src) loaded into each app only translates keys and draws; it
talks to this process over a per-user named pipe, \\\\.\\pipe\\AutoZhuyin-<user>, one
connection per text service instance. Started at sign-in (Run key) or by the DLL.

Protocol, UTF-8, one message each way:
  request   op [TAB arg]
            test <key> | key <key> | testctrl <c> | ctrl <c> | shift | select <i> | commit | reset
            | forget | flippable | flip
  reply     lines "name=value" (value with \\ and newlines escaped):
            handled, commit, preedit, cursor, cand (one per candidate on the page),
            candsel, english; for flippable: text
"test" of a key the engine doesn't take, and "forget" (a key the DLL passed on without
asking), end the chance to flip the last commit. Tab right after a commit: the DLL asks
"flippable", checks that text is right before the caret, then "flip" gives the
replacement in "commit".
Keys: one character, or BS ENTER ESC TAB UP DOWN LEFT RIGHT.
"""
import json
import os
import sys
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
_VENDOR = os.path.join(HERE, "autozhuyin", "vendor", "cp%d%d" % sys.version_info[:2])
if os.path.isdir(_VENDOR):
    sys.path.insert(0, _VENDOR)

from autozhuyin.core.ai import AI  # noqa: E402
from autozhuyin.core.classifier import Classifier, LearnedPreferences  # noqa: E402
from autozhuyin.core.engine import (BACKSPACE, DOWN, ENTER, ESCAPE, LEFT, RIGHT, SHIFT_TAP,  # noqa: E402
                                    TAB, UP, CompositionEngine)
from autozhuyin.core.english import EnglishModel  # noqa: E402
from autozhuyin.core.history import UserHistory  # noqa: E402
from autozhuyin.core.lexicon import Lexicon  # noqa: E402
from autozhuyin.core.user_phrases import UserPhrasesFile  # noqa: E402

DATA = os.path.join(HERE, "autozhuyin", "data")
USER_DIR = os.path.join(os.environ.get("APPDATA", HERE), "AutoZhuyin")
KEYS = {"BS": BACKSPACE, "ENTER": ENTER, "ESC": ESCAPE, "TAB": TAB,
        "UP": UP, "DOWN": DOWN, "LEFT": LEFT, "RIGHT": RIGHT}


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _saver(name):
    def save(data):
        try:
            os.makedirs(USER_DIR, exist_ok=True)
            with open(os.path.join(USER_DIR, name), "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
        except OSError:
            pass
    return save


def load_classifier():
    lexicon = Lexicon.from_file(os.path.join(DATA, "lexicon.txt"))
    english = EnglishModel.from_files(os.path.join(DATA, "english-common.txt"),
                                      os.path.join(DATA, "english-dict.txt"),
                                      os.path.join(DATA, "english-bigram.json"))
    learned = LearnedPreferences(_load_json(os.path.join(USER_DIR, "learned.json")), _saver("learned.json"))
    history = UserHistory(_load_json(os.path.join(USER_DIR, "user-history.json")), _saver("user-history.json"))
    weights = Classifier.load_weights(os.path.join(DATA, "classifier-weights.json"))
    return Classifier(lexicon, english, learned, weights, history)


def _escape(s):
    return s.replace("\\", "\\\\").replace("\n", "\\n")


class Session:
    """One text service instance (one app thread): its own composition engine."""

    def __init__(self, classifier, reranker=None):
        self.engine = CompositionEngine(classifier)
        self.engine.reranker = reranker

    def request(self, message):
        op, _, arg = message.partition("\t")
        e = self.engine
        if op == "test":
            wanted = e.wants(KEYS.get(arg, arg))
            if not wanted:
                e.forget_last_commit()
            return "handled=%d" % wanted
        if op == "forget":
            e.forget_last_commit()
            return "handled=0"
        if op == "flippable":
            return "text=" + _escape(e.flippable_text or "")
        if op == "testctrl":
            return "handled=%d" % (arg in (";", "'", ",", ".", "/"))
        if op == "key":
            handled, commit = e.handle(KEYS.get(arg, arg))
        elif op == "ctrl":
            handled, commit = e.handle_control(arg) or (False, None)
        elif op == "shift":
            handled, commit = e.handle(SHIFT_TAP)
        elif op == "select":
            handled, commit = True, e.select_candidate(e.page_start + int(arg))
        elif op == "flip":
            new = e.flip_last_commit()
            handled, commit = new is not None, new
        elif op == "commit":
            handled, commit = True, e.commit_all()
        elif op == "reset":
            e.reset()
            handled, commit = True, None
        else:
            return "handled=0"
        return self._reply(handled, commit)

    def _reply(self, handled, commit):
        e = self.engine
        lines = ["handled=%d" % bool(handled), "commit=" + _escape(commit or ""),
                 "preedit=" + _escape(e.marked_text), "cursor=%d" % e.cursor_offset,
                 "english=%d" % e.english_mode]
        if e.candidates:
            page, cursor = e.page()
            lines += ["cand=" + _escape(c) for c in page]
            lines.append("candsel=%d" % cursor)
        return "\n".join(lines)


def serve():
    from multiprocessing.connection import Listener
    user = os.environ.get("USERNAME", "user")
    try:
        listener = Listener(r"\\.\pipe\AutoZhuyin-" + user, family="AF_PIPE")
    except OSError:
        return   # another server already owns the pipe
    classifier = load_classifier()
    ai = AI(DATA, USER_DIR)
    # Hand edits to user-phrases.txt apply from the next key (a stat per key is cheap).
    phrases = UserPhrasesFile(os.path.join(USER_DIR, "user-phrases.txt"), classifier.lexicon)
    lock = threading.Lock()

    def run(conn):
        session = Session(classifier, ai.reranker)
        try:
            while True:
                message = conn.recv_bytes().decode("utf-8")
                with lock:
                    if phrases.reload_if_changed() is not None:
                        ai.reranker.clear_cache()
                    reply = session.request(message)
                conn.send_bytes(reply.encode("utf-8"))
        except (EOFError, OSError):
            pass
        finally:
            conn.close()

    while True:
        try:
            conn = listener.accept()
        except OSError:
            continue
        threading.Thread(target=run, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    try:
        serve()
    except Exception:
        # pythonw has no console: leave the reason where a tester can find it.
        import traceback
        os.makedirs(USER_DIR, exist_ok=True)
        with open(os.path.join(USER_DIR, "server-error.log"), "a", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        raise
