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
