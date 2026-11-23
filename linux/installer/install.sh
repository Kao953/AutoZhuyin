#!/bin/bash
# Installs AutoZhuyin (自動注音) for the current user as an IBus input method.
# Nothing outside your home folder is touched, so it works on read-only systems
# (Bazzite, SteamOS, Fedora Atomic). No sudo needed.
set -euo pipefail
cd "$(dirname "$0")"

DEST="${XDG_DATA_HOME:-$HOME/.local/share}/autozhuyin"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
PY=/usr/bin/python3

echo "== 自動注音 AutoZhuyin 安裝 =="

# 1. IBus and its Python bindings must come with the system.
if ! command -v ibus >/dev/null 2>&1; then
    echo "找不到 IBus（ibus 指令）。這個系統沒有內建 IBus，自動注音目前只支援 IBus。" >&2
    exit 1
fi
if ! "$PY" -c 'import gi; gi.require_version("IBus", "1.0"); from gi.repository import IBus' 2>/dev/null; then
    echo "系統的 Python 缺少 IBus 模組（python3-gobject / IBus-1.0 typelib）。" >&2
    exit 1
fi

# 2. Copy the program.
pkill -f "autozhuyin/autozhuyin_ibus.py" 2>/dev/null || true
VENDOR_BACKUP=""
if [ -d "$DEST/vendor" ]; then      # keep numpy downloaded by an earlier install
    VENDOR_BACKUP="$(mktemp -d)"
    mv "$DEST/vendor" "$VENDOR_BACKUP/"
fi
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R autozhuyin autozhuyin_ibus.py phrase_editor.py version.txt tools "$DEST/"
for f in icon.png icon-en.png THIRD_PARTY_LICENSES.txt GPL-3.0.txt; do [ -f "$f" ] && cp "$f" "$DEST/"; done
[ -n "$VENDOR_BACKUP" ] && mv "$VENDOR_BACKUP/vendor" "$DEST/" && rmdir "$VENDOR_BACKUP"
chmod +x "$DEST/autozhuyin_ibus.py"

# 2b. numpy for "AI 選字": use the system's, or download the matching version from PyPI.
TAG="$("$PY" -c 'import sys; print("cp%d%d" % sys.version_info[:2])')"
if "$PY" -c 'import numpy' 2>/dev/null; then
    echo "AI 選字：使用系統的 numpy。"
elif [ -d "$DEST/vendor/$TAG/numpy" ]; then
    echo "AI 選字：使用先前下載的 numpy。"
else
    echo "AI 選字需要 numpy，正在從 PyPI 下載（約 15 MB）…"
    if ! "$PY" -I "$DEST/tools/fetch_numpy.py" "$DEST/vendor" auto auto; then
        echo "下載 numpy 失敗：輸入法照常可用，只是沒有 AI 選字。之後可以重新執行 install.sh。"
    fi
fi

# 2c. Optional: the "AI 選字" 高品質 model (~200 MB), also downloadable from the menu later.
#     install.sh --large-model / --no-large-model answers without asking.
LARGE_URL="https://github.com/Kao953/AutoZhuyin/releases/download/lm-large-v1/lm-large.bin"
LARGE_SHA256="0e376619d2d382b573406ce58beda871162c60541cbe7bdf306142228d230809"
USER_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autozhuyin"
LARGE="$USER_DIR/lm-large.bin"
WANT_LARGE=""
for arg in "$@"; do
    case "$arg" in
        --large-model) WANT_LARGE=y ;;
        --no-large-model) WANT_LARGE=n ;;
    esac
done
if [ -f "$LARGE" ]; then
    echo "AI 高品質模型：已安裝（可在輸入法的設定選單移除）。"
elif [ -z "$WANT_LARGE" ] && [ -t 0 ]; then
    echo "要下載 AI 高品質模型嗎？選字更準（錯字約少四成），但多佔約 400 MB 記憶體，下載約 200 MB。"
    read -r -p "之後也可以在輸入法的設定選單下載或移除。[y/N] " WANT_LARGE || WANT_LARGE=n
fi
case "$WANT_LARGE" in
    y|Y|yes|YES)
        echo "下載 AI 高品質模型…"
        mkdir -p "$USER_DIR"
        if { command -v curl >/dev/null 2>&1 && curl -fL --retry 2 -o "$LARGE.part" "$LARGE_URL"; } \
            || { command -v wget >/dev/null 2>&1 && wget -O "$LARGE.part" "$LARGE_URL"; }; then
            if [ "$(sha256sum "$LARGE.part" | cut -d' ' -f1)" = "$LARGE_SHA256" ]; then
                mv -f "$LARGE.part" "$LARGE"
                "$PY" -I - "$USER_DIR/settings.json" <<'PY'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, encoding="utf-8"))
except (OSError, ValueError):
    data = {}
data["ai_mode"] = "quality"
json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
                echo "AI 高品質模型已安裝，AI 選字設為「高品質」。"
            else
                echo "下載的檔案不完整，略過。之後可以在輸入法的設定選單再下載。"
            fi
        else
            echo "下載失敗，略過。之後可以在輸入法的設定選單再下載。"
        fi
        rm -f "$LARGE.part"
        ;;
esac

# 3. Tell IBus about the engine with a component file, so it knows it from startup (no
#    "configured input method doesn't exist" warning) and runs it itself when it is
#    selected, in the desktop and in game mode. IBus only reads the system folder (read-only
#    here) or IBUS_COMPONENT_PATH, so add ours to that for the user session, and drop IBus's
#    component cache so it is rebuilt. Takes effect at the next sign-in.
"$PY" "$DEST/autozhuyin_ibus.py" --write-component "$DEST/component/autozhuyin.xml"
ENVD="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d"
mkdir -p "$ENVD"
echo "IBUS_COMPONENT_PATH=/usr/share/ibus/component:$DEST/component" > "$ENVD/autozhuyin.conf"
systemctl --user set-environment "IBUS_COMPONENT_PATH=/usr/share/ibus/component:$DEST/component" 2>/dev/null
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/ibus/bus/registry"

# 4. Select it at sign-in.
mkdir -p "$AUTOSTART"
cat > "$AUTOSTART/autozhuyin.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=自動注音 AutoZhuyin
Comment=Selects the AutoZhuyin input method at sign-in
Exec=$PY $DEST/autozhuyin_ibus.py --activate
Icon=$DEST/icon.png
X-GNOME-Autostart-enabled=true
X-KDE-autostart-phase=2
NoDisplay=true
DESKTOP

# 5. Now as well. IBus reads component files only when it starts, and restarting it is not
#    safe (on KDE Wayland the IBus panel crashes and KWin doesn't start it again), so for
#    this session the engine registers itself at run time.
if pgrep -x ibus-daemon >/dev/null 2>&1; then
    nohup "$PY" "$DEST/autozhuyin_ibus.py" --activate >/dev/null 2>&1 &
    sleep 1
    echo "已啟動並切換到自動注音。"
else
    echo "IBus 目前沒有在執行，請照下面的步驟啟用 IBus 後登出再登入。"
fi

cat <<'MSG'

安裝完成。
- KDE（Bazzite / SteamOS 桌面模式）：系統設定 → 鍵盤 → 虛擬鍵盤，選「IBus Wayland」，
  按套用後登出再登入。之後每次登入都會自動切換到自動注音。
- 想暫時改回一般鍵盤：ibus engine xkb:us::eng ；切回自動注音：ibus engine autozhuyin
- 移除：執行 uninstall.sh
MSG
