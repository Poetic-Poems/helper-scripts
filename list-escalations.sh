#!/usr/bin/bash

< <(
  find ~/Code/{Poetic-Poems,Pullwright} \
    -maxdepth 1 -type d -exec [ -d {}/.git ] \; -print0
) readarray -d '' repo_dirs
for repo_dir in "${repo_dirs[@]}"; do
  owner=$(basename "$(dirname "$repo_dir")")
  repo=$owner/$(basename "$repo_dir")
  gh issue list -R"$repo" -sopen --json id,title,labels -q 'map(
    .labels = (.labels | map(.name)) |
    select(.labels | any(test("enabler-escalation|pw::pager"))) |
    .labels = (.labels | join(", ")) |
    .repo = "'"$repo"'"
  )'
done |
jq -s add

