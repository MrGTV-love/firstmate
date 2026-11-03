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
rows() { tail -n +"$((before+1))" "$LOG" | jq -c '{guard,rule,task,decision,override,cleared_by}'; before=$(wc -l <"$LOG"); }
P=/tmp/fmtest-01M6/no-such-project
sp() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE "$@" >/tmp/fmtest-01M6/sp.out 2>&1; echo "spawn rc=$?"; grep -m1 -o 'error: ANTHROPIC_API_KEY[^;]*' /tmp/fmtest-01M6/sp.out || true; }

echo "### S-apikey-spawn: real fm-spawn.sh, config/launch-env-allowlist lists ANTHROPIC_API_KEY, dummy value set"
printf 'ANTHROPIC_API_KEY\n' > "$FM_HOME/config/launch-env-allowlist"
sp ANTHROPIC_API_KEY=dummy-not-a-key bin/fm-spawn.sh key-t1 "$P" --mode no-mistakes --yolo off
rows
echo "### same, with --allow-api-key (waiver used)"
sp ANTHROPIC_API_KEY=dummy-not-a-key bin/fm-spawn.sh key-t2 "$P" --mode no-mistakes --yolo off --allow-api-key
rows
echo "### same allowlist, key unset, --allow-api-key (waiver not used)"
sp bin/fm-spawn.sh key-t3 "$P" --mode no-mistakes --yolo off --allow-api-key
rows
rm -f "$FM_HOME/config/launch-env-allowlist"
echo "### no allowlist (main's default boundary), dummy key set, no opt-in: allowed"
sp ANTHROPIC_API_KEY=dummy-not-a-key bin/fm-spawn.sh key-t4 "$P" --mode no-mistakes --yolo off
rows
echo "credential value in log: $(grep -c dummy-not-a-key "$LOG")"

echo; echo "### S-apikey-lib: library entrypoint matrix"
api() { local label=$1; shift
  ( . bin/fm-api-key-guard-lib.sh; ID=key-lib; [ "$5" != set ] || export ANTHROPIC_API_KEY=dummy-not-a-key
    fm_api_key_guard claude "$1" "$2" "$3" "$4" tmux 2>/dev/null; echo "$label rc=$?" ); }
api "allowlist lists key, key set      " 0 '' 1 ANTHROPIC_API_KEY set
api "allowlist lists key, key unset    " 0 '' 1 ANTHROPIC_API_KEY unset
api "default boundary, key set         " 0 '' 0 '' set
api "--allow-api-key, key set (waiver) " 1 '' 0 '' set
api "--allow-api-key, key unset        " 1 '' 0 '' unset
api "--allow-api-key, allowlist omits  " 1 '' 1 OTHER set
api "worker-account pin, key set       " 0 acct 1 ANTHROPIC_API_KEY set
rows
