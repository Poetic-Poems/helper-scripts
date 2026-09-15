#!/bin/bash

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
echo -e "\n---\n"
cd "$D"
disp host "$(hostname)"
disp node-dir "$D"
disp node-name "$(awk -F= '/^NODE_NAME=/{print $2}' .env)"
docker compose exec -T scheduler /app/agent-cycle.sh --status </dev/null
# The item the running cycle holds, keyed on the cycle that holds lock.json —
# the same fact `--status` reads for its `cycle:` line — and not on the newest
# cycle-start. While a cycle runs, every scheduled firing logs a cycle-start
# and an immediate cycle-end as it stands down, so the newest cycle is nearly
# always one of those no-ops, and keying on it reported `idle` for a node an
# hour into an implementer stage (2026-09-15). A cycle's id ends in the pid
# that lock.json records, which is how the two are matched here.
state=/home/agent/.local/state/poetic-agents
pid="$(docker compose exec -T scheduler jq -r '.pid // empty' "$state/lock.json" 2>/dev/null </dev/null)"
if [ -n "$pid" ] && docker compose exec -T scheduler test -d "/proc/$pid" </dev/null 2>/dev/null; then
  item="$(docker compose exec -T scheduler jq -sr --arg pid "$pid" '
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
  docker compose exec -T scheduler bash -lc '
    . /app/lib/version.sh
    agent_ops_version
  ' </dev/null |
  docker compose exec -T scheduler jq -r '[.pr, .short] | @tsv'
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
