#!/bin/bash

date +'%n%Y-%m-%dT%H:%M:%S%z'

cmd='
echo
printf '\''%-10s%s\n'\'' host: "$(hostname)"
printf '\''%-10s%s\n'\'' node-dir: "$D"
cd "$D"
docker compose exec -T scheduler /app/agent-cycle.sh --status </dev/null
out="$(docker compose exec -T scheduler bash -lc '\''. /app/lib/version.sh; agent_ops_version'\'' </dev/null | docker compose exec -T scheduler jq -r '\''[.pr, .short] | @tsv'\'')"
IFS=$'\''\t'\'' read -r pr short <<<"$out"
printf '\''%-10s#%s  %s\n'\'' image: "${pr:-none}" "$short"
'

# local nodes
for d in ~/poetic-node-{1,2}; do
  D="$d" bash -s <<<"$cmd"
done

# remote nodes
for d in /opt/poetic-node{,-2}; do
  ssh -i ~/.ssh/id_rsa root@5.78.159.79 "D='$d' bash -s" <<<"$cmd"
done

echo -e "\n---"
