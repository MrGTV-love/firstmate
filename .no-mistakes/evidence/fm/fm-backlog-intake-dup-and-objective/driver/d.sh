. ~/tmp/fm-drv/lib.sh
P=~/tmp/fm-peer.xdLVj2
export FM_SSH_BIN=~/tmp/fm-drv/ssh/ssh-bin FM_SSH_CONNECT_TIMEOUT=3
mkdir -p $P/data $P/state; printf '## In flight\n\n## Queued\n\n## Done\n' > $P/data/backlog.md
tasks-axi add pe-open "Peer home open item" --file $P/data/backlog.md >/dev/null
tasks-axi add pe-done "Peer home closed item" --file $P/data/backlog.md >/dev/null
tasks-axi done pe-done --file $P/data/backlog.md >/dev/null
ln -sfn $LAB ~/tmp/fm-drv/lab-link
{
  printf -- '- sm-peer - A local peer home (home: %s; scope: peer; projects: p; added 2026-11-27)\n' "$P"
  printf -- '- sm-self - This same home (home: %s; scope: self; projects: p; added 2026-11-27)\n' "$LAB"
  printf -- '- sm-link - A symlink to this home (home: %s; scope: self; projects: p; added 2026-11-27)\n' ~/tmp/fm-drv/lab-link
  printf -- '- sm-twice - First (home: %s; scope: dup; projects: p; added 2026-11-27)\n' "$P"
  printf -- '- sm-twice - Second (home: %s; scope: dup; projects: p; added 2026-11-27)\n' "$P"
  printf -- '- sm-gone - A host that does not resolve (host: fm-nohost.invalid; root: %s; home: /tmp/nohome; scope: gone; projects: p; added 2026-11-27)\n' "$W"
} > $LAB/data/secondmates.md
st() { run sh -c "bin/fm-tasks-axi.sh show $1 | grep -E 'state:'"; }
for n in 1 2; do :; done
fm add mv-1 "Rewire the masthead tricolour lamp" --objective O7 --kind ship >/dev/null
fm add mv-2 "Replace the cockpit drain hoses" --objective O7 --kind scout >/dev/null
PEER_BEFORE=$(cat $P/data/backlog.md)
say "D1 refused: the home is not registered"
fm done mv-1 --moved-to sm-none pe-open; st mv-1
say "D2 refused: the home is registered twice"
fm done mv-1 --moved-to sm-twice pe-open; st mv-1
say "D3 refused: the peer home has no such item"
fm done mv-1 --moved-to sm-peer pe-absent; st mv-1
say "D4 refused: the peer item is closed"
fm done mv-1 --moved-to sm-peer pe-done; st mv-1
say "D5 refused: the destination is this same home"
fm done mv-1 --moved-to sm-self mv-2; st mv-1
say "D6 refused: the destination is a symlink to this home"
fm done mv-1 --moved-to sm-link mv-2; st mv-1
say "D7 refused: the remote host cannot be reached (real ssh, name does not resolve)"
fm done mv-1 --moved-to sm-gone pe-open; st mv-1
say "D8 refused: an owner-filed item cannot close by --moved-to"
fm done own-1 --moved-to sm-peer pe-open; st own-1
say "D9 refused: the one-value form"
fm done mv-1 --moved-to sm-peer
say "D10 accepted: the peer home holds the item open; the closing note records the proof"
fm done mv-1 --moved-to sm-peer pe-open; st mv-1
run grep -n -A2 '^- \[x\] mv-1' $B
say "D11 the peer home's backlog was not changed"
if [ "$PEER_BEFORE" = "$(cat $P/data/backlog.md)" ]; then echo "peer backlog unchanged"; else echo "PEER BACKLOG CHANGED"; fi
run grep mv-1 $LAB/state/fleet-ledger.jsonl
