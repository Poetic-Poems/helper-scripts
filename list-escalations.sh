#!/usr/bin/bash

# list-escalations.sh [FILTER]
#
# E.g.:
#   list-escalations.sh '.repo|match("^Pullwright")'

filter="${1:-1}"
< <(
  find ~/Code/{Poetic-Poems,Pullwright} \
    -maxdepth 1 -type d -exec [ -d {}/.git ] \; -print0
) readarray -d '' repo_dirs
for repo_dir in "${repo_dirs[@]}"; do
  owner=$(basename "$(dirname "$repo_dir")")
  repo=$owner/$(basename "$repo_dir")
  gh-list() {
    gh $1 list -R"$repo" -s$2 -L1000 --json id,number,title,labels -q 'map(
      .repo = "'"$repo"'" |
      .type = "'$1'" |
      .labels = (.labels | map(.name)) |
      select(
        (.labels | any(test("'$3'"))) and ('"$filter"')
      ) |
      .labels = (.labels | join(", "))
    )'
  }
  gh-list issue open '(pw::)?enabler-escalation|pw::pager'
  gh-list pr all '(pw::)?open-question'
done |
jq -s 'add | sort_by(.number)'

