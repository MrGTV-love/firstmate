#!/usr/bin/env bash
# M1 edge: an unwritable event log never changes a real guard's decision.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6FJ8XSS0AWB1CFHTT675C3M
cd "$WT"; unset FM_TASK_ID FM_GATE_REFUSE_BYPASS ANTHROPIC_API_KEY
. /tmp/fmtest-01M6/lab.path
CL=/tmp/fmtest-01M6/fmclone
BAD=/dev/null/x
echo "### role gate (set -eu script) with FM_GUARD_EVENT_LOG=$BAD"
FM_HOME=$LAB FM_GUARD_EVENT_LOG=$BAD ID=edge bin/fm-role.sh check "$CL" >/dev/null; echo "no consent: rc=$? (expect 1)"
FM_HOME=$LAB FM_GUARD_EVENT_LOG=$BAD ID=edge bin/fm-role.sh check "$CL" upstream-consent github.com/MrGTV-love/firstmate; echo "consent: rc=$? (expect 0)"
echo "### gate refusal with an unwritable log, unmarked home"
env -u FM_ROOT_OVERRIDE FM_HOME="$NH" FM_GUARD_EVENT_LOG=$BAD bin/fm-spawn.sh edge-t1 someproj --mode no-mistakes --yolo off >/dev/null 2>&1; echo "spawn rc=$? (expect 3)"
echo "### api-key refusal with an unwritable log"
( . bin/fm-api-key-guard-lib.sh; export ANTHROPIC_API_KEY=dummy-not-a-key FM_GUARD_EVENT_LOG=$BAD; fm_api_key_guard claude 0 '' 1 ANTHROPIC_API_KEY tmux 2>/dev/null; echo "listed+set rc=$? (expect 1)" )
echo "### writer removed from PATH lookup: event script not executable copy is irrelevant; writer missing jq"
FM_HOME=$LAB PATH=/usr/bin:/bin ID=edge bash -c 'PATH=/nonexistent; /bin/bash '"$WT"'/bin/fm-guard-event.sh g deny; echo "writer without jq on PATH: rc=$?"'
echo "### main-added emitter: fm-worker-env.py --startup attributes the task from FM_TASK_ID"
L=/tmp/fmtest-01M6/startup.jsonl; rm -f "$L"
FM_GUARD_EVENT_LOG=$L FM_TASK_ID=w-start python3 bin/fm-worker-env.py --startup -- /usr/bin/true; echo "rc=$?"
jq -c '{guard,rule,task,decision}' "$L" 2>/dev/null || echo "(no event row)"
