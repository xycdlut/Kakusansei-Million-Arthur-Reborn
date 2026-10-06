# Locate LDPlayer no matter where it was installed.
#
# Why this file exists
# --------------------
# LDPlayer's install path is arbitrary: any drive, any folder depth, and the
# folder name is usually non-ASCII (which is also why every path in this repo is
# found by search rather than written down - these scripts have to stay
# ASCII-only for Windows PowerShell 5.1).
#
# The previous approach was a hardcoded list of drive-letter globs
# (C:\*\installpath\dnplayer2\..., D:\..., F:\...) copy-pasted into four
# scripts. It silently misses a lot:
#   * an install on a drive whose letter is not in the list (this author's
#     machine has C/D/E/F, the list only covered C/D/F - so E: was never
#     searched; another machine may have only C:, or a dozen volumes),
#   * a layout that is not <drive>:\<one level>\installpath\dnplayer2
#     (e.g. D:\Games\emulators\LDPlayer9\),
#   * LDPlayer 4/5's <root>\installpath\leidian\LDPlayer<N>,
#   * the plain C:\LDPlayer\LDPlayer9 default, where adb.exe sits one level
#     below ldconsole.exe,
#   * anything on a volume with no drive letter, or mounted into a folder.
#
# Sources, cheapest and most reliable first:
#   1. an explicit path the caller was given (-LdConsole / -Adb)
#   2. LDPlayer's own running process - dnplayer.exe's own directory always
#      contains (or is a sibling of) ldconsole.exe and adb.exe
#   3. LDPlayer's uninstall registry entry, which records the real install
#      directory even while LDPlayer is not running
#   4. a bounded (depth 5) search of every volume Windows reports - fixed first,
#      then removable, then letter-less volumes and folder-mounted ones. It is
#      NOT a drive-letter list: the number of letters differs per machine, so
#      they are enumerated at run time (see Get-LdScanRoots). Measured ~11 s for
#      the worst volume here, only reached when 1-3 all missed, and it prints
#      per-volume progress so it never looks hung.
#
# Verified on this machine: process -> F:\Game\<non-ASCII>\installpath\dnplayer2,
# registry HKLM\SOFTWARE\WOW6432Node\...\Uninstall\dnplayer ->
# UninstallString = <dir>\dnuninst.exe.
#
# ASCII-only: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so any
# non-ASCII character in a string literal would come out corrupted.

# Given any interesting path (a file inside the install, or a folder), pull both
# tools out of it. Returns $null when ldconsole.exe is nowhere near.
function Get-LdToolsFromPath([string]$Base) {
    if (-not $Base) { return $null }
    if (Test-Path -LiteralPath $Base -PathType Leaf) { $Base = Split-Path -Parent $Base }
    if (-not (Test-Path -LiteralPath $Base -PathType Container)) { return $null }

    # Real-world shapes seen in the wild:
    #   <root>\installpath\dnplayer2\{ldconsole,adb}.exe   (LDPlayer 9)
    #   <root>\installpath\leidian\LDPlayer9\{ldconsole,adb}.exe  (LDPlayer 4/5)
    #   <root>\LDPlayer9\ldconsole.exe + <root>\LDPlayer9\dnplayer2\adb.exe
    #   <dir>\ldconsole.exe next to <dir>\..\ldconsole.exe
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($d in @($Base,
                     (Join-Path $Base 'dnplayer2'),
                     (Join-Path $Base 'leidian'),
                     (Join-Path $Base '..'),
                     (Join-Path $Base '..\..'))) {
        if (-not $d) { continue }
        try { $full = [IO.Path]::GetFullPath($d) } catch { continue }
        if ($dirs -notcontains $full) { $dirs.Add($full) }
    }
    # one level of LDPlayer<N> under ...\leidian\
    foreach ($d in @($dirs.ToArray())) {
        if (Test-Path -LiteralPath $d -PathType Container) {
            foreach ($sub in @(Get-ChildItem -LiteralPath $d -Directory -Filter 'LDPlayer*' -ErrorAction SilentlyContinue)) {
                if ($dirs -notcontains $sub.FullName) { $dirs.Add($sub.FullName) }
            }
        }
    }

    foreach ($d in $dirs) {
        $lc = $null
        foreach ($name in @('ldconsole.exe', 'dnconsole.exe')) {
            $cand = Join-Path $d $name
            if (Test-Path -LiteralPath $cand -PathType Leaf) { $lc = $cand; break }
        }
        if (-not $lc) { continue }
        $ad = ''
        foreach ($cand in @((Join-Path $d 'adb.exe'),
                            (Join-Path $d 'dnplayer2\adb.exe'),
                            (Join-Path $d '..\dnplayer2\adb.exe'),
                            (Join-Path $d '..\adb.exe'),
                            (Join-Path $d '..\..\dnplayer2\adb.exe'))) {
            if (Test-Path -LiteralPath $cand -PathType Leaf) { $ad = $cand; break }
        }
        return [pscustomobject]@{
            LdConsole = $lc
            Adb       = $ad
            Root      = $d
        }
    }
    return $null
}

# Every directory LDPlayer might have recorded about itself.
function Get-LdRegistryHints {
    $hints = New-Object System.Collections.Generic.List[string]

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($root in $uninstallRoots) {
            if (-not (Test-Path -LiteralPath $root)) { continue }
            foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                $p = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
                if (-not $p) { continue }
                $isLd = $false
                foreach ($f in @($p.DisplayName, $p.Publisher, $p.UninstallString)) {
                    if ($f -and ("$f" -match 'LDPlayer|ldplayer|leidian|XuanZhi|dnplayer')) { $isLd = $true; break }
                }
                if (-not $isLd) { continue }
                foreach ($f in @($p.InstallLocation, $p.UninstallString)) {
                    if (-not $f) { continue }
                    $s = "$f".Trim().Trim('"')
                    if ($s -match '\.exe') { $s = Split-Path -Parent $s }
                    if ($s -and (Test-Path -LiteralPath $s -PathType Container)) { $hints.Add($s) }
                }
            }
        }
    } finally { $ErrorActionPreference = $prev }
    return $hints
}

# Process directories: dnplayer.exe etc. live in the install tree itself.
function Get-LdProcessHints {
    $hints = New-Object System.Collections.Generic.List[string]
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($name in @('dnplayer', 'ldconsole', 'dnconsole', 'LdVBoxHeadless', 'Ld9BoxHeadless', 'LdVBoxSVC')) {
            foreach ($p in @(Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                $path = $null
                try { $path = $p.Path } catch { }
                if ($path) { $hints.Add($path) }
            }
        }
    } finally { $ErrorActionPreference = $prev }
    return $hints
}

# Where the last-resort scan should look.
#
# Nothing here is a drive-letter list: the set of letters differs per machine
# (this author's box has C/D/E/F, a fresh install may have only C:, a power user
# may have a dozen), so it is enumerated from Windows instead. What is worth
# spelling out is the ORDER and what is deliberately skipped:
#
#   * fixed volumes first - where an emulator realistically lives
#   * then removable volumes and Unknown ones (a portable install on an external
#     SSD; a `subst` or VHD-mapped letter also reports Unknown)
#   * then volumes with no drive letter at all, scanned through their
#     \\?\Volume{...}\ path (they exist - this machine has one). Volumes under
#     2 GB are skipped: those are the EFI / recovery partitions.
#   * then volumes mounted into a FOLDER (C:\Games being another disk, say).
#     Get-ChildItem -Recurse does NOT descend into a mount point, so the scan
#     would otherwise never see them; Win32_MountPoint names them.
#   * NETWORK drives are skipped on purpose. A mapped share can block for
#     minutes on a dead host, and LDPlayer cannot sensibly run from one. The
#     process / registry paths above still cover them if anyone ever tries.
function Get-LdScanRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $fixed = New-Object System.Collections.Generic.List[string]
    $removable = New-Object System.Collections.Generic.List[string]

    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        # Accessing DriveType throws on a letter with no media (an empty card
        # reader). Skip those rather than failing the whole search.
        $t = $null
        try { $t = $d.DriveType } catch { continue }
        $name = $null
        try { $name = $d.Name } catch { continue }
        if (-not $name) { continue }
        if ($t -eq [System.IO.DriveType]::Fixed) {
            $fixed.Add($name)
        } elseif ($t -eq [System.IO.DriveType]::Removable) {
            $removable.Add($name)
        } elseif ($t -eq [System.IO.DriveType]::Unknown) {
            # subst drives, VHD-mapped volumes and some virtual disks report
            # Unknown - still worth a look, still cheap.
            $removable.Add($name)
        }
        # Network is skipped on purpose (see above). CDRom and NoRootDirectory
        # have nothing to scan.
    }
    foreach ($r in $fixed) { $roots.Add($r) }
    foreach ($r in $removable) { $roots.Add($r) }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue)) {
            if (-not $v) { continue }
            if ($v.DriveLetter) { continue }
            if ($v.DriveType -and $v.DriveType -ne 'Fixed') { continue }
            if ($v.Size -and $v.Size -lt 2GB) { continue }
            if ($v.Path -and ($roots -notcontains $v.Path)) { $roots.Add($v.Path) }
        }
    } catch { }
    try {
        foreach ($m in @(Get-CimInstance -ClassName Win32_MountPoint -ErrorAction SilentlyContinue)) {
            if (-not $m) { continue }
            $dir = $null
            try { $dir = $m.Directory } catch { }
            if ($dir -and -not ($dir -is [string])) { try { $dir = $dir.Name } catch { $dir = $null } }
            if (-not $dir) { continue }
            if ($dir -match '^[A-Za-z]:\\*$') { continue }   # a plain drive root, already listed
            if (Test-Path -LiteralPath $dir -PathType Container) {
                if ($roots -notcontains $dir) { $roots.Add($dir) }
            }
        }
    } catch { }
    finally { $ErrorActionPreference = $prev }

    return $roots
}

# Bounded search of every scan root. Slow path - only used when everything else
# missed, so it prints per-root progress rather than sitting silent for half a
# minute. Depth 5 reaches E:\Tools\Android\LDPlayer9\dnplayer2, and measured
# ~11 s for the worst volume on this machine; the usual case returns on the
# first hit.
function Find-LdByScan {
    param([int]$Depth = 5)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($root in @(Get-LdScanRoots)) {
            Write-Host ('  searching ' + $root + ' for LDPlayer ...')
            foreach ($name in @('ldconsole.exe', 'dnconsole.exe')) {
                $hit = $null
                try {
                    $hit = Get-ChildItem -LiteralPath $root -Filter $name -Recurse -Depth $Depth -File -ErrorAction SilentlyContinue |
                           Select-Object -First 1
                } catch { }
                if ($hit) {
                    $tools = Get-LdToolsFromPath $hit.FullName
                    if ($tools) { return $tools }
                }
            }
        }
    } finally { $ErrorActionPreference = $prev }
    return $null
}

# adb is generic: any adb.exe copies files and installs APKs, so if LDPlayer's
# own copy is missing but one is on PATH / in an SDK, that is good enough.
function Find-AdbAnywhere {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $cmd = Get-Command 'adb.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.Source) { return $cmd.Source }
        foreach ($base in @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT)) {
            if (-not $base) { continue }
            $cand = Join-Path $base 'platform-tools\adb.exe'
            if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
        }
    } finally { $ErrorActionPreference = $prev }
    return ''
}

# The one entry point. Returns $null when LDPlayer cannot be found.
#
#   -Hint    an explicit path the caller already has (file or directory)
#   -Prompt  ask the user for the folder when nothing was found (only use this
#            when a human is actually there to answer)
function Find-LdPlayer {
    [CmdletBinding()]
    param(
        [string]$Hint = '',
        [switch]$Prompt
    )

    $tried = New-Object System.Collections.Generic.List[string]

    # 1. whatever the caller gave us
    if ($Hint) {
        $tried.Add('explicit path')
        $tools = Get-LdToolsFromPath $Hint
        if ($tools) { $tools | Add-Member -NotePropertyName Via -NotePropertyValue 'explicit path' -Force; return $tools }
    }

    # 2. LDPlayer's own running process
    $tried.Add('running process')
    foreach ($h in @(Get-LdProcessHints)) {
        $tools = Get-LdToolsFromPath $h
        if ($tools) { $tools | Add-Member -NotePropertyName Via -NotePropertyValue ('running process: ' + $h) -Force; return $tools }
    }

    # 3. its uninstall registry entry
    $tried.Add('registry')
    foreach ($h in @(Get-LdRegistryHints)) {
        $tools = Get-LdToolsFromPath $h
        if ($tools) { $tools | Add-Member -NotePropertyName Via -NotePropertyValue ('registry: ' + $h) -Force; return $tools }
    }

    # 4. bounded scan of every fixed drive
    $tried.Add('drive scan')
    $tools = Find-LdByScan
    if ($tools) { $tools | Add-Member -NotePropertyName Via -NotePropertyValue 'drive scan' -Force; return $tools }

    # 5. ask the human, if there is one
    if ($Prompt) {
        Write-Host ''
        Write-Warning 'LDPlayer was not found automatically (process / registry / drive scan all missed).'
        Write-Host '  Paste the folder that contains ldconsole.exe (the emulator install folder).'
        Write-Host '  Example: D:\LDPlayer\LDPlayer9   or   C:\Program Files\LDPlayer9'
        # Read-Host throws when there is no console / stdin is redirected (a
        # scheduled run, a piped shell). Never let that mask the real error.
        $answer = $null
        try { $answer = Read-Host 'LDPlayer folder (Enter to give up)' } catch { $answer = $null }
        if ($answer -and $answer.Trim()) {
            $tools = Get-LdToolsFromPath $answer.Trim().Trim('"')
            if ($tools) { $tools | Add-Member -NotePropertyName Via -NotePropertyValue 'user supplied' -Force; return $tools }
            Write-Warning ('no ldconsole.exe under: ' + $answer)
        }
    }

    Write-Verbose ('Find-LdPlayer: searched ' + ($tried -join ', '))
    return $null
}
