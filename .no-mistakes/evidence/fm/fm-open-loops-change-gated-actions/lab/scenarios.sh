# Full live lab run: real bin/fm-wake-drain.sh, bin/fm-open-loops.sh and bin/fm-captain-hold.sh
# against a disposable marked lab FM_HOME. Only the published ledger rows are seeded (as a heartbeat would).
. "$(dirname "$0")/lab-lib.sh"; cd "$W"
NOW=$(date +%s)
edit_rows() { python3 -I -c "import json,sys; p=sys.argv[1]; rows=json.load(open(p)); exec(sys.argv[2]); json.dump(rows,open(p,'w'))" "$ROWS" "$1"; }
cat > $ROWS <<J
[
 {"id":"stalled_worker:alpha","category":"stalled_worker","subject":"alpha","owner":"worker:alpha","next_action":"steer alpha or record why it waits","evidence":"pane: paused by captain order; retry in 45s","start_epoch":$((NOW-7200)),"limit_seconds":3600},
 {"id":"unanswered_question:beta:deploy","category":"unanswered_question","subject":"beta:deploy","owner":"firstmate","next_action":"answer or escalate beta's deploy question","evidence":"needs-decision [key=deploy]: deploy to prod now?","start_epoch":$((NOW-9000)),"limit_seconds":900,"source":{"task":"beta","key":"deploy"}},
 {"id":"silent_report:gamma","category":"silent_report","subject":"gamma","owner":"worker:gamma","next_action":"check in with gamma","evidence":"no report since dispatch","start_epoch":$((NOW-5000)),"limit_seconds":900}
]
J
publish
mkdir -p $FM_HOME/state/alpha.inbox
msg() { printf 'at=%s\nfrom=firstmate\n--\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" > $FM_HOME/state/alpha.inbox/$1; }
REL() { date -u -v+"$1" +%Y-%m-%dT%H:%M:%SZ; }

step "S1a: change wake with 3 NEW overdue rows -> all 3 presented"
run enqueue open-loop-ledger "check: open-loop-ledger (3 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
step "S1b: ack before any action -> refused, lists all 3"
ack
step "S1c: actions on 2 of 3 rows -> ack refused, lists only the 3rd"
msg 001.msg "hold while captain pause lasts"
run ol action stalled_worker:alpha steered --evidence 001.msg
run ol action silent_report:gamma deferred --evidence "captain ordered fleet pause; gamma paused" --recheck "$(REL 6H)"
ack
step "S1d: free-text escalation on firstmate-owned beta while backlog is unreadable -> recorded as answering only this turn; ack succeeds"
run ol action unanswered_question:beta:deploy escalated --evidence "asked captain in chat about beta deploy"
ack

step "S2a: heartbeat republishes SAME rows (ages grow; alpha pane retry counter ticks 45s -> 1m 12s); change wake"
sleep 2
edit_rows 'rows[0]["evidence"]="pane: paused by captain order; retry in 1m 12s"'
publish
run enqueue open-loop-ledger "check: open-loop-ledger (3 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
step "S2b: ack -> unchanged alpha/gamma do not block; beta's turn-only escalation does block"
ack
S2_DRAIN=$DRAIN_OUT

step "S3a: rubber stamp: --hold naming a task NOT held for the captain -> refused"
printf '## In flight\n\n## Queued\n\n## Done\n' > $FM_HOME/data/backlog.md
run ol action unanswered_question:beta:deploy escalated --evidence "escalated" --hold beta-deploy
step "S3b: create a real captain hold, escalate bound to it -> accepted"
run "$W/bin/fm-captain-hold.sh" hold beta-deploy --reason "captain decides whether beta deploys to prod" --title "Beta deploy call"
run ol action unanswered_question:beta:deploy escalated --evidence "captain asked: deploy beta to prod?" --hold beta-deploy
step "S3c: ack the S2 wake -> succeeds"
ack

step "S4a: periodic resurface wake, rows unchanged -> WAITING OPEN WORK list, no OVERDUE, no STANDING"
sleep 2; publish
run enqueue open-loop-ledger-resurface "check: open-loop-ledger-resurface (3 overdue assigned obligations; periodic waiting list)"
drain_and_capture
step "S4b: ack with no new actions -> succeeds"
ack

step "S5a: captain unpauses alpha: new status line (evidence + clock restart); new row epsilon; change wake"
sleep 2
edit_rows '
rows[0].update(evidence="status: resumed after pause; no progress since", start_epoch=int(__import__("time").time())-3700)
rows.append({"id":"open_pr:epsilon","category":"open_pr","subject":"https://github.com/o/r/pull/9","owner":"worker:epsilon","next_action":"route epsilon PR review","evidence":"checks pending","start_epoch":int(__import__("time").time())-4000,"limit_seconds":3600,"source":{"task":"epsilon"}})'
publish
run enqueue open-loop-ledger "check: open-loop-ledger (4 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
step "S5b: ack -> refused, lists only alpha and epsilon"
ack
step "S5c: new steer for alpha; worker-owned escalation (no hold possible) on epsilon; ack -> succeeds"
msg 002.msg "you are unpaused; resume"
run ol action stalled_worker:alpha steered --evidence 002.msg
run ol action open_pr:epsilon escalated --evidence "told captain about epsilon PR"
ack

step "S6a: SAME status text again, but alpha posts a fresh status line (clock restarts) -> alpha gated again"
sleep 2
edit_rows 'rows[0]["start_epoch"]=int(__import__("time").time())-3650'
publish
run enqueue open-loop-ledger "check: open-loop-ledger (4 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
step "S6b: ack -> refused on alpha only; steer; ack -> succeeds"
ack
msg 003.msg "keep going"
run ol action stalled_worker:alpha steered --evidence 003.msg
ack

step "S7a: resurface wake + change wake (new row zeta) together -> OVERDUE zeta, STANDING covered rows, WAITING list incl. epsilon 'no proof'"
sleep 2
edit_rows 'rows.append({"id":"unlanded_commit:zeta","category":"unlanded_commit","subject":"zeta","owner":"worker:zeta","next_action":"land zeta commits","evidence":"2 commits absent from main","start_epoch":int(__import__("time").time())-90000,"limit_seconds":86400})'
publish
run enqueue open-loop-ledger "check: open-loop-ledger (5 overdue assigned obligations; read state/open-loops.json)"
run enqueue open-loop-ledger-resurface "check: open-loop-ledger-resurface (5 overdue assigned obligations; periodic waiting list)"
drain_and_capture
step "S7b: ack refused on zeta; defer zeta; ack -> succeeds"
ack
run ol action unlanded_commit:zeta deferred --evidence "zeta lane paused by captain" --recheck "$(REL 6H)"
ack
step "S7c: one-deferral limit: second deferral on unchanged zeta -> refused, row becomes captain_visible"
run ol action unlanded_commit:zeta deferred --evidence "still paused" --recheck "$(REL 8H)"

step "S8a: captain answers beta-deploy hold -> next change wake re-presents beta (and captain_visible zeta)"
printf 'Captain: yes, deploy beta.\n' > $FM_HOME/lab-decision.txt
run "$W/bin/fm-captain-hold.sh" answer beta-deploy --decision-file $FM_HOME/lab-decision.txt --release
run enqueue open-loop-ledger "check: open-loop-ledger (5 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
step "S8b: ack -> refused on beta and zeta only"
ack
step "S8c: zeta evidence changes (new commit) -> fresh deferral allowance; beta steered via firstmate note"
sleep 1
edit_rows 'rows[-1].update(evidence="3 commits absent from main")'
publish
run ol action unlanded_commit:zeta deferred --evidence "zeta still paused after new commit" --recheck "$(REL 6H)"
run ol action unanswered_question:beta:deploy escalated --evidence "relayed captain answer to beta" 
step "S8d: next drain + ack (beta's unbound escalation answers this turn only)"
run enqueue open-loop-ledger "check: open-loop-ledger (5 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
ack

step "S9a: away daemon: FM_WAKE_ACK_AWAY_DAEMON=1 WITHOUT state/.afk -> still gated (new row eta)"
edit_rows 'rows.append({"id":"silent_report:eta","category":"silent_report","subject":"eta","owner":"worker:eta","next_action":"check in with eta","evidence":"no report","start_epoch":int(__import__("time").time())-2000,"limit_seconds":900})'
publish
run enqueue open-loop-ledger "check: open-loop-ledger (6 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
cmd=$(printf '%s\n' "$DRAIN_OUT" | sed -n 's/^WAKE_ACK_REQUIRED: after handling completes run bin\/fm-wake-drain.sh //p' | tail -1)
echo "\$ FM_WAKE_ACK_AWAY_DAEMON=1 fm-wake-drain.sh $cmd"; FM_WAKE_ACK_AWAY_DAEMON=1 drain $cmd 2>&1; echo "[exit $?]"
step "S9b: with state/.afk present (captain away) -> daemon acks the handled wake without recording an action"
touch $FM_HOME/state/.afk
echo "\$ FM_WAKE_ACK_AWAY_DAEMON=1 fm-wake-drain.sh $cmd"; FM_WAKE_ACK_AWAY_DAEMON=1 drain $cmd 2>&1; echo "[exit $?]"
rm -f $FM_HOME/state/.afk
python3 -I -c "import json,sys; a=json.load(open(sys.argv[1]))['handling']['actions']; print('eta action recorded by daemon ack:', 'silent_report:eta' in a)" $FM_HOME/state/open-loops.json
step "S9c: firstmate's own next drain still presents and gates eta"
run enqueue open-loop-ledger "check: open-loop-ledger (6 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
ack
