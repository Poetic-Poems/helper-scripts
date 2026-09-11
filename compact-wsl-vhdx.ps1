<#
.SYNOPSIS
    Reclaim the dead space inside the WSL2 ext4.vhdx, without interrupting a
    running agent-ops cycle.

.DESCRIPTION
    The WSL virtual disk only ever grows. Blocks freed inside Linux are handed
    back to Windows lazily and incompletely: on 2026-09-10 the file held 90 GiB
    on C: against 58 GiB actually in use inside, and a full fstrim of the whole
    filesystem returned 2 GiB of the 32 GiB gap. WSL punches holes at a coarse
    granularity, and ext4 fragmentation leaves almost every host block partly
    live, so the rest is only recoverable with the distro stopped.

    This script is the part of the maintenance that has to stop the distro.
    wsl-disk-janitor.sh, running hourly inside WSL, does everything that does
    not. Between them the disk is meant to look after itself.

    Because stopping the distro stops the fleet, the run is gated six ways and
    simply returns if any gate is shut. The scheduled task fires hourly, so a
    run deferred now is retried within the hour and will land in an idle gap on
    its own.

      1. Due?    A successful compaction within the last -IntervalDays, and
                 dead space under -MinDeadSpaceGB, means there is nothing worth
                 a bounce. Overridden when C: falls under -CriticalFreeGB.
      1b. Can    diskpart refuses a VHDX that is sparse, NTFS-compressed or
          it?    encrypted, so on such a file there is nothing a bounce could
                 do. Asked of the filesystem every run, never remembered. Also
                 stands down for -IntervalDays after a completed run that
                 recovered under 1 GB, so a lever that has stopped working
                 costs one bounce a week rather than one a night.
      1c. Able?  diskpart needs an elevated token. A task created without
                 /RL HIGHEST cannot compact anything, so it says so and stands
                 down instead of stopping the fleet for nothing.
      2. Quiet?  Outside 02:00-06:00 local, only a critically low disk or
                 -Force will proceed.
      3. Idle?   Every scheduler is asked, through its own
                 watchtower-pre-update.sh, whether a cycle is running. That
                 script is the fleet's existing "safe to interrupt" signal:
                 0 means safe, 75 (EX_TEMPFAIL) means a cycle holds the lock.
                 One busy node defers the whole run.
      4. Alone?  No VS Code / Cursor Remote-WSL session may be attached. Such a
                 session restarts the distro within about four seconds of the
                 shutdown, which makes compaction impossible rather than merely
                 slow - measured at 18:28:41 on 2026-09-10, four seconds after
                 an 18:28:37 shutdown.

    What it does once every gate opens:

      wsl --shutdown
      delete every Temp\<guid>\swap.vhdx  (with the VM down they are all dead)
      diskpart compact vdisk              (rewrites the file without the blocks
                                           the guest has TRIMmed - the one lever
                                           that works on a non-sparse VHDX)
      wsl -d <distro> -- true             (wsl.conf's [boot] command brings up
                                           cron, docker and tailscaled)
      docker compose up -d in each node directory

    What was reclaimed is measured on the VHDX file itself, before and after.
    C: free space is not the measure: the swap file is deleted at shutdown and
    would count as 2 GB "recovered" on every run.

    That last step matters and is easy to miss. agent-ops-dashboard-1 and
    agent-ops-tailscale-1 have restart policy on-failure, not unless-stopped,
    so a clean daemon stop leaves them down. The schedulers, egress proxies and
    watchtower return by themselves; those two do not.

.NOTES
    Which lever works depends on the NTFS state of the file, and that state
    has already changed once.

    Until 2026-09-11 the VHDX was SPARSE (sparseVhd=true, plus a one-off
    --set-sparse true), and in-place compaction recovered essentially nothing.
    Established by a complete elevated run on 2026-09-10:

      - "--set-sparse true" is a no-op once the flag is already set. It
        reported success and gained 0.5 GB, and even that was the swap file
        being deleted at shutdown: allocated size went 90.0 -> 91 GB across the
        whole run, against 33 GB of dead space.
      - "diskpart compact vdisk" refuses outright: "Virtual hard disk files
        must be uncompressed and unencrypted and must not be sparse." That is
        the VHD API, so elevation does not help and Hyper-V's Optimize-VHD,
        which calls the same API, would fail identically.
      - Guest-side discard (fstrim) returns about 2 GiB of 32. NTFS punches
        holes in 64 KB units while ext4 frees scattered 4 KB blocks, so nearly
        every host unit keeps at least one live block and cannot be released.

    On 2026-09-11 the distro was rebuilt (rebuild-wsl-vhdx.ps1: export,
    unregister, import), which wrote a fresh 57 GB file for 56 GB used, and
    straight afterwards the file was made NON-SPARSE ("wsl --manage Ubuntu
    --set-sparse false") and NTFS-uncompressed ("compact /u"). That is the
    regime this script now assumes: the file only ever grows, the guest TRIMs
    hourly (the janitor's fstrim) so the VHDX knows which of its blocks are
    dead, and "diskpart compact vdisk" rewrites it without them. That needs
    the distro stopped and an elevated token, which is what the gates are for.

    Two rules follow:

      - "--set-sparse false" inflates a sparse file to its full apparent size.
        It is nearly free straight after a rebuild (apparent = allocated) and
        ruinous once dead space has accrued (111 GiB against 48 GiB free on
        2026-09-10). Never run it on a file with a large gap between apparent
        and allocated size.
      - The file must not be NTFS-compressed. On 2026-09-11 C: had been
        compressed with inheritance, so the freshly imported VHDX came back
        compressed: 1,807,061 extents at birth, one per 64 KB compression
        unit. NTFS cannot grow a file whose extent list outgrows its MFT
        record, and on a VM disk that surfaces as ext4 write errors. diskpart
        refuses compressed files as well. Gate 1b checks for it every run.

    If the file is ever sparse again this script stands down at gate 1b, and
    the only way back is another rebuild. rebuild-wsl-vhdx.ps1 now leaves the
    imported file non-sparse and uncompressed itself.

    A shutdown terminates everything in WSL, including any interactive session
    running there. That is why the default window is the small hours.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File compact-wsl-vhdx.ps1 -DryRun
    Report what the gates say and what would be reclaimed, changing nothing.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File compact-wsl-vhdx.ps1 -Force
    Compact now if the fleet is idle, ignoring the schedule and the hour.
    The fleet-idle gate is never bypassed.
#>
[CmdletBinding()]
param(
    [switch] $Force,
    [switch] $DryRun,
    [int]    $MinDeadSpaceGB  = 20,
    [int]    $CriticalFreeGB  = 15,
    [int]    $IntervalDays    = 7,
    [int]    $QuietStartHour  = 2,
    [int]    $QuietEndHour    = 6,
    [string] $Distro          = 'Ubuntu',
    [string[]] $NodeDirs      = @('~/poetic-node-1', '~/poetic-node-2')
)

$ErrorActionPreference = 'Continue'

$stateDir  = Join-Path $env:LOCALAPPDATA 'wsl-maintenance'
$stateFile = Join-Path $stateDir 'compact-state.json'
$logFile   = Join-Path $stateDir ('compact-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0}  {1,-5}  {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

function Get-FreeGB {
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    if (-not $c) { return 0 }
    return [math]::Round($c.FreeSpace / 1GB, 1)
}

# The registry is the authoritative location of a distro's backing file. The
# Packages\<publisher-id>\LocalState path is only where a *Store-installed*
# Ubuntu happens to sit; a distro that has been exported and re-imported - the
# one route that actually reclaims dead space - lives wherever it was imported
# to. A glob would then match nothing and this script would report "ext4.vhdx
# not found" forever. The glob is kept as a fallback.
function Get-Vhdx {
    $base = $null
    Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue |
        ForEach-Object {
            $d = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($d.DistributionName -eq $Distro -and $d.BasePath) { $base = $d.BasePath }
        }
    if ($base) {
        # BasePath is sometimes stored with a \\?\ prefix.
        $base = $base -replace '^\\\\\?\\', ''
        $f = Get-Item -LiteralPath (Join-Path $base 'ext4.vhdx') -ErrorAction SilentlyContinue
        if ($f) { return $f }
    }
    Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages\*Ubuntu*\LocalState\ext4.vhdx') `
        -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# The VHD API refuses to compact a file that is sparse, NTFS-compressed or
# encrypted ("Virtual hard disk files must be uncompressed and unencrypted and
# must not be sparse"). Asked of the filesystem on every run rather than
# remembered, because the state has changed under this script before: the
# 2026-09-11 rebuild came back sparse AND compressed until both were undone by
# hand. Returns the reason, or $null when diskpart can work on the file.
function Get-UncompactableReason {
    param([string]$Path)
    try {
        $attr = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Attributes
    } catch { return 'unreadable' }
    if ($attr -band [IO.FileAttributes]::SparseFile) { return 'sparse' }
    if ($attr -band [IO.FileAttributes]::Compressed) { return 'NTFS-compressed' }
    if ($attr -band [IO.FileAttributes]::Encrypted)  { return 'encrypted' }
    return $null
}

# Rebuilt into a fixed shape on every read rather than returned as parsed.
# Assigning to a property that a PSCustomObject does not already carry throws
# ("The property 'x' cannot be found on this object"), and a state file written
# by an earlier version of this script is missing the fields added since. Every
# write below happens AFTER the fleet has been stopped, which is the worst
# possible place to discover a missing property, so the shape is guaranteed
# here instead of being trusted.
function Get-State {
    $raw = $null
    if (Test-Path $stateFile) {
        try { $raw = Get-Content $stateFile -Raw | ConvertFrom-Json } catch { }
    }
    $has = { param($n) $raw -and ($raw.PSObject.Properties.Name -contains $n) }
    return [pscustomobject]@{
        lastSuccess     = if (& $has 'lastSuccess')     { $raw.lastSuccess }     else { $null }
        lastAttempt     = if (& $has 'lastAttempt')     { $raw.lastAttempt }     else { $null }
        lastResult      = if (& $has 'lastResult')      { $raw.lastResult }      else { 'never run' }
        lastReclaimedGB = if (& $has 'lastReclaimedGB') { $raw.lastReclaimedGB } else { $null }
        # When the run last got as far as diskpart, success or not. lastAttempt
        # also moves on every deferral, so it cannot key the futility check.
        lastCompleted   = if (& $has 'lastCompleted')   { $raw.lastCompleted }   else { $null }
    }
}

function Set-State {
    param($State)
    $State | ConvertTo-Json -Depth 4 | Set-Content -Path $stateFile -Encoding UTF8
}

# The janitor inside WSL leaves its measurement here. Reading it saves starting
# the distro purely to measure, but it is only trusted if it is recent.
function Get-DeadSpaceGB {
    # Through a shell, not "wsl -- cat": wsl runs the command directly, so a
    # bare $HOME or ~ would reach cat as a literal and never resolve.
    $out = & wsl.exe -d $Distro -- bash -c 'cat "$HOME/.local/state/wsl-disk-janitor/status.json" 2>/dev/null' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $null }
    try {
        $j = ($out -join "`n") | ConvertFrom-Json
        $age = (Get-Date).ToUniversalTime() - [datetime]::Parse($j.measured_at).ToUniversalTime()
        if ($age.TotalHours -gt 6) { return $null }
        return [double]$j.dead_space_gb
    } catch { return $null }
}

# ---------------------------------------------------------------------------
# Gate 1: is there anything worth a bounce?
# ---------------------------------------------------------------------------

$state    = Get-State
$freeGB   = Get-FreeGB
$vhdx     = Get-Vhdx
$critical = $freeGB -lt $CriticalFreeGB

Write-Log ("C: free {0} GB; last successful compaction: {1}" -f $freeGB,
           $(if ($state.lastSuccess) { $state.lastSuccess } else { 'never' }))

if (-not $vhdx) {
    Write-Log "ext4.vhdx not found (registry BasePath, then LOCALAPPDATA\Packages) - nothing to do." 'WARN'
    exit 1
}

$deadGB = Get-DeadSpaceGB
if ($null -ne $deadGB) { Write-Log ("dead space reported by the janitor: {0} GB" -f $deadGB) }
else { Write-Log "no recent janitor measurement; falling back to the schedule alone" }

$dueBySchedule = $true
if ($state.lastSuccess) {
    $since = (Get-Date) - [datetime]::Parse($state.lastSuccess)
    $dueBySchedule = $since.TotalDays -ge $IntervalDays
}
$dueByDeadSpace = ($null -ne $deadGB) -and ($deadGB -ge $MinDeadSpaceGB)

if (-not ($Force -or $critical -or ($dueBySchedule -and ($dueByDeadSpace -or $null -eq $deadGB)))) {
    Write-Log "not due (compacted recently, and dead space is below the threshold) - nothing to do."
    exit 0
}
if ($critical) { Write-Log ("C: is under {0} GB free - treating as urgent." -f $CriticalFreeGB) 'WARN' }

# ---------------------------------------------------------------------------
# Gate 1b: can a bounce do anything at all?
#
# Every run costs a full fleet stop and restart, so it is not started unless
# the one lever can actually move. Two things stop it:
#
#   - The file's NTFS state. diskpart refuses a sparse, compressed or
#     encrypted VHDX; on such a file no bounce recovers anything and the only
#     way out is a rebuild. Not overridable by -Force, because there is
#     nothing for -Force to do.
#   - The measured result of the last completed run. If diskpart ran within
#     the last -IntervalDays and recovered under 1 GB, the janitor's dead-space
#     figure and reality disagree, and repeating nightly until they agree would
#     bounce the fleet for nothing. One try a week keeps it visible without
#     making it a habit. -Force overrides this half, which makes it testable.
$why = Get-UncompactableReason $vhdx.FullName
if ($why) {
    Write-Log ('the VHDX is {0}, which diskpart refuses to compact - a bounce could recover nothing, so not stopping the fleet. See .NOTES: this needs a rebuild.' -f $why) 'WARN'
    if ($critical) {
        Write-Log ("C: is critically low and compaction cannot help it - the janitor's hourly " +
                   "sweep is the only automatic lever left.") 'WARN'
    }
    exit 0
}
$lastGain = $state.lastReclaimedGB
if ((-not $Force) -and $state.lastCompleted -and ($null -ne $lastGain) -and ([double]$lastGain -lt 1)) {
    $sinceRun = (Get-Date) - [datetime]::Parse($state.lastCompleted)
    if ($sinceRun.TotalDays -lt $IntervalDays) {
        Write-Log ('the last completed run ({0:n1} days ago) recovered {1} GB - not bouncing the fleet again until {2} days have passed. Check that run''s log.' -f $sinceRun.TotalDays, $lastGain, $IntervalDays)
        exit 0
    }
}

# ---------------------------------------------------------------------------
# Gate 1c: is this process able to run diskpart?
#
# diskpart needs an elevated token, and a scheduled task only has one if it
# was created with /RL HIGHEST from an elevated shell. Checked before the gates
# that cost something and long before the shutdown, because a run that cannot
# compact must not stop the fleet. The fix is one command, so the log carries
# it. A dry run reports the verdict and carries on, so the other gates can
# still be read from an ordinary prompt.
# ---------------------------------------------------------------------------

if (-not (Test-Elevated)) {
    Write-Log 'not elevated: diskpart cannot run, so there is nothing this run could reclaim.' 'WARN'
    Write-Log ('fix once, from an Administrator prompt:  schtasks /Create /TN "WSL VHDX maintenance" /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ''{0}''" /SC HOURLY /RL HIGHEST /F' -f $PSCommandPath) 'WARN'
    if (-not $DryRun) { exit 0 }
    Write-Log 'DRY RUN - continuing through the remaining gates for the report.'
}

# ---------------------------------------------------------------------------
# Gate 2: is this a reasonable hour?
# ---------------------------------------------------------------------------

$hour = (Get-Date).Hour
$quiet = ($hour -ge $QuietStartHour) -and ($hour -lt $QuietEndHour)
if (-not ($quiet -or $Force -or $critical)) {
    Write-Log ("due, but {0}:00 is outside the {1}:00-{2}:00 window - deferring to the next run." -f $hour, $QuietStartHour, $QuietEndHour)
    exit 0
}

# ---------------------------------------------------------------------------
# Gate 3: is the fleet idle? Never bypassed, not even by -Force.
# ---------------------------------------------------------------------------

# This gate is fail-safe by construction: anything that cannot be positively
# verified as idle counts as busy. A false "idle" shuts down a running cycle; a
# false "busy" only means trying again in an hour.
#
# Deciding whether WSL is up takes two independent signals because the obvious
# one is a trap. wsl.exe writes its own UI text as UTF-16LE, which PowerShell
# decodes as ANSI, so "Ubuntu" arrives as "U\0b\0u\0n\0t\0u\0" and a plain
# -match against it is always False. Reading that as "WSL is not running" would
# skip this entire gate. The vmmemWSL process is the encoding-free check, and
# the null-stripped list is the corroborating one; either saying yes means yes.

function Get-WslText {
    # wsl.exe's own messages, with the UTF-16 nulls removed.
    param([string[]]$Arguments)
    $raw = (& wsl.exe @Arguments 2>$null) -join "`n"
    return ($raw -replace "`0", '')
}

$vmUp = @(Get-Process -Name 'vmmemWSL', 'vmmem' -ErrorAction SilentlyContinue).Count -gt 0
$listText = Get-WslText @('--list', '--running')
$listedUp = $listText -match [regex]::Escape($Distro)
$wslWasRunning = $vmUp -or $listedUp

Write-Log ("WSL running: {0}  (vm process: {1}, distro listed: {2})" -f $wslWasRunning, $vmUp, $listedUp)

function Stop-Here {
    param([string]$Why)
    Write-Log ("{0} - deferring to the next run." -f $Why)
    $state.lastAttempt = (Get-Date).ToString('o')
    $state.lastResult  = "deferred: $Why"
    Set-State $state
    exit 0
}

if ($wslWasRunning) {
    # WSL's interop on this machine drops calls intermittently: the same
    # "wsl -d Ubuntu -- ..." invocation returns in under a second on one run
    # and times out after thirty on the next, and it recovers by itself. That
    # is a fault in its own right, but here it only needs tolerating, so the
    # reachability probe gets a few attempts before the run gives up. A genuine
    # answer of "busy" is never retried - only a failure to get any answer.
    $schedulers = $null
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $schedulers = & wsl.exe -d $Distro -- docker ps --filter 'name=scheduler' --format '{{.Names}}' 2>$null
        if ($LASTEXITCODE -eq 0) { break }
        Write-Log ("docker was not reachable through WSL interop (attempt {0} of 3)" -f $attempt) 'WARN'
        if ($attempt -lt 3) { Start-Sleep -Seconds 10 }
    }
    if ($LASTEXITCODE -ne 0) { Stop-Here 'could not reach docker inside WSL to check the fleet' }

    $schedulers = @($schedulers | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
    if ($schedulers.Count -eq 0) {
        # WSL is up but no scheduler is. That is either a fleet that is
        # genuinely down or a docker that is lying; neither is worth risking.
        Stop-Here 'WSL is running but no scheduler container was found'
    }

    # 0 (idle) and 75 (EX_TEMPFAIL, a cycle holds the lock) are real answers
    # from watchtower-pre-update.sh and are acted on immediately. Anything else
    # means wsl.exe never got to run it - measured here at 182ms for a native
    # `docker exec` against 31s for the same call through interop - so those
    # are retried, and a run that still cannot get an answer defers.
    foreach ($s in $schedulers) {
        $rc = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            & wsl.exe -d $Distro -- docker exec $s /app/deploy/docker/watchtower-pre-update.sh 2>$null | Out-Null
            $rc = $LASTEXITCODE
            if ($rc -eq 0 -or $rc -eq 75) { break }
            Write-Log ("{0}: no answer through interop, exit {1} (attempt {2} of 3)" -f $s, $rc, $attempt) 'WARN'
            if ($attempt -lt 3) { Start-Sleep -Seconds 10 }
        }
        if ($rc -eq 0) {
            Write-Log ("{0}: idle" -f $s)
        } elseif ($rc -eq 75) {
            Stop-Here ("{0} is mid-cycle (EX_TEMPFAIL)" -f $s)
        } else {
            Stop-Here ("{0} never answered the idle check (last exit {1})" -f $s, $rc)
        }
    }
} else {
    Write-Log "WSL is not running - no fleet to protect."
}

# ---------------------------------------------------------------------------
# Gate 4: is anything on the Windows side holding the distro open?
# ---------------------------------------------------------------------------
#
# Learned on 2026-09-10, the expensive way. A run got all the way through the
# idle gate, shut the fleet down, and then found the VM back up: VS Code's
# Remote-WSL extension had reconnected and restarted the distro four seconds
# after `wsl --shutdown`. Compaction needs minutes of exclusive access to the
# VHDX, so that race is not winnable - and the cost of discovering it late is a
# fleet bounced for nothing.
#
# Live `vscode-server` / `cursor-server` processes inside the distro mean an
# editor window is attached and will reconnect. Checking for them here turns a
# wasted shutdown into a deferral that names the thing to close.
#
# Two things about the pattern, both of which produced a false positive first:
# the leading character of each alternative is bracketed so the regex cannot
# match the command line of the very shell carrying it (without that, pgrep
# always finds itself and this gate fires forever, silently preventing every
# compaction while looking like a polite deferral); and each alternative names
# a real installed path rather than a bare word, so an unrelated process that
# merely mentions "vscode-server" does not trip it.

if ($wslWasRunning) {
    $pat = '[v]scode-server/bin/|[c]ursor-server/bin/|ms-[v]scode-remote\.remote-wsl'
    $attached = & wsl.exe -d $Distro -- bash -c "pgrep -af '$pat' 2>/dev/null | head -1" 2>$null
    $attachText = ((@($attached) -join ' ') -replace "`0", '').Trim()
    if ($attachText) {
        $shown = ($attachText -replace '\s+', ' ')
        if ($shown.Length -gt 110) { $shown = $shown.Substring(0, 110) }
        Write-Log ("attached editor session: {0}" -f $shown)
        Stop-Here 'a VS Code / Cursor Remote-WSL session is attached and would restart the distro within seconds of the shutdown - close that window and this will run'
    }
}

# ---------------------------------------------------------------------------
# Do the work.
# ---------------------------------------------------------------------------

if ($DryRun) {
    Write-Log "DRY RUN - all gates open; would shut down WSL, clear orphan swap files and compact."
    exit 0
}

$freeBefore = Get-FreeGB
Write-Log ("compacting. C: free before: {0} GB; vhdx: {1} GB" -f $freeBefore, [math]::Round($vhdx.Length / 1GB, 1))

Write-Log "wsl --shutdown"
$shutdownMsg = Get-WslText @('--shutdown')
if ($shutdownMsg.Trim()) { Write-Log $shutdownMsg.Trim() }

# Wait for the VM to actually be gone. Compacting a file the VM still holds
# open fails, and on some builds fails silently. The same two signals as the
# idle gate, and for the same reason: here a false "stopped" would mean
# compacting a live disk, so both have to agree it is down.
$shutdownAt = Get-Date
$deadline = $shutdownAt.AddSeconds(90)
do {
    Start-Sleep -Seconds 2
    $procUp = @(Get-Process -Name 'vmmemWSL', 'vmmem' -ErrorAction SilentlyContinue).Count -gt 0
    $listUp = (Get-WslText @('--list', '--running')) -match [regex]::Escape($Distro)
    $stillUp = $procUp -or $listUp
} while ($stillUp -and (Get-Date) -lt $deadline)

if ($stillUp) {
    # "Still up" has two very different causes and the fix differs completely,
    # so distinguish them rather than reporting a bare timeout. Asking the
    # distro when it booted settles it without having to catch the transition:
    # a boot timestamp later than the shutdown means it DID stop and something
    # started it again.
    $restarted = $false
    $bootRaw = & wsl.exe -d $Distro -- bash -c 'uptime -s' 2>$null
    if ($LASTEXITCODE -eq 0 -and $bootRaw) {
        try {
            $bootTime = [datetime]::Parse((($bootRaw -join '') -replace "`0", '').Trim())
            if ($bootTime -gt $shutdownAt) {
                $restarted = $true
                $gap = [int]($bootTime - $shutdownAt).TotalSeconds
            }
        } catch { }
    }

    if ($restarted) {
        Write-Log ("WSL shut down and something restarted it {0}s later, so the disk was never free." -f $gap) 'ERROR'
        Write-Log "The usual cause is an open VS Code window attached over Remote-WSL: the" 'ERROR'
        Write-Log "extension reconnects within seconds, and compaction needs minutes of" 'ERROR'
        Write-Log "exclusive access, so the race cannot be won. Close the VS Code (or Cursor)" 'ERROR'
        Write-Log "window connected to WSL and this will succeed on the next run." 'ERROR'
        $state.lastResult = "aborted: something restarted WSL after ${gap}s (likely VS Code Remote-WSL)"
    } else {
        Write-Log "WSL did not stop within 90s - aborting rather than compacting a live file." 'ERROR'
        $state.lastResult = 'aborted: WSL would not stop'
    }
    $state.lastAttempt = (Get-Date).ToString('o')
    Set-State $state
    exit 1
}
Write-Log "WSL is stopped."

# With the VM down every swap.vhdx under Temp belongs to a VM that no longer
# exists. These accrue at about 2 GiB per unclean shutdown and nothing in
# Windows collects them.
$swaps = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Temp\*\swap.vhdx') -ErrorAction SilentlyContinue
foreach ($s in $swaps) {
    $sizeGB = [math]::Round($s.Length / 1GB, 2)
    try {
        Remove-Item $s.FullName -Force -ErrorAction Stop
        Write-Log ("removed orphan swap file: {0} ({1} GB)" -f $s.FullName, $sizeGB)
        $parent = Split-Path $s.FullName -Parent
        if (-not (Get-ChildItem $parent -Force -ErrorAction SilentlyContinue)) {
            Remove-Item $parent -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log ("could not remove {0}: {1}" -f $s.FullName, $_.Exception.Message) 'WARN'
    }
}

# diskpart rewrites the VHDX without the blocks the guest has TRIMmed. The
# result is measured on the file itself: with the sparse flag off, Length is
# exactly what C: is charged for it.
$lenBefore = (Get-Item -LiteralPath $vhdx.FullName -Force).Length
Write-Log ('diskpart compact vdisk; vhdx is {0} GB' -f [math]::Round($lenBefore / 1GB, 1))
$script = Join-Path $env:TEMP 'compact-wsl.txt'
@(
    ('select vdisk file="{0}"' -f $vhdx.FullName)
    'attach vdisk readonly'
    'compact vdisk'
    'detach vdisk'
) | Set-Content -Path $script -Encoding ASCII
& diskpart.exe /s $script 2>&1 | ForEach-Object { if ("$_".Trim()) { Write-Log ('  ' + "$_".Trim()) } }
$compactRc = $LASTEXITCODE
Remove-Item $script -Force -ErrorAction SilentlyContinue

$lenAfter  = (Get-Item -LiteralPath $vhdx.FullName -Force).Length
$reclaimed = [math]::Round(($lenBefore - $lenAfter) / 1GB, 1)
$freeAfter = Get-FreeGB
if ($compactRc -ne 0) {
    Write-Log ('diskpart exited {0}; vhdx {1} -> {2} GB' -f $compactRc, [math]::Round($lenBefore / 1GB, 1), [math]::Round($lenAfter / 1GB, 1)) 'ERROR'
} else {
    Write-Log ('vhdx {0} -> {1} GB (recovered {2} GB); C: free {3} GB' -f [math]::Round($lenBefore / 1GB, 1), [math]::Round($lenAfter / 1GB, 1), $reclaimed, $freeAfter)
}

# ---------------------------------------------------------------------------
# Bring it all back.
# ---------------------------------------------------------------------------

Write-Log "restarting WSL"
& wsl.exe -d $Distro -- /bin/true 2>&1 | ForEach-Object { Write-Log $_ }

# wsl.conf's [boot] command starts cron, docker and tailscaled, but not
# instantly. Wait for the daemon rather than racing it with compose.
$deadline = (Get-Date).AddSeconds(120)
do {
    Start-Sleep -Seconds 5
    & wsl.exe -d $Distro -- docker info 2>$null | Out-Null
    $dockerUp = ($LASTEXITCODE -eq 0)
} while (-not $dockerUp -and (Get-Date) -lt $deadline)

if (-not $dockerUp) {
    Write-Log "docker did not come up within 120s - the fleet needs a hand." 'ERROR'
    $state.lastAttempt = (Get-Date).ToString('o'); $state.lastCompleted = $state.lastAttempt
    $state.lastReclaimedGB = $reclaimed; $state.lastResult = 'compacted, but docker did not restart'
    Set-State $state
    exit 1
}
Write-Log "docker is up."

# unless-stopped containers are already back; on-failure ones (the dashboard
# and the tailscale sidecar) are not. compose settles both.
foreach ($d in $NodeDirs) {
    Write-Log ("docker compose up -d in {0}" -f $d)
    & wsl.exe -d $Distro -- bash -lc "cd $d && docker compose up -d" 2>&1 |
        ForEach-Object { Write-Log ("  " + $_) }
}

$names = & wsl.exe -d $Distro -- docker ps --format '{{.Names}}' 2>$null
Write-Log ("containers running: {0}" -f (@($names | Where-Object { $_ }) -join ', '))

$now = (Get-Date).ToString('o')
$state.lastAttempt   = $now
$state.lastCompleted = $now
# Kept as its own field, not parsed back out of lastResult, because gate 1b
# reads it and a gate that depends on scraping a human-readable string is one
# reworded log line away from silently never firing.
$state.lastReclaimedGB = $reclaimed
if ($compactRc -eq 0) {
    $state.lastSuccess = $now
    $state.lastResult  = ('recovered {0} GB; vhdx {1} GB; C: free {2} GB' -f $reclaimed, [math]::Round($lenAfter / 1GB, 1), $freeAfter)
} else {
    $state.lastResult  = ('diskpart failed (exit {0}); fleet restarted; C: free {1} GB' -f $compactRc, $freeAfter)
}
Set-State $state
Write-Log ('done. {0}' -f $state.lastResult)
