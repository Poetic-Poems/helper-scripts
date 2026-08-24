ip='dig $HOSTNAME | awk '\''/\tA\t/{print($5,"('\''$HOSTNAME'\'')")}'\'' | tail -1'
f='grep -HP '\''^\s*\w+='\'' {~,/opt}/poetic-node*/.env 2>/dev/null | sort | sed "s/^/$('$ip'):/"'
(
  eval "$f"
  ssh -i ~/.ssh/id_rsa root@5.78.159.79 "$f"
) | awk 'match($0,"(.*(KEY|TOKEN|SECRET)=)(.*)",m){print m[1] gensub(/\w/,".","g",m[3]);next} {print}'
