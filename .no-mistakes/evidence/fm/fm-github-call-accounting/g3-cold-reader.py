#!/usr/bin/env python3
"""Cold reader: stdin = `fm-github-accounting.py records` JSONL. No other input. Prints each quota interval and which observed callers overlap it.
Overlap rule from docs/configuration.md: first_observed_at <= interval_end AND end >= interval_start. No end row = uncertain after last proven scan."""
import json, sys
rows = [json.loads(x) for x in sys.stdin]
q = [r for r in rows if r["kind"] == "quota" and r["status"] == "observed"]
callers = {}
for r in rows:
    if r["kind"] == "process":
        c = callers.setdefault((r["pid"], r["start"], r["run_id"]), {"first": r["first_observed_at"], "argv": r["argv"], "ancestors": r["ancestors"], "end": None})
    if r["kind"] == "process_end":
        k = (r["pid"], r["start"], r["run_id"])
        if k in callers: callers[k]["end"] = r["observed_at"]
out = []
for a, b in zip(q, q[1:]):
    hits = []
    for k, c in callers.items():
        if c["first"] <= b["observed_at"] and (c["end"] is None or c["end"] >= a["observed_at"]):
            hits.append({"pid": k[0], "reading": "overlap, end observed" if c["end"] else "first sighting in interval, end not observed: uncertain after last proven scan", "argv": c["argv"], "parents": [x["argv"] for x in c["ancestors"][:2]]})
    out.append({"from": a["observed_at"], "to": b["observed_at"], "used_delta": b["graphql"]["used"] - a["graphql"]["used"], "callers": hits})
print(json.dumps(out))
