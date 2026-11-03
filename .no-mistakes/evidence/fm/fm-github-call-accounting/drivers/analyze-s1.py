import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
runs=[]
for r in rows:
    if r["kind"]=="owner" and r.get("action")=="start": runs.append(r["run_id"])
print("kinds:",{k:sum(1 for r in rows if r["kind"]==k) for k in sorted({r["kind"] for r in rows})},"runs:",len(runs))
q=[r for r in rows if r["kind"]=="quota" and r["run_id"]==runs[0]]
print("run1 quota rows:")
prev=None
for r in q:
    g=r["graphql"]
    print(" ",r["status"],"source=",r["source"],"endpoint=",r["endpoint"],"host=",r.get("host"),"exit=",r.get("exit_code"),"started=%.3f"%r["request_started_at"],"gap=%s"%("-" if prev is None else "%.3f"%(r["request_started_at"]-prev)),"used=",g.get("used"),"reset=",g.get("reset"),"limit=",g.get("limit"),"remaining=",g.get("remaining"))
    prev=r["request_started_at"]
print("run1 sampling rows:")
for r in rows:
    if r["kind"]=="sampling" and r["run_id"]==runs[0]: print("  scans=%d failures=%d max_gap=%.3f interval=%s"%(r["scans"],r["failures"],r["max_gap_seconds"],r["process_interval"]))
fix=[r for r in rows if r["kind"]=="process" and any(x in r["argv"] for x in ("gh",)) and r["argv"][:1]==["sh"]]
print("fixture process rows (script basename gh, run under sh):")
ends={}
for r in rows:
    if r["kind"]=="process_end": ends.setdefault((r["pid"],r["start"]),[]).append(r)
for r in fix:
    e=ends.get((r["pid"],r["start"]),[])
    print(" pid",r["pid"],"run",runs.index(r["run_id"])+1,"argv",r["argv"],"src",r["argv_source"],"first_seen=%.2f"%r["observed_at"],"end=%s"%(["%.2f(run%d)"%(x["observed_at"],runs.index(x["run_id"])+1) for x in e]),"ancestor_end",r["ancestor_end"])
    print("    ancestors:",[(a["pid"],a["ppid"],a["argv"]) for a in r["ancestors"][:3]])
self_rows=[r for r in rows if r["kind"]=="process" and r["argv"][:1] and "gh-axi" in " ".join(r["argv"][:3])]
qp={r.get("request_pid") for r in rows if r["kind"]=="quota"}
print("gh-axi rows",len(self_rows),"of which observer's own quota child:",sum(1 for r in self_rows if r["pid"] in qp))
allp=[r for r in rows if r["kind"]=="process"]
print("total process rows",len(allp),"process_end rows",sum(1 for r in rows if r["kind"]=="process_end"),"sampling scans total",sum(r["scans"] for r in rows if r["kind"]=="sampling"))
ids={}
for r in allp: ids[(r["run_id"],r["pid"],r["start"])]=ids.get((r["run_id"],r["pid"],r["start"]),0)+1
print("max process rows per identity per run:",max(ids.values()))
print("process_end keys:",sorted(k for r in rows if r["kind"]=="process_end" for k in r.keys()))
txt=open(sys.argv[1]).read()
print("CANARY in records:", "CANARY" in txt)
