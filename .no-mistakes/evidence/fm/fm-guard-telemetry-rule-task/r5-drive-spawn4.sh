#!/usr/bin/env bash
# Real bin/fm-spawn.sh --secondmate in a marked lab home. tmux is a no-op shim, so no real agent launches; the
# shim also never reports a window, so the driver stops the spawn once the switch rows are read or after 45 s.
set -u
WT=$PWD; unset FM_GUARD_EVENT_LOG FM_TASK_ID FM_SESSION_ID FM_GATE_REFUSE_BYPASS
ERR=$(mktemp); eval "$(bin/fm-lab-home.sh env 2>"$ERR")"
TD=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' "$ERR" | head -1); rm -f "$ERR"
FB=$(mktemp -d "${TMPDIR:-/tmp}/fm-fb.XXXXXX"); trap 'rm -rf "$FB"; eval "$TD" >/dev/null 2>&1' EXIT
printf '#!/usr/bin/env bash\nexit 0\n' >"$FB/tmux"; chmod +x "$FB/tmux"
LOG=$FM_HOME/state/guard-events.jsonl
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=l@x.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=l@x.invalid
SM=$FB/smhome; git clone -q --shared --no-checkout "$WT" "$SM"; git -C "$SM" checkout -q --detach "$(git rev-parse HEAD)"; printf 'sm\n' >"$SM/.fm-secondmate-home"
mkdir -p "$SM/data" "$SM/state"; printf 'charter\n' >"$SM/data/charter.md"
run() { local label=$1 want=$2; shift 2; local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  : >"$LOG"; rm -f "$FM_HOME"/state/sm.* ; local rc=running i=0 how=exited
  env -u FM_TASK_ID PATH="$FB:$PATH" TMUX= "${e[@]}" "$WT/bin/fm-spawn.sh" "$@" >"$FM_HOME/out" 2>&1 </dev/null &
  local pid=$!
  while kill -0 $pid 2>/dev/null && [ $i -lt 90 ]; do
    [ "$want" != 0 ] && [ "$(jq -s '[.[]|select(.decision=="bypass")]|length' "$LOG" 2>/dev/null)" = "$want" ] && break
    i=$((i+1)); sleep 0.5; done
  if kill -0 $pid 2>/dev/null; then how="stopped by driver after rows or 45 s"; kill $pid 2>/dev/null; fi; wait $pid 2>/dev/null; rc=$?
  echo "== $label: $how rc=$rc | $(grep -m1 -E '^error' "$FM_HOME/out" | sed "s#$FM_HOME#<lab>#g;s#$FB#<tmp>#g" | cut -c1-170)"
  jq -c 'select(.decision=="bypass")|{guard,decision,rule,task,override}' "$LOG" 2>/dev/null
  echo "   bypass rows: $(jq -s '[.[]|select(.decision=="bypass")]|length' "$LOG" 2>/dev/null); all rows: $(wc -l <"$LOG" | tr -d ' ')"
  sleep 1
}
run "secondmate SYNC=1 INHERIT=1" 2 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_SPAWN_NO_GUARD=internal -- sm "$SM" codex --secondmate
run "secondmate SYNC=internal INHERIT=internal" 0 FM_SKIP_SECONDMATE_SYNC=internal FM_SKIP_SECONDMATE_INHERIT=internal FM_SPAWN_NO_GUARD=internal -- sm "$SM" codex --secondmate
