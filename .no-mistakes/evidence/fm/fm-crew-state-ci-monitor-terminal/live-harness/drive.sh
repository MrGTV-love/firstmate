#!/usr/bin/env bash
# drive.sh <bin-dir> <worktree> <run-id> <label> -- runs the REAL fm-crew-state.sh from <bin-dir>
set -u
LAB=$(cat /tmp/fm-ci-int-lab-path)
BIN=$1 WT=$2 RUN=$3 LABEL=$4
STATE=$LAB/state-$LABEL; rm -rf "$STATE"; mkdir -p "$STATE"
printf 'window=fm:fm-task-%s\nworktree=%s\nkind=ship\n' "$LABEL" "$WT" > "$STATE/task-$LABEL.meta"
FM_DURATION_HOME=$LAB/dur env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PATH="$LAB/shim:$PATH" SHIM_RUN_ID="$RUN" FM_STATE_OVERRIDE="$STATE" "$BIN/bin/fm-crew-state.sh" "task-$LABEL" 2>&1
