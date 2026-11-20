#!/bin/bash
# Removes AutoZhuyin (自動注音) for the current user. Your learned corrections and
# user phrases in ~/.config/autozhuyin are kept (delete that folder to remove them).
set -uo pipefail

DEST="${XDG_DATA_HOME:-$HOME/.local/share}/autozhuyin"
AUTOSTART="${XDG_CONFIG_HOME:-$HOME/.config}/autostart/autozhuyin.desktop"
ENVD="${XDG_CONFIG_HOME:-$HOME/.config}/environment.d/autozhuyin.conf"

if command -v ibus >/dev/null 2>&1 && [ "$(ibus engine 2>/dev/null)" = "autozhuyin" ]; then
    ibus engine xkb:us::eng 2>/dev/null
fi
pkill -f "autozhuyin/autozhuyin_ibus.py" 2>/dev/null
rm -rf "$DEST" "$AUTOSTART" "$ENVD"   # IBus forgets the engine at the next sign-in
systemctl --user unset-environment IBUS_COMPONENT_PATH 2>/dev/null
rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/ibus/bus/registry"
echo "已移除自動注音。學習紀錄留在 ~/.config/autozhuyin，不需要可以自行刪除。"
