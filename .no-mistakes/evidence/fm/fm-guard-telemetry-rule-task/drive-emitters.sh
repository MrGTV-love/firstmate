#!/usr/bin/env bash
# Live driver: fleet entrypoints emit attributed guard events (gate, send, writer).
set -u
WT=${1:?worktree}
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fm-lab-env.$$)"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' /tmp/fm-lab-env.$$ | head -1); rm -f /tmp/fm-lab-env.$$
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-emit.XXXXXX")
trap 'eval "$TEARDOWN" >/dev/null 2>&1; rm -rf "$SCR"' EXIT
LAB=$FM_HOME
show() { echo "--- $1"; jq -c '{guard,decision,rule,task,session,override,actor,cleared_by}' "$2" 2>/dev/null; }

echo "== S1 gate refusal still refuses an unmarked home from inside a gate worktree"
mkdir -p "$SCR/realish/state" "$SCR/realish/data" "$SCR/realish/config"
rc=0; FM_HOME="$SCR/realish" bin/fm-send.sh probe-task hello >"$SCR/s1.out" 2>&1 || rc=$?
echo "exit=$rc"; grep -m1 refusing "$SCR/s1.out"
show "unmarked home log" "$SCR/realish/state/guard-events.jsonl"

echo "== S2 marked lab home passes the gate; send records explicit-home allow"
rc=0; bin/fm-send.sh probe-task hello >"$SCR/s2.out" 2>&1 || rc=$?
echo "exit=$rc (later failure is expected: no such task)"; head -2 "$SCR/s2.out"
show "lab log" "$LAB/state/guard-events.jsonl"

echo "== S3 FM_GATE_REFUSE_BYPASS=1 records a bypass; missing FM_HOME records explicit-home deny"
rc=0; env -u FM_HOME FM_GATE_REFUSE_BYPASS=1 FM_GUARD_EVENT_LOG="$SCR/s3.jsonl" bin/fm-send.sh probe-task hello >"$SCR/s3.out" 2>&1 || rc=$?
echo "exit=$rc"; head -1 "$SCR/s3.out"
show "bypass log" "$SCR/s3.jsonl"

echo "== S4 an event write failure never changes the guarded outcome"
mkdir -p "$SCR/logdir"; mkfifo "$SCR/fifo"
for target in "$SCR/logdir" "$SCR/fifo" "/nonexistent-root-dir/x/guard.jsonl"; do
  rc=0; env -u FM_HOME FM_GATE_REFUSE_BYPASS=1 FM_GUARD_EVENT_LOG="$target" bin/fm-send.sh probe-task hello >"$SCR/s4.out" 2>&1 || rc=$?
  echo "log=$target send exit=$rc (expect 1, same as S3)"
  rc=0; FM_GUARD_EVENT_LOG="$target" bin/fm-guard-event.sh probe-guard deny --rule r --task t 2>/dev/null || rc=$?
  echo "  writer exit=$rc"
done
rc=0; bin/fm-guard-event.sh probe-guard deny --rule 2>/dev/null || rc=$?; echo "malformed args writer exit=$rc"

echo "== S5 session key is stable and never pid-\$\$"
L="$SCR/s5.jsonl"
env -u FM_TASK_ID -u CODEX_THREAD_ID -u PI_SESSION_ID -u OMP_SESSION_ID -u GROK_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u FM_SESSION_ID bin/fm-guard-event.sh g deny --log "$L"
env -u FM_TASK_ID -u CODEX_THREAD_ID -u PI_SESSION_ID -u OMP_SESSION_ID -u GROK_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u FM_SESSION_ID bin/fm-guard-event.sh g deny --log "$L"
env -u FM_TASK_ID FM_SESSION_ID=harness-42 bin/fm-guard-event.sh g deny --log "$L"
bin/fm-guard-event.sh g deny --task task-a --log "$L"
FM_TASK_ID=task-b bin/fm-guard-event.sh g allow --log "$L"
jq -c '{session,task,actor}' "$L"
if grep -q 'pid-' "$L"; then echo "FAIL: pid- session found"; else echo "no pid- session"; fi
