""""AI 選字" for the Windows and Linux shells: settings, background model loading,
system-load detection and the status line shown in the menu."""
import json
import os
import threading

from . import lm
from .reranker import (MODES, NORMAL, OFF, ST_ACTIVE, ST_BUSY, ST_LOADING, ST_OFF, ST_SLOW,
                       STANDARD, Reranker)
from .system_monitor import REDUCED, SystemMonitor

MODE_NAMES = {OFF: "關閉", "saver": "省電", STANDARD: "標準", "quality": "高品質"}


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
        self.reranker = Reranker(mode if mode in MODES else STANDARD)
        self.reranker.system_state = lambda: self.monitor.state() if self.auto_pause else NORMAL
        self.error = None      # why the model cannot be used, if it cannot
        self._loading = False
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
        data.update(ai_mode=self.reranker.mode, ai_auto_pause=self.auto_pause)
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
        else:
            self.load_model()
        self._save_settings()

    def set_auto_pause(self, on):
        self.auto_pause = bool(on)
        self._save_settings()

    # --- model ---

    def load_model(self):
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
        return "AI 使用中"
