#!/usr/bin/env bash
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6FJ8XSS0AWB1CFHTT675C3M
cd "$WT"
unset FM_GUARD_EVENT_LOG FM_TASK_ID FM_SESSION_ID CLAUDE_CODE_SESSION_ID FM_GATE_REFUSE_BYPASS ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
. /tmp/fmtest-01M6/lab.path
export FM_HOME=$LAB
export TMUX_TMPDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB")
unset TMUX
LOG=$FM_HOME/state/guard-events.jsonl
before=$(wc -l <"$LOG")
rows() { tail -n +"$((before+1))" "$LOG" | jq -c '{guard,rule,task,decision,override,cleared_by,actor}'; before=$(wc -l <"$LOG"); }

echo "### S-spawn-switches: real fm-spawn.sh in the marked lab home with FM_SPAWN_NO_GUARD=1 FM_COMPACT_ADVISER_DISABLE=1"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_SPAWN_NO_GUARD=1 FM_COMPACT_ADVISER_DISABLE=1 \
  bin/fm-spawn.sh lab-t1 /tmp/fmtest-01M6/no-such-project --mode no-mistakes --yolo off >/tmp/fmtest-01M6/spawn1.out 2>&1; echo "spawn rc=$?"
tail -3 /tmp/fmtest-01M6/spawn1.out
rows
echo "### S-spawn-internal: FM_SPAWN_NO_GUARD=internal (firstmate's own re-exec) records no bypass"
env -u FM_ROOT_OVERRIDE FM_SPAWN_NO_GUARD=internal bin/fm-spawn.sh lab-t2 /tmp/fmtest-01M6/no-such-project --mode no-mistakes --yolo off >/tmp/fmtest-01M6/spawn2.out 2>&1; echo "spawn rc=$?"
rows

echo; echo "### S-apikey: claude-api-billing via the real library entrypoint (dummy non-credential value)"
api() { # label allow account launch_env names setvar
  local label=$1; shift
  ( . bin/fm-api-key-guard-lib.sh; ID=key-t1; if [ "$6" = set ]; then export ANTHROPIC_API_KEY=dummy-not-a-key; fi
    fm_api_key_guard claude "$1" "$2" "$3" "$4" tmux 2>/dev/null; echo "$label rc=$?" )
}
api "allowlist lists key, key set     " 0 '' 1 ANTHROPIC_API_KEY set
api "allowlist lists key, key unset   " 0 '' 1 ANTHROPIC_API_KEY unset
api "default boundary, key set        " 0 '' 0 '' set
api "--allow-api-key, key set (waiver)" 1 '' 0 '' set
api "--allow-api-key, key unset       " 1 '' 0 '' unset
api "--allow-api-key, allowlist omits " 1 '' 1 OTHER set
api "worker-account pin, key set      " 0 acct 1 ANTHROPIC_API_KEY set
rows
echo "credential value in log: $(grep -c dummy-not-a-key "$LOG")"

echo; echo "### S-role-nm: main's no-mistakes registration check still refuses a mismatched registration, and records deny"
CL=/tmp/fmtest-01M6/fmclone; NMH=/tmp/fmtest-01M6/nmhome; rm -rf "$NMH"; mkdir -p "$NMH"
python3 -I - "$NMH/state.sqlite" "$CL" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE repos(working_path TEXT, upstream_url TEXT)")
c.execute("INSERT INTO repos VALUES (?,?)", (sys.argv[2], "https://github.com/someone-else/firstmate.git")); c.commit()
PY
NM_HOME=$NMH ID=role-nm bin/fm-role.sh check "$CL" upstream-consent github.com/MrGTV-love/firstmate mode no-mistakes; echo "check rc=$?"
rm -f "$NMH/state.sqlite"
NM_HOME=$NMH ID=role-nm bin/fm-role.sh check "$CL" upstream-consent github.com/MrGTV-love/firstmate mode no-mistakes; echo "check rc=$? (unregistered)"
rows
