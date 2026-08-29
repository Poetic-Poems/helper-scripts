#!/usr/bin/bash

gh api "repos/$1/contents/$2" --jq .content | base64 -d
