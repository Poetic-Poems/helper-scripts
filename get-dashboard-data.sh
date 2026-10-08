#!/bin/bash

# get-dashbaord-data.sh [domain]
#
# E.g.: get-dashbaord-data.sh poetic-1

curl "http://${1:-localhost}:8787/data.js"                                    \
  -H 'Accept: */*'                                                            \
  -H 'Accept-Language: en-GB,en;q=0.9'                                        \
  -H 'Accept-Encoding: gzip, deflate'                                         \
  -H 'DNT: 1'                                                                 \
  -H 'Connection: keep-alive'                                                 \
  -H 'Sec-GPC: 1'                                                             \
  -H 'Pragma: no-cache'                                                       \
  -H 'Cache-Control: no-cache' 2>/dev/null                                    |
awk 'BEGIN {printf "{"} NR>2 {print l; l=$0} END {print "}"}'
