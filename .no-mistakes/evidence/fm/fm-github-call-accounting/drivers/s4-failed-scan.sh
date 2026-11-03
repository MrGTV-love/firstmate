#!/usr/bin/env bash
# A failed process scan ends nothing. PATH holds a labeled ps that delegates to /bin/ps until a flag file exists.
set -u
EV=$1; . "$EV/drivers/common.sh"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; export FM_HOME; echo "lab_home=$FM_HOME"
FIX="$FM_HOME/fixtures"; make_caller "$FIX"; mkdir -p "$FIX/bin"
cat > "$FIX/bin/ps" <<F
#!/bin/sh
[ -e "$FIX/fail" ] && exit 1
exec /bin/ps "\$@"
F
cat > "$FIX/bin/gh-axi" <<'F'
#!/bin/sh
printf 'api_response:\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\n'
F
chmod +x "$FIX/bin/ps" "$FIX/bin/gh-axi"; export PATH="$FIX/bin:$PATH"
( FIX_SECS=40 "$FIX/fixture-parent.sh" "$FIX/gh" issue view --repo stays-alive & wait ) &
( FIX_SECS=7 "$FIX/fixture-parent.sh" "$FIX/gh" pr list --repo dies-in-window & wait ) &
python3 "$OWNER" start >/dev/null; T0=$(date +%s); sleep 3
touch "$FIX/fail"; F0=$(date +%s); echo "scans fail from t+$((F0-T0))"
sleep 7   # pr list dies during this window; issue view stays alive
rm -f "$FIX/fail"; F1=$(date +%s); echo "scans recover at t+$((F1-T0)) epoch=$F1"
sleep 7
python3 "$OWNER" stop >/dev/null
python3 "$OWNER" records > "$FIX/all.jsonl"
python3 - "$FIX/all.jsonl" "$F1" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]; f1=float(sys.argv[2])
fix=[r for r in rows if r["kind"]=="process" and r["argv"][:2]==["sh","gh"]]
ends={(r["pid"],r["start"]):r["observed_at"] for r in rows if r["kind"]=="process_end"}
samp=[r for r in rows if r["kind"]=="sampling"]
print("sampling failures per row:",[r["failures"] for r in samp],"worst gap %.3f"%max(r["max_gap_seconds"] for r in samp))
res={}
for r in fix:
    e=ends.get((r["pid"],r["start"])); res[r["argv"][2]+" "+r["argv"][3]]=e
    print(r["argv"],"first=%.2f"%r["observed_at"],"end=%s"%("%.2f"%e if e else None), "secs after recovery=%s"%("%.2f"%(e-f1) if e else None))
assert sum(r["failures"] for r in samp)>0
assert res["issue view"] is None, "a live caller must not get an end row from failed scans"
assert res["pr list"] is not None and res["pr list"]>=f1, "the ended caller's row must wait for the first good scan"
print("ASSERTIONS PASS: failed scans counted; live caller has no end row; ended caller's end row comes after recovery")
PY
pkill -f "$FIX/gh" ; pkill -f "$FIX/fixture-parent"; wait 2>/dev/null
bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME"; echo "teardown_exit=$?"
