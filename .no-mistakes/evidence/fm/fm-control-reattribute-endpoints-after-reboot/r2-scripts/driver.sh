#!/usr/bin/env bash
# Round-2 driver: runs each adoption test function and gate scenario separately,
# each under nice -n 20 and timeout 600, logging to the evidence directory.
set -u
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5E9KQ8HPT3X95GQX1D3CE8K || exit 2
E=/Users/charlesabrooker/.no-mistakes/evidence/01M5E9KQ8HPT3X95GQX1D3CE8K
L=$E/r2-logs
stream=$1; shift
for fn in "$@"; do
  case "$fn" in
    test_gate_*) script=tests/zz-nm-scratch-relaunch.test.sh; cmd=(bash "$script") ;;
    *) script=tests/fm-control-relaunch.test.sh; cmd=(bash bin/fm-test-run.sh "$script") ;;
  esac
  env FM_TEST_ONLY=$fn nice -n 20 timeout 600 "${cmd[@]}" > "$L/relaunch-$fn.log" 2>&1
  echo "$fn exit=$?" >> "$L/summary-$stream.txt"
done
echo "stream $stream done" >> "$L/summary-$stream.txt"
