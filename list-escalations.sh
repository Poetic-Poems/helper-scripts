(
  echo -n "{"
  find ~/Code/Poetic-Poems    \
    -maxdepth 2               \
    -type d                   \
    -name .git                \
    -exec bash -c '
      cd "$(dirname "$1")"
      echo -e "\n\"$(pwd)\":"
      gh issue list -s open --json labels,title,url --jq '\''
        map(
          .labels = (.labels | map(.name))                  |
          select(.labels | any(. == "enabler-escalation"))  |
          .labels = (.labels | join(", "))
        )
      '\''
      echo -n ","
    ' _ {} \;
)                             |
sed -z 's/,$/}/'              |
jq
