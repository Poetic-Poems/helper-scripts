#!/usr/bin/bash

# env-key-hash.sh [options] KEY [KEY ..]
#
# For one or more agent-ops node .env keys, display what is *staged* in the
# node's .env file and, beneath it, what each of the node's *containers* is
# actually using.  Each value is shown as its (trimmed) length followed by
# the value itself or, if the key names a sensitive value, its md5 hash.
# If no length is displayed, the key wasn't found on that side.
#
# A container keeps the .env values it held when it was created, so a value
# that was edited but never delivered by `docker compose up -d` shows here as
# a container line marked STALE.  No "is it set?" check catches that: the
# file is right, the container is wrong, and the two are never compared.
# Stopped containers are included and marked with their state, because a
# sidecar that died on a stale credential is exactly the case worth seeing.
#
# Options
#   --env-only        Show only what is staged in .env, skipping the
#                     container lookup.  Faster, and needs no docker.
#   -h, --help        Display this help then exit.
#   -n, --node NODEE  Specify which node to query.  If omitted,
#                     all nodes are queried.  Available nodes are:
#                     - ockham-container
#                     - ockham-2
#                     - poetic-1
#                     - poetic-2

nodes=( ockham-container ockham-2 poetic-1 poetic-2 )
env_only=0

while [[ "$1" == -* ]]; do
  case "$1" in
    --env-only)
      env_only=1
      shift
      ;;
    -h|--help)
      awk 'NR<3{next} /^\s*$/{exit} match($0,/# ?(.*)/,m){print m[1]}' "$0"
      echo -e "\nAvailable keys are:"
      "$(dirname "$0")"/gh-get.sh \
        Poetic-Poems/agent-ops deploy/docker/.env.example |
        awk -F= '/^[A-Z]/{print "    " $1}' | sort -u
      exit 0
      ;;
    -n|--node)
      shift
      nodes=($(printf '%s\n' "${nodes[@]}" | grep -Fx -- "$1"))
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if (( ${#nodes[@]} == 0 )); then
  echo "No such node.  Known nodes: ockham-container ockham-2 poetic-1 poetic-2" >&2
  exit 2
fi

for key in "$@"; do
  if [[ "$key" =~ [^0-9A-Za-z_] ]]; then
    echo "Invalid key: $key" >&2
    exit -1
  fi
done

vm1='ssh -i ~/.ssh/id_rsa root@5.78.159.79'

# Where each node keeps its .env, how to reach it, and the compose project
# its containers are labelled with.  The project name is what ties a node's
# containers together on a host that runs more than one node; it is not
# unique across hosts, and does not need to be.
declare -A NODE_ENV=(
  [ockham-container]="$HOME/poetic-node-1/.env"
  [ockham-2]="$HOME/poetic-node-2/.env"
  [poetic-1]=/opt/poetic-node/.env
  [poetic-2]=/opt/poetic-node-2/.env
)
declare -A NODE_SSH=(
  [ockham-container]=""
  [ockham-2]=""
  [poetic-1]="$vm1"
  [poetic-2]="$vm1"
)
declare -A NODE_PROJECT=(
  [ockham-container]=agent-ops
  [ockham-2]=agent-ops-2
  [poetic-1]=agent-ops
  [poetic-2]=agent-ops-2
)

# One round trip per node, wherever the node is: emit the .env verbatim and
# every container's environment, each line tagged with where it came from —
# ".env", or the service name (plus its state, when it is not running).
collect='
  sed "s|^|.env\t|" "$ENVFILE" 2>/dev/null
  [ -n "$PROJECT" ] || exit 0
  for c in $(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT" 2>/dev/null); do
    svc=$(docker inspect -f "{{index .Config.Labels \"com.docker.compose.service\"}}" "$c" 2>/dev/null)
    [ -n "$svc" ] || continue
    state=$(docker inspect -f "{{.State.Status}}" "$c" 2>/dev/null)
    [ "$state" = running ] || svc="$svc[$state]"
    docker inspect -f "{{range .Config.Env}}{{println .}}{{end}}" "$c" 2>/dev/null |
      sed "s|^|$svc\t|"
  done
'

# compose strips one layer of matching surrounding quotes when it reads .env,
# so a quoted value in the file is not a quoted value in the container.
# Strip it here too, or every quoted value reads as a false STALE.
unquote() {
  local v=$1
  if (( ${#v} >= 2 )); then
    case "$v" in
      \"*\"|\'*\') v=${v:1:${#v}-2} ;;
    esac
  fi
  printf '%s' "$v"
}

show() {  # show KEY VALUE
  local key=$1 value=$2
  printf '(%5d) ' "$(printf '%s' "$value" | wc -c)"
  if [[ "${key,,}" =~ (key|token|secret) ]] &&
     [[ ! "${key,,}" =~ _path$ ]]; then
    printf '%s' "$(printf '%s' "$value" | md5sum | cut -d' ' -f1)"
  else
    printf '%s' "$value"
  fi
}

for node in "${nodes[@]}"; do
  project=${NODE_PROJECT[$node]}
  (( env_only )) && project=""

  if [[ -n "${NODE_SSH[$node]}" ]]; then
    data=$(${NODE_SSH[$node]} "ENVFILE='${NODE_ENV[$node]}' PROJECT='$project' bash -s" <<<"$collect")
  else
    data=$(ENVFILE="${NODE_ENV[$node]}" PROJECT="$project" bash -s <<<"$collect")
  fi

  for key in "$@"; do
    printf '%-20s %-36s ' "$node" "$key"
    env_value=$(awk -F'\t' -v k="$key" '
      BEGIN {rv=1}
      $1 == ".env" && match($2, "^\\s*(\\w+)=(|.*\\S)", m) {
        if (m[1] == k) {print m[2]; rv=0; exit}
      }
      END {exit(rv)}
    ' <<<"$data") && env_found=1 || env_found=0
    (( env_found )) && { env_value=$(unquote "$env_value"); show "$key" "$env_value"; }
    echo

    (( env_only )) && continue

    # Collapse the containers that agree onto one line, in the order docker
    # returned them, so a node with five containers sharing a value costs one
    # line and a node whose containers disagree costs one line each.
    order=()
    declare -A holders=()
    while IFS=$'\t' read -r svc val; do
      [[ -n "$svc" ]] || continue
      if [[ -z "${holders[$val]+set}" ]]; then
        order+=("$val")
        holders[$val]=$svc
      else
        holders[$val]+=",$svc"
      fi
    done < <(awk -F'\t' -v k="$key" '
      $1 != ".env" && match($2, "^(\\w+)=(.*)$", m) {
        if (m[1] == k) {print $1 "\t" m[2]}
      }
    ' <<<"$data")

    if (( ${#order[@]} == 0 )); then
      printf '%-22s %-34s %s\n' "" "  -> no container defines it" ""
    else
      for val in "${order[@]}"; do
        printf '%-22s %-34s ' "" "  -> ${holders[$val]}"
        show "$key" "$val"
        if (( ! env_found )); then
          printf '  NOT IN .env'
        elif [[ "$val" != "$env_value" ]]; then
          printf '  STALE'
        fi
        echo
      done
    fi
    unset holders
  done
done
