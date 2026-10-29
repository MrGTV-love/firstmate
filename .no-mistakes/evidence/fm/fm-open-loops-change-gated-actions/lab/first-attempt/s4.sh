. "$(dirname "$0")/lab-lib.sh"; cd "$W"
step "S4a: ack the S2 change wake now that beta has a hold-bound escalation (succeeds)"
DRAIN_OUT=$(grep WAKE_ACK_REQUIRED "$(dirname "$0")/s2.txt"); ack
step "S4b: 6 hours later the periodic resurface wake queues; rows still unchanged"
python3 -I - "$ROWS" <<'PY'
import json,sys; p=sys.argv[1]; rows=json.load(open(p))
for r in rows: r["age_seconds"] += 21600
json.dump(rows,open(p,"w"))
PY
publish
run enqueue open-loop-ledger-resurface "check: open-loop-ledger-resurface (3 overdue assigned obligations; periodic waiting list)"
drain_and_capture
step "S4c: ack the resurface wake with no new actions (succeeds)"
ack
step "S4d: digest command directly (same list)"
run ol --digest
