#!/usr/bin/env bash
# partition-scenarios.sh <worktree> <lab> <side> <mutation>=<case>...
# For each pair: copy <lab>/<side> to a scratch dir, apply the mutation, run the
# real partition case from that copy's tests/fm-test-run.test.sh under
# bin/fm-proc-budget.sh, print the result, and delete the scratch copy.
set -u
wt=$1 lab=$2 side=$3; shift 3
ev=$(cd "$(dirname "$0")" && pwd)
for pair in "$@"; do
  m=${pair%%=*} case=${pair#*=}
  c=$lab/$side-$m; rm -rf "$c"; mkdir "$c"; (cd "$lab/$side" && tar -cf - .) | tar -xf - -C "$c"
  [ "$m" = none ] || "$ev/partition-mutate.sh" "$c" "$m"
  echo "### $side + $m -> $case"
  git diff --no-index "$lab/$side/tests" "$c/tests" | grep -E '^[+-][^+-]' | sed 's/^/    edit: /'
  "$wt/bin/fm-proc-budget.sh" -- "$ev/partition-driver.sh" "$c" "$c/tests/fm-test-run.test.sh" "$case" 2>&1
  echo "exit=$?"
  rm -rf "$c"
done
