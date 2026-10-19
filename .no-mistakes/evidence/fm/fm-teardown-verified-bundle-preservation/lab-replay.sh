#!/usr/bin/env bash
# usage: lab-replay.sh <repo> <lab>
set -u
REPO=$1 LAB=$2
. "$REPO/bin/fm-tasks-axi-lib.sh"
. "$REPO/bin/fm-backlog-transition-lib.sh"
marker=$(fm_backlog_close_marker_path "$LAB/state" crash-bundle)
tmp="$marker.stage"
fm_backlog_close_marker_stage "$tmp" crash-bundle "$LAB/data" 1 "$LAB/state" 0 --note "preserved in bundle $LAB/bundles/kept.bundle, not landed" \
  && echo "stage: validated and accepted the bundle note" || { echo "stage: REFUSED: ${FM_BACKLOG_TRANSITION_ERROR:-}"; exit 1; }
mv "$tmp" "$marker" && echo "marker published: $marker"
echo "--- marker contents"; cat "$marker"
fm_backlog_close_marker_replay "$LAB/state" "$marker" "$LAB/data" "$LAB/config"; echo "replay rc=$?"
