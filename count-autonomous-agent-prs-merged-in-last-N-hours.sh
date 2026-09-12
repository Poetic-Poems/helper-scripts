#!/usr/bin/bash

# count-autonomous-agent-prs-merged-in-last-N-hours.sh [HOURS]

ago=$(date -ud@$(($(date -u +%s) - 3600*"${N:-12}")) +%Y-%m-%dT%H:%M:%SZ)
echo Pipeline PRs merged since $ago:
while read -r R; do
  gh pr list -R$R -sclosed --json labels,mergedAt,mergedBy -q'
    map(select(
        ( .mergedAt > "'$ago'" ) and
        ( .labels | any(.name == "autonomous-agent") )
    )) |
    sort_by(.mergedAt)[] |
    .mergedAt + "  " + .mergedBy.login
  ' |
  sed "s,^,$(printf '%26s' "$R")  ,"
done < <(
  "$(dirname "$0")"/gh-get.sh Pullwright/agent-ops config.json |
  jq -r .repos[].slug
) |
tee >(wc -l)

