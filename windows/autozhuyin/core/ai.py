""""AI 選字" for the Windows and Linux shells: settings, background model loading,
system-load detection and the status line shown in the menu."""
import hashlib
import json
import os
import threading
import urllib.error
import urllib.request

from . import lm
from .reranker import (MODES, NORMAL, OFF, ST_ACTIVE, ST_BUSY, ST_LOADING, ST_OFF, ST_SLOW,
                       STANDARD, Reranker)
from .system_monitor import REDUCED, SystemMonitor

MODE_NAMES = {OFF: "關閉", "saver": "省電", STANDARD: "標準", "quality": "高品質"}

# The 高品質 model (gpt2-base, ~200 MB): downloaded on request, or by the installer when its
# option is checked, to <user dir>/lm-large.bin. It uses the bundled lm-vocab.txt.
LARGE_URL = "https://github.com/Kao953/AutoZhuyin/releases/download/lm-large-v1/lm-large.bin"
LARGE_SHA256 = "0e376619d2d382b573406ce58beda871162c60541cbe7bdf306142228d230809"
LARGE_SIZE_TEXT = "約 200 MB"


class AI:
    def __init__(self, data_dir, user_dir, monitor=None, background=True):
        self.model_path = os.path.join(data_dir, "lm.bin")
        self.vocab_path = os.path.join(data_dir, "lm-vocab.txt")
        self.settings_path = os.path.join(user_dir, "settings.json")
        self.monitor = monitor or SystemMonitor()
        self.background = background
        settings = self._load_settings()
        mode = settings.get("ai_mode", STANDARD)
        self.auto_pause = bool(settings.get("ai_auto_pause", True))
        # 要打聲調才出字, on unless turned off (not an AI setting, but kept in the same settings.json).
        self.require_tones = bool(settings.get("require_tones", True))
        self.show_emoji = bool(settings.get("show_emoji", True))   # 候選字顯示符號與 emoji
        self.reranker = Reranker(mode if mode in MODES else STANDARD)
        self.reranker.system_state = lambda: self.monitor.state() if self.auto_pause else NORMAL
        self.error = None      # why the model cannot be used, if it cannot
        self._loading = False
        self.large_path = os.path.join(user_dir, "lm-large.bin")
        self.large_error = None     # why the last download failed
        self.download_progress = None   # 0..1 while downloading
        self._cancel = False
        self._large_loading = False
        self.load_model()

    # --- settings ---

    def _load_settings(self):
        try:
            with open(self.settings_path, encoding="utf-8") as f:
                data = json.load(f)
                return data if isinstance(data, dict) else {}
        except (OSError, ValueError):
            return {}

    def _save_settings(self):
        data = self._load_settings()
        data.update(ai_mode=self.reranker.mode, ai_auto_pause=self.auto_pause, require_tones=self.require_tones,
                    show_emoji=self.show_emoji)
        try:
            os.makedirs(os.path.dirname(self.settings_path), exist_ok=True)
            with open(self.settings_path, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=1)
        except OSError:
            pass

    def set_mode(self, mode):
        if mode not in MODES:
            return
        self.reranker.mode = mode
        if mode == OFF:
            self.reranker.model = None    # free the memory
        if mode != "quality":
            self.reranker.large_model = None
        self.load_model()
        self._save_settings()

    def set_auto_pause(self, on):
        self.auto_pause = bool(on)
        self._save_settings()

    def set_require_tones(self, on):
        self.require_tones = bool(on)
        self._save_settings()

    def set_show_emoji(self, on):
        self.show_emoji = bool(on)
        self._save_settings()

    # --- model ---

    def load_model(self):
        self.load_large_model()
        if self.reranker.mode == OFF or self.reranker.model is not None or self._loading or self.error:
            return
        if not lm.available():
            self.error = "需要 numpy"
            return
        if not (os.path.exists(self.model_path) and os.path.exists(self.vocab_path)):
            self.error = "AI 模型未安裝"
            return
        self._loading = True

        def work():
            try:
                model = lm.GPT2LanguageModel(self.model_path, self.vocab_path)
            except Exception as e:   # noqa: BLE001 — any failure just disables AI
                self.error = f"AI 模型載入失敗：{e}"
                model = None
            self._loading = False
            if self.reranker.mode != OFF:
                self.reranker.model = model

        if self.background:
            threading.Thread(target=work, daemon=True).start()
        else:
            work()

    # --- 高品質 model ---

    @property
    def large_installed(self):
        return os.path.exists(self.large_path)

    def load_large_model(self):
        """Loads it in the background when 高品質 is on and the file is there."""
        if (self.reranker.mode != "quality" or self.reranker.large_model is not None or self._large_loading
                or not self.large_installed or not lm.available() or not os.path.exists(self.vocab_path)):
            return
        self._large_loading = True

        def work():
            try:
                model = lm.GPT2LanguageModel(self.large_path, self.vocab_path)
            except Exception:   # noqa: BLE001 — a broken file: remove it so it can be downloaded again
                model = None
                self.large_error = "高品質模型讀取失敗，請重新下載"
                try:
                    os.remove(self.large_path)
                except OSError:
                    pass
            self._large_loading = False
            if self.reranker.mode == "quality":
                self.reranker.large_model = model

        if self.background:
            threading.Thread(target=work, daemon=True).start()
        else:
            work()

    def download_large_model(self, on_done=None):
        """Downloads and checks the file in the background; `on_done()` afterwards."""
        if self.download_progress is not None:
            return
        self.large_error = None
        self.download_progress = 0.0
        self._cancel = False

        def work():
            part = self.large_path + ".part"
            try:
                os.makedirs(os.path.dirname(self.large_path), exist_ok=True)
                digest = hashlib.sha256()
                with urllib.request.urlopen(LARGE_URL, timeout=30) as resp, open(part, "wb") as out:
                    total = int(resp.headers.get("Content-Length") or 0)
                    done = 0
                    while not self._cancel:
                        chunk = resp.read(1 << 20)
                        if not chunk:
                            break
                        out.write(chunk)
                        digest.update(chunk)
                        done += len(chunk)
                        if total:
                            self.download_progress = done / total
                if self._cancel:
                    os.remove(part)
                elif digest.hexdigest() != LARGE_SHA256:
                    os.remove(part)
                    self.large_error = "下載的高品質模型不完整，請再試一次"
                else:
                    os.replace(part, self.large_path)
            except urllib.error.HTTPError as e:
                self.large_error = "下載失敗：伺服器上找不到高品質模型" if e.code == 404 else f"下載失敗（HTTP {e.code}）"
            except Exception as e:   # noqa: BLE001 — network or disk: report it in the menu
                self.large_error = f"下載失敗：{e}"
                try:
                    os.remove(part)
                except OSError:
                    pass
            self.download_progress = None
            self.load_large_model()
            if on_done:
                on_done()

        threading.Thread(target=work, daemon=True).start()

    def cancel_download(self):
        self._cancel = True

    def remove_large_model(self):
        self.reranker.large_model = None
        self.large_error = None
        try:
            os.remove(self.large_path)
        except OSError:
            pass

    def large_menu_text(self):
        """The menu item for the 高品質 model: what clicking it does."""
        if self.download_progress is not None:
            return f"高品質模型下載中 {int(self.download_progress * 100)}%（點一下取消）"
        if self.large_installed:
            return f"移除高品質模型（{LARGE_SIZE_TEXT}）"
        if self.large_error:
            return f"{self.large_error}（點一下重試）"
        return f"下載高品質模型（{LARGE_SIZE_TEXT}）"

    def large_menu_clicked(self, on_done=None):
        if self.download_progress is not None:
            self.cancel_download()
        elif self.large_installed:
            self.remove_large_model()
        else:
            self.download_large_model(on_done)

    def status_text(self):
        if self.error:
            return self.error
        self.reranker.effective_mode()   # refresh the status
        st = self.reranker.status
        if st == ST_OFF:
            return "AI 選字已關閉"
        if st == ST_LOADING:
            return "AI 模型載入中…"
        if st == ST_BUSY:
            return "AI 已暫停：系統忙碌或過熱"
        if st == ST_SLOW:
            return "AI 已暫停：運算太慢，一分鐘後再試"
        if st == ST_ACTIVE and self.auto_pause and self.monitor.state() == REDUCED:
            return "AI 使用中（省電模式）"
        if self.reranker.mode == "quality" and self.reranker.large_model is None:
            return "AI 使用中（高品質模型載入中…）" if self.large_installed else "AI 使用中（未下載高品質模型，同標準）"
        return "AI 使用中"
