#!/usr/bin/env bash
# Live drive 1: writer, gate refusal, role gate, metrics, detector, in a disposable lab home.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6FJ8XSS0AWB1CFHTT675C3M
cd "$WT"
unset FM_GUARD_EVENT_LOG FM_TASK_ID FM_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID PI_SESSION_ID OMP_SESSION_ID GROK_SESSION_ID FM_GATE_REFUSE_BYPASS
eval "$(bin/fm-lab-home.sh env 2>/tmp/fmtest-01M6/labenv.err)"
cat /tmp/fmtest-01M6/labenv.err | grep -i teardown
LOG=$FM_HOME/state/guard-events.jsonl
echo "== FM_HOME=$FM_HOME"
show() { echo "-- log rows:"; jq -c '{guard,rule,task,session,decision,override,actor,cleared_by}' "$LOG" 2>/dev/null | tail -n "${1:-5}"; }

echo; echo "### S-writer: stable session, rule, task"
FM_SESSION_ID=sessA bin/fm-guard-event.sh demo-guard deny --rule sub-a; echo "rc=$?"
FM_SESSION_ID=sessA bash -c 'bin/fm-guard-event.sh demo-guard deny --rule sub-a'; echo "rc=$? (other process)"
bin/fm-guard-event.sh demo-guard deny --rule sub-a; echo "rc=$? (no harness session)"
bin/fm-guard-event.sh demo-guard allow --rule sub-a --task T-1; echo "rc=$? (task)"
show 4
echo "pid-like sessions in log: $(jq -r .session "$LOG" | grep -c 'pid-')"

echo; echo "### S-writer-failure: unwritable log never fails caller"
mkdir -p /tmp/fmtest-01M6/ro && chmod 500 /tmp/fmtest-01M6/ro
bin/fm-guard-event.sh demo-guard deny --log /tmp/fmtest-01M6/ro/sub/x.jsonl; echo "rc=$? (unwritable dir)"
bin/fm-guard-event.sh demo-guard deny --log /dev/null/x; echo "rc=$? (path under a file)"
bin/fm-guard-event.sh demo-guard bogus-decision; echo "rc=$? (bad decision)"
chmod 700 /tmp/fmtest-01M6/ro

echo; echo "### S-gate-deny: real fm-spawn.sh in gate context against an UNMARKED home refuses and records deny with task"
NH=$(mktemp -d /tmp/fmtest-01M6/plainhome.XXXX); mkdir -p "$NH/state" "$NH/config" "$NH/data" "$NH/projects"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$NH" bin/fm-spawn.sh gate-t1 someproj --mode no-mistakes --yolo off >/tmp/fmtest-01M6/gate.out 2>&1; echo "spawn rc=$?"
head -c 400 /tmp/fmtest-01M6/gate.out; echo
jq -c '{guard,rule,task,decision,override,actor}' "$NH/state/guard-events.jsonl"

echo; echo "### S-gate-bypass: FM_GATE_REFUSE_BYPASS=1 records a bypass row"
env -u FM_ROOT_OVERRIDE FM_HOME="$NH" FM_GATE_REFUSE_BYPASS=1 bash -c '. bin/fm-gate-refuse-lib.sh; FM_GATE_EVENT_TASK=gate-t2; fm_refuse_if_gate_agent; echo "refuse fn rc=$?"'
jq -c '{guard,rule,task,decision,override}' "$NH/state/guard-events.jsonl" | tail -1

echo; echo "### S-role: real fm-role.sh check on a firstmate clone (deny, then allow with consent)"
CL=/tmp/fmtest-01M6/fmclone; rm -rf "$CL"; git clone -q --no-checkout "$WT" "$CL" && git -C "$CL" remote set-url origin https://github.com/MrGTV-love/firstmate.git
ID=role-t1 bin/fm-role.sh check "$CL"; echo "check rc=$?"
ID=role-t1 bin/fm-role.sh check "$CL" upstream-consent github.com/MrGTV-love/firstmate; echo "check rc=$?"
ID=role-t1 bin/fm-role.sh check "$CL" upstream-consent github.com/other/repo; echo "check rc=$?"
show 3

echo "LAB=$FM_HOME" > /tmp/fmtest-01M6/lab.path
echo "NH=$NH" >> /tmp/fmtest-01M6/lab.path
