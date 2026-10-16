#!/usr/bin/env bash
set -u
ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M528N075E7RBQQG8Y5X6XRSB
SCR=$(cat /tmp/fm-base-proof-path.txt)
DRV=$(cat /tmp/fm-race-driver-path.txt)
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M528N075E7RBQQG8Y5X6XRSB
N=${N:-60}
HELPER=$ROOT/bin/fm-herdr-lab.sh
REAL_PATH=$PATH
SESSION=$("$HELPER" name race)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
OWNED=0
cleanup() {
  PATH="$REAL_PATH" "$HELPER" teardown "$SESSION" && echo "teardown ok: $SESSION" || echo "TEARDOWN FAILED: $SESSION"
  rm -rf "$LAB"
}
trap cleanup EXIT
echo "session=$SESSION lab=$LAB"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" || exit 1
"$HELPER" prepare "$SESSION" || exit 1
OWNED=1
"$HELPER" provision "$SESSION" || exit 1
run() { PATH="$REAL_PATH" "$HELPER" run "$SESSION" "$@"; }
mkdir -p "$LAB/fakebin" "$LAB/wt" "$LAB/bin"
ln -s "$(python3 -c 'import sys;print(sys.executable)')" "$LAB/bin/omp"
export FM_LAB_REAL_PATH="$PATH" FM_LAB_HELPER="$HELPER" FM_LAB_SESSION="$SESSION"
cat > "$LAB/fakebin/herdr" <<'EOS'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "${2:-}" = "$FM_LAB_SESSION" ] || exit 91; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
PATH="$FM_LAB_REAL_PATH" "$FM_LAB_HELPER" run "$FM_LAB_SESSION" "${args[@]}"
EOS
chmod +x "$LAB/fakebin/herdr"
WT=$(cd "$LAB/wt" && pwd -P)
WS=$(run workspace create --cwd "$WT" --label "fm-race" | jq -r '.result.workspace.workspace_id')
PANE=$(run pane list --workspace "$WS" | jq -r '.result.panes[0].pane_id')
TAB=$(run pane get "$PANE" | jq -r '.result.pane.tab_id')
echo "ws=$WS tab=$TAB pane=$PANE"
ID=race-secondmate
GEN=race-gen-1
META=$LAB/state/$ID.meta
cat > "$META" <<EOF
window=$SESSION:$PANE
endpoint_task_id=$ID
worktree=$WT
project=$WT
home=$WT
harness=omp
kind=secondmate
mode=secondmate
spawn_gen=$GEN
launch_proof=env-v1
yolo=off
model=openai-codex/gpt-6.1-sol
effort=low
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF
# launch the stand-in agent in the pane, carrying the recorded spawn pin
run pane send-text "$PANE" "env FM_SPAWN_GEN=$GEN $LAB/bin/omp $DRV/agent.py"
run pane send-keys "$PANE" Enter
sleep 2
echo "--- process-info sample:"
run pane process-info --pane "$PANE" | jq -c '.result.process_info | {group:.foreground_process_group_id, procs:[.foreground_processes[]|{pid,name}]}'
echo "--- agent pid via target lib:"
export PATH="$LAB/fakebin:$PATH"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS "$DRV/probe.sh" "$ROOT" "$META" || echo "(probe failed once)"
echo
# omp requires extension-recorded current-session proof for managed
AGENT_PID=
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  AGENT_PID=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS "$DRV/probe.sh" "$ROOT" "$META" 2>/dev/null) && break
done
echo "agent pid=$AGENT_PID"
printf 'session\n' > "$LAB/session.jsonl"
jq -nc --arg gen "$GEN" --argjson pid "$AGENT_PID" --arg f "$LAB/session.jsonl" \
  '{version:1,spawn_gen:$gen,pid:$pid,task_session_file:$f,current_session_file:$f}' > "$LAB/state/$ID.omp-session.json"

attrib() { # <label> <root>
  local ok=0 bad=0 wrong=0 got i
  for ((i = 0; i < N; i++)); do
    if got=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS "$DRV/probe.sh" "$2" "$META" 2>/dev/null); then
      if [ "$got" = "$AGENT_PID" ]; then ok=$((ok + 1)); else wrong=$((wrong + 1)); fi
    else bad=$((bad + 1)); fi
  done
  echo "ATTRIB $1: runs=$N attributed_agent=$ok refused=$bad wrong_pid=$wrong"
}
sweep() { # <label> <root>
  local wakes=0 clean=0 other=0 out i
  for ((i = 0; i < N; i++)); do
    out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" "$2/bin/fm-reboot-recover.sh" recover 2>&1 | grep -v '^fm-gate-refuse: gate agent lifecycle permitted')
    case "$out" in
      *'live launch settings are unreadable'*) wakes=$((wakes + 1)) ;;
      '') clean=$((clean + 1)) ;;
      *) other=$((other + 1)); echo "   other output: $out" ;;
    esac
  done
  echo "SWEEP $1: runs=$N unreadable_wakes=$wakes silent=$clean other=$other"
}
echo "=== A. attribution under a continuous stream of short-lived children"
attrib "base(c6bb05bf)" "$SCR"
attrib "target(b7f0d478)" "$ROOT"
echo "=== B. full reboot-recovery sweep on the healthy lane"
sweep "base(c6bb05bf)" "$SCR"
sweep "target(b7f0d478)" "$ROOT"

echo "=== C. adversarial: a pin that does NOT match must still be reported unmanaged (never silently managed)"
sed -i.bak "s/^spawn_gen=.*/spawn_gen=some-other-gen/" "$META" && rm -f "$META.bak"
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" "$ROOT/bin/fm-reboot-recover.sh" recover 2>&1 | grep -v '^fm-gate-refuse: gate agent lifecycle permitted')
echo "target sweep output: $out"
case "$out" in *'live launch is unmanaged; no lifecycle action taken'*) echo "RESULT C: pass (unmanaged still reported)";; *) echo "RESULT C: FAIL";; esac
sed -i.bak "s/^spawn_gen=.*/spawn_gen=$GEN/" "$META" && rm -f "$META.bak"
echo "=== D. adversarial: two real agents in one foreground group, plus the child stream, must still refuse"
run pane send-keys "$PANE" ctrl+c
sleep 1
kill -0 "$AGENT_PID" 2>/dev/null && echo "WARN: first agent still alive"
run pane send-text "$PANE" "env FM_SPAWN_GEN=$GEN bash -c '$LAB/bin/omp $DRV/agent.py & $LAB/bin/omp $DRV/agent.py & wait'"
run pane send-keys "$PANE" Enter
sleep 2
echo "--- process-info sample (two agents):"
run pane process-info --pane "$PANE" | jq -c '.result.process_info | {group:.foreground_process_group_id, procs:[.foreground_processes[]|{pid,name,argv0}]}'
ok=0; bad=0
for ((i = 0; i < N; i++)); do
  if got=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS "$DRV/probe.sh" "$ROOT" "$META" 2>/dev/null); then ok=$((ok + 1)); echo "   attributed: $got"; else bad=$((bad + 1)); fi
done
echo "ATTRIB two-agents target: runs=$N attributed=$ok refused=$bad"
wakes=0
for ((i = 0; i < N; i++)); do
  out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" "$ROOT/bin/fm-reboot-recover.sh" recover 2>&1 | grep -v '^fm-gate-refuse: gate agent lifecycle permitted')
  case "$out" in *'live launch settings are unreadable; no lifecycle action taken'*) wakes=$((wakes + 1)) ;; esac
done
echo "SWEEP two-agents target: runs=$N unreadable_wakes=$wakes"
run pane send-keys "$PANE" ctrl+c
sleep 1
echo "=== liveness after: agent still alive?"
true
