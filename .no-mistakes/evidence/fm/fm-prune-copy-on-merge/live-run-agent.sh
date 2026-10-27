#!/usr/bin/env bash
# Live scenarios for the pane check (fm_mp_pane_agent_gone) with the REAL pane
# shape of a worker: tmux pane shell -> real `treehouse get` -> slot subshell ->
# agent. The agent is a stand-in native process named `claude` (a real Claude
# Code launch in this lab opened its session dashboard, where typing /exit could
# start a real session, so it was stopped before anything was typed). The exit
# verb's outcome is reproduced exactly: state/<id>.control-exit gen=<gen>, the
# busy record retired by the real bin/fm-busy-event.sh, the agent gone, the pane
# left open. Everything else is real: treehouse on a throwaway TREEHOUSE_ROOT,
# git origin on disk, fm-teardown, fm-merge-prune, fm-idle-reap admission.
#   A   stopped before the merge arm: pruned, no wake
#   A0  same case on the parent commit's bin/ (before the fix), then new code
#   B   relaunched agent alive with an old exit marker: not closed, copy kept
#   B2  a second `treehouse get` in the pane: not accepted
set -u
. "$(dirname "$0")/live-lab.sh"
lab_init
cat > "$LAB/bin/teardown-logged" <<X
#!/usr/bin/env bash
out=\$("$WT/bin/fm-teardown.sh" "\$@" 2>&1); rc=\$?
printf '=== teardown %s rc=%s\\n%s\\n' "\$*" "\$rc" "\$out" >> "$LAB/teardown-calls.log"
printf '%s\\n' "\$out" >&2
exit \$rc
X
chmod +x "$LAB/bin/teardown-logged"
export FM_MERGE_PRUNE_TEARDOWN_BIN="$LAB/bin/teardown-logged"
td() { awk -v id="$1" '/^=== teardown/{on=($3==id)} on' "$LAB/teardown-calls.log" 2>/dev/null | grep -vE 'new version of treehouse|treehouse update' | head -12; }
slot_line() { (cd "$PROJ" && treehouse status 2>/dev/null) | grep -F -- "$1" || echo "(slot not listed)"; }
wait_gone() { local i; for i in $(seq 1 "${2:-180}"); do [ -e "$STATE/$1.merge-prune" ] || return 0; sleep 1; done; return 1; }
tree() {  # <pid>: the process and its descendants, one line each
  local p=$1 c
  ps -o pid=,comm=,args= -p "$p" 2>/dev/null | sed 's/^/  /'
  for c in $(pgrep -P "$p" 2>/dev/null); do tree "$c"; done
}
claude_pids() { tree "$1" | awk '$0 ~ /agentbin\/claude( |$)/ {print $1}'; }
# A stand-in agent: a long-running native binary symlinked as `claude`, so the
# kernel records `claude` as the process name (tests/lib.sh fm_agent_standin).
STANDIN=$(bash -c '. "$1/tests/lib.sh" >/dev/null 2>&1; fm_agent_standin "$2"' _ "$WT" "$LAB/standin") || { echo "no stand-in agent"; exit 1; }
mkdir -p "$LAB/agentbin"; ln -sf "$STANDIN" "$LAB/agentbin/claude"
launch_agent() {  # <id>
  local i
  T send-keys -t "firstmate:fm-$1" "$LAB/agentbin/claude 900" Enter
  for i in $(seq 1 20); do sleep 0.5; [ -n "$(claude_pids "$(T display-message -p -t "firstmate:fm-$1" '#{pane_pid}')")" ] && return 0; done
  echo "agent did not start"; return 1
}
# The state the real `fm-control.sh <id> exit` leaves (bin/fm-control.sh do_exit):
# state/<id>.control-exit gen=<busy gen>, the busy record retired by the real
# bin/fm-busy-event.sh retire, the agent gone, the pane left open.
exit_like_the_verb() {  # <id>
  local gen; gen=$(cat "$STATE/$1.busy-gen")
  printf 'gen=%s\n' "$gen" > "$STATE/$1.control-exit"
  T send-keys -t "firstmate:fm-$1" C-c; sleep 1
  "$WT/bin/fm-busy-event.sh" retire "$STATE" "$1" --gen "$gen" >/dev/null 2>&1
}

echo "===== A: worker stopped (exit-verb state) BEFORE the merge arm, pane = real treehouse get + idle shell: pruned, no wake"
new_task tA 71; C=$COPY; P=$PANE
launch_agent tA || exit 1
echo "pane tree with the live agent:"; tree "$P"
exit_like_the_verb tA
echo "after exit: busy record $([ -e "$STATE/tA.busy-state" ] && echo present || echo gone); control-exit marker: $(cat "$STATE/tA.control-exit" 2>/dev/null || echo absent)"
echo "pane tree after the exit (what the prune must accept):"; tree "$P"
prune arm tA --run </dev/null >/dev/null 2>&1
wait_gone tA || echo "A: record still present after 180s"
show tA
echo "real teardown said:"; td tA
echo "slot after: $(slot_line "$C")"

echo "===== A0 (before/after): the same case A driven with bin/ of the parent commit cce119f49 (before the treehouse-get fix)"
mkdir -p "$LAB/old"; git -C "$WT" archive cce119f49 bin | tar -x -C "$LAB/old"
new_task tA0 70; C=$COPY; P=$PANE
launch_agent tA0 || exit 1
exit_like_the_verb tA0
echo "pane tree:"; tree "$P"
env -u FM_MERGE_PRUNE_TEARDOWN_BIN "$LAB/old/bin/fm-merge-prune.sh" arm tA0 >/dev/null 2>&1
env -u FM_MERGE_PRUNE_TEARDOWN_BIN "$LAB/old/bin/fm-merge-prune.sh" run tA0 --now </dev/null >/dev/null 2>&1
echo "OLD code result:"; show tA0; echo "slot: $(slot_line "$C")"
sed -i.bak 's/^next_at=.*/next_at=0/' "$STATE/tA0.merge-prune"
prune run tA0 </dev/null >/dev/null 2>&1
echo "NEW code, same copy, next attempt:"; show tA0; echo "slot: $(slot_line "$C")"

echo "===== B: worker relaunched after an earlier exit (old marker present, busy record gone, agent alive): not closed, copy kept"
new_task tB 72; C=$COPY; P=$PANE
launch_agent tB || exit 1
exit_like_the_verb tB
launch_agent tB || exit 1
echo "relaunched; busy record $([ -e "$STATE/tB.busy-state" ] && echo present || echo gone); marker: $(cat "$STATE/tB.control-exit" 2>/dev/null || echo absent)"
echo "pane tree with the relaunched agent:"; tree "$P"
BEFORE=$(claude_pids "$P" | tr '\n' ' ')
prune arm tB >/dev/null 2>&1
prune run tB --now </dev/null >/dev/null 2>&1
show tB
echo "teardown calls for tB: $(grep -c '^=== teardown tB' "$LAB/teardown-calls.log" 2>/dev/null)"; td tB
AFTER=$(claude_pids "$P" | tr '\n' ' ')
echo "agent pids before prune: $BEFORE after: $AFTER"
echo "copy exists: $([ -d "$C" ] && echo yes || echo no); slot: $(slot_line "$C")"

echo "===== B2: a second treehouse get in the pane (not the one launcher) after an exit: not accepted, copy kept"
new_task tB2 74; C=$COPY; P=$PANE
launch_agent tB2 || exit 1
exit_like_the_verb tB2
T send-keys -t firstmate:fm-tB2 'treehouse get' Enter; sleep 4
echo "pane tree:"; tree "$P"
prune arm tB2 >/dev/null 2>&1
prune run tB2 --now </dev/null >/dev/null 2>&1
show tB2; echo "slot: $(slot_line "$C")"

echo "===== forbidden flags anywhere in lab logs? (none expected)"
grep -rhoE -- '--include-unlanded|--include-in-use|--force' "$LAB/state" "$LAB/data" "$LAB/teardown-calls.log" 2>/dev/null | sort -u || true
echo "(end)"
