#!/usr/bin/env bash
# spawn.sh <case-label> <pane-path> <fm-spawn args...>: real bin/fm-spawn.sh in the marked lab home,
# fake tmux records the staged launch. Keys scrubbed; omp sees only the isolated agent dir.
W=/tmp/fmlive.9rLnPC; LAB=$(cat $W/labpath); ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4VAQD7PPWAF9AKQSKSDJJ50
label=$1 pane=$2; shift 2
: > "$W/launch-$label.log"
envargs=()
for v in $(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'); do
  case "$v" in *_API_KEY|*_API_KEY_PRIVATE|*_TOKEN|*_SECRET|*_OVERRIDE|OMP_PROFILE|PI_PROFILE|FM_GATE_REFUSE_BYPASS|FM_TEST_SEAM|TMUX|TMUX_PANE) envargs+=(-u "$v") ;; esac
done
cd "$ROOT" && env "${envargs[@]}" FM_HOME="$LAB" HOME="$W/userhome" PI_CODING_AGENT_DIR="$W/agent" OMP_SKIP_SETUP=1 \
  FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX=fake,1,0 FM_FAKE_LAUNCH_LOG="$W/launch-$label.log" \
  FM_CLAUDE_START_POLL_INTERVAL=0.02 PATH="${EXTRA_FAKE:+$EXTRA_FAKE:}$W/fake/fakebin:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
