. "$(dirname "$0")/common.sh"
banner
eval "$("$WT/bin/fm-lab-home.sh" env 2>"$(dirname "$0")/a.teardown")"
echo "### FM_HOME is a marked disposable lab home; no FM_STATE_OVERRIDE; real gh-axi on PATH: $(command -v gh-axi)"
unset FM_STATE_OVERRIDE
FIX=$(dirname "$0")/a-fix; mkdir -p "$FIX"
cat > "$FIX/gh" <<'F'
#!/bin/sh
sleep 3
F
cat > "$FIX/board-reader.sh" <<'F'
#!/bin/sh
"$(dirname "$0")/gh" api graphql -f query=CANARYQUERY --token=CANARYTOKEN --header "Authorization: CANARYHEADER"
sh -c "$(dirname "$0")/gh pr list --repo CANARYREPO/x; true"
true
F
cat > "$FIX/recon-parent.sh" <<'F'
#!/bin/sh
"$(dirname "$0")/board-reader.sh" CANARYARG
true
F
chmod +x "$FIX"/*
run "$PY" "$OWNER" status
run "$PY" "$OWNER" start
run "$PY" "$OWNER" start
run "$PY" "$OWNER" run --duration 1
run "$PY" "$OWNER" records
sleep 2
"$FIX/recon-parent.sh" & P=$!; echo "fixture recon-parent pid=$P"
wait $P; echo "fixture parent exit=$?"
sleep 26
run "$PY" "$OWNER" stop
run "$PY" "$OWNER" status
"$PY" "$OWNER" records > "$FM_HOME/records.jsonl"; echo "records exit=$? rows=$(wc -l < "$FM_HOME/records.jsonl")"
echo "--- independent direct read after stop"
gh-axi api rate_limit --jq '.resources.graphql | "used=\(.used) reset=\(.reset) limit=\(.limit) remaining=\(.remaining)"' --full | grep body
"$PY" - "$FM_HOME/records.jsonl" "$FIX" <<'P'
import json,sys,collections
rows=[json.loads(l) for l in open(sys.argv[1])]
kinds=collections.Counter(r["kind"] for r in rows); print("kinds",dict(kinds))
o=[r for r in rows if r["kind"]=="owner"]; print("owner events",[(r.get("action"),r["run_id"][:8],r.get("process_interval"),r.get("quota_interval")) for r in o])
q=[r for r in rows if r["kind"]=="quota"]
prev=None
for r in q:
    gap=None if prev is None else round(r["request_started_at"]-prev,3)
    prev=r.get("request_started_at")
    print("quota",r["status"],"|",r["source"],"|endpoint",r["endpoint"],"|host",r["host"],"|exit",r["exit_code"],"|",r["graphql"],"|request gap",gap)
s=[r for r in rows if r["kind"]=="sampling"]
for r in s: print("sampling scans",r["scans"],"failures",r["failures"],"max_gap",round(r["max_gap_seconds"],3))
p=[r for r in rows if r["kind"]=="process"]
fix=[r for r in p if any(t in " ".join(x for a in r["ancestors"] for x in a["argv"]) for t in ("recon-parent.sh",))]
for r in fix:
    print("fixture caller",r["argv"],"pid",r["pid"],"ppid",r["ppid"],"start",r["start"],"source",r["argv_source"],"end",r["ancestor_end"],"run",r["run_id"][:8])
    for a in r["ancestors"]: print("   ancestor",a["pid"],a["argv"][:6],a["start"])
print("other local gh rows, not labelled, count only:",len(p)-len(fix))
own=[r for r in p if r["argv"][:1]==["gh-axi"] or (len(r["argv"])>1 and r["argv"][1]=="gh-axi")]
print("gh-axi rows seen, argv heads:",collections.Counter(tuple(r["argv"][:4]) for r in own).most_common(4))
P
echo "--- privacy: canary hits in every owner file (want 0)"
for f in "$FM_HOME"/state/github-accounting/* "$FM_HOME/records.jsonl"; do printf '%s %s\n' "$(basename "$f")" "$(grep -ac CANARY "$f")"; done
echo "--- modes"; stat -f '%Sp %N' "$FM_HOME/state/github-accounting" "$FM_HOME"/state/github-accounting/* | sed "s#$FM_HOME/##"
echo "--- leftover children from this owner: gh-axi rate_limit ps with this home"; pgrep -f "$FM_HOME" | wc -l
"$WT/bin/fm-lab-home.sh" teardown "$FM_HOME" && rm -rf "$FM_HOME"; echo teardown=$?
