#!/usr/bin/env bash
set -eu
ROOT=$(pwd)
LAB="$ROOT/.native-stop-lab"
mkdir -p "$LAB/tmp" "$LAB/hook-home" "$LAB/helper-state"
export TMPDIR="$LAB/tmp"
. "$ROOT/tests/fixtures.sh"
CASE="$LAB/case"
HOME_DIR="$CASE/home"
PROJ_DIR="$CASE/project"
WT_DIR="$CASE/wt"
FAKEBIN_DIR=$(make_spawn_fakebin "$CASE/fake" claude)
fm_test_spawn_home "$HOME_DIR" claude
fm_git_worktree "$PROJ_DIR" "$WT_DIR" native-stop
fm_test_spawn_brief "$HOME_DIR" native-stop "Implement increment in a disposable native Stop-hook validation task"
FM_BACKEND=tmux GROK_HOME="$HOME_DIR/grok-home" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" native-stop "$PROJ_DIR" --mode no-mistakes --yolo off
mkdir -p "$HOME_DIR/data/vendor/jev-belay"
cp "$ROOT/.live-key-validation/primary/data/vendor/jev-belay/belay.mjs" "$HOME_DIR/data/vendor/jev-belay/belay.mjs"
