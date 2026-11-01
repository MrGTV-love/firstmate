#!/usr/bin/env bash
# run.sh <scenario-file>: lab env + helpers, then the scenario.
export WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M69T9DQA5WG038MFEC5MDJ8F
export FM_HOME=/Users/charlesabrooker/tmp/fm-lab.sbAHl7 TMUX_TMPDIR=/tmp/fml.Y3Vt0f
SCR=/Users/charlesabrooker/tmp/fm-lab.sbAHl7.scratch; mkdir -p "$SCR"
cd "$WT" || exit 1
. /tmp/claude-bundle-lab/lib.sh
td() { teardown "$@" 2>&1 | grep -v -e '^●' -e 'watcher still down' -e '^fm-gate-refuse'; echo "[exit ${PIPESTATUS[0]}]"; }
present() { [ -e "$1" ] && echo "present: $1" || echo "ABSENT: $1"; }
. "$1"
