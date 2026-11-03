#!/usr/bin/env python3
"""Cold-reader join from records alone: for each pair of successive observed quota rows,
list callers whose [first seen, process_end or open] span overlaps the interval.
Overlap is coincidence in time, not proof of who spent the points."""
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
print("quota rows in order:")
for r in rows:
    if r["kind"]=="quota":
        print("  t=%.2f status=%s exit=%s reason=%s graphql=%s"%(r["observed_at"],r["status"],r.get("exit_code"),r.get("reason"),r.get("graphql")))
ends={(r["pid"],r["start"],r["run_id"]):r["observed_at"] for r in rows if r["kind"]=="process_end"}
callers=[]
for r in rows:
    if r["kind"]!="process" or r["argv"][:1]!=["sh"] : continue
    if "gh" not in r["argv"][:2]: continue
    callers.append(dict(pid=r["pid"],begin=r["observed_at"],end=ends.get((r["pid"],r["start"],r["run_id"])),argv=r["argv"],parent=r["ancestors"][0]["argv"][:2] if r["ancestors"] else None,cmd=" ".join(r["argv"][2:4])))
print("labeled fixture callers:")
for c in callers: print("  ",c)
obs=[r for r in rows if r["kind"]=="quota" and r["status"]=="observed"]
print("intervals between successive observed quota rows (fixture callers only):")
out=[]
for a,b in zip(obs,obs[1:]):
    t1,t2=a["observed_at"],b["observed_at"]
    alive=[c["cmd"] for c in callers if c["begin"]<=t2 and (c["end"] is None or c["end"]>=t1)]
    print("   %.2f -> %.2f used %s -> %s delta=%s callers=%s"%(t1,t2,a["graphql"]["used"],b["graphql"]["used"],b["graphql"]["used"]-a["graphql"]["used"],alive))
    out.append((b["graphql"]["used"]-a["graphql"]["used"],alive))
s=[r for r in rows if r["kind"]=="sampling"]
print("sampling: rows=%d scans=%d failures=%d worst_gap=%.3f"%(len(s),sum(r["scans"] for r in s),sum(r["failures"] for r in s),max(r["max_gap_seconds"] for r in s)))
# Independent expected result, set before the run by the driver's timeline.
big=[x for x in out if x[0]>1000]
assert len(big)==1 and big[0][1]==["api graphql"], big
one=[x for x in out if x[0]==20]
assert len(one)==1 and one[0][1]==["pr view"], one
un=[r for r in rows if r["kind"]=="quota" and r["status"]=="unavailable"]
assert len(un)==2 and all(r["graphql"]=={} for r in un), un
nul=[r for r in obs if r["graphql"].get("used")==7]
assert nul and "limit" not in nul[0]["graphql"] and "remaining" not in nul[0]["graphql"], nul
ex=[r for r in obs if r["graphql"].get("remaining")==0]
assert len(ex)==1
print("ASSERTIONS PASS: burst caller alone overlaps the big jump; quiet caller alone overlaps the small one; failed and malformed reads are unavailable with no fields; null stays absent; exhausted reads remaining=0")
