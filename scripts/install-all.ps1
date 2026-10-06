param(
    # The two originals a new player has. Both are auto-located when omitted:
    # <root>\*.apk / <root>\base\*.apk and the same for the resource zip.
    [string]$Apk,
    [string]$Zip,

    # LDPlayer's adb. Auto-located by ASCII glob (the install path is non-ASCII).
    [string]$Adb,
    # ldconsole.exe, LDPlayer's management CLI. Auto-located the same way.
    [string]$LdConsole,
    # Which LDPlayer instance to drive. -1 (the default) auto-detects whichever
    # instance is already running, because the instance number is NOT stable
    # between sessions. ONLY LDPlayer is ever touched: a MuMu / Nox / BlueStacks
    # device sitting on the same adb server is ignored, because "take the first
    # online device" is exactly how a 500 MB client ends up on the wrong emulator.
    [int]$LdIndex = -1,
    # Starting an instance when none is running is now the DEFAULT (a one-shot
    # installer should not require the user to open the emulator by hand). Keep
    # -LaunchLd working as an accepted no-op for old command lines.
    [switch]$LaunchLd,
    # Opposite of the default: fail instead of starting LDPlayer.
    [switch]$NoLaunchLd,
    # Leave empty to let the instance above be picked. A serial that does not
    # belong to it is refused.
    [string]$Serial = '',

    # Address the client is told to talk to. Defaults to this host's LAN IPv4
    # on port 50005 (the port the client has hard-coded).
    [string]$BaseURL,

    # Client-side steps are skippable for a server-only reinstall.
    [switch]$SkipClient,
    [switch]$SkipResources,
    [switch]$SkipLibPatch,
    # Repacking the client APK needs Python 3 (standard library only) plus
    # openssl (which ships with Git for Windows). Both are auto-located; if
    # either is missing the install falls back to the stock APK and the 7350
    # build-up presentation plays.
    [string]$Python,
    # Do not repack: install the stock client on purpose.
    [switch]$SkipApkPatch,

    [switch]$NoLaunch,
    # A failure keeps the window open so the message can be read - without it a
    # double-clicked script vanishes before you can see why. -NoPause turns off
    # every pause, for unattended runs.
    [switch]$NoPause,
    # Also pause on success, to read the summary.
    [switch]$Pause
)

# One-shot setup for a brand new player: stock APK + stock resource zip +
# LDPlayer, nothing else. Does, in order:
#
#   1. locate the APK / zip / adb / ldconsole (+ python/openssl for the repack),
#      then find the LDPlayer instance to use - starting one if none is up
#      (other emulators are ignored on purpose)
#   2. unpack the resource zip into base\140330 (the device save tree)
#   3. copy the client resources into runtime\resource-set (server side)
#   4. repack the APK with the patched 7350 build-up layout, self-signed
#   5. adb install the APK
#   6. push the whole resource tree to the device
#   7. apply the native-library patch to the installed client
#   8. start the game server
#   9. launch the client (hosts hijack, proxy, master_card lock)
#
# Step 4 is optional only in the sense that it degrades: without Python or
# openssl the stock APK is installed and a loud warning says that the 7350
# build-up presentation will play. Everything else is orthogonal to it - the
# native-library patch in step 7 fixes a completely different set of crashes.
#
# WHY the resources must be pushed rather than downloaded: the client keeps its
# 500 MB mirror under /sdcard/Android/data/<pkg>/files/save and never fetches it
# from the server - a full session's request log contains zero /contents/ hits.
# The server is started with --suppress-revisions, so the client's own pack
# downloader stays out of it too. No push, no art.
#
# ASCII-only source so Windows PowerShell 5.1 reads it safely.

$ErrorActionPreference = 'Stop'

trap {
    Write-Host ''
    Write-Host ('FAILED: ' + $_.Exception.Message) -ForegroundColor Red
    if ($_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    }
    if (-not $NoPause) { Read-Host 'press Enter to close' | Out-Null }
    exit 1
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Pkg         = 'com.square_enix.million_cn'
$Port        = '50005'
$ServerBin   = Join-Path $ProjectRoot 'kakusansei-ma-ch-main\server\dist\kakusan-server.exe'
$Resources   = Join-Path $ProjectRoot 'runtime\resource-set'
$SaveTree    = Join-Path $ProjectRoot 'base\140330\sdcard\Android\data\com.square_enix.million_cn\files\save'
$LibPatch    = Join-Path $ProjectRoot 'runtime\lib\librooneyj-rarenull.so'

function Step([string]$Text) {
    Write-Host ''
    Write-Host ('=== ' + $Text + ' ===') -ForegroundColor Cyan
}

# Runs adb with the error preference relaxed for the call.
#
# adb prints progress ("8592 KB/s ...") to stderr, and with
# $ErrorActionPreference='Stop' ANY stderr output from a native command is
# promoted to a terminating error - the script dies on a *successful* install.
# `2>&1` alone does not help; the preference has to be lowered around the call.
function Invoke-AdbCmd([string[]]$AdbArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        return @(& $Adb @AdbArgs 2>&1)
    } finally {
        $ErrorActionPreference = $prev
    }
}

# Plain text of the last adb call, for tests like `-match 'Success'`.
function Invoke-AdbText([string[]]$AdbArgs) {
    return ((Invoke-AdbCmd $AdbArgs) | Out-String)
}

# ---------------------------------------------------------------- 1. locate ---
Step '1/9  locate the inputs'

if (-not $Apk) {
    foreach ($g in @('*.apk', 'base\*.apk', 'apk\*.apk')) {
        $hit = Get-ChildItem -Path (Join-Path $ProjectRoot $g) -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { $Apk = $hit.FullName; break }
    }
}
if (-not $Apk -or -not (Test-Path -LiteralPath $Apk -PathType Leaf)) {
    throw "APK not found; put it in the project root or base\, or pass -Apk <path>"
}
Write-Host ('apk    : ' + $Apk)

if (-not $Zip) {
    foreach ($g in @('*.zip', 'base\*.zip')) {
        $hit = Get-ChildItem -Path (Join-Path $ProjectRoot $g) -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { $Zip = $hit.FullName; break }
    }
}
if (-not $Zip -or -not (Test-Path -LiteralPath $Zip -PathType Leaf)) {
    throw "resource zip not found; put it in the project root or base\, or pass -Zip <path>"
}
Write-Host ('zip    : ' + $Zip)

# LDPlayer can be installed anywhere - any drive, any folder depth, usually with
# a non-ASCII name. Find it once and take both tools out of the same tree
# instead of guessing drive-letter globs (which silently missed C/D/E/F machines
# whose install was not on C/D/F). See scripts\find-ldplayer.ps1.
. (Join-Path $PSScriptRoot 'find-ldplayer.ps1')

$ldHint = ''
if ($LdConsole) { $ldHint = $LdConsole } elseif ($Adb) { $ldHint = $Adb }
$ld = $null
if ($ldHint) { $ld = Find-LdPlayer -Hint $ldHint }
if (-not $ld) { $ld = Find-LdPlayer -Prompt:(-not $NoPause) }
if ($ld) {
    if (-not $LdConsole -or -not (Test-Path -LiteralPath $LdConsole -PathType Leaf)) { $LdConsole = $ld.LdConsole }
    if (-not $Adb -or -not (Test-Path -LiteralPath $Adb -PathType Leaf)) { $Adb = $ld.Adb }
    Write-Host ('ldplayer: ' + $ld.Via)
}

# adb is generic - any emulator's copy installs APKs and pushes files - so a
# standalone adb on PATH or in an SDK is an acceptable substitute.
if (-not $Adb -or -not (Test-Path -LiteralPath $Adb -PathType Leaf)) { $Adb = Find-AdbAnywhere }
if (-not $Adb -or -not (Test-Path -LiteralPath $Adb -PathType Leaf)) {
    throw 'adb.exe not found. Install LDPlayer (which ships one), or pass -Adb <path>; any adb.exe works.'
}
Write-Host ('adb    : ' + $Adb)

if (-not (Test-Path -LiteralPath $ServerBin -PathType Leaf)) {
    throw ("server binary missing: $ServerBin" +
           ' - re-download the release, or build it yourself with the Go toolchain (see README 3.4)')
}

# ----------------------------------------------------- 1b. LDPlayer only ---
# `adb devices` is one server shared by every emulator on this box. "Take the
# first online device" therefore installs a 500 MB client onto whatever else
# happens to be running - MuMu, Nox, BlueStacks - and the later push/launch
# steps then fail in ways that look like client bugs. So ask ldconsole first
# and only ever use a serial that belongs to an LDPlayer instance.
#
# LDPlayer instance i publishes adb on port 5555+2i, which adb reports either
# as 127.0.0.1:(5555+2i) (after an explicit connect - the usual case) or as
# emulator-(5554+2i) (when the emulator console discovered it). Two processes
# cannot bind the same port, so this whitelist cannot collide with anything.

if (-not $LdConsole -or -not (Test-Path -LiteralPath $LdConsole -PathType Leaf)) {
    throw ('ldconsole.exe not found. Pass -LdConsole <path> (the LDPlayer install folder); ' +
           'scripts\find-ldplayer.ps1 already looked at the running process, LDPlayer''s ' +
           'uninstall registry entry and every fixed drive.')
}
Write-Host ('ldconsole: ' + $LdConsole)

# One list2 line per instance: index,name,topWindowHandle,bindWindowHandle,running,...
#
# This is deliberately re-read on every run: which instance is up changes from
# session to session (#0 today, #2 tomorrow), so nothing may assume a number.
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
function Test-LdUp([int]$Index) {
    return (@(Get-LdInstances | Where-Object { $_.Index -eq $Index -and $_.Running }).Count -gt 0)
}

$ldInst  = @(Get-LdInstances)
if ($ldInst.Count -eq 0) {
    throw 'ldconsole lists no LDPlayer instance; create one in LDPlayer first'
}
$known   = @($ldInst | ForEach-Object { $_.Index })
$running = @($ldInst | Where-Object { $_.Running } | ForEach-Object { $_.Index })

if ($LdIndex -ge 0) {
    if ($known -notcontains $LdIndex) {
        throw ('LDPlayer has no instance ' + $LdIndex + ' (known: ' + ($known -join ', ') + ')')
    }
    Write-Host ('ldplayer: using instance ' + $LdIndex + ' (-LdIndex)')
    if (($running -notcontains $LdIndex) -and $NoLaunchLd) {
        throw ('LDPlayer instance ' + $LdIndex + ' is not running (-NoLaunchLd). Start it and re-run.')
    }
} elseif ($running.Count -gt 0) {
    $LdIndex = $running[0]
    Write-Host ('ldplayer: auto-detected running instance ' + $LdIndex +
                ' (running: ' + ($running -join ', ') + ')')
    if ($running.Count -gt 1) {
        Write-Warning ('several LDPlayer instances are running (' + ($running -join ', ') +
                       '); using ' + $LdIndex + ' - pass -LdIndex <n> to pick another')
    }
} elseif ($NoLaunchLd) {
    throw ('no LDPlayer instance is running (known: ' + ($known -join ', ') +
           '). Start one, or drop -NoLaunchLd to let this script start it.')
} else {
    # Nothing is up: start the first configured instance rather than demanding
    # the user open LDPlayer by hand first.
    $LdIndex = $known[0]
    Write-Host ('ldplayer: no instance running - will start instance ' + $LdIndex)
}

if (-not (Test-LdUp $LdIndex)) {
    Write-Host ('starting LDPlayer instance ' + $LdIndex + ' (a cold boot takes up to a minute)...')
    & $LdConsole launch --index $LdIndex | Out-Null
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        if (Test-LdUp $LdIndex) { break }
        if ($i % 5 -eq 4) { Write-Host ('  still booting (' + (($i + 1) * 3) + 's)...') }
    }
}
if (-not (Test-LdUp $LdIndex)) {
    throw ('LDPlayer instance ' + $LdIndex + ' did not come up within 180s. Devices from any other emulator are ignored by design.')
}

$ldAdbPort = 5555 + 2 * $LdIndex
Write-Host ('ldplayer: instance ' + $LdIndex + ' running, adb port ' + $ldAdbPort)

$ldSerials = @("127.0.0.1:$ldAdbPort", "emulator-$(5554 + 2 * $LdIndex)")

# The device sometimes only shows up after an explicit connect; harmless (and
# silent) when it is already there.
Invoke-AdbCmd @('connect', "127.0.0.1:$ldAdbPort") | Out-Null

$all = @()
foreach ($line in (Invoke-AdbCmd @('devices'))) {
    if ($line -match '^\s*(\S+)\s+device\s*$') { $all += $Matches[1] }
}
$devices = @($all | Where-Object { $ldSerials -contains $_ })

if ($devices.Count -eq 0) {
    throw ('LDPlayer instance ' + $LdIndex + ' is running but its adb device is not online. ' +
           'Expected one of [' + ($ldSerials -join ', ') + ']; adb sees [' + ($all -join ', ') + '].')
}

$foreign = @($all | Where-Object { $ldSerials -notcontains $_ })
if ($foreign.Count -gt 0) {
    Write-Host ('ignored: ' + ($foreign -join ', ') + ' (not LDPlayer instance ' + $LdIndex + ')')
}

if ($Serial -and ($ldSerials -notcontains $Serial)) {
    Write-Warning ($Serial + ' does not belong to LDPlayer instance ' + $LdIndex +
                   ' (expected ' + ($ldSerials -join ' or ') + '); ignoring it')
    $Serial = ''
}
if (-not $Serial) {
    $Serial = $devices[0]
    Write-Host ('device : ' + $Serial)
} elseif ($devices -notcontains $Serial) {
    Write-Warning ($Serial + ' is not online; using ' + $devices[0])
    $Serial = $devices[0]
} else {
    Write-Host ('device : ' + $Serial + ' online')
}

$abi = (Invoke-AdbText @('-s', $Serial, 'shell', 'getprop ro.product.cpu.abilist')).Trim()
Write-Host ('abilist: ' + $abi)
if ($abi -notmatch 'armeabi') {
    Write-Warning 'this instance has no armeabi (32-bit ARM); the client will not run'
}

# ------------------------------------------ 1c. python + openssl (step 4) ----
# Only step 4 needs these. Locating them here keeps the failure mode explicit:
# a missing toolchain downgrades to the stock client instead of aborting.
function Find-Python {
    foreach ($cand in @(
            @{ Name = 'python.exe';  Args = @() },
            @{ Name = 'python3.exe'; Args = @() },
            @{ Name = 'py.exe';      Args = @('-3') }
        )) {
        $cmd = Get-Command $cand.Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { continue }
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $v = (& $cmd.Source @($cand.Args + @('--version')) 2>&1 | Out-String).Trim() }
        catch { $v = '' }
        finally { $ErrorActionPreference = $prev }
        # Rejects the Microsoft Store stub and any Python 2 on PATH.
        if ($v -match 'Python\s+3\.') {
            return [pscustomobject]@{ Exe = $cmd.Source; Args = @($cand.Args); Version = $v }
        }
    }
    return $null
}
function Find-OpenSsl {
    $cmd = Get-Command 'openssl.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            'C:\Program Files\Git\usr\bin\openssl.exe',
            'C:\Program Files (x86)\Git\usr\bin\openssl.exe',
            (Join-Path $env:LOCALAPPDATA 'Programs\Git\usr\bin\openssl.exe')
        )) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
    }
    return $null
}

if ($Python) {
    if (Test-Path -LiteralPath $Python -PathType Leaf) {
        $Py = [pscustomobject]@{ Exe = $Python; Args = @(); Version = 'explicit' }
    } else {
        $Py = $null
        Write-Warning ('python not found at ' + $Python + '; step 4 will fall back to the stock APK')
    }
} else {
    $Py = Find-Python
}
if ($Py) { Write-Host ('python  : ' + $Py.Exe + ' (' + $Py.Version + ')') }
else     { Write-Host 'python  : not found (step 4 will fall back to the stock APK)' }

$OpenSsl = Find-OpenSsl
if ($OpenSsl) {
    Write-Host ('openssl : ' + $OpenSsl)
    # patch-client-apk.py shells out to a plain `openssl`, so its directory has
    # to be on PATH for the child process.
    $env:PATH = (Split-Path -Parent $OpenSsl) + ';' + $env:PATH
} else {
    Write-Host 'openssl : not found (step 4 will fall back to the stock APK)'
}

# -------------------------------------------------------------- 2. unpack ----
Step '2/9  unpack the resource zip into base\140330'

if (Test-Path -LiteralPath (Join-Path $SaveTree 'download') -PathType Container) {
    Write-Host 'already unpacked - skipping'
} else {
    $dest = Join-Path $ProjectRoot 'base\140330'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Write-Host 'extracting (about 490 MB, this can take a few minutes)...'
    # -Force overwrites: base\140330 may already hold files (the raw-master
    # database ships with the repo) and the client keeps its own copies of a
    # few of them. Expand-Archive rather than ZipFile.ExtractToDirectory, which
    # refuses to overwrite anything already there.
    Expand-Archive -LiteralPath $Zip -DestinationPath $dest -Force
    Write-Host 'extracted'
}
if (-not (Test-Path -LiteralPath (Join-Path $SaveTree 'download') -PathType Container)) {
    throw "unpacked tree has no download\: $SaveTree"
}

# ------------------------------------------------------- 3. server res set ---
Step '3/9  stage the client resources into the server resource-set'

# The server refuses to boot without these three ("load resources: resource-set:
# open ...\resource-set.json: The system cannot find the file specified"), and
# the failure only surfaces four steps later as "the server did not come up".
# They are small and ship in the repo - only the 490 MB of art beside them is
# staged from the zip below - so check them here and say plainly what is wrong.
foreach ($need in @('resource-set.json', 'master\master.json', 'content.json')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Resources $need) -PathType Leaf)) {
        throw ('server resource-set is incomplete: ' + $need + ' is missing from ' + $Resources +
               '. Re-extract the release over this directory (do not delete runtime\resource-set),' +
               ' then run install-all.ps1 again.')
    }
}
Write-Host 'resource-set metadata present (resource-set.json / master\master.json / content.json)'

$ResDownload = Join-Path $Resources 'save\download'
if ($SkipResources) {
    Write-Host 'skipped (-SkipResources)'
} elseif (Test-Path -LiteralPath $ResDownload -PathType Container) {
    Write-Host 'already present - skipping'
} else {
    Write-Host 'copying (about 490 MB, this takes a minute)...'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ResDownload) | Out-Null
    Copy-Item -LiteralPath (Join-Path $SaveTree 'download') -Destination $ResDownload -Recurse -Force
    Write-Host 'copied'
}

# ------------------------------------------------- 4. repack the client ----
# The 7350 build-up presentation (the attribute-change overlay shown on every
# strengthen) can only be removed inside the APK: the client resolves
# bundle/<name>.xml against its own archive, never against a writable directory.
# patch-client-apk.py swaps that one entry and re-signs the archive with the
# self-signed key in runtime\keys (no JDK needed, JAR/v1 is enough on API 22).
#
# Repacking is not mandatory. If anything it needs is missing, the stock APK is
# installed instead and the warning below says exactly what that costs.
if ($SkipClient) {
    Step '4/9  repack the client APK - skipped (-SkipClient)'
    Step '5/9  install the client APK - skipped (-SkipClient)'
    Step '6/9  push the resource tree - skipped (-SkipClient)'
    Step '7/9  native library patch - skipped (-SkipClient)'
} else {
    Step '4/9  repack the client APK (skip the 7350 build-up presentation)'

    $PatchedApk  = Join-Path $ProjectRoot 'apk\kakusen-client-patched.apk'
    $PatchScript = Join-Path $PSScriptRoot 'patch-client-apk.py'
    $PatchLayout = Join-Path $ProjectRoot 'runtime\client-patch\layout_buildup_animation.xml'
    $PatchEntry  = 'assets/bundle/layout_buildup_animation.xml'
    $KeyPem      = Join-Path $ProjectRoot 'runtime\keys\kakusen-mod.pem'
    $KeyCrt      = Join-Path $ProjectRoot 'runtime\keys\kakusen-mod.crt'
    $KnownMd5    = 'f8a5002da91f10b88220ea783319a359'

    $ApkInstall = $Apk      # what step 5 actually installs
    $patchWhy   = ''
    $srcMd5     = (Get-FileHash -LiteralPath $Apk -Algorithm MD5).Hash.ToLower()
    $Sidecar    = $PatchedApk + '.src-md5'

    # A repack is reusable only when it was made from this exact source file, so
    # the source's md5 is kept beside the output.
    #
    # The stronger check - reading the asset back out of the zip - needs
    # System.IO.Compression loaded via Add-Type, which locked-down hosts block,
    # and patch-client-apk.py already verifies its own output (its 'patched
    # asset' line prints NOT PATCHED if the swap did not stick, and that is
    # checked below).
    $reusable = (Test-Path -LiteralPath $PatchedApk -PathType Leaf) -and
                (Test-Path -LiteralPath $Sidecar -PathType Leaf) -and
                ((Get-Content -LiteralPath $Sidecar -Raw).Trim() -eq $srcMd5)

    if ($SkipApkPatch) {
        $patchWhy = 'skipped (-SkipApkPatch)'
    } elseif (-not $Py) {
        $patchWhy = 'Python 3 not found'
    } elseif (-not $OpenSsl) {
        $patchWhy = 'openssl not found (it ships with Git for Windows)'
    } elseif (-not (Test-Path -LiteralPath $PatchScript -PathType Leaf)) {
        $patchWhy = 'scripts\patch-client-apk.py is missing'
    } elseif (-not (Test-Path -LiteralPath $PatchLayout -PathType Leaf)) {
        $patchWhy = 'runtime\client-patch\layout_buildup_animation.xml is missing'
    } elseif ($reusable) {
        Write-Host ('reusing the existing repack: ' + $PatchedApk)
        Write-Host '  (delete it, or the .src-md5 beside it, to force a rebuild)'
        $ApkInstall = $PatchedApk
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $PatchedApk) | Out-Null
        Write-Host 'repacking and signing (reads 290 MB, writes 290 MB; about a minute)...'
        Push-Location $ProjectRoot
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $pyArgs = @($Py.Args) + @(
                $PatchScript,
                '--src', $Apk,
                '--replace', ($PatchEntry + '=' + $PatchLayout),
                '--out', $PatchedApk,
                '--key', $KeyPem,
                '--cert', $KeyCrt
            )
            $pyOut = & $Py.Exe @pyArgs 2>&1
            $pyCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
            Pop-Location
        }
        $pyText = ($pyOut | Out-String)
        $pyOut | Where-Object {
            $_ -match 'replaced|wrote|integrity|verify|Manifest|PKCS|patched asset|NOT PATCHED|MISMATCH|FAILED|Error|Traceback|\.SF'
        } | ForEach-Object { Write-Host ('  ' + $_) }

        if ($pyCode -ne 0) {
            $patchWhy = ('patch-client-apk.py exited with ' + $pyCode)
        } elseif ($pyText -match 'NOT PATCHED') {
            $patchWhy = 'the repack does not carry the patched layout'
        } elseif (-not (Test-Path -LiteralPath $PatchedApk -PathType Leaf)) {
            $patchWhy = 'the repack produced no file'
        } else {
            $mb  = [math]::Round((Get-Item -LiteralPath $PatchedApk).Length / 1MB, 1)
            $md5 = (Get-FileHash -LiteralPath $PatchedApk -Algorithm MD5).Hash.ToLower()
            Write-Host ('patched : ' + $PatchedApk)
            Write-Host ('          ' + $mb + ' MB, md5 ' + $md5)
            if ($md5 -eq $KnownMd5) { Write-Host '          matches the known-good build' }
            Set-Content -LiteralPath $Sidecar -Value $srcMd5 -NoNewline
            $ApkInstall = $PatchedApk
        }
    }

    if ($patchWhy) {
        Write-Warning ('step 4 not applied: ' + $patchWhy)
        Write-Warning 'installing the STOCK client. The 7350 build-up presentation (the attribute-change overlay) WILL play on every strengthen.'
        Write-Warning 'to get the patched client: install Python 3 and Git for Windows, then re-run this script.'
    } else {
        Write-Host 'client patched: the 7350 build-up presentation is skipped, the result page is kept'
    }

    # ------------------------------------------------------------ 5. install ----
    Step '5/9  install the client APK'
    Write-Host 'uninstalling any previous copy (the repack is self-signed, so it cannot be upgraded in place)...'
    Invoke-AdbCmd @('-s', $Serial, 'uninstall', $Pkg) | Out-Null
    $installText = Invoke-AdbText @('-s', $Serial, 'install', $ApkInstall)
    $installCode = $LASTEXITCODE
    $installText.Trim().Split("`n") | ForEach-Object { Write-Host ('  ' + $_.Trim()) }
    if ($installCode -ne 0) { throw "adb install failed ($installCode)" }
    if ($installText -notmatch 'Success') { throw 'adb install reported no Success' }
    Write-Host ('installed: ' + (Split-Path -Leaf $ApkInstall))

    Step '6/9  push the resource tree to the device'
    Write-Host 'this is the slow one (about 6900 files); the client never fetches them from the server'
    & (Join-Path $PSScriptRoot 'push-save-tree.ps1') -Adb $Adb -Serial $Serial -Source $SaveTree

    Step '7/9  native library patch'
    if ($SkipLibPatch) {
        Write-Host 'skipped (-SkipLibPatch): the awakened-fairy animation will crash the client'
    } elseif (-not (Test-Path -LiteralPath $LibPatch -PathType Leaf)) {
        Write-Warning ('library patch not found: ' + $LibPatch)
    } else {
        # The library sits in the installed APK's extracted lib dir. Replace it
        # with the patched build: null guards in ResourceManagerEx::getMasterBoss
        # and _AnmExpAppFairy::setRareFairy (otherwise the awakened-fairy
        # appearance animation SIGSEGVs), plus the awakened artwork fix.
        $libPath = (Invoke-AdbText @('-s', $Serial, 'shell',
            "ls /data/app/$Pkg*/lib/arm/librooneyj.so 2>/dev/null")).Trim()
        if (-not $libPath -or $libPath -notmatch 'librooneyj\.so') {
            Write-Warning 'no extracted librooneyj.so on the device (extractNativeLibs=false?); skipping'
        } else {
            $libPath = ($libPath -split "`n")[0].Trim()
            Write-Host ('device lib: ' + $libPath)
            Invoke-AdbCmd @('-s', $Serial, 'push', $LibPatch, '/data/local/tmp/librooneyj.so.new') | Out-Null
            # Keep a rollback copy of whatever is there now.
            Invoke-AdbCmd @('-s', $Serial, 'shell', "su 0 cp $libPath /data/local/tmp/librooneyj.so.orig 2>/dev/null") | Out-Null
            Invoke-AdbCmd @('-s', $Serial, 'shell', "su 0 cp /data/local/tmp/librooneyj.so.new $libPath") | Out-Null
            Invoke-AdbCmd @('-s', $Serial, 'shell', "su 0 chown system:system $libPath; su 0 chmod 755 $libPath; su 0 restorecon $libPath 2>/dev/null") | Out-Null
            $got = Invoke-AdbText @('-s', $Serial, 'shell', "md5sum $libPath")
            $want = (Get-FileHash -LiteralPath $LibPatch -Algorithm MD5).Hash.ToLower()
            if ($got -match '([0-9a-f]{32})') {
                if ($Matches[1] -ne $want) { throw "library md5 mismatch: device $($Matches[1]) vs $want" }
                Write-Host ('library patched, md5 ' + $Matches[1] + ' (rollback: /data/local/tmp/librooneyj.so.orig)')
            } else {
                Write-Warning 'could not read the device library hash back'
            }
        }
    }
}

# ------------------------------------------------------------- 7. server ----
Step '8/9  start the game server'

if (-not $BaseURL) {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
          Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $ip) { $ip = '127.0.0.1' }
    $BaseURL = "http://${ip}:${Port}"
}
Write-Host ('base url: ' + $BaseURL)
& (Join-Path $PSScriptRoot 'restart-server.ps1') -BaseURL $BaseURL -NoBuild
Write-Host 'server up (console http://127.0.0.1:26031/)'

# ------------------------------------------------------------- 8. client ----
Step '9/9  launch the client'
if ($NoLaunch) {
    Write-Host 'skipped (-NoLaunch); start it later with scripts\start-game-ld.ps1'
} else {
    & (Join-Path $PSScriptRoot 'start-game-ld.ps1') -HostAddr (([uri]$BaseURL).Host)
}

Write-Host ''
Write-Host 'done. If the client shows a connection error, check the server console page' -ForegroundColor Green
Write-Host 'at http://127.0.0.1:26031/ and the on-screen hints from start-game-ld.ps1.' -ForegroundColor Green
if ($Pause -and -not $NoPause) { Read-Host 'press Enter to close' | Out-Null }
