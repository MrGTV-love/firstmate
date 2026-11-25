#!/bin/bash
# usage: run-case.sh <suite-file> <case>  (run from the worktree root)
# Runs one registered suite case. Each case drives the real bin/fm-teardown.sh
# in its own scratch FM_HOME (make_case) with a fake treehouse pool, fake
# closeout driver and fake process table, all under this run's own TMPDIR.
set -u
suite=$1 case=$2
export TMPDIR=${SCEN_TMPDIR:-/Users/charlesabrooker/tmp/nm-01M87E3D-test-cli}
mkdir -p "$TMPDIR"
out=/Users/charlesabrooker/.no-mistakes/evidence/01M87E3DXKY8YXG964RQ01FZ3D/cli/$case.txt
start=$(date +%s)
{
  echo "\$ TMPDIR=$TMPDIR bin/fm-proc-budget.sh --own-procs 128 -- bash $suite $case   (head $(git rev-parse --short HEAD))"
  bin/fm-proc-budget.sh --own-procs 128 -- bash "$suite" "$case" 2>&1
  echo "rc=$? elapsed=$(( $(date +%s) - start ))s"
} > "$out" 2>&1
tail -3 "$out"
