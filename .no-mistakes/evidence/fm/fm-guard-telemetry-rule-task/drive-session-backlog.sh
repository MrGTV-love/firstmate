#!/usr/bin/env bash
# Live: (1) no task and no harness session -> one stable home:unattributed session,
# never a per-process id; (2) the real manual-backend switch records a bypass.
set -u
EV=$1
unset FM_GUARD_EVENT_LOG FM_GATE_REFUSE_BYPASS FM_TASK_ID
eval "$(bin/fm-lab-home.sh env 2>"$EV/.lab-stderr")"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' "$EV/.lab-stderr" | head -1); rm -f "$EV/.lab-stderr"
LOG="$FM_HOME/state/guard-events.jsonl"
echo "=== no task, no harness session: two separate processes ==="
for n in 1 2; do
  env -u CLAUDE_CODE_SESSION_ID -u CODEX_THREAD_ID -u PI_SESSION_ID -u OMP_SESSION_ID -u GROK_SESSION_ID -u FM_SESSION_ID \
    bash -c 'echo "  writer pid=$$"; exec bin/fm-guard-event.sh nosess-guard deny --rule r'
done
jq -c 'select(.guard=="nosess-guard") | {task,session}' "$LOG"
echo "  distinct sessions: $(jq -s '[.[]|select(.guard=="nosess-guard")|.session]|unique|length' "$LOG"); any pid-shaped session: $(jq -s '[.[]|select(.session|test("pid-"))]|length' "$LOG")"
echo "=== backlog manual backend (real switch) ==="
mkdir -p "$FM_HOME/config" "$FM_HOME/data"; echo manual >"$FM_HOME/config/backlog-backend"
( . bin/fm-tasks-axi-lib.sh; . bin/fm-backlog-transition-lib.sh
  if fm_backlog_transition_applies "$FM_HOME/config" "$FM_HOME/data" ship; then echo "  applies: yes"; else echo "  applies: no ($FM_BACKLOG_TRANSITION_SKIP)"; fi
  fm_backlog_transition_skip_event lab-bl1
  fm_backlog_transition_applies "$FM_HOME/config" "$FM_HOME/data" secondmate || echo "  secondmate: no ($FM_BACKLOG_TRANSITION_SKIP)"
  fm_backlog_transition_skip_event lab-bl2 )
echo "  rows: $(jq -sc '[.[]|select(.guard=="backlog-transition")|{task,rule,decision,override}]' "$LOG")"
rm -f "$FM_HOME/config/backlog-backend"
( . bin/fm-tasks-axi-lib.sh; . bin/fm-backlog-transition-lib.sh; fm_backlog_transition_applies "$FM_HOME/config" "$FM_HOME/data" ship >/dev/null 2>&1; fm_backlog_transition_skip_event lab-bl3 )
echo "  default backend rows for lab-bl3: $(jq -s '[.[]|select(.task=="lab-bl3")]|length' "$LOG")"
eval "$TEARDOWN" && echo "lab removed: $([ -e "$FM_HOME" ] && echo NO || echo yes)"
