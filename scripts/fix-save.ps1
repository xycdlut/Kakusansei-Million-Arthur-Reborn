param(
    [string]$Serial = '127.0.0.1:16416',
    [string]$Adb,
    [switch]$Ld,
    [int]$Index = 0,
    [string]$LdConsole,
    [string]$Backup,
    [string]$BgFrom = 'mainbg_70_sp',
    [string]$BgTo = 'mainbg_nn'
)

# Repairs the client save data that makes the game crash on entering the world.
#
# Symptom: save/appdata/save_appdata is all zero. During GLRenderer.nativeInitialize
# the client then deletes save/database/master_card while save_version still marks
# the card table as current, so it is never downloaded again. Card faces resolve to
# image/face/face_0 (nonexistent) and the texture loader aborts in
# GetObjectClass(null) -> data_app_native_crash on com.test.RooneyJActivity.
#
# Fix: push a non-zero save_appdata plus the master_* tables from the device
# backup. The backup's main background name is rewritten in place (same byte
# length, NUL padded) when it names a background the server does not ship.
#
# Two transports:
#   default : adb.exe -s <serial>       (pass -Adb; real device or any emulator)
#   -Ld     : ldconsole.exe adb --index <n> --command    (LDPlayer)
#
# ASCII-only source so Windows PowerShell 5.1 reads it safely.
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
if (-not $Backup) {
    $Backup = Join-Path $ProjectRoot 'base\140330\sdcard\Android\data\com.square_enix.million_cn\files\save'
}
if (-not (Test-Path -LiteralPath $Backup -PathType Container)) { throw "backup not found: $Backup" }

if ($Ld) {
    if (-not $LdConsole) {
        # LDPlayer 9 installs under <root>\installpath\dnplayer2; LDPlayer 4/5 use
        # <root>\installpath\leidian\LDPlayer<N>.
        foreach ($g in @('F:\Game\*\installpath\dnplayer2\ldconsole.exe',
                         'F:\Game\*\installpath\leidian\LDPlayer*\ldconsole.exe',
                         'F:\*\installpath\dnplayer2\ldconsole.exe',
                         'D:\*\installpath\dnplayer2\ldconsole.exe',
                         'F:\*\leidian\LDPlayer*\ldconsole.exe',
                         'D:\*\leidian\LDPlayer*\ldconsole.exe',
                         'D:\*\LDPlayer*\ldconsole.exe')) {
            $hit = Get-ChildItem -Path $g -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $LdConsole = $hit.FullName; break }
        }
    }
    if (-not $LdConsole) { throw "ldconsole.exe not found; pass -LdConsole <path>" }
    $Script:AdbPush  = { param($local, $remote) & $LdConsole adb --index $Index --command "push $local $remote" }
    $Script:AdbShell = { param($cmd) & $LdConsole adb --index $Index --command "shell $cmd" }
} else {
    # The emulator install dir is non-ASCII, so it cannot be globbed from an
    # ASCII-only script; pass -Adb explicitly.
    if (-not $Adb) { throw "adb.exe not found; pass -Adb <path>" }
    $Script:AdbPush  = { param($local, $remote) & $Adb -s $Serial push $local $remote }
    $Script:AdbShell = { param($cmd) & $Adb -s $Serial shell $cmd }
}

$package = 'com.square_enix.million_cn'
$remote  = "/sdcard/Android/data/$package/files/save"

# ---- stage everything in an ASCII temp dir (adb push mangles non-ASCII args) ----
$stage = Join-Path ([IO.Path]::GetTempPath()) "kakusan-fixsave-$PID"
New-Item -ItemType Directory -Path $stage -Force | Out-Null
try {
    $appdataSrc = Join-Path $Backup 'appdata'
    $dbSrc      = Join-Path $Backup 'database'
    New-Item -ItemType Directory -Path (Join-Path $stage 'appdata')  -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stage 'database') -Force | Out-Null

    $saveAppData = Join-Path $appdataSrc 'save_appdata'
    if (-not (Test-Path -LiteralPath $saveAppData -PathType Leaf)) { throw "missing $saveAppData" }

    $bytes = [IO.File]::ReadAllBytes($saveAppData)
    if (-not ($bytes | Where-Object { $_ -ne 0 } | Select-Object -First 1)) {
        throw "backup save_appdata is all zero; this backup cannot repair the client"
    }
    if ($BgTo.Length -gt $BgFrom.Length) { throw "-BgTo must not be longer than -BgFrom" }
    $from = [Text.Encoding]::ASCII.GetBytes($BgFrom)
    $to   = [byte[]]::new($from.Length)
    [Text.Encoding]::ASCII.GetBytes($BgTo).CopyTo($to, 0)
    $rewrote = 0
    for ($i = 0; $i -le $bytes.Length - $from.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $from.Length; $j++) { if ($bytes[$i + $j] -ne $from[$j]) { $match = $false; break } }
        if ($match) { $to.CopyTo($bytes, $i); $rewrote++ }
    }
    if ($rewrote) { Write-Host ("rewrote " + $BgFrom + " -> " + $BgTo + " (" + $rewrote + " place(s))") }
    [IO.File]::WriteAllBytes((Join-Path $stage 'appdata\save_appdata'), $bytes)

    foreach ($f in Get-ChildItem -LiteralPath $appdataSrc -File) {
        if ($f.Name -eq 'save_appdata') { continue }
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $stage "appdata\$($f.Name)") -Force
    }
    foreach ($f in Get-ChildItem -LiteralPath $dbSrc -File) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $stage "database\$($f.Name)") -Force
    }

    & $Script:AdbShell "am force-stop $package" | Out-Null
    & $Script:AdbShell "mkdir -p $remote/appdata $remote/database" | Out-Null

    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $stage 'appdata') -File) {
        & $Script:AdbPush $f.FullName "$remote/appdata/$($f.Name)" | Out-Null
        Write-Host ("pushed appdata/" + $f.Name)
    }
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $stage 'database') -File) {
        & $Script:AdbPush $f.FullName "$remote/database/$($f.Name)" | Out-Null
        Write-Host ("pushed database/" + $f.Name)
    }
}
finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "restored client save data from $Backup"
Write-Host 'start the client normally'
