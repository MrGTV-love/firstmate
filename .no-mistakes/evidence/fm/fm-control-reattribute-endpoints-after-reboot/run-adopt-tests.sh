#!/usr/bin/env bash
# Runs one adoption test function from tests/fm-control-relaunch.test.sh in the
# worktree under nice/timeout and writes a log + exit code + duration.
fn=$1
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5F7QXCMDY8X746T2JDG381G
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5F7QXCMDY8X746T2JDG381G || exit 99
start=$SECONDS
FM_TEST_ONLY=$fn nice -n 20 timeout 600 bash bin/fm-test-run.sh tests/fm-control-relaunch.test.sh > "$EV/logs/$fn.log" 2>&1
rc=$?
echo "$fn exit=$rc seconds=$((SECONDS-start))" | tee -a "$EV/logs/summary.txt"
