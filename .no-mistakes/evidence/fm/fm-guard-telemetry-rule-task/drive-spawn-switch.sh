#!/usr/bin/env bash
# Live: real fm-spawn.sh in a marked lab home; the project does not exist, so no
# worker can launch. Shows the FM_SPAWN_NO_GUARD escape record.
set -u
EV=$1
unset FM_GUARD_EVENT_LOG FM_GATE_REFUSE_BYPASS FM_TASK_ID FM_SPAWN_NO_GUARD
eval "$(bin/fm-lab-home.sh env 2>"$EV/.lab-stderr")"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' "$EV/.lab-stderr" | head -1); rm -f "$EV/.lab-stderr"
LOG="$FM_HOME/state/guard-events.jsonl"
for v in 1 internal; do
  FM_SPAWN_NO_GUARD=$v bin/fm-spawn.sh "lab-sp-$v" "$FM_HOME/projects/no-such-project" --mode local-only --yolo off >"$FM_HOME/out" 2>&1; rc=$?
  echo "FM_SPAWN_NO_GUARD=$v: spawn rc=$rc ($(grep -m1 -i 'error' "$FM_HOME/out" | cut -c1-140))"
  echo "  rows: $(jq -sc --arg t "lab-sp-$v" '[.[]|select(.task==$t)|{guard,rule,decision,override}]' "$LOG" 2>/dev/null || echo '[]')"
done
echo "tmux sessions on lab socket: $(tmux -L fm-lab ls 2>/dev/null | wc -l | tr -d ' ')"
tmux -L fm-lab kill-server 2>/dev/null
eval "$TEARDOWN" && echo "lab removed: $([ -e "$FM_HOME" ] && echo NO || echo yes)"
