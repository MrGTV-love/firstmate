#!/bin/bash
# run-one.sh <side> <test> <budget-or-unset> : runs one named test from a scratch copy, logs to evidence
side=$1; t=$2; EVD=$3; budget=${4:-}
out=$EVD/$side-$t${budget:+-budget$budget}.log
start=$(date +%s)
if [ -n "$budget" ]; then export FM_SEND_REMOTE_BUDGET=$budget; fi
bash /tmp/fmlive/one-$side-$t.sh > "$out" 2>&1
rc=$?
echo "RESULT side=$side test=$t budget=${budget:-default} rc=$rc wall=$(( $(date +%s) - start ))s" >> "$out"
