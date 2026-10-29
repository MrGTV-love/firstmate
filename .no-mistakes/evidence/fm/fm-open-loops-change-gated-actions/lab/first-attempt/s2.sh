. "$(dirname "$0")/lab-lib.sh"; cd "$W"
step "S2a: heartbeat republishes the SAME rows (ages grow; stalled_worker retry counter ticks 45s -> 1m 12s); a change wake queues"
python3 -I - "$ROWS" <<'PY'
import json,sys; p=sys.argv[1]; rows=json.load(open(p))
for r in rows:
    r["age_seconds"] += 600
    if r["category"]=="stalled_worker": r["evidence"]="pane: paused by captain order; retry in 1m 12s"
json.dump(rows,open(p,"w"))
PY
publish
run enqueue open-loop-ledger "check: open-loop-ledger (3 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
step "S2b: ack (alpha and gamma unchanged must NOT block; beta's unverified escalation answered only its own turn, so beta must block)"
ack
