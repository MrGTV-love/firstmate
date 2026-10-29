. "$(dirname "$0")/lab-lib.sh"; cd "$W"
cat > $ROWS <<'J'
[
 {"id":"stalled_worker:alpha","category":"stalled_worker","subject":"alpha","owner":"worker:alpha","next_action":"steer alpha or record why it waits","evidence":"pane: paused by captain order; retry in 45s","age_seconds":7200,"limit_seconds":3600},
 {"id":"unanswered_question:beta:deploy","category":"unanswered_question","subject":"beta:deploy","owner":"firstmate","next_action":"answer or escalate beta's deploy question","evidence":"needs-decision [key=deploy]: deploy to prod now?","age_seconds":9000,"limit_seconds":900,"source":{"task":"beta","key":"deploy"}},
 {"id":"silent_report:gamma","category":"silent_report","subject":"gamma","owner":"worker:gamma","next_action":"check in with gamma","evidence":"no report since dispatch","age_seconds":5000,"limit_seconds":900}
]
J
publish
step "S1a: change wake with 3 new overdue rows"
run enqueue open-loop-ledger "check: open-loop-ledger (3 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
step "S1b: ack before any action (must refuse)"
ack
step "S1c: record actions on 2 of 3 rows, ack again (must refuse, naming only the 3rd)"
mkdir -p $FM_HOME/state/alpha.inbox
printf 'at=%s\nfrom=firstmate\n--\nhold while captain pause lasts\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > $FM_HOME/state/alpha.inbox/001.msg
run ol action stalled_worker:alpha steered --evidence 001.msg
run ol action silent_report:gamma deferred --evidence "captain ordered fleet pause; gamma paused" --recheck "$(date -u -v+6H +%Y-%m-%dT%H:%M:%SZ)"
ack
step "S1d: action on the last row, ack succeeds"
run ol action unanswered_question:beta:deploy escalated --evidence "asked captain in chat about beta deploy"
ack
