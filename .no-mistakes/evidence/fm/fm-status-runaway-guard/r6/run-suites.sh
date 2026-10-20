#!/usr/bin/env bash
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M587J2B7SWACYS0486QFX4P8 || exit 1
for t in "$@"; do
  s=$SECONDS
  echo "=== $t start (load: $(uptime | sed 's/.*load averages: //'))"
  nice -n 20 bash "tests/$t" > "/tmp/r6-suite-$t.out" 2>&1
  rc=$?
  tail -4 "/tmp/r6-suite-$t.out" | cut -c1-300
  echo "=== $t exit=$rc secs=$((SECONDS - s))"
done
