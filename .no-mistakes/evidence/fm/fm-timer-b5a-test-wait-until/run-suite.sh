#!/usr/bin/env bash
# run-suite.sh <evidence-dir> <tests/file> : run one suite under the tree leash; log exit code.
E=$1 f=$2 n=$(basename "$2" .test.sh)
s=$(date +%s)
bin/fm-proc-budget.sh --own-procs 128 -- bash "$f" > "$E/suites/$n.log" 2>&1; rc=$?
printf 'bin/fm-proc-budget.sh --own-procs 128 -- bash %s -> exit %s (%ss)\n' "$f" "$rc" "$(( $(date +%s) - s ))" | tee -a "$E/suites/$n.log"
