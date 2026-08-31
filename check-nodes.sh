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
item="$(docker compose exec -T scheduler jq -sr '
    ([.[] | select(.event=="cycle-start")] | last) as $s
    | if $s == null then "idle" else
        (map(select(.cycle == $s.cycle))) as $c
        | if ($c | any(.event=="cycle-end")) then "idle" else
            ([$c[] | select(.event=="selection")] | last) as $sel
            | if $sel == null then "selecting" else "\($sel.repo) \($sel.item)" end
          end
      end
  ' /home/agent/.local/state/poetic-agents/log.jsonl 2>/dev/null </dev/null)"
disp item "${item:-idle}"
out="$(
  docker compose exec -T scheduler bash -lc '
    . /app/lib/version.sh
    agent_ops_version
  ' </dev/null |
  docker compose exec -T scheduler jq -r '[.pr, .short] | @tsv'
)"
IFS=$'\t' read -r pr short <<<"$out"
disp image "${pr:-none}  #$short"


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
    sprintf("%s (%3d minutes %sgo)", $timestamp, $diff/60, $sign)
  }
}
s/((?:\d\d[-T:Z]?){7})/ago/ge;
s/^(\S*?:\s*)(?=\S)/$1." "x(16-length$1)/e;
s/^(  \S+)( \S+)/sprintf '%-35s%-5s',$1,$2/e;
