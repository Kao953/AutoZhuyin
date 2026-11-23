"""Engine server for the stand-alone Windows text service (experimental, no PIME).

The TSF DLL (windows/tsf/src) loaded into each app only translates keys and draws; it
talks to this process over a per-user named pipe, \\\\.\\pipe\\AutoZhuyin-<user>, one
connection per text service instance. Started at sign-in (Run key) or by the DLL.

Protocol, UTF-8, one message each way:
  request   op [TAB arg]
            test <key> | key <key> | testctrl <c> | ctrl <c> | shift | select <i> | commit | reset
            | forget | flippable | flip | english | menu | command <id>
  reply     lines "name=value" (value with \\ and newlines escaped):
            handled, commit, preedit, cursor, cand (one per candidate on the page),
            candsel, english; for flippable: text; for menu: item (one per menu item,
            "<id> TAB <flags> TAB <text>", flags c = checked, d = disabled; an empty item is a
            separator); for command: message (to show briefly, may be empty)
"test" of a key the engine doesn't take, and "forget" (a key the DLL passed on without
asking), end the chance to flip the last commit. Tab right after a commit: the DLL asks
"flippable", checks that text is right before the caret, then "flip" gives the
replacement in "commit". "english" (the language bar button): English mode on/off,
committing the composition first. "menu" / "command" are the settings menu (core/menu.py)
of the language bar button.
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
from autozhuyin.core import loading, menu  # noqa: E402
from autozhuyin.core.history import UserHistory  # noqa: E402
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
    # Parsed data is cached in USER_DIR\cache (see core/loading.py): much faster at sign-in.
    timings = {}
    cache = os.path.join(USER_DIR, "cache")
    lexicon = loading.load_lexicon(DATA, cache, timings)
    english = loading.load_english(DATA, cache, timings)
    loading.log_timings(os.path.join(USER_DIR, "startup.log"), timings)
    learned = LearnedPreferences(_load_json(os.path.join(USER_DIR, "learned.json")), _saver("learned.json"))
    history = UserHistory(_load_json(os.path.join(USER_DIR, "user-history.json")), _saver("user-history.json"))
    weights = Classifier.load_weights(os.path.join(DATA, "classifier-weights.json"))
    return Classifier(lexicon, english, learned, weights, history)


def _escape(s):
    return s.replace("\\", "\\\\").replace("\n", "\\n")


class Session:
    """One text service instance (one app thread): its own composition engine. `ai` (the
    settings) and `phrases` (user-phrases.txt) are shared by all sessions."""

    def __init__(self, classifier, ai=None, phrases=None):
        self.classifier = classifier
        self.ai = ai
        self.phrases = phrases
        self.engine = CompositionEngine(classifier)
        self.engine.reranker = ai.reranker if ai else None

    def request(self, message):
        op, _, arg = message.partition("\t")
        e = self.engine
        if self.ai:
            e.require_tones = self.ai.require_tones   # the menu may have changed it in another app
        if op == "menu":
            return self._menu()
        if op == "command":
            return self._command(int(arg) if arg.isdigit() else -1)
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
        elif op == "english":
            commit = e.commit_all() if e.keys else None
            e.set_english_mode(not e.english_mode)
            handled = True
        elif op == "reset":
            e.reset()
            handled, commit = True, None
        else:
            return "handled=0"
        return self._reply(handled, commit)

    def _menu(self):
        lines = []
        for item in menu.items(self.ai) if self.ai else []:
            if not item:
                lines.append("item=")
                continue
            flags = ("c" if item.get("checked") else "") + ("" if item.get("enabled", True) else "d")
            lines.append("item=%d\t%s\t%s" % (item["id"], flags, _escape(item["text"])))
        lines.append("english=%d" % self.engine.english_mode)
        return "\n".join(lines)

    def _command(self, command_id):
        if not self.ai:
            return "handled=0"
        message, action = menu.run(self.ai, command_id, self.classifier)
        if action == menu.EDIT_PHRASES and self.phrases is not None:
            # From this process: the app the DLL runs in may not be allowed to start programs.
            os.startfile(self.phrases.ensure_exists())
        return "handled=1\nmessage=" + _escape(message or "")

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


# Who may open the pipe: this user (its SID filled in), SYSTEM, and apps running in an
# AppContainer (Microsoft Store apps, the Start menu search) at low integrity, which the
# default security of a pipe leaves out.
PIPE_SDDL = "D:(A;;GA;;;SY)(A;;GA;;;{user})(A;;GRGW;;;AC)(A;;GRGW;;;S-1-15-2-2)S:(ML;;NW;;;LW)"


def _user_sid():
    """The SID of the user running this process, as a string ("S-1-5-21-…")."""
    import ctypes
    from ctypes import wintypes
    advapi32, kernel32 = ctypes.windll.advapi32, ctypes.windll.kernel32
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    advapi32.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    advapi32.GetTokenInformation.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD,
                                             ctypes.POINTER(wintypes.DWORD)]
    advapi32.ConvertSidToStringSidW.argtypes = [wintypes.LPVOID, ctypes.POINTER(wintypes.LPWSTR)]
    kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    token = wintypes.HANDLE()
    if not advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), 0x0008, ctypes.byref(token)):   # TOKEN_QUERY
        raise OSError("OpenProcessToken")
    try:
        size = wintypes.DWORD()
        advapi32.GetTokenInformation(token, 1, None, 0, ctypes.byref(size))   # TokenUser
        buf = ctypes.create_string_buffer(size.value)
        if not advapi32.GetTokenInformation(token, 1, buf, size, ctypes.byref(size)):
            raise OSError("GetTokenInformation")
        sid = ctypes.cast(buf, ctypes.POINTER(wintypes.LPVOID))[0]   # TOKEN_USER.User.Sid
        text = wintypes.LPWSTR()
        if not advapi32.ConvertSidToStringSidW(sid, ctypes.byref(text)):
            raise OSError("ConvertSidToStringSidW")
        try:
            return text.value
        finally:
            kernel32.LocalFree(text)
    finally:
        kernel32.CloseHandle(token)


def _allow_app_containers():
    """Makes multiprocessing create its pipes with PIPE_SDDL. Best effort: without it the
    input method still works in ordinary apps."""
    import ctypes
    import _winapi
    from ctypes import wintypes
    from multiprocessing import connection

    class SECURITY_ATTRIBUTES(ctypes.Structure):
        _fields_ = [("nLength", wintypes.DWORD), ("lpSecurityDescriptor", wintypes.LPVOID),
                    ("bInheritHandle", wintypes.BOOL)]

    convert = ctypes.windll.advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW
    convert.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(wintypes.LPVOID), wintypes.LPVOID]
    convert.restype = wintypes.BOOL
    descriptor = wintypes.LPVOID()
    if not convert(PIPE_SDDL.format(user=_user_sid()), 1, ctypes.byref(descriptor), None):   # SDDL_REVISION_1
        return
    attributes = SECURITY_ATTRIBUTES(ctypes.sizeof(SECURITY_ATTRIBUTES), descriptor, False)

    def new_handle(self, first=False):   # PipeListener._new_handle with security attributes
        flags = _winapi.PIPE_ACCESS_DUPLEX | _winapi.FILE_FLAG_OVERLAPPED
        if first:
            flags |= _winapi.FILE_FLAG_FIRST_PIPE_INSTANCE
        return _winapi.CreateNamedPipe(
            self._address, flags,
            _winapi.PIPE_TYPE_MESSAGE | _winapi.PIPE_READMODE_MESSAGE | _winapi.PIPE_WAIT,
            _winapi.PIPE_UNLIMITED_INSTANCES, connection.BUFSIZE, connection.BUFSIZE,
            _winapi.NMPWAIT_WAIT_FOREVER, ctypes.addressof(attributes))

    new_handle.attributes = attributes   # keep them alive with the method
    connection.PipeListener._new_handle = new_handle


def serve():
    from multiprocessing.connection import Listener
    user = os.environ.get("USERNAME", "user")
    try:
        _allow_app_containers()
    except Exception:   # noqa: BLE001 — ordinary apps work without it
        pass
    try:
        listener = Listener(r"\\.\pipe\AutoZhuyin-" + user, family="AF_PIPE")
    except OSError:
        return   # another server already owns the pipe
    classifier = load_classifier()
    loading.freeze_gc()
    ai = AI(DATA, USER_DIR)
    # Hand edits to user-phrases.txt apply from the next key (a stat per key is cheap).
    phrases = UserPhrasesFile(os.path.join(USER_DIR, "user-phrases.txt"), classifier.lexicon)
    lock = threading.Lock()

    def run(conn):
        session = Session(classifier, ai, phrases)
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
