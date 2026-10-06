param(
    [string]$Adb,
    [string]$Serial = 'emulator-5554',
    [string]$Source,
    [switch]$SkipVerify
)

# Stages the client's whole local data tree onto the device.
#
# WHY THIS STEP EXISTS
#   The client keeps 500+ MB of resources under
#   /sdcard/Android/data/<pkg>/files/save/ and NEVER pulls them from the server:
#   the CDN router is there (/contents/), but measured over a whole session the
#   request log contains ZERO /contents/ fetches - the only "contents" hits are
#   the gacha/select/getcontents API. The client reads its local mirror and
#   nothing else, and scripts\start-game-ld.ps1 runs the server with
#   --suppress-revisions (the client's pack downloader SIGSEGVs), so it will not
#   fill the gap either.
#
#   Net effect: a device without this tree renders without images/sounds, or
#   crashes. A fresh LDPlayer instance has no files/save directory at all, so
#   this must run before the first launch.
#
#   The source is the retail client dump from com.square_enix.million_cn-140330.zip
#   (fetched by scripts\fetch-base.ps1, extracted to base\140330\).
#
#   scripts\install-client-patched.ps1 also needs this tree: it parks and
#   restores it around the reinstall so the data survives.
#
# ASCII-only functional content: Windows PowerShell 5.1 reads .ps1 without a BOM
# as ANSI, so non-ASCII inside strings/paths would be corrupted. The LDPlayer
# directory name is non-ASCII, which is why adb is found by wildcard glob.
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Pkg = 'com.square_enix.million_cn'
$DevSave = "/data/media/0/Android/data/$Pkg/files/save"

if (-not $Source) {
    $Source = Join-Path $ProjectRoot 'base\140330\sdcard\Android\data\com.square_enix.million_cn\files\save'
}
if (-not (Test-Path -LiteralPath (Join-Path $Source 'download') -PathType Container)) {
    throw "source is not a client save tree (no download/): $Source"
}

# LDPlayer can be installed anywhere, so find its adb by search rather than by
# guessing drive-letter globs. Any adb.exe works for install/push, so a
# standalone one on PATH is accepted too.
. (Join-Path $PSScriptRoot 'find-ldplayer.ps1')
if (-not $Adb -or -not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    $ld = Find-LdPlayer -Hint $Adb
    if ($ld -and $ld.Adb) { $Adb = $ld.Adb }
}
if (-not $Adb -or -not (Test-Path -LiteralPath $Adb -PathType Leaf)) { $Adb = Find-AdbAnywhere }
if (-not $Adb -or -not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    throw 'adb.exe not found; pass -Adb <path> (any adb.exe works)'
}

# adb prints progress lines to stderr, and under
# $ErrorActionPreference='Stop' ANY stderr output from a native command is
# promoted to a terminating error - so a *successful* push would abort the
# script. `2>&1` alone does not prevent it; the preference has to be relaxed
# around the call. Both wrappers below do that.
function A {
    param([string]$C)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return ((& $Adb -s $Serial shell $C 2>&1) | Out-String) }
    finally { $ErrorActionPreference = $prev }
}

function Push([string]$Local, [string]$Remote) {
    # adb push prints one line per file: keep only the summary, otherwise a
    # 6900-file run buries everything else in the console.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Adb -s $Serial push $Local $Remote 2>&1 |
            Where-Object { $_ -match 'files? (pushed|skipped)|KB/s|error|failed|denied' } |
            ForEach-Object { Write-Host ("  " + $_) }
    } finally { $ErrorActionPreference = $prev }
}

Write-Host "adb    : $Adb"
Write-Host "source : $Source"
if ((A 'echo ok') -notmatch 'ok') { throw "no device at $Serial (start the emulator first)" }

# ---- 1. the client must be down, or it will delete what we stage -----------
Write-Host 'stopping client'
A "am force-stop $Pkg" | Out-Null

# ---- 2. clean the old mirror ----------------------------------------------
# A stale file is worse than a missing one: the client renders it and the server
# has no idea. The correct target path includes download/ - an earlier ad-hoc
# run pushed everything to .../save/image/... (missing a level) and the game
# still looked empty.
Write-Host 'clearing the old tree'
A "su 0 rm -rf $DevSave/download $DevSave/database" | Out-Null
A "su 0 mkdir -p $DevSave/download $DevSave/database $DevSave/appdata" | Out-Null

# ---- 3. push --------------------------------------------------------------
# appdata/save_appdata is deliberately NOT pushed here: start-game-ld.ps1 seeds
# it from the same dump with one byte-string rewritten (mainbg_70_sp ->
# mainbg_nn) and then locks it read-only. Pushing the raw dump first would only
# be overwritten a moment later.
Write-Host 'pushing download/ (500+ MB, this takes a few minutes)'
Push (Join-Path $Source 'download') "$DevSave/download"

Write-Host 'pushing database/'
Push (Join-Path $Source 'database') "$DevSave/database"

Write-Host 'pushing appdata/save_version'
Push (Join-Path $Source 'appdata\save_version') "$DevSave/appdata/save_version"

# ---- 4. make everything readable by the app -------------------------------
# adb push arrives as root:root 644. The game reads through the FUSE view as its
# own uid, which works for read-only content, but the client also likes to be
# able to rewrite a resource it re-renders, and the retail dump is 666/777.
Write-Host 'fixing permissions'
# adb push lands as root:root 644; the retail dump is 666 on files and 777 on
# directories. 777 everywhere is a superset of that, and an executable bit on
# data files is harmless - what matters is that the game can always read them.
A "su 0 chmod -R 777 $DevSave/download $DevSave/database $DevSave/appdata" | Out-Null

# ---- 5. verify ------------------------------------------------------------
if (-not $SkipVerify) {
    Write-Host 'verifying'
    # The 140330 dump carries the splash/adv resources that the running client
    # had already partially pruned, so the counts are not expected to match
    # exactly - report both and only fail on a gross shortfall.
    $want = (Get-ChildItem -LiteralPath (Join-Path $Source 'download') -Recurse -File).Count
    $got = (A "su 0 find $DevSave/download -type f | wc -l").Trim()
    Write-Host "  download files: local=$want device=$got"
    if ([int]$got -lt ($want * 0.95)) {
        Write-Warning '  device has far fewer files than the source; the push may have been cut short'
    }
    $want2 = (Get-ChildItem -LiteralPath (Join-Path $Source 'database') -Recurse -File).Count
    $got2 = (A "su 0 find $DevSave/database -type f | wc -l").Trim()
    Write-Host "  database files: local=$want2 device=$got2"

    # spot-check content, not just counts
    $sample = @(
        'download/rest/rja_gac_lakeball',
        'download/rest/gac_lake02.png',
        'download/rest/exp_get',
        'download/sound/bgm_common1.ogg'
    )
    foreach ($rel in $sample) {
        $local = Join-Path $Source ($rel -replace '/', '\')
        if (-not (Test-Path -LiteralPath $local)) { continue }
        $wantMd5 = (Get-FileHash -LiteralPath $local -Algorithm MD5).Hash.ToLower()
        $gotMd5 = (A "su 0 md5sum $DevSave/$rel").Trim().Split(' ')[0]
        # 5.1 has no inline if-expression, so build the mark in a plain branch.
        $mark = 'MISMATCH'
        if ($wantMd5 -eq $gotMd5) { $mark = 'ok' }
        Write-Host ("  {0,-42} {1}" -f $rel, $mark)
    }
}

Write-Host ''
Write-Host 'save tree staged. Next:'
Write-Host '  scripts\start-game-ld.ps1      (starts emulator + server, locks master_card and appdata, launches)'
