#!/usr/bin/env bash
# 48 h retention through the owner's own commands, in a lab database the owner created. Never ages real state.
set -u
EV=$1; . "$EV/drivers/common.sh"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; export FM_HOME; echo "lab_home=$FM_HOME"
FIX="$FM_HOME/fixtures"; mkdir -p "$FIX/bin"
cat > "$FIX/bin/gh-axi" <<'F'
#!/bin/sh
printf 'api_response:\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\n'
F
chmod +x "$FIX/bin/gh-axi"; export PATH="$FIX/bin:$PATH"
S="$FM_HOME/state/github-accounting"; DB="$S/observations.sqlite"
python3 "$OWNER" prune; echo "first_prune_exit=$?"
echo sentinel > "$FM_HOME/state/unrelated.sentinel"; echo sentinel > "$S/unrelated-in-dir.sentinel"
seed() { python3 - "$DB" "$@" <<'PY'
import json,sqlite3,sys,time
db=sqlite3.connect(sys.argv[1]); now=time.time()
for spec in sys.argv[2:]:
    kind,label,age=spec.split(":")
    t=now-float(age)
    db.execute("INSERT INTO observations VALUES (?,?,?)",(t,kind,json.dumps(dict(kind=kind,label=label,observed_at=t,pid=1,start="x"))))
db.commit()
PY
}
inv() { python3 "$OWNER" records | python3 -c '
import json,sys,time
now=time.time()
for l in sys.stdin:
    r=json.loads(l)
    if "label" in r: print("   ",r["label"],r["kind"],"age_h=%.4f"%((now-r["observed_at"])/3600))'; }
H=172800
seed "quota:old-quota:$((H+3600))" "process:old-process:$((H+120))" "process_end:old-end:$((H+120))" "sampling:old-sampling:$((H+60))" "owner:old-owner:$((H+60))" \
     "quota:keep-inside-48h:$((H-300))" "process:keep-recent:60" "process_end:keep-recent-end:60"
echo "--- before prune"; inv
python3 "$OWNER" prune; echo "prune_exit=$?"
echo "--- after prune (old rows must be gone, keep rows must stay)"; inv
ls "$FM_HOME/state/unrelated.sentinel" "$S/unrelated-in-dir.sentinel"
echo "--- startup prune: old row seeded while stopped"
seed "quota:old-at-startup:$((H+60))"
python3 "$OWNER" start >/dev/null; sleep 1; python3 "$OWNER" stop >/dev/null; inv
echo "--- tick prune: row 8 s inside the cutoff at start, expires during a run, the next 15 s tick removes it"
seed "quota:expires-in-run:$((H-8))"
python3 "$OWNER" run --duration 17; echo "run_exit=$?"; inv
ls "$FM_HOME/state/unrelated.sentinel" "$S/unrelated-in-dir.sentinel"
echo "--- file does not grow unbounded after delete: auto_vacuum"; /usr/bin/sqlite3 "$DB" 'PRAGMA auto_vacuum;PRAGMA secure_delete;'
bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME"; echo "teardown_exit=$?"
