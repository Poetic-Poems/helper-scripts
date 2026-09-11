<#
.SYNOPSIS
    Rebuild the WSL VHDX by exporting the distro and importing it again, which
    is the only thing that actually reclaims dead space on this machine.

.DESCRIPTION
    Established 2026-09-10/11: in-place compaction cannot work here. The file is
    sparse, so "diskpart compact vdisk" refuses it outright ("must not be
    sparse" - a VHD API limitation, not a permissions one), and
    "--set-sparse true" is a no-op once the flag is already set. fstrim returns
    about 2 GiB of 32 because NTFS punches 64 KB holes while ext4 frees
    scattered 4 KB blocks. See compact-wsl-vhdx.ps1's .NOTES.

    Export/unregister/import sidesteps all of that: the import writes a fresh
    filesystem containing only live files, so the new VHDX lands at its used
    size. Measured before this run: 88.6 GB allocated against 57.7 GB used.

    THE DANGEROUS WINDOW is between unregister and import, where the tar is the
    only copy of the distro - including the docker volumes holding real state
    (agent-ops_state, supabase_db_poetic-fiddle, and the rest). Two things
    guard it:

      1. The tar is verified by a COMPLETE read (tar -tf to the end) before
         anything is destroyed. That is what catches a truncated or corrupt
         export, which is the realistic failure. A size check alone would not.
      2. A separate archive of the docker volumes is required to exist first,
         so even total loss of the main tar does not cost irreplaceable state.

    Every gate fails closed. Nothing destructive runs unless the gate before it
    passed.

.NOTES
    Run from an ordinary Windows PowerShell - NOT from inside WSL, whose own
    filesystem this destroys midway, and not from a session that has a VS Code
    Remote-WSL window attached, which restarts the distro within about four
    seconds of a shutdown and would corrupt the export.
#>

[CmdletBinding()]
param(
    [string] $Distro       = 'Ubuntu',
    [string] $WorkDir      = 'C:\wsl\rebuild-20260911',
    [string] $ImportPath   = 'C:\WSL\Ubuntu',
    [int]    $MinTarGB     = 30,
    [int]    $MinFreeGB    = 8,
    [switch] $DryRun,
    [switch] $Force,
    # Verify and continue from an export that already exists, instead of
    # spending another half hour writing an identical one. NOTE: anything
    # written inside the distro since that export was taken is NOT in it and
    # will be lost at import.
    [switch] $UseExistingTar
)

# Deliberately NOT 'Stop'. wsl.exe writes routine chatter to stderr - the
# "<3>WSL (nnn) ERROR: UtilAcceptVsock:251: accept4 failed 110" interop warning
# is a live example on this machine - and under 'Stop' a native command writing
# to a redirected stderr raises a terminating NativeCommandError. That would
# abort at an arbitrary point, which during a rebuild could mean between
# unregister and import. Every step below is checked by exit code instead.
$ErrorActionPreference = 'Continue'
$stateDir = Join-Path $env:LOCALAPPDATA 'wsl-maintenance'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$logFile = Join-Path $stateDir ('rebuild-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  {1,-6} {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}
function Stop-Here {
    param([string]$Why)
    Write-Log $Why 'ERROR'
    Write-Log 'STOPPED. Nothing has been destroyed.' 'ERROR'
    exit 1
}

# wsl.exe emits UTF-16LE, which PowerShell decodes as ANSI, leaving embedded
# nulls that make every -match silently fail. Strip them.
function Get-WslText {
    param([string[]]$Arguments)
    $raw = (& wsl.exe @Arguments 2>$null) -join "`n"
    return ($raw -replace "`0", '')
}
function Get-FreeGB {
    [math]::Round((Get-PSDrive -Name C).Free / 1GB, 1)
}

Write-Log ('rebuild starting; log: {0}' -f $logFile)

# ---------------------------------------------------------------------------
# Preflight. Everything that can be checked before anything is touched.
# ---------------------------------------------------------------------------

if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
    Stop-Here 'tar.exe not found. It ships with Windows 10 1803+ and is what verifies the export.'
}

$listed = Get-WslText @('--list', '--quiet')
if ($listed -notmatch [regex]::Escape($Distro)) {
    Stop-Here ("distro '{0}' is not registered - refusing to guess which one you meant." -f $Distro)
}

$volBackup = Join-Path $WorkDir 'docker-volumes.tar.gz'
if (-not (Test-Path $volBackup)) {
    Stop-Here ("the docker volume backup is missing: {0}. It is the safety net for the window where the main tar is the only copy - refusing to proceed without it." -f $volBackup)
}
$volGB = [math]::Round((Get-Item $volBackup).Length / 1GB, 2)
if ($volGB -lt 1) {
    Stop-Here ('the volume backup is only {0} GB, which is too small to be a real archive of ~14 GB of volumes.' -f $volGB)
}
Write-Log ('volume backup present: {0} GB' -f $volGB)

# A VS Code / Cursor Remote-WSL session restarts the distro within seconds of a
# shutdown. During an export that is not an inconvenience, it is corruption.
$pat = '[v]scode-server/bin/|[c]ursor-server/bin/|ms-[v]scode-remote\.remote-wsl'
$attached = & wsl.exe -d $Distro -- bash -c "pgrep -af '$pat' 2>/dev/null | head -1" 2>$null
$attachText = ((@($attached) -join ' ') -replace "`0", '').Trim()
if ($attachText) {
    Write-Log ('attached editor session: {0}' -f ($attachText -replace '\s+', ' ')) 'WARN'
    Stop-Here 'a VS Code / Cursor Remote-WSL session is attached. It would restart the distro mid-export and corrupt it. Close that window and run this again.'
}
Write-Log 'no editor session attached.'

$usedKB = (& wsl.exe -d $Distro -- bash -c "df -k --output=used / | tail -1" 2>$null)
$usedGB = [math]::Round(((($usedKB -join '') -replace "`0", '').Trim() -as [double]) / 1MB, 1)
$freeGB = Get-FreeGB
Write-Log ('C: free {0} GB; used inside WSL {1} GB' -f $freeGB, $usedGB)

# Only the EXPORT needs room for a second copy of the filesystem. Resuming from
# an archive that already exists writes nothing of the sort: the one new file is
# the listing, a few hundred MB, and `unregister` returns the entire old VHDX
# before `import` writes a single byte. Applying the export's requirement to a
# resume is what made a 13.5 GB disk look insufficient for an operation whose
# first act frees 88 GB.
if ($UseExistingTar) {
    if ($freeGB -lt $MinFreeGB) {
        Stop-Here ('C: has {0} GB free; {1} GB is wanted for the listing and Windows headroom.' -f $freeGB, $MinFreeGB)
    }
    Write-Log ('resuming, so no export is written. {0} GB free is enough - unregister returns the old VHDX before import writes anything.' -f $freeGB)
} else {
    $needGB = $usedGB + $MinFreeGB
    if ($freeGB -lt $needGB) {
        Stop-Here ('C: has {0} GB free but the export needs about {1} GB plus {2} GB headroom.' -f $freeGB, $usedGB, $MinFreeGB)
    }
    Write-Log ('export should fit: needs ~{0} GB, have {1} GB.' -f $needGB, $freeGB)
}

if (Test-Path $ImportPath) {
    $existing = @(Get-ChildItem -Path $ImportPath -Force -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0 -and -not $Force) {
        Stop-Here ("{0} already exists and is not empty. Refusing to import over it without -Force." -f $ImportPath)
    }
}

$tar = Join-Path $WorkDir ('{0}.tar' -f $Distro)
if ($UseExistingTar) {
    if (-not (Test-Path $tar)) { Stop-Here ("-UseExistingTar was given but {0} does not exist." -f $tar) }
    $age = [math]::Round(((Get-Date) - (Get-Item $tar).LastWriteTime).TotalMinutes)
    Write-Log ('using the existing export {0} ({1} GB, written {2} minutes ago)' -f $tar, [math]::Round((Get-Item $tar).Length / 1GB, 2), $age) 'WARN'
    Write-Log 'anything written inside the distro since then is NOT in that archive and will be lost.' 'WARN'
} elseif (Test-Path $tar) {
    if (-not $Force) { Stop-Here ("{0} already exists. Move it aside, pass -UseExistingTar to continue from it, or -Force to overwrite." -f $tar) }
    Write-Log ('removing previous export {0}' -f $tar) 'WARN'
    Remove-Item $tar -Force
}

if ($DryRun) {
    Write-Log 'DRY RUN - preflight passed. Would export, verify, unregister and import.'
    exit 0
}

# ---------------------------------------------------------------------------
# Quiesce, then export.
# ---------------------------------------------------------------------------

if ($UseExistingTar) {
    Write-Log 'skipping the export; verifying the existing archive instead.'
    & wsl.exe --terminate $Distro 2>$null | Out-Null
} else {

Write-Log 'stopping containers and the docker daemon for a consistent export'
& wsl.exe -d $Distro -u root -- bash -c 'docker stop $(docker ps -q) 2>/dev/null; service docker stop 2>/dev/null; sync' 2>$null | Out-Null

Write-Log ('wsl --terminate {0}' -f $Distro)
& wsl.exe --terminate $Distro 2>$null | Out-Null

Write-Log ('exporting to {0} - this takes a while and writes ~{1} GB' -f $tar, $usedGB)
$swExport = [Diagnostics.Stopwatch]::StartNew()
& wsl.exe --export $Distro $tar
$exportRc = $LASTEXITCODE
$swExport.Stop()
if ($exportRc -ne 0) { Stop-Here ('wsl --export failed with exit code {0}.' -f $exportRc) }
if (-not (Test-Path $tar)) { Stop-Here 'wsl --export reported success but produced no file.' }

Write-Log ('export finished in {0:n1} min' -f $swExport.Elapsed.TotalMinutes)
}

$tarGB = [math]::Round((Get-Item $tar).Length / 1GB, 2)
Write-Log ('archive to verify: {0} GB' -f $tarGB)

# ---------------------------------------------------------------------------
# THE GATE. Verify by reading the whole archive. Everything after this is
# destructive, so nothing after this runs unless this passes.
# ---------------------------------------------------------------------------

if ($tarGB -lt $MinTarGB) {
    Stop-Here ('the tar is only {0} GB against an expected ~{1} GB - that is a truncated export.' -f $tarGB, $usedGB)
}

Write-Log 'verifying the archive by reading it end to end (this is the real check, and it is slow)'
$listing = Join-Path $WorkDir 'tar-listing.txt'
$tarErr  = Join-Path $WorkDir 'tar-errors.txt'
$swVerify = [Diagnostics.Stopwatch]::StartNew()
# Redirection is handed to cmd.exe rather than done in PowerShell: '2>' in
# PowerShell takes a literal path, not an expression, and redirecting a native
# command's stderr from PowerShell is exactly the combination that produces
# spurious NativeCommandError terminations.
& cmd.exe /c "tar.exe -tf `"$tar`" > `"$listing`" 2> `"$tarErr`""
$verifyRc = $LASTEXITCODE
$swVerify.Stop()
# bsdtar exits 1 both for warnings it recovered from and for genuine damage, so
# the exit code alone cannot decide this. Measured on the 2026-09-11 export:
# five "Archive entry has empty or unreadable filename ... skipping" lines, one
# per socket that WSL had already reported it could not archive (gpg-agent,
# gnome-keyring, tmux, keybase). Sockets carry no data and must not be restored
# anyway, so failing the rebuild on them throws away a 28-minute export for
# nothing.
#
# The messages are therefore CLASSIFIED, not merely counted. Anything that is
# not a recognised harmless skip is treated as damage; and a large number of
# even harmless skips still stops the run, because at that point something
# other than a few sockets is going on. Truncation - the failure that actually
# matters here - reports "Unexpected EOF in archive" and does not match the
# benign pattern, so it still stops everything.
if ($verifyRc -ne 0) {
    $errLines = @()
    if (Test-Path $tarErr) { $errLines = @(Get-Content $tarErr | Where-Object { $_.Trim() }) }
    $benign = '(empty or unreadable filename|Error exit delayed from previous errors)'
    $unexplained = @($errLines | Where-Object { $_ -notmatch $benign })
    $skips = @($errLines | Where-Object { $_ -match 'empty or unreadable filename' }).Count

    foreach ($l in ($errLines | Select-Object -First 8)) { Write-Log ('tar: {0}' -f $l) 'WARN' }

    if ($unexplained.Count -gt 0) {
        Stop-Here ('the archive did not read cleanly: {0} of {1} messages are not recognised skips (first: "{2}"). It is not safe to unregister.' -f $unexplained.Count, $errLines.Count, $unexplained[0])
    }
    if ($skips -gt 100) {
        Stop-Here ('{0} entries were skipped as unreadable. A handful of sockets is expected; this is not that.' -f $skips)
    }
    Write-Log ('tar exited {0}, on {1} skipped socket entries, all recognised as harmless - continuing.' -f $verifyRc, $skips)
}

$entries = (Get-Content $listing -ReadCount 10000 | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
Write-Log ('archive read cleanly in {0:n1} min; {1:n0} entries' -f $swVerify.Elapsed.TotalMinutes, $entries)
if ($entries -lt 100000) {
    Stop-Here ('only {0} entries - that is not a full root filesystem.' -f $entries)
}

# Sentinels: things whose absence would mean the export is not what we think.
foreach ($needle in @('home/wallen/', 'etc/wsl.conf', 'var/lib/docker/')) {
    if (-not (Select-String -Path $listing -SimpleMatch -Pattern $needle -Quiet)) {
        Stop-Here ("the archive has no '{0}' - refusing to treat it as a complete backup." -f $needle)
    }
    Write-Log ("sentinel present: {0}" -f $needle)
}
Remove-Item $listing -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Destructive from here.
# ---------------------------------------------------------------------------

Write-Log ('unregistering {0} - the tar is now the only copy' -f $Distro) 'WARN'
& wsl.exe --unregister $Distro
if ($LASTEXITCODE -ne 0) { Stop-Here ('wsl --unregister failed with exit code {0}. The distro should still be intact.' -f $LASTEXITCODE) }
Write-Log ('unregistered. C: free {0} GB' -f (Get-FreeGB))

if (-not (Test-Path $ImportPath)) { New-Item -ItemType Directory -Path $ImportPath -Force | Out-Null }
Write-Log ('importing to {0}' -f $ImportPath)
$swImport = [Diagnostics.Stopwatch]::StartNew()
& wsl.exe --import $Distro $ImportPath $tar --version 2
$importRc = $LASTEXITCODE
$swImport.Stop()
if ($importRc -ne 0) {
    Write-Log ('wsl --import FAILED with exit code {0}.' -f $importRc) 'ERROR'
    Write-Log ('The export is intact at {0} and the volume backup at {1}.' -f $tar, $volBackup) 'ERROR'
    Write-Log ('Recover with:  wsl --import {0} "{1}" "{2}" --version 2' -f $Distro, $ImportPath, $tar) 'ERROR'
    exit 1
}
Write-Log ('imported in {0:n1} min' -f $swImport.Elapsed.TotalMinutes)

# ---------------------------------------------------------------------------
# Verify what came back.
# ---------------------------------------------------------------------------

$who = ((Get-WslText @('-d', $Distro, '--', 'id', '-un'))).Trim()
if ($who -eq 'wallen') { Write-Log 'default user is wallen.' }
else {
    Write-Log ("default user came back as '{0}', not wallen. /etc/wsl.conf should carry [user] default=wallen." -f $who) 'WARN'
    Write-Log 'Fix: add it, then wsl --terminate Ubuntu.' 'WARN'
}

$homeOk = ((Get-WslText @('-d', $Distro, '--', 'bash', '-c', 'test -d /home/wallen/Code && echo yes'))).Trim()
Write-Log ('/home/wallen/Code present: {0}' -f $(if ($homeOk -eq 'yes') { 'yes' } else { 'NO' }))

Write-Log 'starting docker'
& wsl.exe -d $Distro -u root -- bash -c 'service docker start' 2>$null | Out-Null
Start-Sleep -Seconds 15
$vols = ((Get-WslText @('-d', $Distro, '--', 'bash', '-c', 'docker volume ls -q 2>/dev/null | wc -l'))).Trim()
Write-Log ('docker volumes visible: {0}' -f $vols)

$newVhdx = Join-Path $ImportPath 'ext4.vhdx'
if (Test-Path $newVhdx) {
    $newGB = [math]::Round((Get-Item $newVhdx).Length / 1GB, 1)
    Write-Log ('new ext4.vhdx apparent size: {0} GB (was 110.6 GB apparent / 88.6 GB allocated)' -f $newGB)
}

Write-Log ('done. C: free {0} GB' -f (Get-FreeGB))
Write-Log ''
Write-Log 'The export and the volume backup have been LEFT IN PLACE deliberately.'
Write-Log ('Delete them only once you are satisfied everything works:')
Write-Log ('    {0}' -f $tar)
Write-Log ('    {0}' -f $volBackup)
