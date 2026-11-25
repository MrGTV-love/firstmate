#!/bin/bash
# usage: SCEN_TMPDIR=<dir> batch.sh <worktree> <scenario>...   one scenario at a time per stream
W=$1; shift
R=$(cd "$(dirname "$0")" && pwd)
cd "$W" || exit 2
for sc in "$@"; do
  start=$(date +%s)
  {
    echo "\$ bin/fm-proc-budget.sh --own-procs 128 -- bash $R/cli-scenario.sh $W $sc   (head $(git rev-parse --short HEAD))"
    bin/fm-proc-budget.sh --own-procs 128 -- bash "$R/cli-scenario.sh" "$W" "$sc" 2>&1
    echo "rc=$? elapsed=$(( $(date +%s) - start ))s"
  } > "$R/scenario-$sc.txt" 2>&1
  echo "$sc: $(grep -h '^SCENARIO' "$R/scenario-$sc.txt") $(tail -1 "$R/scenario-$sc.txt")" >> "$R/progress.txt"
done
echo "stream done: $*" >> "$R/progress.txt"
