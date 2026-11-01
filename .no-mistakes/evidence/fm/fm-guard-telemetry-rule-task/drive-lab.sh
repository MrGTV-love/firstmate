#!/usr/bin/env bash
# Live driver: real firstmate scripts against a disposable marked lab home.
# Run from the gate worktree. Prints a transcript; never prints env values.
set -u
WT=$PWD
EVID=/Users/charlesabrooker/.no-mistakes/evidence/01M6A1M5XYTCJS89BZNWQEAKMJ
CODE_LOG="$WT/state/guard-events.jsonl"
code_before=$(wc -l <"$CODE_LOG" 2>/dev/null || echo 0)
unset FM_GUARD_EVENT_LOG FM_TASK_ID FM_SESSION_ID FM_GATE_REFUSE_BYPASS
eval "$(bin/fm-lab-home.sh env 2>"$EVID/.lab-stderr")"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' "$EVID/.lab-stderr" | head -1)
rm -f "$EVID/.lab-stderr"
LOG="$FM_HOME/state/guard-events.jsonl"
echo "lab home: $FM_HOME"
hr() { printf '\n=== %s ===\n' "$1"; }
rows() { jq -c "$1" "$LOG"; }

hr "S1 event carries rule + task; session = task"
bin/fm-guard-event.sh pr-merge-gate deny --rule red-checks --task lab-t1 --head abc123 --base main; echo "rc=$?"
rows 'select(.task=="lab-t1") | {guard,rule,task,session,decision,override,actor,head,base}'

hr "S1b no task: session is home:harness-session, stable across processes, never pid"
bash -c 'bin/fm-guard-event.sh probe-guard deny --rule r-a'
bash -c 'bin/fm-guard-event.sh probe-guard deny --rule r-a'
FM_SESSION_ID=lab-sess-9 bin/fm-guard-event.sh probe-guard deny --rule r-b
rows 'select(.guard=="probe-guard") | {rule,task,session}'
echo "distinct unattributed sessions across 2 processes: $(jq -s '[.[]|select(.guard=="probe-guard" and .rule=="r-a")|.session]|unique|length' "$LOG")"

hr "S2 adversarial: write failure never fails caller"
mkdir -p "$FM_HOME/ro"; chmod 555 "$FM_HOME/ro"
bin/fm-guard-event.sh probe-guard deny --log "$FM_HOME/ro/sub/x.jsonl"; echo "unwritable dir rc=$?"
mkfifo "$FM_HOME/fifo"; bin/fm-guard-event.sh probe-guard deny --log "$FM_HOME/fifo"; echo "fifo log rc=$? (returns without blocking)"
bin/fm-guard-event.sh probe-guard deny --repeat notanumber --elapsed-ms -5 --task; echo "malformed args rc=$?"
chmod 755 "$FM_HOME/ro"
# guarded action outcome unchanged when log is unwritable: fm-send with empty FM_HOME still refuses with rc=1
( FM_HOME='' FM_GUARD_EVENT_LOG="$FM_HOME/ro/sub/y.jsonl" bin/fm-send.sh some-task hello >/dev/null 2>&1; echo "fm-send empty-home refusal rc=$? with unwritable log" )

hr "S3 gate containment: real fm-send in this gate worktree"
# (a) against a non-lab home -> refused (deny --actor gate) ; log is the scenario's own file
NONLAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-nonlab.XXXXXX"); mkdir -p "$NONLAB/state"
FM_HOME="$NONLAB" bin/fm-send.sh nonlab-task hi >/dev/null 2>"$NONLAB/err"; echo "non-lab home fm-send rc=$?"
head -1 "$NONLAB/err"
jq -c '{guard,rule,task,decision,actor}' "$NONLAB/state/guard-events.jsonl"
rm -rf "$NONLAB"
# (b) against the marked lab home -> permitted, allow --actor gate (send itself then fails: no such task)
bin/fm-send.sh lab-task-send hi >/dev/null 2>&1; echo "lab home fm-send rc=$? (task does not exist; guard passed)"
rows 'select(.task=="lab-task-send") | {guard,rule,task,decision,actor,override}'
# (c) bypass switch records a bypass event
FM_GATE_REFUSE_BYPASS=1 bin/fm-send.sh lab-task-bypass hi >/dev/null 2>&1; echo "bypass fm-send rc=$?"
rows 'select(.task=="lab-task-bypass") | {guard,rule,task,decision,override}'

hr "S4 bypass switches: library emitters"
( . bin/fm-compact-adviser-lib.sh; fm_compact_adviser_bypass_event lab-ca )
( FM_BACKLOG_TRANSITION_BYPASS=manual-backend; . bin/fm-backlog-transition-lib.sh; FM_BACKLOG_TRANSITION_BYPASS=manual-backend fm_backlog_transition_skip_event lab-bt )
rows 'select(.task=="lab-ca" or .task=="lab-bt") | {guard,rule,task,decision,override}'

hr "S5 waiver: --allow-api-key records allow+override; plain refusal records deny"
( . bin/fm-api-key-guard-lib.sh; ID=lab-key; ANTHROPIC_API_KEY=dummy-not-a-real-key fm_api_key_guard claude 0 '' 0 '' 2>/dev/null; echo "no waiver rc=$?" )
( . bin/fm-api-key-guard-lib.sh; ID=lab-key; ANTHROPIC_API_KEY=dummy-not-a-real-key fm_api_key_guard claude 1 '' 0 '' 2>/dev/null; echo "with --allow-api-key rc=$?" )
rows 'select(.task=="lab-key") | {guard,rule,task,decision,override,cleared_by}'

hr "S6 metrics on the lab log: per rule, bypass ratio, repeat denies, deny-only, zero-events"
# two more sessions deny the same task to show repeat denies across sessions
FM_SESSION_ID=s2 bin/fm-guard-event.sh pr-merge-gate deny --rule red-checks --task lab-t1
bin/fm-guard-event.sh pr-merge-gate allow --rule red-checks --task lab-t1 --override --cleared-by allow-red
bin/fm-guard-metrics.sh --json --days 30 > "$EVID/lab-metrics.json"; echo "metrics rc=$?"
jq -c '.' "$EVID/lab-metrics.json" | head -c 400; echo
bin/fm-guard-metrics.sh --days 30 2>&1 | grep -E 'pr-merge-gate|gate-agent-containment|claude-api-billing|compact-adviser|backlog-transition|deny-only|zero|ratio|repeat' | head -30

cp "$LOG" "$EVID/lab-guard-events.jsonl"
hr "code-root log untouched"
code_after=$(wc -l <"$CODE_LOG" 2>/dev/null || echo 0)
echo "code-root rows before=$code_before after=$code_after"

hr "teardown"
eval "$TEARDOWN" && echo "lab removed: $([ -e "$FM_HOME" ] && echo NO || echo yes)"
