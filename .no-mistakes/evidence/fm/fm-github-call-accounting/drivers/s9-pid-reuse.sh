#!/usr/bin/env bash
# The OS cannot be forced to reuse a pid on demand, so a LABELED ps on PATH feeds the real owner CLI a staged table.
# Rows are labeled input, not a host observation. Filter, identity, ancestry and storage are the real code.
set -u
EV=$1; . "$EV/drivers/common.sh"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; export FM_HOME; echo "lab_home=$FM_HOME"
FIX="$FM_HOME/fixtures"; mkdir -p "$FIX/bin"; echo 1 > "$FIX/stage"
cat > "$FIX/bin/ps" <<F
#!/bin/sh
case "\$*" in *lstart*) ;; *) exec /bin/ps "\$@";; esac
s=\$(cat "$FIX/stage")
echo "    1     0 Mon Nov  2 09:00:00 2026 /sbin/launchd"
echo "  100     1 Mon Nov  2 09:00:01 2026 /bin/bash /x/cron.sh arg-value"
case \$s in
 1) echo " 4242   100 Mon Nov  2 10:00:00 2026 gh api graphql --field q=one"
    echo " 5000  9999 Mon Nov  2 10:00:00 2026 gh pr view 12";;
 2) echo " 4242   100 Mon Nov  2 11:00:00 2026 gh issue list"
    echo " 5000  9999 Mon Nov  2 10:00:00 2026 gh pr view 12";;
 3) echo " 4242   100 Mon Nov  2 11:00:00 2026 not-a-caller now";;
esac
F
cat > "$FIX/bin/gh-axi" <<'F'
#!/bin/sh
printf 'api_response:\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\n'
F
chmod +x "$FIX/bin/ps" "$FIX/bin/gh-axi"; export PATH="$FIX/bin:$PATH"
python3 "$OWNER" start >/dev/null; sleep 1.5; echo 2 > "$FIX/stage"; sleep 1.5; echo 3 > "$FIX/stage"; sleep 1.5; python3 "$OWNER" stop >/dev/null
python3 "$OWNER" records | python3 -c '
import json,sys
rows=[json.loads(l) for l in sys.stdin]
keep=[r for r in rows if r["kind"] in("process","process_end") and r["pid"] in(4242,5000)]
for r in keep:
    print(r["kind"],r["pid"],r["start"],r.get("argv",""),"ancestor_end=%s"%r.get("ancestor_end",""),"chain=%s"%[a["argv"] for a in r.get("ancestors",[])])
p=[r for r in keep if r["kind"]=="process" and r["pid"]==4242]; e=[r for r in keep if r["kind"]=="process_end" and r["pid"]==4242]
assert [r["start"] for r in p]==["Mon Nov 2 10:00:00 2026","Mon Nov 2 11:00:00 2026"],p
assert [r["start"] for r in e]==["Mon Nov 2 10:00:00 2026","Mon Nov 2 11:00:00 2026"],e
assert p[1]["observed_at"]>=e[0]["observed_at"]
o=[r for r in keep if r["pid"]==5000 and r["kind"]=="process"]; assert len(o)==1 and o[0]["ancestor_end"]=="unobserved" and o[0]["ancestors"]==[]
print("ASSERTIONS PASS: a reused pid with a new start is a new identity with its own end row; a process that stops being a caller ends; a missing parent stays unobserved")'
bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME"; echo "teardown_exit=$?"
