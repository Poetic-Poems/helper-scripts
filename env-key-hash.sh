#!/usr/bin/bash

# env-key-hash.sh [options] KEY [KEY ..]
#
# Display the (trimmed) length of the value and the value of one or more
# agent-ops node .env keys, or, if it is a sensitive value, display its
# md5 hash instead.  If no length is displayed, the key wasn't found in
# the associated .env file.
#
# Options
#   --node            Specify which node to query.  If omitted,
#                     all nodes are queried.  Available nodes are:
#                     - ockham-container
#                     - ockham-2
#                     - poetic-1
#                     - poetic-2

if [ "$1" == "--help" ]; then
  awk 'NR<3{next} /^\s*$/{exit} match($0,/# ?(.*)/,m){print m[1]}' "$0"
  exit
fi

nodes=( ockham-container ockham-2 poetic-1 poetic-2 )
if [ "$1" == "--node" ]; then
  shift
  nodes=($(printf '%s\n' "${nodes[@]}" | grep -Fx -- "$1"))
  shift
fi

for key in "$@"; do
  if [[ "$key" =~ [^0-9A-Za-z_] ]]; then
    echo "Invalid key: $key" >&2
    exit -1
  fi
done

vm1='ssh -i ~/.ssh/id_rsa root@5.78.159.79'
ockham-container() { cat "$HOME/poetic-node-1/.env"; }
ockham-2()         { cat "$HOME/poetic-node-2/.env"; }
poetic-1() { $vm1 'cat /opt/poetic-node/.env  '; }
poetic-2() { $vm1 'cat /opt/poetic-node-2/.env'; }

for node in "${nodes[@]}"; do
  for key in "$@"; do
    printf '%-22s %-36s ' "$node" "$key"
    value=$($node | awk '
      BEGIN {rv=1}
      match($0, "^\\s*(\\w+)=(|.*\\S)", m) {
        if(m[1]=="'$key'"){print m[2]; rv=0; exit}
      }
      END {exit(rv)}
    ') &&
    printf '(%5d) ' $(printf '%s' "$value" | wc -c) &&
    if [[ "${key,,}" =~ (key|token|secret) ]]; then
      printf '%s%.0s' $(printf '%s' "$value" | md5sum)
    else
      echo -n "$value"
    fi
    echo
  done
done
