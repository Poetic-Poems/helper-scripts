#!/bin/bash
#
# check-nodes.sh — one status block per pipeline node: the two local stacks
# under ~/poetic-node-{1,2} and the two under /opt on the VM. Each block is
# the scheduler's `--status`, the item its running cycle holds, and the image
# it runs.
#
# Every `docker exec` into a scheduler is bounded to 30 s. A scheduler in the
# parent-cgroup livelock (memory.high below its working set) hangs `docker
# exec` itself, and an unbounded call hung this script for good on
# 2026-09-16. When the first exec times out, the block reads the parent
# cgroup's memory counters from the host instead — the reading that names
# that condition — and skips the execs that would follow.

printf '\n%72s\n' | tr \  =
date +'%n%Y-%m-%dT%H:%M:%S%z'

extract() { awk 'p&&/^###/{exit} /^## '$1' /{p=1;next} p{print}' "$0"; }
cmd=$(extract COMMANDS)
fmt=$(extract FORMAT)
format() { perl -pe "$fmt"; }

# local nodes
for d in ~/poetic-node-{1,2}; do
  D="$d" bash -s <<<"$cmd" | format
done

# remote nodes
for d in /opt/poetic-node{,-2}; do
  ssh -i ~/.ssh/id_rsa root@5.78.159.79 "D='$d' bash -s" <<<"$cmd" | format
done

exit


################################################################################
## COMMANDS ####################################################################

#!/bin/bash

disp() { printf '%-16s%s\n' "$1:" "$2"; }
dx() { timeout 30 docker compose exec -T scheduler "$@"; }
echo -e "\n---\n"
cd "$D"
disp host "$(hostname)"
disp node-dir "$D"
disp node-name "$(awk -F= '/^NODE_NAME=/{print $2}' .env)"
dx /app/agent-cycle.sh --status </dev/null
if [ $? -eq 124 ]; then
  disp status "docker exec hung for 30s"
  disp load "$(cut -d' ' -f1-3 /proc/loadavg), $(ps -eo stat= | grep -c '^D') in D"
  ev="$(awk -F= '/^AGENT_OPS_SCHEDULER_CGROUP_EVENTS=/{print $2}' .env)"
  if [ -r "$ev" ]; then
    c="${ev%/memory.events}"
    disp cgroup "$c: current $(( $(cat "$c/memory.current") / 1048576 ))MiB, high $(cat "$c/memory.high"), max $(cat "$c/memory.max")"
    disp events "$(tr '\n' ' ' < "$ev")"
    disp see "a high count in the millions with current above high is the memory.high livelock: operations/scheduler-memory-high-parent-cgroup.md"
  else
    disp cgroup "no readable AGENT_OPS_SCHEDULER_CGROUP_EVENTS in .env (unparented); read the load and D count above"
  fi
  exit 0
fi
# The item the running cycle holds, keyed on the cycle that holds lock.json —
# the same fact `--status` reads for its `cycle:` line — and not on the newest
# cycle-start. While a cycle runs, every scheduled firing logs a cycle-start
# and an immediate cycle-end as it stands down, so the newest cycle is nearly
# always one of those no-ops, and keying on it reported `idle` for a node an
# hour into an implementer stage (2026-09-15). A cycle's id ends in the pid
# that lock.json records, which is how the two are matched here.
state=/home/agent/.local/state/poetic-agents
pid="$(dx jq -r '.pid // empty' "$state/lock.json" 2>/dev/null </dev/null)"
if [ -n "$pid" ] && dx test -d "/proc/$pid" </dev/null 2>/dev/null; then
  item="$(dx jq -sr --arg pid "$pid" '
      ([.[] | select(.event=="cycle-start") | select(.cycle | tostring | endswith("-" + $pid))] | last) as $s
      | if $s == null then "selecting" else
          ([.[] | select(.cycle == $s.cycle and .event=="selection")] | last) as $sel
          | if $sel == null then "selecting" else "\($sel.repo) \($sel.item)" end
        end
    ' "$state/log.jsonl" 2>/dev/null </dev/null)"
else
  item=idle
fi
disp item "${item:-idle}"
out="$(
  dx bash -lc '
    . /app/lib/version.sh
    agent_ops_version
  ' </dev/null |
  dx jq -r '[.pr, .short] | @tsv'
)"
IFS=$'\t' read -r pr short <<<"$out"
if [ -n "$short" ]; then short="  #$short"; fi
disp image "${pr:-none}$short"


################################################################################
## FORMAT ######################################################################

#!/usr/bin/perl -p

BEGIN {
  $now = `date +%s`;
  sub ago {
    $timestamp = $1;
    $then = `date -d"$1" +%s`;
    $diff = $then - $now;
    $sign = $diff =~ s/^-// ? "a" : "to ";
    @units       = qw/ w  d  h  m  s /;
    @multipliers = qw/    7 24 60 60 /;
    while (@multipliers) {
      $multiplier = pop @multipliers;
      $diff > 1.65*$multiplier or last;
      $diff /= $multiplier;
      pop @units;
    }
    sprintf('%s (%.0f%s %sgo)', $timestamp, $diff, $units[-1], $sign)
  }
}
s/((?:\d\d[-T:Z]?){7})/ago/ge;
s/ (\d+)([wdhms] (?:a|to )go)\b/sprintf '% 3d%s', $1, $2/eg;
s/^(\S*?:\s*)(?=\S)/$1." "x(16-length$1)/e;
s/^(  \S+)( \S+)/sprintf '%-35s%-5s',$1,$2/e;
