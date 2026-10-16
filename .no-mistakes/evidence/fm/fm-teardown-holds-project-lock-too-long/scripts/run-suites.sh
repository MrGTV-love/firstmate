#!/usr/bin/env bash
# Runs the focused suites that own the changed files, one after another; one log and one exit code per suite.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M50Z5BM4BGYDHKQ31BMVK6ZB
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M50Z5BM4BGYDHKQ31BMVK6ZB
cd "$WT" || exit 1
for t in fm-teardown-endpoint-safety fm-idle-session-reap fm-open-loops fm-secondmate-safety fm-teardown; do
  s=$(date +%s)
  bash "tests/$t.test.sh" > "$EV/suite-$t.log" 2>&1
  rc=$?
  echo "$t rc=$rc seconds=$(( $(date +%s) - s ))" >> "$EV/suite-results.txt"
done
echo ALL-DONE >> "$EV/suite-results.txt"
