#!/usr/bin/env bash
# S3 (F1): real owner + real ps + real fixture callers, wall clock x7200 (1 s real = 2 h).
# argv: <label> <owner-path>. Fake gh-axi keeps account out; prune runs at each real 15 s quota tick.
. /Users/charlesabrooker/.no-mistakes/evidence/01M6HY67SMDHG0CZE4NE696MQG/lib-fixture.sh
LABEL=$1; OWNERPATH=$2
mklab; mkfix
trap 'cleanup_fixture_procs; rm -rf "$FIX"; eval "$LAB_TEARDOWN"' EXIT
mkdir "$FIX/bin"; printf '#!/bin/sh\nprintf "api_response:\\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\\n"\n' > "$FIX/bin/gh-axi"; chmod +x "$FIX/bin/gh-axi"
export PATH="$FIX/bin:$PATH"
SECRET=FIXTURESECRETs3zz
S=$(start_caller pr checks 1 --body "$SECRET")   # survivor: alive when the observer stops
L=$(start_caller run watch 2 --body "$SECRET")    # ender: leaves after more than 48 simulated h
GS=$(gh_pid_of "$S"); GL=$(gh_pid_of "$L")
BL=$(pgrep -P "$L" | head -1)
python3 "$E/clock-launcher.py" "$OWNERPATH" 7200 34 2>"$FIX/owner.err" &
RUNPID=$!
sleep 8
echo "at +8s real ($LABEL): kill ender's parent wrapper-b (pid $BL), so its ancestry changes; renewal must keep the saved chain"
kill "$BL"
sleep 22
echo "at +30s real ($LABEL): end ender gh pid $GL (about 60 simulated h)"
kill_gh "$GL"
wait $RUNPID; echo "owner exit=$?  stderr bytes=$(wc -c < "$FIX/owner.err")"
python3 "$WT/bin/fm-github-accounting.py" records > "$FIX/all.jsonl"
grep -c "$SECRET" "$FM_HOME/state/github-accounting/observations.sqlite" | sed 's/^/secret matches in db: /'
python3 - "$FIX/all.jsonl" "$GS" "$GL" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]; gs,gl=int(sys.argv[2]),int(sys.argv[3]); B=1794000000
for name,pid in(("survivor",gs),("ender",gl)):
    p=[r for r in rows if r['kind']=='process' and r['pid']==pid]
    e=[r for r in rows if r['kind']=='process_end' and r['pid']==pid]
    print(f"{name} pid={pid}: retained process rows at sim hours",[round((r['observed_at']-B)/3600,1) for r in p],"process_end at sim hours",[round((r['observed_at']-B)/3600,1) for r in e])
    print("  argv set:",{json.dumps(r['argv']) for r in p}); print("  ancestor set:",{json.dumps([a['argv'][:2] for a in r['ancestors']]) for r in p})
    if e:
        j=[r for r in p if (r['pid'],r['start'],r['run_id'])==(e[0]['pid'],e[0]['start'],e[0]['run_id'])]
        print("  end row joins retained process rows by pid+start+run_id:",len(j))
    if len(p)>1: print("  largest gap between retained rows, sim h:",round(max(b['observed_at']-a['observed_at'] for a,b in zip(p,p[1:]))/3600,2))
print("sampling failures:",sum(r['failures'] for r in rows if r['kind']=='sampling'),"owner rows:",[r['action'] for r in rows if r['kind']=='owner'])
print("oldest stored row sim h:",round((rows[0]['observed_at']-B)/3600,1)," last prune tick sim h ~",round(max(r['request_started_at'] for r in rows if r['kind']=='quota')/3600-B/3600,1),"(48 h window is enforced at each tick)")
PY
