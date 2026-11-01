#!/usr/bin/env bash
# Live driver: operator bypass switches on fm-spawn record a bypass event; the
# internal marker used by firstmate's own re-execs records none.
set -u
WT=${1:?worktree}
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fm-lab-env.$$)"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' /tmp/fm-lab-env.$$ | head -1); rm -f /tmp/fm-lab-env.$$
trap 'tmux -L fm-lab kill-server 2>/dev/null; eval "$TEARDOWN" >/dev/null 2>&1' EXIT
LOG=$FM_HOME/state/guard-events.jsonl
run() { # <label> <env...> -- spawn args
  local label=$1; shift
  : > "$LOG"
  local rc=0
  env -u FM_TASK_ID "$@" bin/fm-spawn.sh probe-sw /nonexistent-project-dir --mode no-mistakes --yolo off >/tmp/fm-sw.$$ 2>&1 </dev/null || rc=$?
  echo "== $label: spawn exit=$rc ($(grep -m1 -i 'error' /tmp/fm-sw.$$ | cut -c1-140))"
  jq -c 'select(.decision=="bypass") | {guard,decision,rule,task,override}' "$LOG" 2>/dev/null
  echo "   bypass rows: $(jq -s '[.[]|select(.decision=="bypass")]|length' "$LOG" 2>/dev/null)"
  rm -f /tmp/fm-sw.$$
}
run "FM_SPAWN_NO_GUARD=1 (operator)" FM_SPAWN_NO_GUARD=1
run "FM_SPAWN_NO_GUARD=internal (firstmate re-exec)" FM_SPAWN_NO_GUARD=internal
run "FM_COMPACT_ADVISER_DISABLE=1 (operator) + internal watcher skip" FM_COMPACT_ADVISER_DISABLE=1 FM_SPAWN_NO_GUARD=internal
run "no switches" FM_SPAWN_NO_GUARD=internal
