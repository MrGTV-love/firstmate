. "$(dirname "$0")/common.sh"
banner; echo "### LABELLED FIXTURE quota values, not the real account"
R=$(mktemp -d "$(dirname "$0")/b.XXXX"); export FM_STATE_OVERRIDE="$R/state"; mkdir -p "$R/state" "$R/bin" "$R/fix"
cat > "$R/bin/gh-axi" <<F
#!/bin/sh
n=\$(cat "$R/n" 2>/dev/null || echo 0); echo \$((n+1)) > "$R/n"
case \$n in 0) u=4000;r=1000;; 1) u=4001;r=999;; *) u=5000;r=0;; esac
printf 'api_response:\n  body: used=%s reset=1794000000 limit=5000 remaining=%s\n' \$u \$r
F
cat > "$R/fix/gh" <<'F'
#!/bin/sh
sleep 4
F
cat > "$R/fix/board-reader.sh" <<'F'
#!/bin/sh
"$(dirname "$0")/gh" api graphql -f query=PAYLOAD
true
F
cat > "$R/fix/recon.sh" <<'F'
#!/bin/sh
"$(dirname "$0")/board-reader.sh"
true
F
chmod +x "$R/bin/gh-axi" "$R/fix"/*
export PATH="$R/bin:$PATH"
"$PY" "$OWNER" start >/dev/null; echo start=$?
sleep 20
"$R/fix/recon.sh"; echo caller exit=$?
sleep 10
"$PY" "$OWNER" stop >/dev/null; echo stop=$?
"$PY" "$OWNER" records > "$R/rec.jsonl"; echo records=$? rows=$(wc -l < "$R/rec.jsonl")
"$PY" - "$R/rec.jsonl" <<'P'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
q=[r for r in rows if r["kind"]=="quota" and r["status"]=="observed"]
p=[r for r in rows if r["kind"]=="process" and r["argv"][:2]!=["sh","gh-axi"] ]
for a,b in zip(q,q[1:]):
    g0,g1=a["graphql"],b["graphql"]
    print("interval used",g0["used"],"->",g1["used"],"delta",g1["used"]-g0["used"],"remaining",g1["remaining"],"reset",g1["reset"])
    lab=[r for r in p if a["observed_at"]<=r["observed_at"]<=b["observed_at"] and any("recon.sh" in x for an in r["ancestors"] for x in an["argv"])]
    for r in lab:
        print("  observed caller",r["argv"],"pid",r["pid"],"start",r["start"],"chain",[x["argv"][:2] for x in r["ancestors"][:3]])
    if not lab: print("  observed labelled caller: none -> this delta stays unattributed")
print("note: time overlap only; a row does not prove that caller spent these points")
P
