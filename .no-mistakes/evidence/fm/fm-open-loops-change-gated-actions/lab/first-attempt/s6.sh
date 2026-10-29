. "$(dirname "$0")/lab-lib.sh"; cd "$W"
step "S6a: a resurface wake and a change wake (new row zeta) arrive together"
python3 -I - "$ROWS" <<'PY'
import json,sys; p=sys.argv[1]; rows=json.load(open(p))
rows.append({"id":"unlanded_commit:zeta","category":"unlanded_commit","subject":"zeta","owner":"worker:zeta","next_action":"land zeta's commits","evidence":"2 commits absent from main","age_seconds":90000,"limit_seconds":86400})
json.dump(rows,open(p,"w"))
PY
publish
run enqueue open-loop-ledger "check: open-loop-ledger (5 overdue assigned obligations; read state/open-loops.json)"
run enqueue open-loop-ledger-resurface "check: open-loop-ledger-resurface (5 overdue assigned obligations; periodic waiting list)"
drain_and_capture
step "S6b: ack refuses on zeta only; then defer zeta and ack succeeds"
ack
run ol action unlanded_commit:zeta deferred --evidence "zeta lane paused by captain" --recheck "$(date -u -v+6H +%Y-%m-%dT%H:%M:%SZ)"
ack
step "S6c: one-deferral limit: a second deferral on unchanged zeta is refused"
run ol action unlanded_commit:zeta deferred --evidence "still paused" --recheck "$(date -u -v+8H +%Y-%m-%dT%H:%M:%SZ)"
step "S6d: captain answers the beta-deploy hold; next change wake presents beta again (and zeta, now captain_visible)"
printf 'Captain: yes, deploy beta.\n' > $FM_HOME/lab-decision.txt
run "$W/bin/fm-captain-hold.sh" answer beta-deploy --decision-file $FM_HOME/lab-decision.txt --release
run enqueue open-loop-ledger "check: open-loop-ledger (5 overdue assigned obligations; read state/open-loops.json)"
drain_and_capture
step "S6e: ack refused until beta and zeta get new actions"
ack
