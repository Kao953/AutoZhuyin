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
rm -rf "$DEST"
mkdir -p "$DEST"
cp -R autozhuyin autozhuyin_ibus.py version.txt "$DEST/"
[ -f icon.png ] && cp icon.png "$DEST/"
[ -f THIRD_PARTY_LICENSES.txt ] && cp THIRD_PARTY_LICENSES.txt "$DEST/"
chmod +x "$DEST/autozhuyin_ibus.py"

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
