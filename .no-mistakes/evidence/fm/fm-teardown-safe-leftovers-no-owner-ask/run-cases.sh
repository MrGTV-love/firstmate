#!/bin/bash
# usage: run-cases.sh <worktree> <evidence-dir> <suite> <case>...
# Runs each named case alone through its own suite (real bin/fm-teardown.sh in a
# scratch FM_HOME the fixtures build under the suite's TMP_ROOT), under a
# per-tree process budget, and keeps each case's output.
WT=$1 EV=$2 SUITE=$3; shift 3
cd "$WT" || exit 2
for c in "$@"; do
  out="$EV/cases/$(basename "$SUITE" .test.sh)__$c.log"
  start=$(date +%s)
  FM_RETAINED_EVIDENCE="$EV/cases/retained-observations.tsv" \
    bin/fm-proc-budget.sh --own-procs 256 -- bash "$SUITE" "$c" > "$out" 2>&1
  rc=$?
  printf '%s\t%s\t%s\t%ss\n' "$rc" "$(basename "$SUITE")" "$c" "$(( $(date +%s) - start ))" | tee -a "$EV/cases/summary.tsv"
done
