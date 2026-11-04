#!/usr/bin/env bash
# S8: labeled fixture quota transition to exhaustion with known callers; a cold reader
# reconstructs the candidates from `records` output alone. Real owner, real ps. Fake gh-axi only:
# the real account is never exhausted.
. /Users/charlesabrooker/.no-mistakes/evidence/01M6HY67SMDHG0CZE4NE696MQG/lib-fixture.sh
mklab; mkfix
trap 'python3 "$OWNER" stop >/dev/null 2>&1; cleanup_fixture_procs; rm -rf "$FIX"; eval "$LAB_TEARDOWN"' EXIT
mkdir "$FIX/bin"
cat > "$FIX/bin/gh-axi" <<SH
#!/bin/sh
n=\$(cat "$FIX/tick" 2>/dev/null || echo 0); echo \$((n+1)) > "$FIX/tick"
case \$n in 0|1) u=4000;; *) u=5000;; esac
printf 'api_response:\n  body: used=%s reset=1794000000 limit=5000 remaining=%s\n' "\$u" "\$((5000-u))"
SH
chmod +x "$FIX/bin/gh-axi"; export PATH="$FIX/bin:$PATH"
python3 "$OWNER" start >/dev/null; T0=$(date +%s)
at(){ sleep "$(python3 -c "import time;print(max(0,$T0+$1-time.time()))")"; }
at 1;  EARLY=$(start_caller issue list --search early-only-secret); GE=$(gh_pid_of "$EARLY")
at 2;  SPEND=$(start_caller pr checks 9 --watch);                    GP=$(gh_pid_of "$SPEND")
at 5;  kill_gh "$GE"
at 20; SHORT=$(start_caller api graphql --paginate);                 GH=$(gh_pid_of "$SHORT")
at 22; SURV=$(start_caller run watch 3);                             GV=$(gh_pid_of "$SURV")
at 24; kill_gh "$GH"
at 33; kill_gh "$GP"
at 36; python3 "$OWNER" stop >/dev/null
echo "labels (held out from the reader): early=$GE spender=$GP short=$GH survivor=$GV"
python3 "$OWNER" records > "$FIX/all.jsonl"
cat > "$E/s8-cold-reader.py" <<'PY'
"""Cold reader: stored `records` JSONL on stdin only. Lists callers that overlap the largest quota rise."""
import json,sys
rows=[json.loads(l) for l in sys.stdin]
q=[r for r in rows if r['kind']=='quota' and r['status']=='observed']
pairs=[(b['graphql']['used']-a['graphql']['used'],a,b) for a,b in zip(q,q[1:])]
rise,a,b=max(pairs,key=lambda p:p[0]); t1,t2=a['observed_at'],b['observed_at']
print(f"largest rise: used {a['graphql']['used']} -> {b['graphql']['used']} (remaining {b['graphql']['remaining']}) in interval +{t2-t1:.1f}s")
ends={(r['pid'],r['start']):r['observed_at'] for r in rows if r['kind']=='process_end'}
seen={}
for r in rows:
    if r['kind']=='process': seen.setdefault((r['pid'],r['start']),r)
for key,r in seen.items():
    end=ends.get(key); overlap=r['observed_at']<=t2 and (end is None or end>=t1)
    names=[x for an in r['ancestors'] for x in an['argv'][1:2] if x!='[REDACTED]']
    fixture='wrapper-a.sh' in names
    if not fixture: continue
    print(f"pid={r['pid']} {'CANDIDATE' if overlap else 'excluded '} first_seen={r['observed_at']-t1:+.1f}s end={'none-observed' if end is None else format(end-t1,'+.1f')+'s'} argv={' '.join(r['argv'])} chain={' <- '.join(names)}")
print(f"other local rows not shown: {sum('wrapper-a.sh' not in [x for an in r['ancestors'] for x in an['argv'][1:2]] for r in seen.values())}")
print("A candidate overlaps the interval in time. That is an observed fact, not proof that it spent the points.")
print(f"sampling gaps: max {max(r['max_gap_seconds'] for r in rows if r['kind']=='sampling'):.3f}s failures {sum(r['failures'] for r in rows if r['kind']=='sampling')}")
PY
python3 "$E/s8-cold-reader.py" < "$FIX/all.jsonl"
grep -c early-only-secret "$FM_HOME/state/github-accounting/observations.sqlite" | sed 's/^/secret matches in db: /'
