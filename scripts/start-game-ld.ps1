param(
    # -1 = auto-detect the LDPlayer instance that is already running. The
    # instance number is NOT stable between sessions, so do not hardcode one.
    [int]$Index = -1,
    [string]$LdConsole,
    [string]$HostAddr,
    [switch]$FixSave,
    [switch]$NoLaunch,
    # Advertise revisions / run the tutorial. Both are OFF by default because
    # the client's CDN pack updater SIGSEGVs in ResourceDownloader::
    # parseMasterScolTagData, and the tutorial script loader crashes too.
    [switch]$WithRevisions,
    [switch]$WithTutorial,
    # Open the back-office console (http://127.0.0.1:26031/) in a browser.
    [switch]$Admin,
    # Skip pinning save/database/master_card. Only useful when deliberately
    # reproducing the card-collection crash; those screens SIGSEGV without it.
    [switch]$NoLockMasterCard,
    # Keep the window open after an error so the message can be read.
    [switch]$Pause
)

# One-click preflight + launch for LDPlayer (雷电模拟器).
#
# Measured on this box:
#
#   - LDPlayer instance 0 is already connected as emulator-5554; no adb connect.
#     Extra instances take 5557, 5559, ...
#   - Android 5.1.1 / SDK 22 with abilist x86,armeabi-v7a,armeabi - friendly to
#     this old 32-bit client. (The script prints the device's real values below;
#     an older note here claimed 7.1.2, which never matched what this box
#     reports.)
#   - Management CLI is ldconsole.exe.
#   - THE IMPORTANT ONE: the device sits on 172.16.1.0/24 and cannot reach the
#     qemu-style NAT gateway. 10.0.2.2 times out and 172.16.1.1 answers
#     "No route to host". Only the host's own LAN IPv4 works, so the server
#     must advertise the LAN address and the proxy must point at it. That
#     address is detected below - never hardcode one, it differs per machine.
#   - A fresh LDPlayer has no files/save directory at all, so the repaired save
#     data can be staged before the very first launch.
#   - Reachability probe uses curl, not toybox nc: Android 5.1.1 images here have
#     no toybox, and a missing binary would otherwise look like "reachable".
#
# ASCII-only source so Windows PowerShell 5.1 reads it safely.
$ErrorActionPreference = 'Stop'

trap {
    Write-Host ''
    Write-Host ('FAILED: ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    }
    if ($Pause) { Read-Host 'press Enter to close' | Out-Null }
    exit 1
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ServerRoot  = Join-Path $ProjectRoot 'kakusansei-ma-ch-main\server'
$Resources   = Join-Path $ProjectRoot 'runtime\resource-set'
$Data        = Join-Path $ProjectRoot 'runtime\data'
$Bin         = Join-Path $ServerRoot 'dist\kakusan-server.exe'
$package     = 'com.square_enix.million_cn'

# ---- 0. locate ldconsole.exe (the install path contains non-ASCII text) ----
# LDPlayer may be installed anywhere; scripts\find-ldplayer.ps1 checks the
# running process, its uninstall registry entry, then every fixed drive.
. (Join-Path $PSScriptRoot 'find-ldplayer.ps1')
if (-not $LdConsole -or -not (Test-Path -LiteralPath $LdConsole -PathType Leaf)) {
    $ld = Find-LdPlayer -Hint $LdConsole
    if ($ld) {
        $LdConsole = $ld.LdConsole
        Write-Host ('ldplayer: ' + $ld.Via)
    }
}
if (-not $LdConsole -or -not (Test-Path -LiteralPath $LdConsole -PathType Leaf)) {
    throw "ldconsole.exe not found; pass -LdConsole <path> (the LDPlayer install folder)"
}
if (-not (Test-Path -LiteralPath $Bin -PathType Leaf)) {
    throw ("server binary missing: $Bin" +
           " - re-download the release, or build it yourself with the Go toolchain (see README 3.4)")
}
if (-not (Test-Path -LiteralPath (Join-Path $Resources 'resource-set.json'))) {
    throw ("resource-set is missing from $Resources - re-extract the release over this directory" +
           " (do not delete runtime\resource-set), then run install-all.ps1")
}
Write-Host ("ldconsole: " + $LdConsole)

# Every adb call is wrapped in a job with a hard timeout. Routing a command
# through ldconsole can hang forever (wait-for-device never returns, and a
# dropped adb transport can block a shell call), and a hung helper used to
# leave the script and the test loop spinning with no way out.
function Invoke-Ld([string]$cmd, [int]$TimeoutSec = 30) {
    $job = Start-Job -ScriptBlock {
        param($exe, $idx, $c)
        & $exe adb --index $idx --command $c 2>&1
    } -ArgumentList $LdConsole, $Index, $cmd
    if (-not (Wait-Job $job -Timeout $TimeoutSec)) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Write-Warning ("adb command timed out after ${TimeoutSec}s: " + $cmd)
        return ''
    }
    $out = Receive-Job $job
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return ($out -join "`n")
}

# ---- 1. make sure the instance is up ----
# Re-read the instance list every run: which one is up changes from session to
# session (#0 today, #2 tomorrow), so -1 (the default) just takes the first one
# that is already running.
function Get-LdInstances {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($line in (& $LdConsole list2 2>$null)) {
            $f = $line.Trim().Split(',')
            if ($f.Count -ge 5 -and $f[0] -match '^\d+$') {
                [pscustomobject]@{ Index = [int]$f[0]; Running = ($f[4] -eq '1') }
            }
        }
    } finally { $ErrorActionPreference = $prev }
}
function Test-LdUp([int]$Idx) {
    return (@(Get-LdInstances | Where-Object { $_.Index -eq $Idx -and $_.Running }).Count -gt 0)
}

if ($Index -lt 0) {
    $up = @(Get-LdInstances | Where-Object { $_.Running } | ForEach-Object { $_.Index })
    if ($up.Count -gt 0) {
        $Index = $up[0]
        Write-Host ("ldplayer: auto-detected running instance " + $Index + " (running: " + ($up -join ', ') + ")")
        if ($up.Count -gt 1) {
            Write-Warning ("several LDPlayer instances are running (" + ($up -join ', ') + "); using " + $Index)
        }
    } else {
        $known = @(Get-LdInstances | ForEach-Object { $_.Index })
        if ($known.Count -gt 0) { $Index = $known[0] } else { $Index = 0 }
        Write-Host ("ldplayer: nothing running - starting instance " + $Index)
    }
}
if (-not (Test-LdUp $Index)) {
    Write-Host "starting LDPlayer instance $Index ..."
    & $LdConsole launch --index $Index | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 3
        if (Test-LdUp $Index) { break }
    }
}
if (-not (Test-LdUp $Index)) { throw "LDPlayer instance $Index did not start" }

# Informational only. Every real command below goes through ldconsole's own adb
# channel (`ldconsole adb --index N`), so it always reaches THIS instance no
# matter what else is attached to the adb server. "devices" here reports the
# whole adb server, so take the first match and do not read it as "our device".
$dev = ''
foreach ($line in (Invoke-Ld 'devices') -split "`n") {
    if ($line -match '^(\S+)\s+device$') { $dev = $Matches[1]; break }
}
if (-not $dev) { throw "no adb device reachable from LDPlayer instance $Index" }
Write-Host ("device: " + $dev)

$rel = (Invoke-Ld 'shell getprop ro.build.version.release').Trim()
$abi = (Invoke-Ld 'shell getprop ro.product.cpu.abilist').Trim()
Write-Host ("android " + $rel + " abilist " + $abi)
if ($abi -notmatch 'armeabi') { Write-Warning "no armeabi support; the game cannot run here" }
if (-not (Invoke-Ld "shell pm list packages $package")) { Write-Warning "$package is not installed" }

# ---- 2. candidate host addresses the device might reach ----
# Test-Reach fetches the server banner, so it only works once the server is up.
function Test-Reach([string]$addr) {
    $r = Invoke-Ld "shell curl -s -m 5 -o /data/local/tmp/kakusan-probe.txt -w %{http_code} http://${addr}:50005/"
    $r = $r.Trim()
    if ($r -match 'not found') { return $false }   # curl missing -> inconclusive
    return ($r -match '200')
}

$cands = @()
if ($HostAddr) {
    $cands += $HostAddr
} else {
    $cands += Get-NetIPAddress -AddressFamily IPv4 |
              Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
              Select-Object -ExpandProperty IPAddress
    $cands += '10.0.2.2'
    $devIp = (Invoke-Ld 'shell ip -f inet addr show') -join "`n"
    if ($devIp -match 'inet\s+(\d+)\.(\d+)\.(\d+)\.\d+/') { $cands += "$($Matches[1]).$($Matches[2]).$($Matches[3]).2" }
    $cands = $cands | Sort-Object -Unique
}
if ($cands.Count -eq 0) { throw "no candidate host address; pass -HostAddr <ip>" }

# ---- 3. start the server, provisionally advertising the first candidate ----
$RawMaster = Join-Path $ProjectRoot 'base\140330\sdcard\Android\data\com.square_enix.million_cn\files\save\database'

# Paths for the master_card lock in step 7b. The seed is the exact table the
# reference project accepts (480 cards, sha256 pinned); the same constants live
# in scripts\lock-mastercard.sh, which applies the identical device state.
$SeedMaster    = Join-Path $RawMaster 'master_card'
$SeedMasterSha = '7b121de5626dd3b9820022c698a1ff754f87cac4b64e563b70138f68b3a56bdf'
$DevSeed       = '/data/local/tmp/master_card.seed'
$DevDbFuse     = "/sdcard/Android/data/$package/files/save/database"
$DevDbRaw      = "/data/media/0/Android/data/$package/files/save/database"

# ---- the save database runs in SQLite WAL mode ----
#
# store.Open sets _pragma=journal_mode(WAL), so every committed write lands in
# game.sqlite-wal first and only reaches game.sqlite when SQLite checkpoints.
# DELETING THE WAL DESTROYS THOSE WRITES. Measured on this box: an admin edit
# that set gold=444444 was absent from the main file (still 25000) and vanished
# completely once the WAL was removed. That is exactly why back-office edits
# "did not take effect": this script used to force-kill the server and then
# delete game.sqlite-wal, so anything written since the last checkpoint - admin
# edits and in-game progress alike - was rolled back on the next launch.
#
# Keeping the WAL is correct and safe: SQLite replays it on open. Verified - the
# server read gold=444444 straight out of the WAL and was healthy in 1s. The old
# note claiming a leftover WAL "makes the server hang silently on boot" did not
# reproduce.
#
# So: never delete the sidecars. If the server somehow refuses to start, rename
# them aside (the data stays on disk for manual recovery) and retry once.
function Stop-Server {
    $procs = Get-Process -Name kakusan-server -ErrorAction SilentlyContinue
    if (-not $procs) { return }
    # Ask nicely first, so the server's deferred db.Close() runs and SQLite
    # checkpoints the WAL into the main file. A minimized console app usually
    # ignores CloseMainWindow, so this is best-effort; the kill below is the norm.
    foreach ($p in $procs) { try { $null = $p.CloseMainWindow() } catch { } }
    for ($i = 0; $i -lt 6; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Name kakusan-server -ErrorAction SilentlyContinue)) { return }
    }
    Get-Process -Name kakusan-server -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
}

function Start-ServerOnce([string[]]$argv) {
    Start-Process -FilePath $Bin -ArgumentList $argv -WorkingDirectory $ServerRoot -WindowStyle Minimized
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        try {
            Invoke-RestMethod -Uri 'http://127.0.0.1:26031/healthz' -TimeoutSec 3 | Out-Null
            return $true
        } catch { }
    }
    return $false
}

function Start-Server([string]$base) {
    Stop-Server
    $argv = @(
        '--resources', $Resources,
        '--data', $Data,
        '--listen', ':50005',
        '--base-url', $base,
        '--request-log', (Join-Path $ProjectRoot 'runtime\requests.jsonl'),
        '--admin-listen', '127.0.0.1:26031'
    )
    if (Test-Path -LiteralPath $RawMaster) { $argv += @('--raw-master', $RawMaster) }
    if (-not $WithRevisions) { $argv += '--suppress-revisions' }
    if (-not $WithTutorial)  { $argv += '--skip-tutorial' }
    Write-Host ("starting server with base url " + $base)
    if (Start-ServerOnce $argv) { return }

    # Start-ServerOnce already spent 20s waiting. Before giving up, rename the
    # sidecars aside - never delete - so the next attempt reads the main file
    # alone, then try once more.
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $moved = @()
    foreach ($f in 'game.sqlite-wal', 'game.sqlite-shm', 'game.sqlite-journal') {
        $src = Join-Path $Data $f
        if (Test-Path -LiteralPath $src) {
            Move-Item -LiteralPath $src -Destination ($src + '.orphan-' + $stamp) -Force -ErrorAction SilentlyContinue
            $moved += $f
        }
    }
    if ($moved.Count -eq 0) {
        throw "server did not become healthy; run it in the foreground to see the error"
    }
    Write-Warning ("server unhealthy with " + ($moved -join ', ') + " present; renamed them aside (data kept) and retrying")
    Stop-Server
    if (Start-ServerOnce $argv) { return }
    throw ("server still not healthy after quarantining " + ($moved -join ', ') + "; run it in the foreground to see the error")
}

Start-Server ("http://" + $cands[0] + ":50005")

# ---- 4. probe from the device now that something is listening ----
$chosen = $null
foreach ($c in $cands) {
    Write-Host ("probing " + $c + " ...")
    if (Test-Reach $c) { $chosen = $c; break }
}
if (-not $chosen) {
    $chosen = $cands[0]
    Write-Warning ("device could not fetch ${chosen}:50005; keeping it - check the android proxy and the firewall")
} else {
    Write-Host ("reachability: OK (" + $chosen + ":50005)")
}
if ($chosen -ne $cands[0]) { Start-Server ("http://" + $chosen + ":50005") }

$BaseURL = "http://${chosen}:50005"
$proxy   = "${chosen}:50005"
Write-Host ("server up, base url (device-reachable): " + $BaseURL)

# ---- 5. hijack the hardcoded game domain ----
#
# The client posts to http://dlc.game-CBT.ma.sdo.com:50005, and that name still
# resolves to a retired SDO address (121.4.186.15) from the emulator's DNS. Two
# independent levers are needed:
#
#   - /system/etc/hosts  - covers every absolute lookup. REQUIRED: with the
#     domain pointed anywhere else the client shows "cannot connect to server"
#     and emits no request at all, so nothing arrives to diagnose.
#   - global http_proxy  - REQUIRED TOO. Measured here: with hosts alone the
#     client stays silent; add the proxy and check_inspection /
#     post_devicetoken / login appear immediately. The client's HTTP stack does
#     consult the system proxy, so both are set rather than choosing one.
#
# The port matters as much as the name: the client hardcodes 50005, which is on
# the 5000+ range that the APK expects, hence the server listens there too.
$domains = @('dlc.game-CBT.ma.sdo.com', 'game-CBT.ma.sdo.com')
# LDPlayer ships an already-rooted adbd, and /system is read-only until it is
# remounted. Do NOT insert `adb wait-for-device` here: routed through ldconsole
# it never returns, and the script hangs before it ever reaches the launch
# step. A plain sleep covers the adbd restart that `root` may trigger.
Write-Host '  enabling root + remounting /system ...'
Invoke-Ld 'root' | Out-Null
Start-Sleep -Seconds 3
Invoke-Ld 'remount' | Out-Null

$keep = (Invoke-Ld "shell grep -v 'sdo.com' /system/etc/hosts") -split "`n" |
        ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
$lines = @($keep) + ($domains | ForEach-Object { "$chosen $_" })
$blob  = ([Text.Encoding]::ASCII.GetBytes(($lines -join "`n") + "`n"))
$b64   = [Convert]::ToBase64String($blob)
# base64 keeps the payload free of quoting and newline hazards on the shell.
Invoke-Ld "shell echo $b64 | busybox base64 -d > /system/etc/hosts" | Out-Null
Invoke-Ld 'shell chmod 644 /system/etc/hosts' | Out-Null
Write-Host 'android hosts:'
Invoke-Ld 'shell cat /system/etc/hosts' | ForEach-Object { Write-Host ("  " + $_) }

# ---- 6. point the device at it ----
Invoke-Ld "shell settings put global http_proxy $proxy" | Out-Null
Write-Host ("android http_proxy = " + $proxy)

# ---- 7. optional save-data repair ----
if ($FixSave) {
    & (Join-Path $PSScriptRoot 'fix-save.ps1') -Ld -Index $Index -LdConsole $LdConsole
}

# ---- 7b. pin save/database/master_card for the whole client session ----
#
# The client reads save/database/master_card once during startup and then
# unlinks it: the packaged file is a one-shot preload that the resource
# bootstrap consumes, not a persistent cache. Reference:
#   ref/KSSMA-Re-main/work/mumu-a12-master-card-launch-seed-card-20260819.md
#
# On this Android 5.1.1 image the unlink wins the race, so CCardManager commits
# an empty table and every card lookup returns a null smart_ptr.
# _CardCollectionAdapter::createFaceCard then calls _Card::getCountryId with
# this == NULL, and that function's first instruction is `ldr r2,[r0,#8]` -
# exactly the tombstones' "Fatal signal 11 ... fault addr 0x8". The same empty
# table reaches _RecycleShopAdapter::createFaceCard, so the card-collection and
# synthesize/sell screens die the same way. Pin the file and both render.
#
# Measured subtleties, all of which this function encodes:
#   - Only the mode on the backing ext4 path (/data/media/0/...) takes effect.
#     chown/chmod through the FUSE view (/sdcard/...) are not honoured, and the
#     FUSE view keeps reporting its own synthesized owner.
#   - 444 on the backing file is enough on its own: it is world-readable, so the
#     ownership of the copy does not matter. The chown below only mirrors the
#     bash script; the lock works whether or not it succeeds.
#   - The directory, not the file, is the lever: 555 on it denies the unlink.
#   - The client must be force-stopped first; a live process would simply delete
#     the file again on its next launch.
#   - A single-file bind mount over master_card does NOT work: the client needs
#     to consume (unlink) it and aborts at startup instead.
function Lock-MasterCard {
    if ($NoLockMasterCard) {
        Write-Host 'master_card lock: SKIPPED (-NoLockMasterCard) - card screens will SIGSEGV'
        return
    }
    if (-not (Test-Path -LiteralPath $SeedMaster -PathType Leaf)) {
        Write-Warning ("master_card seed missing: " + $SeedMaster + " - card screens will SIGSEGV")
        return
    }
    $hostSha = (Get-FileHash -LiteralPath $SeedMaster -Algorithm SHA256).Hash.ToLower()
    if ($hostSha -ne $SeedMasterSha) {
        Write-Warning ("seed is not the accepted 480-card table (host sha256 " + $hostSha + "); skipping lock")
        return
    }

    Write-Host 'locking save/database/master_card ...'

    # The client is what unlinks the file, so it has to be down first.
    Invoke-Ld "shell am force-stop $package" | Out-Null
    Start-Sleep -Seconds 2

    # Stage the seed once per device. /data/local/tmp lives on the data
    # partition, so it survives emulator restarts and later boots skip the push.
    $staged = (Invoke-Ld "shell su 0 sha256sum $DevSeed" -TimeoutSec 20).Trim()
    if ($staged -notmatch $SeedMasterSha) {
        Write-Host '  staging seed on device ...'
        Invoke-Ld "push $SeedMaster $DevSeed" -TimeoutSec 60 | ForEach-Object { Write-Host ("  " + $_) }
    }

    # Reopen the directory so the copy can land, then close it again below.
    Invoke-Ld "shell su 0 chmod 775 $DevDbRaw" | Out-Null
    Invoke-Ld "shell su 0 cp $DevSeed $DevDbFuse/master_card" | Out-Null
    Invoke-Ld "shell su 0 chown --reference=$DevDbFuse/master_boss $DevDbFuse/master_card" | Out-Null
    Invoke-Ld "shell su 0 chmod 660 $DevDbFuse/master_card" | Out-Null

    # Verify before locking: chmod 555 below would make a silent bad copy stick.
    $got = (Invoke-Ld "shell su 0 sha256sum $DevDbFuse/master_card").Trim()
    if ($got -notmatch $SeedMasterSha) {
        Write-Warning ("master_card copy failed (device reports: " + $got + "); left the directory writable")
        return
    }

    Invoke-Ld "shell su 0 chmod 444 $DevDbRaw/master_card" | Out-Null
    Invoke-Ld "shell su 0 chmod 555 $DevDbRaw" | Out-Null

    $dirMode = (Invoke-Ld "shell su 0 ls -ld $DevDbRaw").Trim()
    if ($dirMode -notmatch '^dr-xr-xr-x') {
        Write-Warning ("master_card seeded but the directory is still writable: " + $dirMode)
    } else {
        Write-Host '  locked: master_card survives the run; card screens are safe'
    }
}

Lock-MasterCard

# ---- 7c. seed + lock save/appdata/save_appdata (this is what turns the audio on) ----
#
# Symptom: the game has no BGM and no SE at all, host volume and in-game options
# notwithstanding. Root cause: the client truncates save/appdata/save_appdata to
# 2849 zero bytes on every launch, and an ALL-ZERO appdata is what mutes the
# game. Measured on this box:
#
#   all-zero, writable   -> audio_flinger shows the client's live track at -inf dB
#   nonzero, read-only   -> the same track reads -6.9 dB, mediaserver holds an
#                           open fd on .../sound/bgm_common1.ogg, BGM is audible
#
# The seed is the factory dump under base\140330 with mainbg_70_sp rewritten to
# mainbg_nn (equal length, NUL padded) because the server ships mainbg_nn and not
# mainbg_70_sp. sha256 db44109d... is the accepted value; the file also carries
# the autologin phone/password (18770350589 / tyu135wq) at 0x124/0x164.
#
# Read-only is REQUIRED, not a nicety: if the file is writable the client zeroes
# it at the next launch and the sound is gone again. The cost is one EACCES line
# in the client log for the write it attempts, measured harmless - the card box,
# gacha, synthesis and battle screens all render and the BGM keeps playing.
# Do NOT lock save_version: it sits in the same directory and is left alone.
$SeedAppDataSha = 'db44109d9921dade9390a2a29dd2a809000646e9a0601f56413df51ff844e706'

function New-AppDataSeed {
    # Rebuild the seed from the factory dump so this script stays self-contained.
    $src = Join-Path $ProjectRoot 'base\140330\sdcard\Android\data\com.square_enix.million_cn\files\save\appdata\save_appdata'
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { return $null }
    $bytes = [IO.File]::ReadAllBytes($src)
    if (-not ($bytes | Where-Object { $_ -ne 0 } | Select-Object -First 1)) { return $null }
    $from = [Text.Encoding]::ASCII.GetBytes('mainbg_70_sp')
    $to   = [byte[]]::new($from.Length)
    [Text.Encoding]::ASCII.GetBytes('mainbg_nn').CopyTo($to, 0)
    for ($i = 0; $i -le $bytes.Length - $from.Length; $i++) {
        $hit = $true
        for ($j = 0; $j -lt $from.Length; $j++) { if ($bytes[$i + $j] -ne $from[$j]) { $hit = $false; break } }
        if ($hit) { $to.CopyTo($bytes, $i) }
    }
    $stage = Join-Path ([IO.Path]::GetTempPath()) "kakusan-appdata-seed-$PID"
    [IO.File]::WriteAllBytes($stage, $bytes)
    return $stage
}

function Lock-AppData {
    $DevAppData = "/data/media/0/Android/data/$package/files/save/appdata"
    $DevSeed2   = '/data/local/tmp/save_appdata.seed'

    $stage = New-AppDataSeed
    if (-not $stage -or -not (Test-Path -LiteralPath $stage -PathType Leaf)) {
        # Fall back to the byte-for-byte artifact captured from a working device.
        $stage = Join-Path $ProjectRoot 'runtime\verify-pull\appdata_save_appdata'
        if (-not (Test-Path -LiteralPath $stage -PathType Leaf)) {
            Write-Warning 'appdata seed unavailable - the client will run with NO BGM/SE'
            return
        }
    }
    $sha = (Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash.ToLower()
    if ($sha -ne $SeedAppDataSha) {
        Write-Warning ('appdata seed does not reproduce the accepted hash (got ' + $sha + '); skipping lock')
        return
    }

    $cur     = (Invoke-Ld "shell su 0 sha256sum $DevAppData/save_appdata" -TimeoutSec 20).Trim()
    $dirMode = (Invoke-Ld "shell su 0 ls -ld $DevAppData" -TimeoutSec 20).Trim()
    if (($cur -match $SeedAppDataSha) -and ($dirMode -match '^dr-xr-xr-x')) {
        Write-Host '  appdata lock: already in place (BGM/SE on)'
        Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        return
    }

    Write-Host 'locking save/appdata/save_appdata ...'
    Invoke-Ld "shell am force-stop $package" | Out-Null
    Start-Sleep -Seconds 2

    # Reopen the directory so the copy can land, then close it again below.
    Invoke-Ld "shell su 0 chmod 775 $DevAppData" | Out-Null
    Invoke-Ld "push $stage $DevSeed2" -TimeoutSec 60 | Out-Null
    Invoke-Ld "shell su 0 cp $DevSeed2 $DevAppData/save_appdata" | Out-Null
    Invoke-Ld "shell su 0 chown media_rw:media_rw $DevAppData/save_appdata" | Out-Null
    Invoke-Ld "shell su 0 chmod 444 $DevAppData/save_appdata" | Out-Null

    $got = (Invoke-Ld "shell su 0 sha256sum $DevAppData/save_appdata" -TimeoutSec 20).Trim()
    if ($got -notmatch $SeedAppDataSha) {
        # Leave the directory writable so the next run can retry; 555 here would
        # make a silent bad copy stick.
        Write-Warning ("appdata seed copy failed (device reports: " + $got + "); BGM/SE will stay off")
        Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
        return
    }

    Invoke-Ld "shell su 0 chmod 555 $DevAppData" | Out-Null
    $dirMode = (Invoke-Ld "shell su 0 ls -ld $DevAppData" -TimeoutSec 20).Trim()
    if ($dirMode -notmatch '^dr-xr-xr-x') {
        Write-Warning ("appdata seeded but the directory is still writable: " + $dirMode)
    } else {
        Write-Host '  locked: BGM/SE enabled (client cannot zero the seed)'
    }
    Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
}

Lock-AppData

# ---- 8. launch ----
if (-not $NoLaunch) {
    Invoke-Ld "shell am force-stop $package" | Out-Null
    Invoke-Ld "shell monkey -p $package -c android.intent.category.LAUNCHER 1" | Out-Null
    Write-Host 'game launched - the daily-notice WebView closes itself and the main menu appears'
}

Write-Host ''
Write-Host '==========================================================' -ForegroundColor Green
Write-Host '  ADMIN CONSOLE : http://127.0.0.1:26031/' -ForegroundColor Green
Write-Host '==========================================================' -ForegroundColor Green
Write-Host '  Edit gacha banners, area drops, shop, starter kit and player saves there.'
Write-Host '  Changes take effect as soon as you press Apply - no restart needed.'
Write-Host ("  config file: " + (Join-Path $ProjectRoot 'runtime\resource-set\content.json'))
Write-Host ''
Write-Host ("request log: " + (Join-Path $ProjectRoot 'runtime\requests.jsonl'))
if ($NoLockMasterCard) {
    Write-Host 'master_card lock: OFF - the card screens will crash' -ForegroundColor Yellow
} else {
    Write-Host 'master_card lock: ON - re-applied before every launch'
}
Write-Host 'watch the client:'
Write-Host ("  " + $LdConsole + " adb --index " + $Index + " --command `"shell screencap -p /sdcard/s.png`"")
Write-Host ("  " + $LdConsole + " adb --index " + $Index + " --command `"pull /sdcard/s.png <path>`"")
if ($Admin) { Start-Process 'http://127.0.0.1:26031/' }
if ($Pause) { Read-Host 'press Enter to close' | Out-Null }
