#!/usr/bin/bash

config=$(
  gh api -H "Accept: application/vnd.github.raw" \
    repos/Pullwright/agent-ops/contents/config.json
) || { echo "count-autonomous-agent-prs.sh: failed to fetch config.json" >&2; exit 1; }

repos=$(jq -r '.repos[].slug' <<<"$config")
if [[ -z "$repos" ]]; then
  echo "count-autonomous-agent-prs.sh: config.json listed no repos" >&2
  exit 1
fi

n=0
for repo in $repos; do
  n=$((n + $(
    gh pr list --limit 9999 --repo $repo --state all  \
      --json id --label autonomous-agent --jq length
  )))
done
echo $n
