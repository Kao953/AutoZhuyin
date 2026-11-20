; One-step Windows installer: installs PIME (bundled, silently) if it isn't there yet,
; then AutoZhuyin as a PIME input method. Built by scripts/package-windows.sh:
;   makensis -INPUTCHARSET UTF8 -DVERSION=… -DSRC=<staged zip folder> -DPIME_SETUP=<PIME-…-setup.exe>
;            -DLICENSE=<license text, UTF-8 with BOM> -DOUTFILE=… setup.nsi
Unicode true
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

!define PIME "$PROGRAMFILES32\PIME"
!define IME_DIR "${PIME}\python\input_methods\autozhuyin"
!define UNINSTALLER "${PIME}\AutoZhuyin-Uninstall.exe"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\AutoZhuyin"

Name "自動注音 AutoZhuyin ${VERSION}"
OutFile "${OUTFILE}"
RequestExecutionLevel admin
InstallDir "${PIME}"
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=1028 "ProductName" "自動注音 AutoZhuyin"
VIAddVersionKey /LANG=1028 "FileDescription" "自動注音 AutoZhuyin 安裝程式"
VIAddVersionKey /LANG=1028 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=1028 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=1028 "LegalCopyright" "GPL-3.0"

!define MUI_WELCOMEPAGE_TITLE "安裝自動注音"
!define MUI_WELCOMEPAGE_TEXT "用大千注音鍵盤直接打字，不用切換中英文。$\r$\n$\r$\n自動注音需要 PIME 輸入法框架（免費、開源）。電腦上還沒有 PIME 的話，這個安裝程式會一起安裝。$\r$\n$\r$\n按「下一步」繼續。"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE}"
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TITLE "安裝完成"
!define MUI_FINISHPAGE_TEXT "到「設定 > 時間與語言 > 語言與地區 > 中文(台灣) > 語言選項 > 新增鍵盤」加入「自動注音 AutoZhuyin」，再用 Win + 空白鍵 切換過去。$\r$\n$\r$\n清單裡沒有的話，重新開機一次。"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "TradChinese"

Var InstalledPime

Function .onInit
    ${If} ${RunningX64}
    ${OrIf} ${IsNativeARM64}
        SetRegView 64
    ${EndIf}
FunctionEnd

Function un.onInit
    ${If} ${RunningX64}
    ${OrIf} ${IsNativeARM64}
        SetRegView 64
    ${EndIf}
FunctionEnd

; PIME registers every input_methods\*\ime.json when its text service DLLs are registered,
; so after adding or removing an input method: unregister, then register again.
!macro ReRegisterPime
    ExecWait '"$SYSDIR\regsvr32.exe" /u /s "${PIME}\x86\PIMETextService.dll"'
    ExecWait '"$SYSDIR\regsvr32.exe" /s "${PIME}\x86\PIMETextService.dll"'
    ${DisableX64FSRedirection}   ; $SYSDIR → the native System32 for the 64-bit DLLs
    ${If} ${FileExists} "${PIME}\x64\PIMETextService.dll"
        ExecWait '"$SYSDIR\regsvr32.exe" /u /s "${PIME}\x64\PIMETextService.dll"'
        ExecWait '"$SYSDIR\regsvr32.exe" /s "${PIME}\x64\PIMETextService.dll"'
    ${EndIf}
    ${If} ${FileExists} "${PIME}\arm64\PIMETextService.dll"
        ExecWait '"$SYSDIR\regsvr32.exe" /u /s "${PIME}\arm64\PIMETextService.dll"'
        ExecWait '"$SYSDIR\regsvr32.exe" /s "${PIME}\arm64\PIMETextService.dll"'
    ${EndIf}
    ${EnableX64FSRedirection}
!macroend

; Started through explorer.exe so it runs as the signed-in user, not as administrator.
!macro StartPimeLauncher
    Exec '"$WINDIR\explorer.exe" "${PIME}\PIMELauncher.exe"'
!macroend

Section "自動注音" SecMain
    SectionIn RO
    StrCpy $InstalledPime "0"

    ${IfNot} ${FileExists} "${PIME}\python\input_methods\*.*"
    ${AndIf} ${IsNativeARM64}
        ; The bundled PIME 1.3 has no ARM64 text service; PIME 2.x does.
        MessageBox MB_ICONINFORMATION|MB_OK "這台電腦是 ARM 處理器，需要 PIME 2.0 以上的版本。$\r$\n請先到 https://github.com/EasyIME/PIME/releases 下載安裝最新版 PIME，再執行一次這個安裝程式。"
        ExecShell "open" "https://github.com/EasyIME/PIME/releases"
        Abort
    ${EndIf}

    ${IfNot} ${FileExists} "${PIME}\python\input_methods\*.*"
        DetailPrint "安裝 PIME 輸入法框架…"
        InitPluginsDir
        File "/oname=$PLUGINSDIR\pime-setup.exe" "${PIME_SETUP}"
        ExecWait '"$PLUGINSDIR\pime-setup.exe" /S' $0
        ${If} $0 != 0
        ${OrIfNot} ${FileExists} "${PIME}\python\input_methods\*.*"
            MessageBox MB_ICONSTOP|MB_OK "PIME 安裝失敗（代碼 $0）。$\r$\n請到 https://github.com/EasyIME/PIME/releases 下載安裝 PIME 後，再執行一次這個安裝程式。"
            Abort
        ${EndIf}
        StrCpy $InstalledPime "1"
    ${EndIf}

    DetailPrint "安裝自動注音…"
    nsExec::Exec 'taskkill /f /im PIMELauncher.exe'
    Pop $0
    RMDir /r "${IME_DIR}"
    SetOutPath "${IME_DIR}"
    File /r "${SRC}\autozhuyin\*.*"

    ; PIME's silent install also adds its Chewing input method. It wasn't asked for here,
    ; so take it out again; only AutoZhuyin should show up in the keyboard list.
    ${If} $InstalledPime == "1"
        RMDir /r "${PIME}\python\input_methods\chewing"
    ${EndIf}

    DetailPrint "註冊輸入法…"
    !insertmacro ReRegisterPime
    !insertmacro StartPimeLauncher

    WriteUninstaller "${UNINSTALLER}"
    WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "自動注音 AutoZhuyin"
    WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
    WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "AutoZhuyin"
    WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "${IME_DIR}\icon.ico"
    WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"${UNINSTALLER}"'
    WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
    WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1
SectionEnd

Section "Uninstall"
    nsExec::Exec 'taskkill /f /im PIMELauncher.exe'
    Pop $0
    RMDir /r "${IME_DIR}"
    !insertmacro ReRegisterPime
    !insertmacro StartPimeLauncher
    Delete "${UNINSTALLER}"
    DeleteRegKey HKLM "${UNINST_KEY}"
    MessageBox MB_ICONINFORMATION|MB_OK "已移除自動注音。$\r$\n學習紀錄在 %APPDATA%\PIME\autozhuyin，可以手動刪除。$\r$\nPIME 輸入法框架沒有移除，不需要的話可以在「設定 > 應用程式」移除 PIME。" /SD IDOK
SectionEnd
