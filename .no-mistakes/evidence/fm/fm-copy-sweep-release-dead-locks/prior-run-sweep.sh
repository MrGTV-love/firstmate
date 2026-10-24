#!/usr/bin/env bash
# Runs the worktree's bin/fm-copy-sweep.sh against a disposable world, with Vernant's real driver interpreter.
# Usage: run-sweep.sh <world-dir> [sweep args...]
W=$1; shift
exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$W/home" FM_COPY_SWEEP_TREEHOUSE_ROOT="$W/th" PYTHONDONTWRITEBYTECODE=1 \
  FM_TEARDOWN_VERNANT_PYTHON="$HOME/.treehouse/vernant-2ee7ec/102/vernant/.venv/bin/python" \
  /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5P3NC1H8A87STSZFV2V0SFW/bin/fm-copy-sweep.sh "$@"
