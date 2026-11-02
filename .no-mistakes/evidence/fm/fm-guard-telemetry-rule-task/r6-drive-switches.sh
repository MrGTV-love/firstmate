#!/usr/bin/env bash
# Real bin/fm-spawn.sh and the backlog/compact libs in a marked lab home. tmux is a
# no-op shim on PATH, so no agent or tmux server ever starts. Each operator switch
# must record one attributed bypass row with override; internal re-exec values and
# no switch must record none.
set -u
WT=$PWD; unset FM_GUARD_EVENT_LOG FM_TASK_ID FM_SESSION_ID FM_GATE_REFUSE_BYPASS TMUX
ERR=$(mktemp); eval "$(bin/fm-lab-home.sh env 2>"$ERR")"
TD=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' "$ERR" | head -1); rm -f "$ERR"
FB=$(mktemp -d "${TMPDIR:-/tmp}/fm-r6sw.XXXXXX")
trap 'rm -rf "$FB"; eval "$TD" >/dev/null 2>&1; rm -rf "$TMUX_TMPDIR"; echo "lab torn down: $([ -e "$FM_HOME" ] && echo no || echo yes)"' EXIT
printf '#!/usr/bin/env bash\nexit 0\n' >"$FB/tmux"; chmod +x "$FB/tmux"
LOG=$FM_HOME/state/guard-events.jsonl
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=l@x.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=l@x.invalid
SM=$FB/smhome; git clone -q --shared --no-checkout "$WT" "$SM"; git -C "$SM" checkout -q --detach "$(git rev-parse HEAD)"; printf 'sm\n' >"$SM/.fm-secondmate-home"
mkdir -p "$SM/data" "$SM/state"; printf 'charter\n' >"$SM/data/charter.md"
run() { local label=$1 want=$2; shift 2; local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  : >"$LOG"; rm -f "$FM_HOME"/state/sm.* "$FM_HOME"/state/sw*.* ; local i=0 how=exited rc
  env -u FM_TASK_ID PATH="$FB:$PATH" "${e[@]}" "$WT/bin/fm-spawn.sh" "$@" >"$FM_HOME/out" 2>&1 </dev/null &
  local pid=$!
  while kill -0 $pid 2>/dev/null && [ $i -lt 90 ]; do
    [ "$want" != 0 ] && [ "$(jq -s '[.[]|select(.decision=="bypass")]|length' "$LOG" 2>/dev/null)" = "$want" ] && break
    i=$((i+1)); sleep 0.5; done
  if kill -0 $pid 2>/dev/null; then how="stopped by driver after rows or 45 s"; kill $pid 2>/dev/null; fi; wait $pid 2>/dev/null; rc=$?
  echo "== $label: $how rc=$rc | $(grep -m1 -E '^(error|fm-)' "$FM_HOME/out" | sed "s#$FM_HOME#<lab>#g;s#$FB#<tmp>#g" | cut -c1-150)"
  jq -c 'select(.decision=="bypass")|{guard,decision,rule,task,override}' "$LOG" 2>/dev/null
  echo "   bypass rows: $(jq -s '[.[]|select(.decision=="bypass")]|length' "$LOG" 2>/dev/null) (want $want)"
  sleep 1
}
run "FM_SPAWN_NO_GUARD=1" 1 FM_SPAWN_NO_GUARD=1 -- sw1 /nonexistent-project-dir --mode no-mistakes --yolo off
run "FM_SPAWN_NO_GUARD=internal (own re-exec)" 0 FM_SPAWN_NO_GUARD=internal -- sw2 /nonexistent-project-dir --mode no-mistakes --yolo off
run "FM_COMPACT_ADVISER_DISABLE=1" 1 FM_COMPACT_ADVISER_DISABLE=1 FM_SPAWN_NO_GUARD=internal -- sw3 /nonexistent-project-dir --mode no-mistakes --yolo off
run "no switches" 0 FM_SPAWN_NO_GUARD=internal -- sw4 /nonexistent-project-dir --mode no-mistakes --yolo off
run "secondmate SYNC=1 INHERIT=1" 2 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_SPAWN_NO_GUARD=internal -- sm "$SM" codex --secondmate
run "secondmate SYNC=internal INHERIT=internal" 0 FM_SKIP_SECONDMATE_SYNC=internal FM_SKIP_SECONDMATE_INHERIT=internal FM_SPAWN_NO_GUARD=internal -- sm "$SM" codex --secondmate
echo "== FM_BACKLOG_TRANSITION_SKIP via the real manual-backend switch"
: >"$LOG"; mkdir -p "$FM_HOME/config" "$FM_HOME/data"; echo manual >"$FM_HOME/config/backlog-backend"
( . bin/fm-tasks-axi-lib.sh; . bin/fm-backlog-transition-lib.sh
  fm_backlog_transition_applies "$FM_HOME/config" "$FM_HOME/data" ship || echo "   ship applies: no ($FM_BACKLOG_TRANSITION_SKIP)"
  fm_backlog_transition_skip_event lab-bl1
  fm_backlog_transition_applies "$FM_HOME/config" "$FM_HOME/data" secondmate || echo "   secondmate applies: no ($FM_BACKLOG_TRANSITION_SKIP)"
  fm_backlog_transition_skip_event lab-bl2 )
jq -c 'select(.guard=="backlog-transition")|{guard,decision,rule,task,override}' "$LOG"
echo "== code-root log rows: $(cat "$WT/state/guard-events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
