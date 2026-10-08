~/Code/Poetic-Poems/helper-scripts/get-dashboard-data.sh |
jq '
  .github.inputs["Pullwright/agent-ops"] |
  [
    (.issues|map(.number)),
    (.tech_debt|map(.id|match("([0-9]+)").string|tonumber))
  ] |
  add |
  sort[]
'
