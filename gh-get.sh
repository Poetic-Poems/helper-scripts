#!/usr/bin/bash

# gh-get.sh ORG/REPO PATH/TO/FILE
#
# Retrieve a file from origin main.

gh api "repos/$1/contents/$2" --jq .content | base64 -d
