#!/usr/bin/env bash
# Real bin/fm-guard-event.sh and bin/fm-send.sh in a marked lab home, from the gate worktree.
set -u
WT=$PWD; BASE=1a8fdf768
unset FM_GUARD_EVENT_LOG FM_TASK_ID FM_SESSION_ID FM_GATE_REFUSE_BYPASS CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID PI_SESSION_ID OMP_SESSION_ID GROK_SESSION_ID
ERR=$(mktemp); eval "$(bin/fm-lab-home.sh env 2>"$ERR")"
TD=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' "$ERR" | head -1); rm -f "$ERR"
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-r5.XXXXXX"); trap 'eval "$TD" >/dev/null 2>&1; rm -rf "$S"' EXIT
LOG=$FM_HOME/state/guard-events.jsonl; E=bin/fm-guard-event.sh; H=$(cd "$FM_HOME" && pwd -P)
echo "code-root rows before: $(wc -l < state/guard-events.jsonl)"
hr() { printf '\n=== %s ===\n' "$1"; }
hr "A1 rule, task and session on an attributed row"
$E merge-green-head deny --rule checks-green --task t1 --head abc --base main; jq -c 'select(.task=="t1")' "$LOG"
hr "A2 no task: two processes share one session; a harness session is kept; no pid-"
bash -c "$E g deny --rule r"; bash -c "$E g deny --rule r"; FM_SESSION_ID=h-42 $E g deny --rule r2
jq -c 'select(.guard=="g")|{rule,task,session}' "$LOG" | sed "s#$H#<home>#"
echo "distinct sessions from 2 processes: $(jq -s '[.[]|select(.guard=="g" and .rule=="r").session]|unique|length' "$LOG")"
grep -c 'pid-' "$LOG" | sed 's/^/rows with pid-: /'
hr "A3 write failure never fails the caller"
mkdir "$S/dir"; mkfifo "$S/fifo"; 
for t in "$S/dir" "$S/fifo" /nonexistent-root/x/g.jsonl; do rc=0; $E p deny --task t --log "$t" 2>/dev/null || rc=$?; echo "log=${t/#$S/<tmp>} writer rc=$rc"; done
rc=0; $E p deny --rule 2>/dev/null || rc=$?; echo "malformed args rc=$rc"
rc=0; $E p notadecision 2>/dev/null || rc=$?; echo "bad decision rc=$rc"
rc=0; PATH=/nonexistent /bin/bash $E p deny --log "$S/nojq" 2>/dev/null || rc=$?; echo "no jq on PATH rc=$rc; row written: $([ -e "$S/nojq" ] && echo yes || echo no)"
hr "A4 typo home stays absent; the refusal is the same as with telemetry pointed elsewhere and as base"
mkdir "$S/base"; git archive $BASE bin | tar -x -C "$S/base"
send() { (cd "$S" && env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE "$@" 2>&1); }
hr1=0; o1=$(send FM_HOME="$S/typo/nested" "$WT/bin/fm-send.sh" sess:win probe) || hr1=$?
echo "head default log: rc=$hr1 home exists=$([ -e "$S/typo" ] && echo yes || echo no) | ${o1/#*typo/<typo>}" | sed "s#$S#<tmp>#g"
hr2=0; o2=$(send FM_GUARD_EVENT_LOG="$S/else.jsonl" FM_HOME="$S/typo/nested" "$WT/bin/fm-send.sh" sess:win probe) || hr2=$?
echo "head explicit log: rc=$hr2 same output=$([ "$o1" = "$o2" ] && echo yes || echo no)"
br=0; o3=$(send FM_HOME="$S/typo2/nested" "$S/base/bin/fm-send.sh" sess:win probe) || br=$?
echo "base default log: rc=$br home exists=$([ -e "$S/typo2" ] && echo yes || echo no) | $(echo "$o3" | sed "s#$S#<tmp>#g" | head -1)"
hr "A5 home removed between the precheck and the append (throwaway jq shim)"
real=$(command -v jq); mkdir -p "$S/rh/state" "$S/rb"
printf '#!/usr/bin/env bash\nrm -rf -- "%s"\nexec "%s" "$@"\n' "$S/rh" "$real" >"$S/rb/jq"; chmod +x "$S/rb/jq"
rc=0; out=$(PATH="$S/rb:$PATH" FM_HOME="$S/rh" $E race allow --task r 2>&1) || rc=$?
echo "default log: rc=$rc home recreated=$([ -e "$S/rh" ] && echo yes || echo no) stderr=[${out//$S/<tmp>}]"
mkdir -p "$S/ex/state"; printf '#!/usr/bin/env bash\nrm -rf -- "%s"\nexec "%s" "$@"\n' "$S/ex" "$real" >"$S/rb/jq"
rc=0; PATH="$S/rb:$PATH" FM_GUARD_EVENT_LOG="$S/ex/state/g.jsonl" $E race allow --task r 2>/dev/null || rc=$?
echo "explicit FM_GUARD_EVENT_LOG: rc=$rc log rows=$(wc -l < "$S/ex/state/g.jsonl" | tr -d ' ') (keeps creating its directory)"
$E race allow --task r --log "$S/ex2/sub/g.jsonl"; echo "explicit --log rows=$(wc -l < "$S/ex2/sub/g.jsonl" | tr -d ' ')"
hr "B1 real fm-send from the gate worktree against an unmarked home: refused, attributed deny"
mkdir -p "$S/real/state" "$S/real/config" "$S/real/data"
rc=0; FM_HOME="$S/real" bin/fm-send.sh probe-task hello >"$S/o" 2>&1 || rc=$?; echo "rc=$rc | $(grep -m1 -i refus "$S/o" | cut -c1-120)"
jq -c '{guard,decision,rule,task,actor,override}' "$S/real/state/guard-events.jsonl"
hr "B2 marked lab home passes the gate: allow rows, no bypass"
rc=0; bin/fm-send.sh probe-task hello >"$S/o" 2>&1 || rc=$?; echo "rc=$rc (later failure expected: no such task)"; jq -c 'select(.task=="probe-task")|{guard,decision,rule,task,actor,override}' "$LOG"
hr "B3 FM_GATE_REFUSE_BYPASS=1: bypass row with override"
rc=0; FM_GATE_REFUSE_BYPASS=1 bin/fm-send.sh bp-task hello >"$S/o" 2>&1 || rc=$?; echo "rc=$rc"; jq -c 'select(.task=="bp-task")|{guard,decision,rule,task,override}' "$LOG"
hr "code-root log"
echo "code-root rows after: $(wc -l < state/guard-events.jsonl)"
