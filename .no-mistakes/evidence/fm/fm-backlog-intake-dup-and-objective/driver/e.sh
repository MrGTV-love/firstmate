. ~/tmp/fm-drv/lib.sh
S=~/tmp/fm-drv/ssh
export FM_SSH_BIN=$S/ssh-bin FM_SSH_CONNECT_TIMEOUT=5
/usr/sbin/sshd -D -e -f $S/sshd_config 2> $S/sshd.log &
SSHD=$!
trap 'kill $SSHD 2>/dev/null; wait $SSHD 2>/dev/null' EXIT
for i in $(seq 1 50); do nc -z 127.0.0.1 22922 2>/dev/null && break; sleep 0.1; done
say "E0 backlog identity is the same with and without /usr/sbin on PATH (machine= line)"
run env PATH=/usr/bin:/bin bin/fm-backlog-identity.sh
run bin/fm-backlog-identity.sh
say "E1 smoke: the real ssh client reaches the throwaway sshd on 127.0.0.1:22922 (banner on stderr)"
run $S/ssh-bin fm-far echo connected-through-real-sshd
R1=$(mktemp -d ~/tmp/fm-remote.XXXXXX)
mkdir -p $R1/data $R1/state $R1/config; printf '## In flight\n\n## Queued\n\n## Done\n' > $R1/data/backlog.md
tasks-axi add rf-open "Remote home open item" --file $R1/data/backlog.md >/dev/null
tasks-axi add rf-done "Remote home closed item" --file $R1/data/backlog.md >/dev/null
tasks-axi done rf-done --file $R1/data/backlog.md >/dev/null
{
  printf -- '- sm-far - A remote home over real ssh (host: fm-far; root: %s; home: %s; scope: far; projects: p; added 2026-11-27)\n' "$W" "$R1"
  printf -- '- sm-loop - A remote record that reaches THIS home over real ssh (host: fm-far; root: %s; home: %s; scope: loop; projects: p; added 2026-11-27)\n' "$W" "$LAB"
} >> $LAB/data/secondmates.md
fm add rm-1 "Refit the forward cabin bunk slats" --objective O7 --kind ship >/dev/null
fm add rm-2 "Patch the tender inflatable seams" --objective O7 >/dev/null
st() { run sh -c "bin/fm-tasks-axi.sh show $1 | grep -E 'state:'"; }
say "E2 the remote side answers fm-backlog-identity.sh through bin/fm-on.sh and real ssh"
run bin/fm-on.sh sm-far fm-backlog-identity.sh
say "E3 refused: a remote record that reaches this same home (sshd banner on stderr must not count as a different backlog)"
fm done rm-2 --moved-to sm-loop rm-1; st rm-2
say "E4 refused: the remote home has no such item"
fm done rm-1 --moved-to sm-far rf-absent; st rm-1
say "E5 refused: the remote item is closed"
fm done rm-1 --moved-to sm-far rf-done; st rm-1
say "E6 accepted: the remote home holds the item open; read over real ssh"
R_BEFORE=$(cat $R1/data/backlog.md)
fm done rm-1 --moved-to sm-far rf-open; st rm-1
run grep -n -A2 '^- \[x\] rm-1' $B
if [ "$R_BEFORE" = "$(cat $R1/data/backlog.md)" ]; then echo "remote backlog unchanged"; else echo "REMOTE BACKLOG CHANGED"; fi
say "E7 sshd log: the sessions really went through the throwaway sshd"
grep -c 'Accepted publickey' $S/sshd.log | sed 's/^/accepted publickey sessions: /'
rm -rf $R1
