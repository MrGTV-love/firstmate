#!/usr/bin/env bash
# Serial, one invocation per named case of tests/fm-status-runaway-guard.test.sh,
# so one timing failure does not hide the cases after it.
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M587J2B7SWACYS0486QFX4P8 || exit 1
for t in "$@"; do
  s=$SECONDS
  echo "=== $t (load: $(uptime | sed 's/.*load averages: //'))"
  bash tests/fm-status-runaway-guard.test.sh "$t" 2>&1 | cut -c1-400
  echo "=== $t exit=${PIPESTATUS[0]} secs=$((SECONDS - s))"
done
