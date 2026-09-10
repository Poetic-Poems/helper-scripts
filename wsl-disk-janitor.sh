#!/usr/bin/bash
#
# wsl-disk-janitor.sh [-n|--dry-run] [--tier auto|routine|low|urgent] [--status]
#
# Keep C: from filling up, unattended, without ever touching live work.
#
# Why this exists alongside clean-machine.sh: that one is the deep manual
# sweep. It switches branches, pulls, gcs and deletes branches — right when you
# are watching it, wrong on a timer. This is the subset that is safe to run
# every hour with nobody looking, and it covers three ratchets clean-machine
# never touched.
#
# The three ratchets, as measured on 2026-09-10 (476 GB disk, 39 GB free):
#
#   1. Orphaned swap files. WSL puts the VM's 2 GiB swap.vhdx in a per-boot
#      GUID directory under %LOCALAPPDATA%\Temp and removes it on a *clean*
#      shutdown. This machine does not reliably get one: four orphans had piled
#      up — 7.6 GiB from crashes on Sep 4, 5, 7 and 8. Nothing in Windows ever
#      collects them, so they accrue at ~2 GiB per crash forever.
#   2. Caches. ms-playwright 3.2G, puppeteer 1.2G, npm 2.4G, pip 280M,
#      typescript 264M, cpan 507M — around 10 GiB, all of it re-downloadable.
#   3. Dead space inside ext4.vhdx. 90 GiB allocated on C: against 58 GiB
#      actually used inside: 32 GiB held and never given back. This script
#      CANNOT fix that one — see "On compaction" at the foot of this comment.
#      It measures it and says when recovering it is worth a bounce.
#
# Nothing here needs root. fstrim is the only privileged operation and it goes
# through a throwaway privileged container, because this box's user is in the
# docker group while sudo wants a password. If docker is down, the trim is
# skipped and said so, rather than the run failing.
#
# What it will never do, deliberately:
#
#   - `docker volume prune`. Several volumes here report 0 links but hold real
#     state: supabase_db_poetic-fiddle, agent-ops-2_tailscale-state,
#     docker_grafana_db. Pruning volumes on this box loses data. `docker system
#     prune` is called without --volumes for exactly this reason.
#   - Touch agent-ops_state or agent-ops-2_state (5.7G + 4.1G). That growth is
#     fleet-log snapshot retention, which is agent-ops's own business
#     (agent-ops#1025). It is reported every run, never swept.
#   - Touch .nvm, any node_modules, or any git repository. clean-machine.sh
#     owns repositories; this script does not go near them.
#   - Delete a swap.vhdx that could be the live one. An orphan is defined as a
#     swap.vhdx whose mtime predates this VM's boot, which the running VM's
#     file can never satisfy. Windows' own file lock is the second backstop.
#
# On compaction. The VHDX is already sparse and the filesystem is already
# mounted `discard`, so blocks are being returned continuously — and it is not
# enough. A full `fstrim` of the whole filesystem was measured to hand back
# 2 GiB out of 32, because WSL punches holes at a coarse granularity and ext4
# fragmentation leaves almost every host block partly live. The remaining dead
# space needs the VHDX compacted offline, with the distro stopped. That is
# compact-wsl-vhdx.ps1, run from Windows on a schedule, and it is the only part
# of this that interrupts the fleet.
#
# NEVER run `wsl --manage Ubuntu --set-sparse false` on this machine. It
# inflates the file to its full apparent size — 111 GiB against 42 GiB free —
# and fills the disk it is trying to empty.

set -uo pipefail

name=$(basename -s.sh "$0")
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Logs go under ~/.local/state rather than beside the script, which is what
# clean-machine.sh does. That script is run by hand from ~/bin; this one runs
# hourly from cron and lives in a git working tree, so writing its logs next to
# itself would leave a fresh untracked file every hour.
LOG_DIR=${LOG_DIR:-$HOME/.local/state/$name}
out="$LOG_DIR/$name.$now.log"
mkdir -p "$LOG_DIR" 2>/dev/null

LOG_RETENTION_DAYS=14

# Tier thresholds, in GB free on C:. Floors, never ceilings — each tier does
# everything the tiers above it do, and more. The numbers are set against a
# 476 GB disk whose healthy resting state after compaction is about 75 GB free.
FREE_LOW=${FREE_LOW:-40}         # start shedding package caches
FREE_URGENT=${FREE_URGENT:-25}   # start shedding browser downloads too
FREE_CRITICAL=${FREE_CRITICAL:-15}  # shout; the box wedges not far below this

# Recovering less than this by compacting is not worth bouncing the fleet.
DEAD_SPACE_WORTH_COMPACTING_GB=${DEAD_SPACE_WORTH_COMPACTING_GB:-20}

WIN_TEMP=${WIN_TEMP:-/mnt/c/Users/warwi_b/AppData/Local/Temp}
STATUS_FILE=${STATUS_FILE:-$HOME/.local/state/wsl-disk-janitor/status.json}

DRY=${DRYRUN:-0}
TIER=auto
status_only=0

while (( $# )); do
  case "$1" in
    -n|--dry-run) DRY=1; shift ;;
    --wet-run)    DRY=0; shift ;;
    --tier)       TIER="$2"; shift 2 ;;
    --status)     status_only=1; shift ;;
    -h|--help)    sed -n '3,/^# NEVER/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "wsl-disk-janitor: unknown argument: $1" >&2; exit 2 ;;
  esac
done

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# Every measurement in this script is in bytes and comes from one of these two.
# `df /` is deliberately not among them: the root filesystem reports 1007G with
# 899G "available", which is the size of the virtual disk and not a fact about
# any real storage. What is true about C: comes from C:.
free_bytes_on_c() { df -B1 --output=avail /mnt/c 2>/dev/null | tail -1 | tr -dc 0-9; }
used_bytes_in_wsl() { df -B1 --output=used / 2>/dev/null | tail -1 | tr -dc 0-9; }

# Bytes to GB. The clamp is only there to stop a run that reclaimed nothing
# printing "-0.0 GB" because a few hundred bytes moved the wrong way.
gb() { awk -v b="${1:-0}" 'BEGIN { v = b / 1073741824; if (v > -0.05 && v < 0.05) v = 0; printf "%.1f", v }'; }

# The distro's backing file. Derived rather than hardcoded: a Store-installed
# Ubuntu lives under Packages/<publisher-id>/LocalState, and re-registering the
# distro changes that id.
find_vhdx() {
  local p
  for p in /mnt/c/Users/*/AppData/Local/Packages/*Ubuntu*/LocalState/ext4.vhdx; do
    [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# du reports blocks actually allocated; --apparent-size reports the size the
# file claims. On a sparse VHDX the gap between them is space Windows has
# already taken back, and the gap between *allocated* and what is used inside
# the VM is the dead space only compaction recovers.
vhdx_allocated_bytes() { du -sB1 "$1" 2>/dev/null | cut -f1; }
vhdx_apparent_bytes()  { du -sB1 --apparent-size "$1" 2>/dev/null | cut -f1; }

# --- measurement -------------------------------------------------------------

vhdx=$(find_vhdx) || vhdx=""
free_now=$(free_bytes_on_c); free_now=${free_now:-0}
used_in=$(used_bytes_in_wsl); used_in=${used_in:-0}
alloc=0; apparent=0; dead=0
if [[ -n "$vhdx" ]]; then
  alloc=$(vhdx_allocated_bytes "$vhdx"); alloc=${alloc:-0}
  apparent=$(vhdx_apparent_bytes "$vhdx"); apparent=${apparent:-0}
  (( alloc > used_in )) && dead=$(( alloc - used_in ))
fi

free_gb=$(gb "$free_now")
dead_gb=$(gb "$dead")

# Resolve the tier once, from the free space, unless one was forced. Floors,
# not ceilings: each tier does everything the looser ones do, and more.
# FREE_CRITICAL deliberately has no tier of its own — there is nothing left to
# shed below `urgent`, so it only decides how loudly the run ends.
below() { awk -v f="$free_gb" -v t="$1" 'BEGIN { exit !(f < t) }'; }

if [[ "$TIER" == auto ]]; then
  if   below "$FREE_URGENT"; then TIER=urgent
  elif below "$FREE_LOW";    then TIER=low
  else                            TIER=routine
  fi
fi

# A machine-readable line for the Windows scheduled task and for anything that
# wants to graph this. Written before the sweep as well as after, so a run that
# dies half way still leaves the measurement it started from.
write_status() {
  local phase="$1" f d
  f=$(free_bytes_on_c); d=0
  [[ -n "$vhdx" ]] && { local a; a=$(vhdx_allocated_bytes "$vhdx"); (( a > used_in )) && d=$(( a - used_in )); }
  mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null
  cat > "$STATUS_FILE" <<EOF
{
  "measured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "phase": "$phase",
  "tier": "$TIER",
  "c_free_gb": $(gb "${f:-0}"),
  "wsl_used_gb": $(gb "$used_in"),
  "vhdx_allocated_gb": $(gb "$alloc"),
  "vhdx_apparent_gb": $(gb "$apparent"),
  "dead_space_gb": $(gb "$d"),
  "compaction_worthwhile": $(awk -v d="$(gb "$d")" -v t="$DEAD_SPACE_WORTH_COMPACTING_GB" 'BEGIN { print (d >= t) ? "true" : "false" }')
}
EOF
}

if (( status_only )); then
  write_status measurement-only
  cat "$STATUS_FILE"
  exit 0
fi

echo -e "Logging to $out\\n"
{

say "$now  —  tier: $TIER"
say
say "== measured"
note "C: free              ${free_gb} GB"
note "used inside WSL      $(gb "$used_in") GB"
if [[ -n "$vhdx" ]]; then
  note "ext4.vhdx allocated  $(gb "$alloc") GB   (apparent $(gb "$apparent") GB)"
  note "dead space           ${dead_gb} GB   — only compaction recovers this"
else
  note "ext4.vhdx            not found; dead space unknown"
fi
say

write_status before

# Prune this script's own logs first, so a long run of them cannot itself
# become the thing filling the disk.
while IFS= read -r -d '' old; do
  if (( DRY )); then say "would remove  $old  (log older than ${LOG_RETENTION_DAYS} days)"
  else rm -f "$old"
  fi
done < <(find "$LOG_DIR" -maxdepth 1 -name "${name}.*.log" \
           -mtime +"$LOG_RETENTION_DAYS" -print0 2>/dev/null)

# --- 1. orphaned swap files --------------------------------------------------
#
# The live VM's swap.vhdx is written to continuously, so its mtime is always
# after boot. Anything older belongs to a VM that no longer exists. Windows
# refuses to delete a file it still has open, which is the second line of
# defence behind that test.

say "== orphaned swap files (pre-boot swap.vhdx under %LOCALAPPDATA%\\Temp)"
boot_epoch=$(date -d "$(uptime -s)" +%s 2>/dev/null || echo 0)
swap_found=0
if [[ -d "$WIN_TEMP" ]]; then
  while IFS= read -r -d '' f; do
    swap_found=1
    m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    sz=$(du -h "$f" 2>/dev/null | cut -f1)
    if (( m >= boot_epoch )); then
      note "keep $sz  $(basename "$(dirname "$f")")  — written since boot, this VM is using it"
      continue
    fi
    if (( DRY )); then
      say "would remove  $sz  $(basename "$(dirname "$f")")/swap.vhdx  (orphan from $(date -d "@$m" '+%Y-%m-%d %H:%M'))"
    else
      if rm -f "$f" 2>/dev/null && [[ ! -e "$f" ]]; then
        say "removed       $sz  $(basename "$(dirname "$f")")/swap.vhdx  (orphan from $(date -d "@$m" '+%Y-%m-%d %H:%M'))"
        rmdir "$(dirname "$f")" 2>/dev/null
      else
        note "refused $sz $(basename "$(dirname "$f")") — Windows holds it open; left alone"
      fi
    fi
  done < <(find "$WIN_TEMP" -maxdepth 2 -name swap.vhdx -print0 2>/dev/null)
fi
(( swap_found )) || note "none present"
say

# --- 2. docker ---------------------------------------------------------------
#
# --volumes is absent on purpose; see the header. This removes stopped
# containers, dangling images and build cache, none of which any running
# container depends on.

say "== docker"
if docker info >/dev/null 2>&1; then
  if (( DRY )); then
    note "would run  docker system prune -f   (never --volumes)"
    docker system df 2>/dev/null | sed 's/^/  /'
  else
    docker system prune -f 2>/dev/null | sed 's/^/  /'
  fi
  # Reported, never swept: the fleet's own state volumes. If these dominate,
  # the fix is agent-ops's retention, not a janitor.
  while IFS= read -r line; do
    note "state volume (not swept): $line"
  done < <(docker system df -v 2>/dev/null | awk '/^agent-ops.*_state/ { print $1, $3 }')
else
  note "docker is not responding — skipped"
fi
say

# --- 3. caches ---------------------------------------------------------------
#
# Everything in this table is re-downloadable. The tier column is the floor at
# which it starts being shed: routine leaves all of it alone, because a cache
# that is refetched every day is a cost, not a saving.

say "== caches (tier: $TIER)"

sweep_path() {  # sweep_path <path> <why>
  local p="$1" why="$2" sz
  [[ -e "$p" ]] || return 0
  sz=$(du -sh "$p" 2>/dev/null | cut -f1)
  if (( DRY )); then
    say "would remove  ${sz:-?}  $p  ($why)"
  else
    say "removing      ${sz:-?}  $p  ($why)"
    rm -rf -- "$p"
  fi
}

run_cmd() {  # run_cmd <description> <command...>
  local d="$1"; shift
  if (( DRY )); then say "would run     $d"
  else say "running       $d"; "$@" >/dev/null 2>&1 || note "($d failed or was a no-op)"
  fi
}

case "$TIER" in
  routine)
    note "C: has ${free_gb} GB free (>= ${FREE_LOW} GB) — caches left intact"
    ;;
  low|urgent)
    run_cmd "npm cache clean --force" npm cache clean --force
    run_cmd "pip cache purge"         python3 -m pip cache purge
    sweep_path "$HOME/.cache/typescript" "regenerated on next tsc"
    sweep_path "$HOME/.cpan/build"       "cpan build scratch"
    sweep_path "$HOME/.cache/Homebrew"   "re-downloaded on demand"
    ;;&
  urgent)
    # Browser binaries: several GB each and slow to refetch, so they only go
    # when the disk is genuinely tight, and only versions nothing has touched
    # for a month.
    for root in "$HOME/.cache/ms-playwright" "$HOME/.cache/puppeteer"; do
      [[ -d "$root" ]] || continue
      while IFS= read -r -d '' v; do
        sweep_path "$v" "browser build unused for 30+ days"
      done < <(find "$root" -mindepth 1 -maxdepth 1 -mtime +30 -print0 2>/dev/null)
    done
    sweep_path "$HOME/.cache/pip" "pip http cache"
    ;;
esac
say

# --- 4. trim -----------------------------------------------------------------
#
# The filesystem is mounted `discard` so this is mostly belt and braces, but a
# full-filesystem FITRIM still catches regions freed by operations that did not
# issue a discard of their own. It reclaims single-figure GB at best; the bulk
# needs compaction.

say "== trim"
if (( DRY )); then
  note "would run  fstrim / via a privileged container"
elif docker info >/dev/null 2>&1; then
  docker run --rm --privileged -v /:/host alpine:latest fstrim -v /host 2>&1 \
    | sed 's/^/  /' || note "fstrim failed"
else
  note "docker is not responding — trim skipped"
fi
say

# --- verdict -----------------------------------------------------------------

write_status after
free_after=$(free_bytes_on_c); free_after=${free_after:-0}
gained=$(( free_after - free_now ))

say "== result"
note "C: free  ${free_gb} GB -> $(gb "$free_after") GB  (recovered $(gb "$gained") GB)"

if awk -v d="$dead_gb" -v t="$DEAD_SPACE_WORTH_COMPACTING_GB" 'BEGIN { exit !(d >= t) }'; then
  say
  say "  ${dead_gb} GB is dead space inside ext4.vhdx and no amount of sweeping"
  say "  in here will return it. Recovering it needs the distro stopped:"
  say "      compact-wsl-vhdx.ps1   (runs hourly, but acts only in the small hours"
  say "                              and only when every scheduler reports idle)"
fi

if awk -v f="$(gb "$free_after")" -v t="$FREE_CRITICAL" 'BEGIN { exit !(f < t) }'; then
  say
  say "  *** C: is below ${FREE_CRITICAL} GB free after sweeping. This box wedges when the"
  say "  *** disk fills — the pagefile and the working set starve each other. Compact"
  say "  *** now rather than waiting for the weekly window."
fi

(( DRY )) && { say; say "DRY RUN — nothing was deleted"; }

} 2>&1 | tee "$out"
