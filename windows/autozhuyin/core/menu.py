"""The settings menu of the Windows shells: the PIME text service (autozhuyin_ime.py) and
the stand-alone one (tsf/server.py, drawn by the TSF DLL). Both show the same items."""
from .ai import MODE_NAMES
from .reranker import MODES

ID_AUTO_PAUSE, ID_STATUS, ID_CLEAR, ID_EDIT_PHRASES, ID_REQUIRE_TONES, ID_LARGE_MODEL = 2, 3, 4, 5, 6, 7
ID_SHOW_EMOJI = 8
ID_AI_MODE = {mode: 10 + i for i, mode in enumerate(MODES)}   # 10..13

# What a command needs the shell to do besides changing a setting.
EDIT_PHRASES, REQUIRE_TONES_CHANGED = "edit-phrases", "require-tones"


def items(ai):
    """[{"text", "id", "checked", "enabled"}], {} for a separator (PIME's menu format)."""
    out = [{"text": "AI 選字：" + MODE_NAMES[m], "id": ID_AI_MODE[m], "checked": ai.reranker.mode == m}
           for m in MODES]
    out += [
        {"text": ai.large_menu_text(), "id": ID_LARGE_MODEL},
        {},
        {"text": "系統忙碌時自動暫停 AI", "id": ID_AUTO_PAUSE, "checked": ai.auto_pause},
        {"text": ai.status_text(), "id": ID_STATUS, "enabled": False},
        {},
        {"text": "要打聲調才出字", "id": ID_REQUIRE_TONES, "checked": ai.require_tones},
        {"text": "候選字顯示 emoji", "id": ID_SHOW_EMOJI, "checked": ai.show_emoji},
        {"text": "編輯自訂詞…", "id": ID_EDIT_PHRASES},
        {"text": "清除學習紀錄", "id": ID_CLEAR},
    ]
    return out


def run(ai, command_id, classifier):
    """Carries out a menu command. Returns (message to show or None, action for the shell
    or None)."""
    for mode, cid in ID_AI_MODE.items():
        if command_id == cid:
            ai.set_mode(mode)
            return "AI 選字：" + MODE_NAMES[mode], None
    if command_id == ID_LARGE_MODEL:
        downloading = ai.download_progress is not None
        ai.large_menu_clicked()
        if not downloading and ai.download_progress is not None:
            return "開始下載高品質模型，完成後自動使用（選單可看進度）", None
        return None, None
    if command_id == ID_AUTO_PAUSE:
        ai.set_auto_pause(not ai.auto_pause)
    elif command_id == ID_REQUIRE_TONES:
        ai.set_require_tones(not ai.require_tones)
        return None, REQUIRE_TONES_CHANGED
    elif command_id == ID_SHOW_EMOJI:
        ai.set_show_emoji(not ai.show_emoji)
    elif command_id == ID_EDIT_PHRASES:
        return None, EDIT_PHRASES
    elif command_id == ID_CLEAR:
        classifier.learned.clear()
        classifier.history.clear()
        return "已清除學習紀錄", None
    return None, None
