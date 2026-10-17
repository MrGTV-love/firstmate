#!/usr/bin/env bash
# Drives the real shared run_cells_in_parallel helper: a failing cell must fail the case.
# usage: run-cells-adversarial.sh <worktree> <mode: allgood|onebad>
set -u
WT=$1; MODE=$2
. "$WT/tests/fm-captain-hold-lifecycle-helpers.sh"
good_cell() { sleep 0.2; echo "cell $1 fine"; }
bad_cell() { echo "cell $1 saw the regression"; fail "synthetic cell failure $1"; }
if [ "$MODE" = allgood ]; then
  run_cells_in_parallel "adversarial matrix" "good_cell a" "good_cell b" "good_cell c"
else
  run_cells_in_parallel "adversarial matrix" "good_cell a" "bad_cell b" "good_cell c"
fi
pass "adversarial matrix $MODE passed"
