#!/bin/bash
# Cross-compiles the stand-alone Windows text service (windows/tsf/src, experimental)
# with mingw-w64 (brew install mingw-w64) into build/tsf/{x64,x86}/AutoZhuyinTSF.dll.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=windows/tsf/src
for arch in x64 x86; do
    case $arch in
        x64) cc=x86_64-w64-mingw32 ;;
        x86) cc=i686-w64-mingw32 ;;
    esac
    out=build/tsf/$arch
    mkdir -p "$out"
    # The icon comes from the PIME package build (scripts/package-windows.sh renders it).
    cp windows/autozhuyin/icon.ico windows/autozhuyin/icon-en.ico "$out/"
    "$cc-windres" -I "$out" "$SRC/AutoZhuyinTSF.rc" -O coff -o "$out/resource.o"
    "$cc-g++" -std=c++17 -O2 -Wall -Wextra -Wno-unused-parameter -Wno-missing-field-initializers \
        -D_WIN32_WINNT=0x0A00 -DUNICODE -D_UNICODE -shared -static -static-libgcc -static-libstdc++ \
        -o "$out/AutoZhuyinTSF.dll" "$SRC"/*.cpp "$out/resource.o" "$SRC/AutoZhuyinTSF.def" -Wl,--kill-at -Wl,--enable-stdcall-fixup \
        -lole32 -loleaut32 -luuid -ladvapi32 -luser32 -lgdi32
    "$cc-strip" "$out/AutoZhuyinTSF.dll"
    rm "$out/resource.o" "$out/icon.ico" "$out/icon-en.ico"
done
ls -l build/tsf/*/AutoZhuyinTSF.dll
