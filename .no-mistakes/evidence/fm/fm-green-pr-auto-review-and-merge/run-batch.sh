#!/usr/bin/env bash
# usage: run-batch.sh <out-file> <case>...
out=$1; shift
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M75RA795EVK8E2RXKPYSFYD2 || exit 1
printf 'cases: %s\n' "$*" > "$out"
FM_AUTO_EVIDENCE=1 bin/fm-proc-budget.sh --own-procs 256 -- bash tests/fm-pr-merge.test.sh "$@" >> "$out" 2>&1
echo "exit=$?" >> "$out"
