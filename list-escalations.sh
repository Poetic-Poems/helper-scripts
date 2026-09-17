#!/usr/bin/bash

# list-escalations.sh [OWNER-REPO-FILTER] [JQ-FILTER]
#
# E.g.:
#   list-escalations.sh ^Pullwright '.number > 1000'

owner_repo_filter=.
if [ -n "$1" ]; then
  owner_repo_filter="$1"
  shift
fi
jq_filter="${1:-1}"
< <(
  find ~/Code/{Poetic-Poems,Pullwright} \
    -maxdepth 1 -type d -exec [ -d {}/.git ] \; -print0
) readarray -d '' repo_dirs
for repo_dir in "${repo_dirs[@]}"; do
  owner=$(basename "$(dirname "$repo_dir")")
  owner_repo=$owner/$(basename "$repo_dir")
  <<<"$owner_repo" grep -Eq "$owner_repo_filter" || continue
  gh-list() {
    gh $1 list -R"$owner_repo" -s$2 -L1000 --json id,number,title,labels -q 'map(
      .repo = "'"$owner_repo"'" |
      .type = "'$1'" |
      .labels = (.labels | map(.name)) |
      select(
        (.labels | any(test("'$3'"))) and ('"$jq_filter"')
      ) |
      .labels = (.labels | join(", "))
    )'
  }
  gh-list issue open '(pw::)?enabler-escalation|pw::pager'
  gh-list pr all '(pw::)?open-question'
done |
jq -s 'add | sort_by(.number)'

