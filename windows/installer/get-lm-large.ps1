# "AI 高品質模型" installer option (windows/installer/setup.nsi, windows/tsf/setup.nsi):
# downloads the 高品質 model to <Dir>\lm-large.bin, checks it, and sets AI 選字 to 高品質
# in <Dir>\settings.json. Exit code 0 = installed, 1 = failed (the menu can retry later).
param([Parameter(Mandatory = $true)][string]$Dir)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # the progress bar slows Invoke-WebRequest a lot
$Url = "https://github.com/Kao953/AutoZhuyin/releases/download/lm-large-v1/lm-large.bin"
$Sha256 = "0e376619d2d382b573406ce58beda871162c60541cbe7bdf306142228d230809"
$Dest = Join-Path $Dir "lm-large.bin"
$Part = "$Dest.part"
try {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $have = (Test-Path $Dest) -and ((Get-FileHash $Dest -Algorithm SHA256).Hash -eq $Sha256)
    if (-not $have) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Part -UseBasicParsing
        if ((Get-FileHash $Part -Algorithm SHA256).Hash -ne $Sha256) { throw "checksum" }
        Move-Item -Force $Part $Dest
    }
    # settings.json is read by Python's json module: write UTF-8 without a BOM.
    $settingsPath = Join-Path $Dir "settings.json"
    $settings = @{}
    if (Test-Path $settingsPath) {
        (Get-Content -Raw -Encoding UTF8 $settingsPath | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $settings[$_.Name] = $_.Value }
    }
    $settings["ai_mode"] = "quality"
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json))
    exit 0
} catch {
    Remove-Item -Force -ErrorAction SilentlyContinue $Part
    exit 1
}
