@echo off
chcp 65001 >nul
setlocal

net session >nul 2>&1
if errorlevel 1 (
    echo 請在 install.bat 上按右鍵，選「以系統管理員身分執行」。
    pause
    exit /b 1
)

set "PIME=%ProgramFiles(x86)%\PIME"
if not exist "%PIME%\python\input_methods" (
    echo 找不到 PIME。請先安裝 PIME：
    echo https://github.com/EasyIME/PIME/releases
    pause
    exit /b 1
)

echo 正在安裝自動注音...
taskkill /f /im PIMELauncher.exe >nul 2>&1

set "DEST=%PIME%\python\input_methods\autozhuyin"
if exist "%DEST%" rmdir /s /q "%DEST%"
robocopy "%~dp0autozhuyin" "%DEST%" /E /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 (
    echo 複製檔案失敗。
    pause
    exit /b 1
)

rem Registering PIME scans input_methods\*\ime.json and adds AutoZhuyin to Windows.
if exist "%PIME%\x86\PIMETextService.dll" regsvr32 /s "%PIME%\x86\PIMETextService.dll"
if exist "%PIME%\x64\PIMETextService.dll" regsvr32 /s "%PIME%\x64\PIMETextService.dll"
if exist "%PIME%\arm64\PIMETextService.dll" regsvr32 /s "%PIME%\arm64\PIMETextService.dll"

rem Start PIMELauncher as the normal (non-admin) user.
explorer.exe "%PIME%\PIMELauncher.exe"

echo.
echo 安裝完成！
echo 到「設定 > 時間與語言 > 語言與地區 > 中文(台灣) > 語言選項 > 新增鍵盤」
echo 加入「自動注音 AutoZhuyin」，再用 Win+空白鍵 切換過去。
echo 如果清單裡沒有，請重新開機一次。
pause
