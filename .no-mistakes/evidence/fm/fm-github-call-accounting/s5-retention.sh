#!/usr/bin/env bash
# S5: real owner prune command at a fixed labeled clock on owner-format rows, with sentinels.
. /Users/charlesabrooker/.no-mistakes/evidence/01M6HY67SMDHG0CZE4NE696MQG/lib-fixture.sh
mklab; mkfix
trap 'cleanup_fixture_procs; rm -rf "$FIX"; eval "$LAB_TEARDOWN"' EXIT
A="$FM_HOME/state/github-accounting"
python3 "$OWNER" prune; echo "first prune creates private db: exit=$?"
echo sentinel-inside > "$A/unrelated.txt"; echo sentinel-outside > "$FM_HOME/state/unrelated-state.txt"
NOW=1794000000
python3 - "$A/observations.sqlite" $NOW <<'PY'
import sqlite3,sys,json
db=sqlite3.connect(sys.argv[1]); n=int(sys.argv[2])
for label,age,kind in(("older-1s",172801,"process"),("older-1s",172801,"process_end"),("older-1s",172801,"quota"),("exact-48h",172800,"process"),("exact-48h",172800,"process_end"),("newer-1s",172799,"process"),("newer-1s",172799,"quota"),("fresh",10,"sampling")):
    db.execute("INSERT INTO observations VALUES (?,?,?)",(n-age,kind,json.dumps({"label":label,"marker":"PAYLOADMARKER-"+label,"kind":kind,"observed_at":n-age})))
db.commit()
PY
cat > "$FIX/at.py" <<PY
import runpy,sys,time
time.time=lambda:$NOW.0
sys.argv=["$OWNER",*sys.argv[1:]]
runpy.run_path("$OWNER",run_name="__main__")
PY
echo "--- cutoff convention: only rows strictly older than now-172800 expire. now=$NOW"
echo "--- before"; python3 "$OWNER" records | python3 -c 'import json,sys
for l in sys.stdin:
  r=json.loads(l); print(r["kind"],r["label"])'
echo "--- prune at fixed clock"; python3 "$FIX/at.py" prune; echo "exit=$?"
echo "--- after"; python3 "$OWNER" records | python3 -c 'import json,sys
for l in sys.stdin:
  r=json.loads(l); print(r["kind"],r["label"])'
echo "--- expired payload bytes left in the db file (0 expected): $(grep -c 'PAYLOADMARKER-older' "$A/observations.sqlite")"
echo "--- retained payload bytes present (1 expected): $(grep -c 'PAYLOADMARKER-exact' "$A/observations.sqlite")"
echo "--- sentinels: $(cat "$A/unrelated.txt") $(cat "$FM_HOME/state/unrelated-state.txt")"
