#!/usr/bin/bash

n=0
for repo in $(
  gh api -H "Accept: application/vnd.github.raw"      \
    repos/Poetic-Poems/agent-ops/contents/config.json |
  jq -r .repos[].slug
); do
  n=$((n + $(
    gh pr list --limit 9999 --repo $repo --state all  \
      --json id --label autonomous-agent --jq length
  )))
done
echo $n
