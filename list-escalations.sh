#!/usr/bin/bash

# list-escalations.sh [FILTER]
#
# E.g.:
#   list-escalations.sh '.repo|match("^Pullwright")'

< <(
  find ~/Code/{Poetic-Poems,Pullwright} \
    -maxdepth 1 -type d -exec [ -d {}/.git ] \; -print0
) readarray -d '' repo_dirs
for repo_dir in "${repo_dirs[@]}"; do
  owner=$(basename "$(dirname "$repo_dir")")
  repo=$owner/$(basename "$repo_dir")
  gh issue list -R"$repo" -sopen -L1000 --json id,title,labels -q 'map(
    .repo = "'"$repo"'" |
    .labels = (.labels | map(.name)) |
    select(
      (.labels | any(test("enabler-escalation|pw::pager"))) and ('"${1:-1}"')
    ) |
    .labels = (.labels | join(", "))
  )'
done |
jq -s add

