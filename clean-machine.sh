#!/usr/bin/bash
#
# clean-machine.sh [-n|--dry-run] — reclaim disk without destroying live work.
#
# This box wedges when the disk fills (the pagefile and the working set starve
# each other), so sweeping stale scratch matters. What follows is the same
# sweep, with the four ways the previous version could take live work:
#
#   1. `find /tmp -maxdepth 1 -mmin +N -exec rm -rf {}` includes find's own
#      starting point, so a /tmp whose own mtime had aged past N meant
#      `rm -rf /tmp` — every socket, every live session, the lot.
#   2. A *directory's* mtime only moves when an entry is added or removed
#      directly inside it. `/tmp/claude-1000` is one entry holding every Claude
#      session; five quiet hours at the top level made it "stale" no matter how
#      recently the sessions underneath were writing, and it went as one.
#      Liveness now means "newest file anywhere in the tree", never the
#      directory's own stamp.
#   3. `git switch main` ran in every repo it found, yanking anyone working on
#      a branch back to main mid-task.
#   4. `git branch -D` force-deleted *every* non-current branch, including ones
#      whose commits existed nowhere else.
#
# Nothing here is deleted unless it is both stale throughout and recoverable.
# Run with -n first if you want to see what it would do.

directory=$(dirname "$0")
basename=.$(basename -s.sh "$0")
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
out="$directory/$basename.$now.log"
echo -e Logging to $out\\n
{

set -uo pipefail

USER=$(whoami)
LOG_RETENTION_DAYS=7
AGE_HOURS="${AGE_HOURS:-12}"
mins=$(( 60 * AGE_HOURS ))
DRY=${DRYRUN:-0}    # DRYRUN can be set in the environment.
case "${1:-}" in -n|--wet-run) DRY=0 ;; esac
case "${1:-}" in -n|--dry-run) DRY=1 ;; esac

kept=0; swept=0

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

say $now

# Remove old logs
(( DRY )) && dry_guard=echo || dry_guard=
find "$directory"                               \
  -maxdepth 1                                   \
  -name "$(<<<"$basename" sed 's/[*?]/\\&/g')*" \
  -mtime +$LOG_RETENTION_DAYS                   \
  -exec $dry_guard rm -v {} +

# Delete, or say what would have been deleted. Never called on a root.
sweep() {
  local p="$1" why="$2"
  if (( DRY )); then
    say "would remove  $p  ($why)"
  else
    say "removing      $p  ($why)"
    rm -rf -- "$p"
  fi
  swept=$(( swept + 1 ))
}
keep() { note "keep $1 — $2"; kept=$(( kept + 1 )); }

# Anything modified inside the tree within the window. `-print -quit` stops at
# the first hit, so this costs almost nothing on a live tree and a full walk
# only on one that is genuinely cold.
has_recent() {
  [[ -n "$(find "$1" -newermt "-$mins minutes" -print -quit 2>/dev/null)" ]]
}

# Work that exists nowhere but here: uncommitted changes, or commits on a local
# branch that no remote carries. Either makes the tree unrecoverable, so it is
# never swept however cold it looks.
holds_unpushed_work() {
  local g repo
  while IFS= read -r g; do
    repo="${g%/.git}"
    git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]] && return 0
    [[ -n "$(git -C "$repo" log --branches --not --remotes --oneline -1 2>/dev/null)" ]] && return 0
  done < <(find "$1" -maxdepth 4 -type d -name .git 2>/dev/null)
  return 1
}

# Sockets and the X/ICE rendezvous directories are ancient by design and in use
# regardless; deleting one breaks a running program rather than freeing space.
is_protected() {
  case "$(basename "$1")" in
    .X11-unix|.ICE-unix|.font-unix|.XIM-unix|.Test-unix) return 0 ;;
    systemd-*|snap*|tailscaled*|docker*|containerd*)     return 0 ;;
    tmux-1000)                                           return 0 ;;
  esac
  [[ -S "$1" ]]
}

sweep_dir() {  # sweep_dir <root>
  local root="$1" p
  [[ -d "$root" ]] || return 0
  say "== $root (older than ${AGE_HOURS}h, throughout)"
  # -mindepth 1: never the root itself. That is hazard 1.
  while IFS= read -r -d '' p; do
    if is_protected "$p";        then keep "$p" "protected name or socket";      continue; fi
    if [[ ! -O "$p" ]];          then keep "$p" "not owned by ${USER}";          continue; fi
    if has_recent "$p";          then keep "$p" "modified within ${AGE_HOURS}h"; continue; fi
    if holds_unpushed_work "$p"; then keep "$p" "holds uncommitted or unpushed git work"; continue; fi
    sweep "$p" "cold throughout"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

tidy_repo() {  # tidy_repo <repo>
  local repo="$1" cur b
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  say "== $repo"

  if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
    keep "$repo" "uncommitted changes — left alone entirely"; return 0
  fi

  cur="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null)" || cur=""
  if [[ -z "$cur" ]]; then
    keep "$repo" "detached HEAD — left alone entirely"; return 0
  fi

  # Hazard 3: only take someone back to main when the branch they are on holds
  # nothing that would be lost by leaving it.
  if [[ "$cur" != main ]]; then
    if [[ -n "$(git -C "$repo" log --oneline "$cur" --not --remotes 2>/dev/null)" ]]; then
      keep "$repo" "on '$cur' with unpushed commits — not switching"; return 0
    fi
    if (( DRY )); then note "would switch $cur -> main"
    else git -C "$repo" switch --quiet main 2>/dev/null || { keep "$repo" "could not switch to main"; return 0; }
    fi
  fi

  (( DRY )) || git -C "$repo" pull --ff-only --quiet 2>/dev/null || note "pull skipped (not fast-forward)"
  (( DRY )) || git -C "$repo" worktree prune

  # Hazard 4: -D only where every commit is already on a remote, so the branch
  # is recoverable from origin. Anything else stays, and says why.
  while IFS= read -r b; do
    [[ -n "$b" && "$b" != main ]] || continue
    if [[ -n "$(git -C "$repo" log --oneline "$b" --not --remotes 2>/dev/null)" ]]; then
      keep "$b" "has commits no remote carries"; continue
    fi
    if (( DRY )); then note "would delete branch $b (fully pushed)"
    else git -C "$repo" branch -D "$b" >/dev/null 2>&1 && note "deleted branch $b (fully pushed)"
    fi
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)

  (( DRY )) || git -C "$repo" gc --quiet 2>/dev/null
}

(( DRY )) && say "DRY RUN — nothing will be deleted"

if (( DRY )); then
  say "== docker: would run 'docker system prune -f' (no --volumes)"
else
  say "== docker"
  docker system prune -f
fi

sweep_dir /tmp
for d in ~/clones ~/Code/clones; do sweep_dir "$d"; done

for root in ~/Code/Artist-OS ~/Code/Poetic-Poems ~/Code/Pullwright; do
  [[ -d "$root" ]] || continue
  while IFS= read -r g; do tidy_repo "${g%/.git}"; done \
    < <(find "$root" -maxdepth 2 -type d -name .git 2>/dev/null)
done

say
say "swept $swept, kept $kept$( (( DRY )) && printf ' (dry run)' )"

} 2>&1 | tee "$out"
