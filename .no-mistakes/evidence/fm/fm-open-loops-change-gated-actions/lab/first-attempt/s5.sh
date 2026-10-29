. "$(dirname "$0")/lab-lib.sh"; cd "$W"
step "S5a: captain unpauses alpha: alpha posts a new status line (evidence changes); a NEW row epsilon appears; change wake"
python3 -I - "$ROWS" <<'PY'
import json,sys; p=sys.argv[1]; rows=json.load(open(p))
for r in rows:
    if r["id"]=="stalled_worker:alpha":
        r["evidence"]="status: resumed after pause; no progress since"; r["age_seconds"]=3700
rows.append({"id":"open_pr:epsilon","category":"open_pr","subject":"https://github.com/o/r/pull/9","owner":"worker:epsilon","next_action":"route epsilon's PR review","evidence":"checks pending","age_seconds":4000,"limit_seconds":3600,"source":{"task":"epsilon"}})
json.dump(rows,open(p,"w"))
PY
publish
run enqueue open-loop-ledger "check: open-loop-ledger (4 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
step "S5b: ack without actions (must refuse; only alpha and epsilon listed)"
ack
step "S5c: new steer for alpha; worker-owned escalation (no hold possible) for epsilon; ack succeeds"
printf 'at=%s\nfrom=firstmate\n--\nyou are unpaused; resume\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > $FM_HOME/state/alpha.inbox/002.msg
run ol action stalled_worker:alpha steered --evidence 002.msg
run ol action open_pr:epsilon escalated --evidence "told captain about epsilon PR"
ack
