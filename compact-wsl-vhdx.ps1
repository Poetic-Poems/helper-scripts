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

    Because stopping the distro stops the fleet, the run is gated three ways
    and simply returns if any gate is shut. The scheduled task fires hourly,
    so a run deferred now is retried within the hour and will land in an idle
    gap on its own.

      1. Due?    A successful compaction within the last -IntervalDays, and
                 dead space under -MinDeadSpaceGB, means there is nothing worth
                 a bounce. Overridden when C: falls under -CriticalFreeGB.
      2. Quiet?  Outside 02:00-06:00 local, only a critically low disk or
                 -Force will proceed.
      3. Idle?   Every scheduler is asked, through its own
                 watchtower-pre-update.sh, whether a cycle is running. That
                 script is the fleet's existing "safe to interrupt" signal:
                 0 means safe, 75 (EX_TEMPFAIL) means a cycle holds the lock.
                 One busy node defers the whole run.

    What it does once all three gates open:

      wsl --shutdown
      delete every Temp\<guid>\swap.vhdx  (with the VM down they are all dead)
      wsl --manage <distro> --set-sparse true
      diskpart compact vdisk              (only if the above reclaimed nothing
                                           and we are running elevated)
      wsl -d <distro> -- true             (wsl.conf's [boot] command brings up
                                           cron, docker and tailscaled)
      docker compose up -d in each node directory

    That last step matters and is easy to miss. agent-ops-dashboard-1 and
    agent-ops-tailscale-1 have restart policy on-failure, not unless-stopped,
    so a clean daemon stop leaves them down. The schedulers, egress proxies and
    watchtower return by themselves; those two do not.

.NOTES
    NEVER run "wsl --manage Ubuntu --set-sparse false" on this machine. It
    inflates the file to its full apparent size, which is 111 GiB against
    roughly 42 GiB free, and fills the disk it is meant to be emptying.

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

function Get-Vhdx {
    Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Packages\*Ubuntu*\LocalState\ext4.vhdx') `
        -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-State {
    if (Test-Path $stateFile) {
        try { return Get-Content $stateFile -Raw | ConvertFrom-Json } catch { }
    }
    return [pscustomobject]@{ lastSuccess = $null; lastAttempt = $null; lastResult = 'never run' }
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
    Write-Log "ext4.vhdx not found under LOCALAPPDATA\Packages - nothing to do." 'WARN'
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
# Do the work.
# ---------------------------------------------------------------------------

if ($DryRun) {
    Write-Log "DRY RUN - all gates open; would shut down WSL, clear orphan swap files and compact."
    exit 0
}

$freeBefore = Get-FreeGB
Write-Log ("compacting. C: free before: {0} GB; vhdx apparent: {1} GB" -f $freeBefore, [math]::Round($vhdx.Length / 1GB, 1))

Write-Log "wsl --shutdown"
$shutdownMsg = Get-WslText @('--shutdown')
if ($shutdownMsg.Trim()) { Write-Log $shutdownMsg.Trim() }

# Wait for the VM to actually be gone. Compacting a file the VM still holds
# open fails, and on some builds fails silently. The same two signals as the
# idle gate, and for the same reason: here a false "stopped" would mean
# compacting a live disk, so both have to agree it is down.
$deadline = (Get-Date).AddSeconds(90)
do {
    Start-Sleep -Seconds 3
    $procUp = @(Get-Process -Name 'vmmemWSL', 'vmmem' -ErrorAction SilentlyContinue).Count -gt 0
    $listUp = (Get-WslText @('--list', '--running')) -match [regex]::Escape($Distro)
    $stillUp = $procUp -or $listUp
} while ($stillUp -and (Get-Date) -lt $deadline)

if ($stillUp) {
    Write-Log "WSL did not stop within 90s - aborting rather than compacting a live file." 'ERROR'
    $state.lastAttempt = (Get-Date).ToString('o'); $state.lastResult = 'aborted: WSL would not stop'
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

# Primary: the supported, unprivileged path. On an already-sparse disk this
# still walks the file and releases what it can.
Write-Log ("wsl --manage {0} --set-sparse true" -f $Distro)
$sparseMsg = Get-WslText @('--manage', $Distro, '--set-sparse', 'true')
if ($sparseMsg.Trim()) { Write-Log $sparseMsg.Trim() }

$freeMid = Get-FreeGB
Write-Log ("C: free after set-sparse: {0} GB (gained {1} GB)" -f $freeMid, [math]::Round($freeMid - $freeBefore, 1))

# Fallback: diskpart actually rewrites the file, which recovers what
# hole-punching cannot. It needs elevation, which the scheduled task supplies
# by running with highest privileges.
if (($freeMid - $freeBefore) -lt 1) {
    if (Test-Elevated) {
        Write-Log "set-sparse reclaimed little; falling back to diskpart compact vdisk."
        $script = Join-Path $env:TEMP 'compact-wsl.txt'
        @(
            ('select vdisk file="{0}"' -f $vhdx.FullName)
            'attach vdisk readonly'
            'compact vdisk'
            'detach vdisk'
        ) | Set-Content -Path $script -Encoding ASCII
        & diskpart.exe /s $script 2>&1 | ForEach-Object { Write-Log $_ }
        Remove-Item $script -Force -ErrorAction SilentlyContinue
    } else {
        Write-Log "set-sparse reclaimed little and diskpart needs elevation - skipping the fallback." 'WARN'
    }
}

$freeAfter = Get-FreeGB
Write-Log ("C: free after compaction: {0} GB (recovered {1} GB in total)" -f $freeAfter, [math]::Round($freeAfter - $freeBefore, 1))

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
    $state.lastAttempt = (Get-Date).ToString('o'); $state.lastResult = 'compacted, but docker did not restart'
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

$state.lastSuccess = (Get-Date).ToString('o')
$state.lastAttempt = (Get-Date).ToString('o')
$state.lastResult  = ('recovered {0} GB; C: free {1} GB' -f [math]::Round($freeAfter - $freeBefore, 1), $freeAfter)
Set-State $state
Write-Log ("done. {0}" -f $state.lastResult)
