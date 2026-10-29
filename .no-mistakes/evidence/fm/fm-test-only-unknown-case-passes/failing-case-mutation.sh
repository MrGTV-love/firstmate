#!/usr/bin/env bash
# Run a mutated (forced-failing) selected case in a throwaway tree; print the file's exit status.
# Usage: failing-case-mutation.sh <tree> <label> <orca_case>
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M639BN2X5M4ZFE83EXBJA579
dir=$1 lbl=$2 orca_case=$3
cd "$dir" || exit 1
out=$(FM_TEST_ONLY=test_lock_wait_breadcrumb "$W/bin/fm-proc-budget.sh" -- bash tests/fm-watcher-lock.test.sh 2>&1); rc=$?
echo "$lbl  FM_TEST_ONLY=test_lock_wait_breadcrumb bash tests/fm-watcher-lock.test.sh  (case mutated: 'return 5')  exit=$rc"; printf '   | %s\n' "$out"
out=$("$W/bin/fm-proc-budget.sh" -- bash tests/fm-backend-orca.test.sh "$orca_case" 2>&1); rc=$?
echo "$lbl  bash tests/fm-backend-orca.test.sh $orca_case  (case mutated: 'return 4')  exit=$rc"; printf '   | %s\n' "$out" | tail -3
