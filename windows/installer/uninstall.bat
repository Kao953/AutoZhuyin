@echo off
chcp 65001 >nul
setlocal

net session >nul 2>&1
if errorlevel 1 (
    echo 請在 uninstall.bat 上按右鍵，選「以系統管理員身分執行」。
    pause
    exit /b 1
)

set "PIME=%ProgramFiles(x86)%\PIME"
taskkill /f /im PIMELauncher.exe >nul 2>&1
if exist "%PIME%\python\input_methods\autozhuyin" rmdir /s /q "%PIME%\python\input_methods\autozhuyin"

rem Unregister all PIME input methods, then register the remaining ones again.
for %%A in (x86 x64 arm64) do (
    if exist "%PIME%\%%A\PIMETextService.dll" (
        regsvr32 /u /s "%PIME%\%%A\PIMETextService.dll"
        regsvr32 /s "%PIME%\%%A\PIMETextService.dll"
    )
)
explorer.exe "%PIME%\PIMELauncher.exe"

echo 已移除自動注音。學習紀錄在 %APPDATA%\PIME\autozhuyin，可以手動刪除。
pause
