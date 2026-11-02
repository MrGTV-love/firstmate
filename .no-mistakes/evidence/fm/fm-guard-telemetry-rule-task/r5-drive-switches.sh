#!/usr/bin/env bash
# Real bin/fm-spawn.sh and fm-teardown.sh in a marked lab home: every operator switch records one bypass row.
set -u
WT=$PWD; cd "$WT"
unset FM_GUARD_EVENT_LOG FM_TASK_ID FM_SESSION_ID FM_GATE_REFUSE_BYPASS
ERR=$(mktemp); eval "$(bin/fm-lab-home.sh env 2>"$ERR")"
TD=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' "$ERR" | head -1); rm -f "$ERR"
trap 'tmux kill-server 2>/dev/null; eval "$TD" >/dev/null 2>&1' EXIT
LOG=$FM_HOME/state/guard-events.jsonl
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=l@x.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=l@x.invalid
P=$FM_HOME/projects/demo; git init -q -b main "$P"; echo x >"$P/x"; git -C "$P" add x; git -C "$P" commit -qm init
SM=$FM_HOME/sm-copy
run() { # <label> <env...> -- <spawn args>
  local label=$1; shift; local envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  : >"$LOG"; local rc=0
  env -u FM_TASK_ID "${envs[@]}" bin/fm-spawn.sh "$@" >"$FM_HOME/out" 2>&1 </dev/null || rc=$?
  echo "== $label: spawn rc=$rc | $(grep -m1 -iE 'error|refus' "$FM_HOME/out" | sed "s#$FM_HOME#<lab>#g" | cut -c1-140)"
  jq -c 'select(.decision=="bypass")|{guard,decision,rule,task,override}' "$LOG" 2>/dev/null
  echo "   bypass rows: $(jq -s '[.[]|select(.decision=="bypass")]|length' "$LOG" 2>/dev/null)"
  tmux kill-server 2>/dev/null
}
run "FM_SPAWN_NO_GUARD=1" FM_SPAWN_NO_GUARD=1 -- sw1 /nonexistent-project-dir --mode no-mistakes --yolo off
run "FM_SPAWN_NO_GUARD=internal (own re-exec)" FM_SPAWN_NO_GUARD=internal -- sw2 /nonexistent-project-dir --mode no-mistakes --yolo off
run "FM_COMPACT_ADVISER_DISABLE=1" FM_COMPACT_ADVISER_DISABLE=1 FM_SPAWN_NO_GUARD=internal -- sw3 /nonexistent-project-dir --mode no-mistakes --yolo off
run "no switches" FM_SPAWN_NO_GUARD=internal -- sw4 /nonexistent-project-dir --mode no-mistakes --yolo off
run "FM_SKIP_SECONDMATE_SYNC=1 + INHERIT=1, secondmate" FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_SPAWN_NO_GUARD=internal -- sm1 "$SM" codex --secondmate
run "FM_SKIP_SECONDMATE_SYNC=internal + INHERIT=internal, secondmate" FM_SKIP_SECONDMATE_SYNC=internal FM_SKIP_SECONDMATE_INHERIT=internal FM_SPAWN_NO_GUARD=internal -- sm2 "$SM" codex --secondmate
echo "--- api key guard through real spawn; the value is a fake placeholder"
: >"$LOG"; rc=0
env -u FM_TASK_ID -u ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY=fake-placeholder FM_SPAWN_NO_GUARD=internal bin/fm-spawn.sh probe-key "$P" claude --mode no-mistakes --yolo off >"$FM_HOME/out" 2>&1 </dev/null || rc=$?
echo "no waiver: rc=$rc | $(grep -m1 -E 'error' "$FM_HOME/out" | sed 's/fake-placeholder/<fake>/g' | cut -c1-140)"
jq -c 'select(.guard=="claude-api-billing")|{guard,decision,rule,task,override,cleared_by}' "$LOG"
echo "tmux windows launched: $(tmux list-windows -a 2>/dev/null | wc -l | tr -d ' ')"
echo "out tail:"; tail -3 "$FM_HOME/out" | sed "s#$FM_HOME#<lab>#g" | cut -c1-160
