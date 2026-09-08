#!/usr/bin/bash

# deploy-latest-compose.yaml.sh [--dry-run] [--repo ORG/REPO]
#
# Deliver origin main's deploy/docker/compose.yaml to all four agent-ops nodes
# — poetic-node-1 and -2 here, poetic-node and -2 on the tailnet host — and say
# per node whether anything actually changed.
#
# This is the only way a compose.yaml change reaches a node: an image roll
# delivers new code but never compose-level config, and a node holds the file
# rather than a clone (agent-ops#131).  Nothing here restarts anything, so the
# new file does nothing until `docker compose up -d` runs in that node's
# directory.
#
# The fetch is verified before any node is written to.  This used to pipe
# gh-get.sh straight into `tee` across all four at once, which meant a failed
# fetch — an expired token, a renamed path, a network blip — wrote its empty
# output over four live production files simultaneously, with the truncation
# only becoming visible at the next `up -d`.  Now the content is fetched once,
# checked for being non-empty and parseable and for carrying the services this
# file is supposed to carry, and only then distributed; each node keeps a
# timestamped backup of what it had, in the same `.bak-<stamp>` shape the .env
# files on the tailnet host already use.

set -uo pipefail

here=$(dirname "$(readlink -f "$0")")
repo=Pullwright/agent-ops
path=deploy/docker/compose.yaml
remote=root@5.78.159.79
local_dirs=(~/poetic-node-1 ~/poetic-node-2)
remote_dirs=(/opt/poetic-node /opt/poetic-node-2)
stamp=$(date -u +%Y%m%dT%H%M%SZ)
dry_run=0

while (( $# )); do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --repo) repo="$2"; shift 2 ;;
    -h|--help) sed -n '3,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "deploy-latest-compose: unknown argument: $1" >&2; exit 2 ;;
  esac
done

die() { echo "deploy-latest-compose: $*" >&2; exit 1; }

tmp=$(mktemp) || die "cannot create a temporary file"
trap 'rm -f "$tmp"' EXIT

"$here/gh-get.sh" "$repo" "$path" > "$tmp" \
  || die "could not fetch $path from $repo — nothing written"

# Verify before distributing, not after.  Each of these has been a real
# failure mode of the one-liner this replaces.
[[ -s "$tmp" ]] || die "fetched an empty $path — nothing written"
for want in 'services:' 'scheduler:' 'dashboard:'; do
  grep -q "^ *$want" "$tmp" \
    || die "fetched file has no '$want' — that is not compose.yaml, nothing written"
done
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$tmp" 2>/dev/null \
    || die "fetched file is not parseable YAML — nothing written"
fi

printf 'fetched %s %s — %s lines, %s bytes\n\n' \
  "$repo" "$path" "$(wc -l < "$tmp")" "$(wc -c < "$tmp")"

# report_and_place LABEL CURRENT_FILE — how this node's copy differs from what
# was fetched.  Printed before anything is written, so --dry-run and a real run
# say the same thing about the same node.
report() {
  local label="$1" current="$2" changed
  if [[ ! -f "$current" ]]; then
    printf '  %-32s no existing file — will create\n' "$label"
    return 0
  fi
  if cmp -s "$current" "$tmp"; then
    printf '  %-32s already current\n' "$label"
    return 1
  fi
  changed=$(diff "$current" "$tmp" | grep -c '^[<>]')
  printf '  %-32s %s differing lines\n' "$label" "$changed"
  return 0
}

rc=0

for d in "${local_dirs[@]}"; do
  report "$(basename "$d")" "$d/compose.yaml" || continue
  (( dry_run )) && continue
  [[ -f "$d/compose.yaml" ]] && cp -p "$d/compose.yaml" "$d/compose.yaml.bak-$stamp"
  cp "$tmp" "$d/compose.yaml" || { echo "    write failed" >&2; rc=1; }
done

for d in "${remote_dirs[@]}"; do
  current=$(mktemp)
  ssh -o BatchMode=yes "$remote" "cat $d/compose.yaml" > "$current" 2>/dev/null
  report "$remote:$(basename "$d")" "$current"
  needed=$?
  rm -f "$current"
  (( needed )) && continue
  (( dry_run )) && continue
  ssh -o BatchMode=yes "$remote" \
    "cp -p $d/compose.yaml $d/compose.yaml.bak-$stamp 2>/dev/null; cat > $d/compose.yaml" \
    < "$tmp" || { echo "    write failed" >&2; rc=1; }
done

if (( dry_run )); then
  printf '\n(dry run — nothing written)\n'
else
  printf '\nBackups kept as compose.yaml.bak-%s.\n' "$stamp"
  printf 'Nothing is running the new file yet: run "docker compose up -d" in each\n'
  printf 'node directory when you want it to take effect.\n'
fi
exit "$rc"
