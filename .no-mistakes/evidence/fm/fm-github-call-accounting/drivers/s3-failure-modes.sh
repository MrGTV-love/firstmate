#!/usr/bin/env bash
# Fail-closed paths: gh-axi missing, gh-axi hung, owner killed. Real owner, real ps. Never touches the account.
set -u
EV=$1; . "$EV/drivers/common.sh"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
PY=$(python3 -c 'import sys;print(sys.executable)')
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; export FM_HOME; echo "lab_home=$FM_HOME"
FIX="$FM_HOME/fixtures"; mkdir -p "$FIX/hang" "$FIX/ok"
dump() { "$PY" "$OWNER" records --kind "$1" | python3 -c '
import json,sys
for l in sys.stdin:
    r=json.loads(l); print("  ",{k:r[k] for k in sorted(r) if k in("status","reason","exit_code","graphql","action","scans","failures")})'; }
echo "=== A. gh-axi not on PATH: owner keeps running and says command_unavailable"
( export PATH=/usr/bin:/bin; command -v gh-axi || echo "gh-axi absent from this PATH"
  "$PY" "$OWNER" start; echo "start_exit=$?"; sleep 17; "$PY" "$OWNER" status; "$PY" "$OWNER" stop; echo "stop_exit=$?" )
dump quota
rm -rf "$FM_HOME/state/github-accounting"
echo "=== B. gh-axi hung: next tick says pending, no overlap; stop ends the private group fast"
cat > "$FIX/hang/gh-axi" <<F
#!/bin/sh
echo \$\$ >> "$FIX/hang/pids"
sleep 1000
F
chmod +x "$FIX/hang/gh-axi"
( export PATH="$FIX/hang:$PATH"; "$PY" "$OWNER" start >/dev/null; sleep 17; time "$PY" "$OWNER" stop; echo "stop_exit=$?" )
dump quota; echo "gh-axi launches: $(wc -l < "$FIX/hang/pids") (expect 1 across 2 ticks)"
for p in $(cat "$FIX/hang/pids"); do kill -0 "$p" 2>/dev/null && echo "hung child $p ALIVE" || echo "hung child $p gone"; done
rm -rf "$FM_HOME/state/github-accounting"; rm -f "$FIX/hang/pids"
echo "=== C. gh-axi hung, no-progress verdict at 4 s: timeout row, next tick sends a new request"
( export PATH="$FIX/hang:$PATH" FM_DURATION_NO_PROGRESS_SECS=4; "$PY" "$OWNER" start >/dev/null; sleep 22; "$PY" "$OWNER" stop >/dev/null )
dump quota; echo "gh-axi launches: $(wc -l < "$FIX/hang/pids") (expect 2)"
rm -rf "$FM_HOME/state/github-accounting"
echo "=== D. SIGKILL the owner: status stopped, new start works, database intact"
cat > "$FIX/ok/gh-axi" <<'F'
#!/bin/sh
printf 'api_response:\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\n'
F
chmod +x "$FIX/ok/gh-axi"; export PATH="$FIX/ok:$PATH"
pid=$("$PY" "$OWNER" start | python3 -c 'import json,sys;print(json.load(sys.stdin)["pid"])'); sleep 1; kill -9 "$pid"; wait_gone "$pid"
"$PY" "$OWNER" status
"$PY" "$OWNER" start; echo "restart_exit=$?"; sleep 1
echo "=== E. SIGTERM ends it cleanly with an owner stop row"
pid=$("$PY" "$OWNER" status | python3 -c 'import json,sys;print(json.load(sys.stdin)["pid"])'); kill -TERM "$pid"; wait_gone "$pid"; "$PY" "$OWNER" status
dump owner
/usr/bin/sqlite3 "$FM_HOME/state/github-accounting/observations.sqlite" 'PRAGMA integrity_check; PRAGMA auto_vacuum; PRAGMA application_id;'
echo "=== F. usage errors"
"$PY" "$OWNER" run --duration 0 2>&1 | tail -1; echo "exit=${PIPESTATUS[0]}"
"$PY" "$OWNER" start --duration 5 2>&1 | tail -1; echo "exit=${PIPESTATUS[0]}"
"$PY" "$OWNER" prune --kind quota 2>&1 | tail -1; echo "exit=${PIPESTATUS[0]}"
"$PY" "$OWNER" --help | sed -n 1,6p; echo "help_exit=${PIPESTATUS[0]}"
pgrep -fl "$FM_HOME" | grep -v pgrep || echo "no lab processes left"
bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME"; echo "teardown_exit=$?"
