#!/usr/bin/env bash
# S4: real owner + real ps behind a disposable fault switch, wall clock x7200 (1 s real = 2 h).
# argv: <label> <flag-off-at-real-s> <stop-at-real-s>
. /Users/charlesabrooker/.no-mistakes/evidence/01M6HY67SMDHG0CZE4NE696MQG/lib-fixture.sh
LABEL=$1; OFF=$2; STOP=$3
mklab; mkfix
trap 'cleanup_fixture_procs; rm -rf "$FIX"; eval "$LAB_TEARDOWN"' EXIT
mkdir "$FIX/bin"
printf '#!/bin/sh\nprintf "api_response:\\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\\n"\n' > "$FIX/bin/gh-axi"
cat > "$FIX/bin/ps" <<SH
#!/bin/sh
[ -e "$FIX/ps-fail" ] && exit 1
exec /bin/ps "\$@"
SH
chmod +x "$FIX/bin/"*; export PATH="$FIX/bin:$PATH"
S=$(start_caller pr checks 1); L=$(start_caller run watch 2)
GS=$(gh_pid_of "$S"); GL=$(gh_pid_of "$L")
python3 "$E/clock-launcher.py" "$OWNER" 7200 "$STOP" 2>"$FIX/owner.err" & RUNPID=$!
sleep 3;  : > "$FIX/ps-fail"; echo "[$LABEL] ps made to fail at about 6 sim h"
sleep 3;  kill_gh "$GL"; echo "[$LABEL] ender caller killed at about 12 sim h, while scans fail"
sleep $((OFF-6)); rm -f "$FIX/ps-fail"; echo "[$LABEL] ps restored at about $((OFF*2)) sim h"
wait $RUNPID; echo "[$LABEL] owner exit=$? stderr bytes=$(wc -c < "$FIX/owner.err")"
python3 "$WT/bin/fm-github-accounting.py" records > "$FIX/all.jsonl"
python3 - "$FIX/all.jsonl" "$GS" "$GL" "$LABEL" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]; gs,gl=int(sys.argv[2]),int(sys.argv[3]); B=1794000000; L=sys.argv[4]
h=lambda r:round((r['observed_at']-B)/3600,1)
for name,pid in(("survivor",gs),("ender",gl)):
    print(f"[{L}] {name}: process rows sim h",[h(r) for r in rows if r['kind']=='process' and r['pid']==pid],"process_end sim h",[h(r) for r in rows if r['kind']=='process_end' and r['pid']==pid])
print(f"[{L}] sampling (sim h, scans, failures):",[(h(r),r['scans'],r['failures']) for r in rows if r['kind']=='sampling'])
PY
