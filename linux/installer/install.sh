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

# 3. Start with the desktop session: registers the engine with IBus and selects it.
mkdir -p "$AUTOSTART"
cat > "$AUTOSTART/autozhuyin.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=自動注音 AutoZhuyin
Comment=Registers the AutoZhuyin input method with IBus
Exec=$PY $DEST/autozhuyin_ibus.py --activate
Icon=$DEST/icon.png
X-GNOME-Autostart-enabled=true
X-KDE-autostart-phase=2
NoDisplay=true
DESKTOP

# 4. Start it now as well.
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
