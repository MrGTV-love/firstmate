#!/usr/bin/env bash
# S1/S2: real owner, real gh-axi rate_limit (read-only, free), real ps, in a marked lab home.
. /Users/charlesabrooker/.no-mistakes/evidence/01M6HY67SMDHG0CZE4NE696MQG/lib-fixture.sh
cd "$WT"
mklab
mkfix
trap 'cleanup_fixture_procs; python3 "$OWNER" stop >/dev/null 2>&1; rm -rf "$FIX"; eval "$LAB_TEARDOWN"' EXIT
SECRET=FIXTURESECRETs1zz
echo "host=$(hostname -s) head=$(git rev-parse HEAD) gh-axi=$(command -v gh-axi)"
echo "--- start"; python3 "$OWNER" start; echo "exit=$?"
A=$(start_caller pr checks 123 --watch --body "$SECRET" --token="$SECRET")
B=$(start_caller api graphql -f "query=$SECRET")
GA=$(gh_pid_of "$A"); GB=$(gh_pid_of "$B")
echo "fixture survivor gh pid=$GA ; fixture ender gh pid=$GB"
sleep 20
echo "--- end ender caller at +20s"; kill_gh "$GB"; ENDED_AT=$(python3 -c 'import time;print(time.time())')
sleep 17
echo "--- status"; python3 "$OWNER" status
echo "--- stop"; python3 "$OWNER" stop; echo "exit=$?"
echo "--- survivor still alive after stop (owner must not touch callers):"; kill -0 "$GA" && echo alive=$GA
python3 "$OWNER" records > "$FIX/all.jsonl"; echo "records exit=$?"
echo "--- independent REST read (one free call) for comparison"
gh-axi api rate_limit --jq '.resources.graphql | "used=\(.used) reset=\(.reset) limit=\(.limit) remaining=\(.remaining)"' --full | sed -n 's/^  body: //p'
echo "--- private state modes"
stat -f '%Lp %N' "$FM_HOME/state/github-accounting" "$FM_HOME/state/github-accounting/"* | sed "s#$FM_HOME#<lab>#"
echo "--- raw-byte secret check of db/log (0 matches expected)"
grep -c "$SECRET" "$FM_HOME/state/github-accounting/observations.sqlite" "$FM_HOME/state/github-accounting/owner.log" | sed "s#$FM_HOME#<lab>#"
python3 - "$FIX/all.jsonl" "$GA" "$GB" "$ENDED_AT" "$FIX" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]; ga,gb,ended=int(sys.argv[2]),int(sys.argv[3]),float(sys.argv[4]); fix=sys.argv[5]
print("--- kinds",{k:sum(r['kind']==k for r in rows) for k in sorted({r['kind'] for r in rows})})
print("--- quota rows")
q=[r for r in rows if r['kind']=='quota']
for r in q: print({k:r.get(k) for k in('status','source','endpoint','host','exit_code','request_started_at','graphql','reason')})
s=[r['request_started_at'] for r in q if 'request_started_at' in r]
print("quota gaps s:",[round(b-a,3) for a,b in zip(s,s[1:])])
print("--- sampling rows");
for r in rows:
    if r['kind']=='sampling': print({k:r[k] for k in('scans','failures','max_gap_seconds','process_interval')})
print("--- owner rows");
for r in rows:
    if r['kind']=='owner': print({k:r.get(k) for k in('action','process_interval','quota_interval')})
print("--- fixture process rows")
fx=[r for r in rows if r['kind']=='process' and r['pid'] in (ga,gb)]
for r in fx:
    print(json.dumps({'pid':r['pid'],'start':r['start'],'argv':r['argv'],'argv_source':r['argv_source'],'ancestor_end':r['ancestor_end'],
      'ancestors':[a['argv'] for a in r['ancestors']][:3],'run_id_matches':r['run_id']==rows[0]['run_id']}))
print("--- fixture process_end rows")
ends=[r for r in rows if r['kind']=='process_end' and r['pid'] in (ga,gb)]
for r in ends: print({'pid':r['pid'],'start':r['start'],'seconds_after_kill':round(r['observed_at']-ended,3)})
print("survivor process_end rows (0 expected):",sum(r['pid']==ga for r in ends)," ender process_end rows (1 expected):",sum(r['pid']==gb for r in ends))
others=[r for r in rows if r['kind']=='process' and r['pid'] not in (ga,gb)]
own=[r for r in others if any('fm-github-accounting.py' in a['argv'] for a in r['ancestors'][:1])]
print("--- other host gh/gh-axi rows: count=%d (of which owner's own quota child=%d). Details are withheld from this log."%(len(others),len(own)))
if own: print("owner-child example argv:",own[0]['argv'],"parent:",own[0]['ancestors'][0]['argv'])
txt=json.dumps(others)
print("all retained words of other rows free of '/' paths in argv values:",all(not any(('/' in w and w!='[REDACTED]') for w in r['argv']) for r in others))
print("fixture dir path present in stored rows (0 expected):",sum(fix in json.dumps(r) for r in rows))
PY
