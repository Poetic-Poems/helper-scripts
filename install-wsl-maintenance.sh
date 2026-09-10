#!/usr/bin/bash
#
# install-wsl-maintenance.sh [--uninstall] [--dry-run]
#
# Make the disk look after itself. Installs the two halves of the maintenance
# and the one config change that stops the biggest leak at source:
#
#   1. wsl-disk-janitor.sh on an hourly cron entry, inside WSL. Everything that
#      can be done without interrupting anything: orphaned swap files, docker
#      prune, tiered cache shedding, fstrim.
#   2. compact-wsl-vhdx.ps1 on an hourly Windows scheduled task. Almost every
#      run does nothing; it compacts only when there is real dead space to
#      recover, the hour is quiet, and every scheduler says no cycle is
#      running. Hourly rather than weekly precisely so that a run deferred by a
#      busy node is retried soon and lands in an idle gap by itself.
#   3. swapFile= pinned in .wslconfig, so the VM's 2 GiB swap file lives at one
#      fixed path instead of a fresh Temp\<guid>\ directory per boot. WSL only
#      deletes that directory on a clean shutdown, so on this machine they
#      accumulated at about 2 GiB per crash - 7.6 GiB of them by 2026-09-10.
#      Pinning the path means there is only ever one, reused.
#
# Two deliberate choices, both scars from agent-ops#1347:
#
#   - The cron entry is hourly, never @reboot. A boot-time hook races whatever
#     else is coming up; that is exactly how the cgroup-parent hook left a
#     poisoned path and an unbootable node. Nothing here runs at boot.
#   - Installing REPLACES any previous entry for these scripts rather than
#     appending. Re-running this script cannot leave two copies behind.
#
# The scheduled task points at a copy of the .ps1 under %LOCALAPPDATA%, not at
# the one in this repo. The repo is inside WSL, and a script that begins by
# shutting WSL down must not be reading itself over \\wsl.localhost while it
# does so. Re-run this installer after editing the .ps1 to refresh that copy.

set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
janitor="$here/wsl-disk-janitor.sh"
compactor="$here/compact-wsl-vhdx.ps1"

TASK_NAME=${TASK_NAME:-WSL VHDX maintenance}
CRON_MARK='wsl-disk-janitor.sh'
# A Windows path, single backslashes. It reaches awk through the environment
# rather than -v because awk processes escape sequences in a -v assignment, so
# a path passed that way silently loses (or doubles) its backslashes depending
# on how it was quoted here.
SWAP_PATH_WIN=${SWAP_PATH_WIN:-'C:\wsl\swap.vhdx'}

dry=0; uninstall=0
while (( $# )); do
  case "$1" in
    --uninstall) uninstall=1; shift ;;
    --dry-run)   dry=1; shift ;;
    -h|--help)   sed -n '3,/^# The scheduled task/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install-wsl-maintenance: unknown argument: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
run()  { if (( dry )); then say "would run: $*"; else "$@"; fi; }

# Asked of PowerShell rather than cmd.exe: cmd refuses to keep a UNC working
# directory and silently falls back to C:\Windows, which mangles the answer
# when this is run from the repo (which lives inside WSL).
winenv() { powershell.exe -NoProfile -Command "\$env:$1" 2>/dev/null | tr -d '\r\n'; }

winprofile=$(wslpath "$(winenv USERPROFILE)" 2>/dev/null)
localappdata=$(wslpath "$(winenv LOCALAPPDATA)" 2>/dev/null)
wslconfig="$winprofile/.wslconfig"
installed_ps1_wsl="$localappdata/wsl-maintenance/compact-wsl-vhdx.ps1"
installed_ps1_win='%LOCALAPPDATA%\wsl-maintenance\compact-wsl-vhdx.ps1'

# --- crontab ----------------------------------------------------------------
#
# Read once, filter out any entry mentioning this script, add the new one back.
# Appending is what leaves duplicates behind on a second run.

install_cron() {
  local tmp entry
  # flock matches the convention the existing entries use, and matters more
  # here than for most: an fstrim of a 90 GiB disk can outlast the hour on a
  # busy machine, and two of these running at once would fight over the same
  # caches. :17 keeps it clear of clean-machine.sh at :13.
  entry="17 * * * * flock -n /tmp/wsl-disk-janitor.lck $janitor >/dev/null 2>&1"
  tmp=$(mktemp)
  crontab -l 2>/dev/null | grep -Fv "$CRON_MARK" > "$tmp"
  (( uninstall )) || printf '%s\n' "$entry" >> "$tmp"
  if (( dry )); then
    say "would install this crontab:"
    sed 's/^/    /' "$tmp"
  else
    crontab "$tmp" && note "crontab updated"
  fi
  rm -f "$tmp"
}

# --- scheduled task ---------------------------------------------------------

install_task() {
  if (( uninstall )); then
    run schtasks.exe /Delete /TN "$TASK_NAME" /F
    return
  fi
  if (( dry )); then
    say "would copy   $compactor -> $installed_ps1_wsl"
    say "would create scheduled task '$TASK_NAME' (hourly, highest privileges)"
    return
  fi
  mkdir -p "$(dirname "$installed_ps1_wsl")"
  cp "$compactor" "$installed_ps1_wsl" && note "copied the compactor to $installed_ps1_win"

  # Two levels, because they buy different things.
  #
  # /RL HIGHEST lets the diskpart fallback run without a UAC prompt, and
  # registering a task at that level needs an elevated shell. Without it the
  # task still works and still compacts - it just loses the fallback for the
  # case where `--set-sparse true` reclaims nothing on its own. That is worth
  # having anyway, so a failure here drops to a normal task rather than
  # installing nothing.
  #
  # Note the task is deliberately left as "run only when the user is logged
  # on", which is schtasks' default without /RU. A task set to run whether or
  # not the user is logged on executes in session 0, where wsl.exe generally
  # cannot reach the VM at all - and this task's entire safety gate depends on
  # being able to ask the schedulers whether they are busy.
  local tr="powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"$installed_ps1_win\""
  # The same thing with single quotes inside, so the hint below can be pasted
  # into a shell without its nested double quotes closing the outer pair.
  local tr_display="powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$installed_ps1_win'"
  if schtasks.exe /Create /TN "$TASK_NAME" /TR "$tr" /SC HOURLY /RL HIGHEST /F >/dev/null 2>&1; then
    note "scheduled task '$TASK_NAME' created (hourly, highest privileges)"
  elif schtasks.exe /Create /TN "$TASK_NAME" /TR "$tr" /SC HOURLY /F >/dev/null 2>&1; then
    note "scheduled task '$TASK_NAME' created (hourly, normal privileges)"
    say
    say "  Created without highest privileges, which needs an elevated shell."
    say "  Everything works; only the diskpart fallback is unavailable, and that"
    say "  is used solely when 'wsl --manage --set-sparse true' reclaims nothing"
    say "  by itself. To add it later, run this once as Administrator:"
    say
    say "      schtasks /Create /TN \"$TASK_NAME\" /TR \"$tr_display\" /SC HOURLY /RL HIGHEST /F"
    say
  else
    say "  Could not create the scheduled task. Run this as Administrator:"
    say "      schtasks /Create /TN \"$TASK_NAME\" /TR \"$tr_display\" /SC HOURLY /RL HIGHEST /F"
  fi
}

# --- .wslconfig -------------------------------------------------------------
#
# Inserted directly after the existing swap= line so it lands inside [wsl2] and
# not in the [experimental] section that follows. A backup is taken first; this
# file is hand-written and worth not mangling.

install_swapfile_pin() {
  [[ -f "$wslconfig" ]] || { note ".wslconfig not found at $wslconfig - skipped"; return; }

  if (( uninstall )); then
    note "leaving swapFile= in .wslconfig alone (removing it would orphan the pinned file)"
    return
  fi

  if grep -qi '^[[:space:]]*swapFile[[:space:]]*=' "$wslconfig"; then
    note "swapFile= is already set in .wslconfig - unchanged"
    return
  fi
  if ! grep -qi '^[[:space:]]*swap[[:space:]]*=' "$wslconfig"; then
    note "no swap= line found in .wslconfig - not guessing where to put swapFile="
    return
  fi

  if (( dry )); then
    say "would add swapFile=$SWAP_PATH_WIN to .wslconfig after the swap= line"
    return
  fi

  cp -p "$wslconfig" "$wslconfig.bak-$(date -u +%Y%m%dT%H%M%SZ)"
  local tmp; tmp=$(mktemp)
  SWAP_PATH_WIN="$SWAP_PATH_WIN" awk '
    { print }
    !added && /^[[:space:]]*swap[[:space:]]*=/ {
      print ""
      print "# Pin the swap file to one fixed path. Left to itself WSL puts it in a fresh"
      print "# Temp\\<guid>\\ directory per boot and only removes that directory on a clean"
      print "# shutdown, so every crash leaks another 2 GiB onto C: with nothing in Windows"
      print "# to collect it. Seven point six GiB of them had accrued by 2026-09-10. One"
      print "# fixed path means one file, reused."
      print "swapFile=" ENVIRON["SWAP_PATH_WIN"]
      added = 1
    }
  ' "$wslconfig" > "$tmp" && mv "$tmp" "$wslconfig" \
    && note "swapFile=$SWAP_PATH_WIN added to .wslconfig (backup kept)"
  rm -f "$tmp" 2>/dev/null

  # The directory has to exist before WSL will use the path.
  local swapdir; swapdir=$(wslpath "${SWAP_PATH_WIN%\\*}" 2>/dev/null)
  [[ -n "$swapdir" ]] && mkdir -p "$swapdir" 2>/dev/null
}

# --- go ---------------------------------------------------------------------

if (( uninstall )); then
  say "== removing WSL disk maintenance"
else
  say "== installing WSL disk maintenance"
  for f in "$janitor" "$compactor"; do
    [[ -f "$f" ]] || { echo "install-wsl-maintenance: missing $f" >&2; exit 1; }
  done
  chmod +x "$janitor"
fi

say
say "cron (inside WSL, hourly):"
install_cron
say
say "scheduled task (Windows, hourly):"
install_task
say
say ".wslconfig:"
install_swapfile_pin
say

if (( uninstall )); then
  say "Removed. Nothing is scheduled any more."
else
  say "Installed."
  note "the janitor runs at :17 past each hour (clean-machine.sh already has :13)"
  note "  its logs and its status.json are under ~/.local/state/wsl-disk-janitor/"
  note "the compactor runs hourly but acts only when there is dead space worth"
  note "  recovering, the hour is between 02:00 and 06:00, and every scheduler is idle"
  note "swapFile= takes effect at the next 'wsl --shutdown' - the compactor's first"
  note "  successful run will do that for you"
  say
  note "check it any time with:  $janitor --status"
  note "force a compaction with: powershell.exe -ExecutionPolicy Bypass -File '$installed_ps1_win' -Force"
fi
