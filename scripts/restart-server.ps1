param(
    # Empty = advertise this host's first non-loopback IPv4. Never hardcode a
    # LAN address here: the emulator reaches the server through the host's LAN
    # address and every machine has a different one, so a baked-in 192.168.x.x
    # silently points the client at a dead host on anyone else's PC.
    [string]$BaseURL = '',
    [switch]$NoBuild,
    [switch]$LaunchGame
)

# Restarts ONLY the game server (dist\kakusan-server.exe), with the same argv
# scripts\start-game-ld.ps1 uses, without touching the emulator, the save tree
# or the appdata seed. That is what you want after rebuilding the server: the
# console page (ui.html) and the master data are embedded in the binary, so a
# restart is what makes console changes visible.
#
# The game client will drop its connection; pass -LaunchGame to force-stop and
# relaunch it, or relaunch it yourself.
#
# ASCII-only content so Windows PowerShell 5.1 reads it safely.
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ServerRoot  = Join-Path $ProjectRoot 'kakusansei-ma-ch-main\server'
$Bin         = Join-Path $ServerRoot 'dist\kakusan-server.exe'
$Resources   = Join-Path $ProjectRoot 'runtime\resource-set'
$Data        = Join-Path $ProjectRoot 'runtime\data'
$RawMaster   = Join-Path $ProjectRoot 'base\140330\sdcard\Android\data\com.square_enix.million_cn\files\save\database'
$Package     = 'com.square_enix.million_cn'

if (-not $BaseURL) {
    $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
          Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $ip) { $ip = '127.0.0.1' }
    $BaseURL = "http://${ip}:50005"
}

# Build only when a build script is there to run.
#
# A runtime-only copy of this repo ships the compiled server and no Go toolchain
# (no build.ps1 / go-env.ps1 at all). Failing the restart over a missing build
# step would be wrong - the shipped binary is exactly what we want to start.
if (-not $NoBuild) {
    $build = Join-Path $PSScriptRoot 'build.ps1'
    if (Test-Path -LiteralPath $build -PathType Leaf) {
        & $build
    } else {
        Write-Warning 'scripts\build.ps1 is not present (runtime-only copy): starting the shipped kakusan-server.exe as-is'
    }
}

# Never delete the sqlite sidecars: SQLite replays the WAL on open and the
# unflushed progress lives there.
Get-Process -Name kakusan-server -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800

$argv = @(
    '--resources', $Resources,
    '--data', $Data,
    '--listen', ':50005',
    '--base-url', $BaseURL,
    '--request-log', (Join-Path $ProjectRoot 'runtime\requests.jsonl'),
    '--admin-listen', '127.0.0.1:26031',
    '--suppress-revisions',
    '--skip-tutorial'
)
if (Test-Path -LiteralPath $RawMaster) { $argv += @('--raw-master', $RawMaster) }

# Start detached so the server outlives this script and its shell.
#
# Start-Process, not the WMI Win32_Process.Create this used to use: WMI returns
# no handle, so a server that died during boot was indistinguishable from one
# that was still booting - the wait loop just ran to its end and the step hung
# with no output. With a process object we can tell the two apart immediately,
# report the pid, and say which script to run to see the server's own output.
#
# The data dir has to exist before the server opens its sqlite file; on a fresh
# clone it does not (it is gitignored and created on first run).
New-Item -ItemType Directory -Force -Path $Data | Out-Null

# Start the server detached, in its own console window, so closing this script's
# window cannot take it down.
#
# A Process handle is kept (unlike the WMI Win32_Process.Create this used to
# use, which returns none) so that a server dying during boot is reported at
# once instead of looking exactly like a slow boot.
#
# The one thing Start-Process trips over: PowerShell 5.1 builds a case-
# INSENSITIVE dictionary of the child's environment and throws ArgumentException
# ("an item with the same key has already been added") when the environment
# holds two names differing only in case - which is exactly what a proxy tool
# creates by setting both http_proxy and HTTP_PROXY. Enumerating Env: to clean
# them up throws the very same error, so the .NET setter is used instead: it
# works one name at a time and Windows matches names case-insensitively.
#
# The data dir has to exist before the server opens its sqlite file; on a fresh
# clone it does not (it is gitignored and created on first run).
New-Item -ItemType Directory -Force -Path $Data | Out-Null

foreach ($n in @('http_proxy', 'https_proxy', 'no_proxy', 'all_proxy')) {
    try { [System.Environment]::SetEnvironmentVariable($n, $null, 'Process') } catch { }
}

# Hidden window + redirected output rather than a minimised console: the server
# logs its startup complaints (missing resource-set.json, port already in use,
# ...) to stderr, and a minimised console buries exactly the line needed to
# diagnose a failed boot. The redirect keeps those lines and keeps the server
# off this script's console as well.
$srvOut = Join-Path $ProjectRoot 'runtime\server.out.log'
$srvErr = Join-Path $ProjectRoot 'runtime\server.err.log'
$argLine = (($argv | ForEach-Object { '"' + $_ + '"' }) -join ' ')
try {
    $proc = Start-Process -FilePath $Bin -ArgumentList $argLine -WorkingDirectory $ServerRoot `
                          -WindowStyle Hidden -PassThru -ErrorAction Stop `
                          -RedirectStandardOutput $srvOut -RedirectStandardError $srvErr
} catch {
    throw ('could not start the server: ' + $_.Exception.Message +
           '  [a proxy tool setting both http_proxy and HTTP_PROXY is the usual cause]')
}
Write-Host ('server pid ' + $proc.Id + ', waiting for it to answer on 127.0.0.1:26031 ...')
Write-Host ('  server output -> ' + $srvOut)

$up = $false
$t0 = Get-Date
$n  = 0
# 240s, not the 20s this used to claim: the first boot on a cold disk reads the
# whole 490 MB client resource tree and measured 130s on this machine. The old
# bound was a fiction - the loop actually ran ~140s and produced no output at
# all while it did, which is exactly what "the installer hangs at step 8" was.
# The progress line below is the other half of that fix.
while ($up -eq $false -and ((Get-Date) - $t0).TotalSeconds -lt 240) {
    if ($proc.HasExited) {
        try { $proc.WaitForExit() } catch { }      # let ExitCode settle
        Write-Host '--- the server said: ---' -ForegroundColor DarkGray
        foreach ($f in @($srvOut, $srvErr)) {
            if (Test-Path -LiteralPath $f) {
                # -Encoding UTF8: the server logs UTF-8 and 5.1 reads ANSI by
                # default, which turns any non-ASCII path in the message into
                # mojibake - exactly the part that says which file is missing.
                Get-Content -LiteralPath $f -Tail 40 -Encoding UTF8 -ErrorAction SilentlyContinue |
                    ForEach-Object { if ($_.Trim()) { Write-Host ('  | ' + $_) } }
            }
        }
        throw ('the server exited during startup (code ' + $proc.ExitCode + '); full log: ' + $srvOut)
    }
    try {
        Invoke-RestMethod -Uri 'http://127.0.0.1:26031/healthz' -TimeoutSec 2 | Out-Null
        $up = $true
        break
    } catch { }
    $n++
    if ($n % 10 -eq 0) {
        Write-Host ('  still starting (' + [int]((Get-Date) - $t0).TotalSeconds + 's)...')
    }
    Start-Sleep -Milliseconds 500
}
if (-not $up) {
    throw ('server pid ' + $proc.Id + ' did not answer on 127.0.0.1:26031 within 240s; ' +
           'its own output is in ' + $srvOut + ' and ' + $srvErr)
}
Write-Host ('server up on :50005 (admin 127.0.0.1:26031, pid ' + $proc.Id + ')')

if ($LaunchGame) {
    # Locate ldconsole.exe through the shared finder: the install path is
    # arbitrary (any drive, any depth, usually non-ASCII), so hunt for it rather
    # than listing drive letters - see scripts\find-ldplayer.ps1. -LdConsole on
    # start-game-ld.ps1 is the explicit way to point at a non-standard install.
    . (Join-Path $PSScriptRoot 'find-ldplayer.ps1')
    $ld = ''
    $already = Join-Path $ProjectRoot 'installpath\ldconsole.exe'
    if (Test-Path -LiteralPath $already -PathType Leaf) { $ld = $already }
    if (-not $ld) {
        $found = Find-LdPlayer
        if ($found) { $ld = $found.LdConsole }
    }
    if ($ld -and (Test-Path -LiteralPath $ld -PathType Leaf)) {
        & $ld adb --index 0 --command "shell am force-stop $Package" | Out-Null
        & $ld adb --index 0 --command "shell monkey -p $Package -c android.intent.category.LAUNCHER 1" | Out-Null
        Write-Host 'game relaunched'
    } else {
        Write-Warning 'ldconsole.exe not found; relaunch the game by hand (or run scripts\start-game-ld.ps1)'
    }
}
