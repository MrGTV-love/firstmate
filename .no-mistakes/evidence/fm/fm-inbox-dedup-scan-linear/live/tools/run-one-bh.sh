#!/bin/bash
# run the HEAD test file's named case against the BASE lib (red-on-base control)
t=$1; EVD=$2; budget=${3:-}
out=$EVD/basecode-$t${budget:+-budget$budget}.log
start=$(date +%s)
if [ -n "$budget" ]; then export FM_SEND_REMOTE_BUDGET=$budget; fi
bash /tmp/fmlive/one-basehead-$t.sh > "$out" 2>&1
echo "RESULT side=base-code-with-head-test test=$t budget=${budget:-default} rc=$? wall=$(( $(date +%s) - start ))s" >> "$out"
