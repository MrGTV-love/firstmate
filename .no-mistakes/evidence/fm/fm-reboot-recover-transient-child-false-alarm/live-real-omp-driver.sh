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

NH=$LAB/native-home
mkdir -p "$NH/.omp/agent" "$NH/.config" "$NH/.local/share/omp" "$NH/.local/state/omp" "$NH/.cache/omp"
printf 'composer:\n  shape: box\n' > "$NH/.omp/agent/config.yml"
cat > "$LAB/launch.sh" <<EOS
#!/usr/bin/env bash
exec env HOME=$NH XDG_CONFIG_HOME=$NH/.config XDG_DATA_HOME=$NH/.local/share XDG_STATE_HOME=$NH/.local/state XDG_CACHE_HOME=$NH/.cache PI_CONFIG_DIR=.omp PI_CODING_AGENT_DIR=$NH/.omp/agent OMP_PROFILE=default PI_PROFILE=default OMP_SKIP_SETUP=1 OPENAI_API_KEY=fm-non-submitting-fixture FM_SPAWN_GEN=$GEN $(command -v omp)
EOS
chmod +x "$LAB/launch.sh"
run pane send-text "$PANE" "bash $LAB/launch.sh"
run pane send-keys "$PANE" Enter
export PATH="$LAB/fakebin:$PATH"
AGENT_PID=
for _ in $(seq 1 60); do
  AGENT_PID=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS "$DRV/probe.sh" "$ROOT" "$META" 2>/dev/null) && break
  sleep 0.5
done
echo "real omp pid=$AGENT_PID"
run pane process-info --pane "$PANE" | jq -c '.result.process_info | {group:.foreground_process_group_id, procs:[.foreground_processes[]|{pid,name,argv0}]}'
sleep 3
printf 'session\n' > "$LAB/session.jsonl"
jq -nc --arg gen "$GEN" --argjson pid "$AGENT_PID" --arg f "$LAB/session.jsonl" \
  '{version:1,spawn_gen:$gen,pid:$pid,task_session_file:$f,current_session_file:$f}' > "$LAB/state/$ID.omp-session.json"
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
echo "=== real omp, pinned, healthy: sweep must stay silent"
sweep "base(c6bb05bf)" "$SCR"
sweep "target(b7f0d478)" "$ROOT"
kill -0 "$AGENT_PID" && echo "real omp pid $AGENT_PID still alive after sweeps"
run pane send-keys "$PANE" ctrl+c; sleep 1; run pane send-keys "$PANE" ctrl+c; sleep 1
