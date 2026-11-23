; Installer for the stand-alone text service (experimental, no PIME). Built by
; scripts/package-windows-standalone.sh:
;   makensis -INPUTCHARSET UTF8 -DVERSION=… -DSRC=<staged folder> -DLICENSE=<UTF-8 with BOM>
;            -DOUTFILE=… setup.nsi
; SRC holds x64\ and x86\AutoZhuyinTSF.dll, python\ (embeddable Python), server.py and
; autozhuyin\ (the engine and its data).
Unicode true
SetCompressor /SOLID lzma

!include "MUI2.nsh"
!include "LogicLib.nsh"
!include "x64.nsh"

!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\AutoZhuyinStandalone"
!define RUN_KEY "Software\Microsoft\Windows\CurrentVersion\Run"

Name "自動注音（獨立版） ${VERSION}"
OutFile "${OUTFILE}"
RequestExecutionLevel admin
InstallDir "$PROGRAMFILES64\AutoZhuyin"
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=1028 "ProductName" "自動注音（獨立版）"
VIAddVersionKey /LANG=1028 "FileDescription" "自動注音（獨立版）安裝程式"
VIAddVersionKey /LANG=1028 "FileVersion" "${VERSION}"
VIAddVersionKey /LANG=1028 "ProductVersion" "${VERSION}"
VIAddVersionKey /LANG=1028 "LegalCopyright" "GPL-3.0"

!define MUI_WELCOMEPAGE_TITLE "安裝自動注音（獨立版）"
!define MUI_WELCOMEPAGE_TEXT "這是不需要 PIME 的實驗版本，還沒在實機上完整測試過。$\r$\n$\r$\n它和 PIME 版的自動注音可以同時安裝，在鍵盤清單裡的名稱是「自動注音（獨立版）」。$\r$\n$\r$\n設定在工作列時鐘旁邊的「中／英」圖示上按右鍵；按一下切換英文模式。"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${LICENSE}"
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_TITLE "安裝完成"
!define MUI_FINISHPAGE_TEXT "到「設定 > 時間與語言 > 語言與地區 > 中文(台灣) > 語言選項 > 新增鍵盤」加入「自動注音（獨立版）」，再用 Win + 空白鍵 切換過去。設定選單在工作列「中／英」圖示上按右鍵。$\r$\n$\r$\n清單裡沒有的話，重新開機一次。"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "TradChinese"

Function .onInit
    ${IfNot} ${RunningX64}
    ${AndIfNot} ${IsNativeARM64}
        MessageBox MB_ICONSTOP|MB_OK "自動注音（獨立版）需要 64 位元的 Windows 10 / 11。"
        Abort
    ${EndIf}
    SetRegView 64
FunctionEnd

Function un.onInit
    SetRegView 64
FunctionEnd

; The engine server (pythonw.exe from this folder only; other Python programs keep running).
!macro StopServer
    nsExec::Exec `powershell -NoProfile -Command "Get-Process pythonw -ErrorAction SilentlyContinue | Where-Object { $$_.Path -eq '$INSTDIR\python\pythonw.exe' } | Stop-Process -Force"`
    Pop $0
!macroend

; The x86 DLL with the 32-bit regsvr32, the x64 one with the native one.
!macro RegsvrBoth flags
    ExecWait '"$SYSDIR\regsvr32.exe" ${flags} "$INSTDIR\x86\AutoZhuyinTSF.dll"'
    ${DisableX64FSRedirection}
    ExecWait '"$SYSDIR\regsvr32.exe" ${flags} "$INSTDIR\x64\AutoZhuyinTSF.dll"'
    ${EnableX64FSRedirection}
!macroend

; Apps that use the input method keep the DLL loaded, so it can't be overwritten: move the
; old one aside (allowed while loaded) and delete it at the next restart.
!macro MoveAsideLoadedDll arch
    ${If} ${FileExists} "$INSTDIR\${arch}\AutoZhuyinTSF.dll"
        Delete "$INSTDIR\${arch}\AutoZhuyinTSF.dll.old"
        Rename "$INSTDIR\${arch}\AutoZhuyinTSF.dll" "$INSTDIR\${arch}\AutoZhuyinTSF.dll.old"
        Delete /REBOOTOK "$INSTDIR\${arch}\AutoZhuyinTSF.dll.old"
    ${EndIf}
!macroend

Section "自動注音（獨立版）" SecMain
    SectionIn RO
    !insertmacro StopServer
    !insertmacro MoveAsideLoadedDll x64
    !insertmacro MoveAsideLoadedDll x86
    RMDir /r "$INSTDIR\autozhuyin"
    RMDir /r "$INSTDIR\python"

    SetOutPath "$INSTDIR"
    File /r "${SRC}\*.*"

    DetailPrint "註冊輸入法…"
    !insertmacro RegsvrBoth "/s"

    ; Start the engine server at sign-in (the DLL also starts it when it isn't running).
    WriteRegStr HKLM "${RUN_KEY}" "AutoZhuyinServer" '"$INSTDIR\python\pythonw.exe" "$INSTDIR\server.py"'

    WriteUninstaller "$INSTDIR\Uninstall.exe"
    WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "自動注音（獨立版）"
    WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
    WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "AutoZhuyin"
    WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\x64\AutoZhuyinTSF.dll"
    WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
    WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1
SectionEnd

; Optional: the 高品質 model, downloaded now (also from the input method's menu later).
Section /o "AI 高品質模型（下載約 200 MB）" SecLarge
    DetailPrint "下載 AI 高品質模型（約 200 MB），請稍候…"
    InitPluginsDir
    File "/oname=$PLUGINSDIR\get-lm-large.ps1" "../installer/get-lm-large.ps1"   ; relative to this script
    nsExec::ExecToLog 'powershell -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\get-lm-large.ps1" -Dir "$APPDATA\AutoZhuyin"'
    Pop $0
    ${If} $0 != 0
        MessageBox MB_ICONEXCLAMATION|MB_OK "AI 高品質模型下載失敗。$\r$\n之後可以在輸入法的設定選單裡選「下載高品質模型」再試一次。" /SD IDOK
    ${Else}
        !insertmacro StopServer   ; started again on next use, with the model
    ${EndIf}
SectionEnd

!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
    !insertmacro MUI_DESCRIPTION_TEXT ${SecMain} "輸入法本身（必要）。"
    !insertmacro MUI_DESCRIPTION_TEXT ${SecLarge} "AI 選字更準（錯字約少四成），但多佔約 400 MB 記憶體。勾選後會下載，並把 AI 選字設為「高品質」。之後也可以在輸入法選單下載或移除。"
!insertmacro MUI_FUNCTION_DESCRIPTION_END

Section "Uninstall"
    !insertmacro RegsvrBoth "/u /s"
    !insertmacro StopServer
    DeleteRegValue HKLM "${RUN_KEY}" "AutoZhuyinServer"
    DeleteRegKey HKLM "${UNINST_KEY}"
    Delete "$INSTDIR\Uninstall.exe"
    ; DLLs still loaded in running apps go at the next restart.
    RMDir /r /REBOOTOK "$INSTDIR"
    MessageBox MB_ICONINFORMATION|MB_OK "已移除自動注音（獨立版）。$\r$\n學習紀錄在 %APPDATA%\AutoZhuyin，可以手動刪除。" /SD IDOK
SectionEnd
