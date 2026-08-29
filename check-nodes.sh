#!/bin/bash

date +'%n%Y-%m-%dT%H:%M:%S%z'

cmd=$(cat <<'HERE'
echo
printf '%-10s%s\n' host: "$(hostname)"
printf '%-10s%s\n' node-dir: "$D"
cd "$D"
docker compose exec -T scheduler /app/agent-cycle.sh --status </dev/null
out="$(
  docker compose exec -T scheduler bash -lc '
    . /app/lib/version.sh
    agent_ops_version
  ' </dev/null |
  docker compose exec -T scheduler jq -r '[.pr, .short] | @tsv'
)"
IFS=$'\t' read -r pr short <<<"$out"
printf '%-10s#%s  %s\n' image: "${pr:-none}" "$short"
HERE
)

format() { perl -p <(awk '/^#!.*\/perl\>/{p=1;next} p{print}' "$0"); }

# local nodes
for d in ~/poetic-node-{1,2}; do
  D="$d" bash -s <<<"$cmd" | format
done

# remote nodes
for d in /opt/poetic-node{,-2}; do
  ssh -i ~/.ssh/id_rsa root@5.78.159.79 "D='$d' bash -s" <<<"$cmd" | format
done

echo -e "\n---"
exit

################################################################################

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
s/^(  \S+)( \S+)/sprintf '%-35s%-5s',$1,$2/e;
