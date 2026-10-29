#!/usr/bin/env bash
# usage: drive.sh <repo-copy> <fm-test-run.test.sh to take checks from> <test_fn>...
# Loads tests/lib.sh from the copy, then the exact partition helpers and the named
# test functions, verbatim, from the given fm-test-run.test.sh, and runs them with
# ROOT pointed at the copy.
set -u
copy=$1 src=$2; shift 2
. "$copy/tests/lib.sh"
ROOT=$copy
want="partition_registered partition_called partition_defined partition_called_elsewhere partition_problems assert_partition_exact $*"
for fn in $want; do
  body=$(awk -v fn="$fn" '$0 ~ "^" fn "\\(\\) *\\{" {on=1} on {print} on && /^\}/ {exit}' "$src")
  [ -n "$body" ] && eval "$body"
done
rc=0
for t in "$@"; do ( "$t" ) || rc=1; done
exit $rc
