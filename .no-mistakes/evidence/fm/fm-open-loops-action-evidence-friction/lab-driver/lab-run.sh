#!/usr/bin/env bash
# One-shell lab: mint, seed, start lab tmux workers, drive, tear down.
set -u
cd "$1"; export NM_HOME=/tmp/fm-live-drv/nm-home; mkdir -p "$NM_HOME"
for k in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS; do unset "$k"; done
eval "$(bin/fm-lab-home.sh env 2>/tmp/fm-live-drv/lab-env.txt)"
echo "lab FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR"
cleanup() { tmux kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME" /tmp/fm-live-drv/trees /tmp/fm-live-drv/fake /tmp/fm-live-drv/nm-home && echo "lab torn down: $FM_HOME"; }
trap cleanup EXIT
python3 /tmp/fm-live-drv/setup.py "$FM_HOME" /tmp/fm-live-drv/fake >/dev/null
export PATH=/tmp/fm-live-drv/fake:$PATH
W=/tmp/fm-live-drv/workers/claude-standin
tmux new-session -d -s fm -n fm-repair-owner "$W 7200"
tmux new-window -d -a -t fm:fm-repair-owner -n fm-parked-job "$W 7200"
tmux new-window -d -a -t fm:fm-parked-job -n fm-green-job "$W 7200"
for t in repair-owner parked-job green-job; do
  bin/fm-busy-event.sh arm "$FM_HOME/state" "$t" >/dev/null
  bin/fm-busy-event.sh apply "$FM_HOME/state" "$t" busy --current-gen --source claude-hook --event UserPromptSubmit
done
echo "no-mistakes on PATH: $(command -v no-mistakes) NM_HOME=$NM_HOME"; bin/fm-proc-budget.sh --own-procs 256 -- python3 /tmp/fm-live-drv/drive.py "$PWD"
echo "driver exit=$?"
