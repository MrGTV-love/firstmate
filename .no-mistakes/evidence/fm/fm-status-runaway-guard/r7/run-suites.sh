#!/usr/bin/env bash
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M587J2B7SWACYS0486QFX4P8 || exit 1
E=/Users/charlesabrooker/.no-mistakes/evidence/01M587J2B7SWACYS0486QFX4P8/r7
echo "head=$(git rev-parse --short HEAD)"
for t in "$@"; do
  s=$SECONDS
  echo "=== $t start (load: $(uptime | sed 's/.*load averages: //'))"
  bash "tests/$t" > "$E/suite-$t.out" 2>&1
  rc=$?
  grep -E '^ok|^not ok|passed|PASSED|FAIL' "$E/suite-$t.out" | tail -6 | cut -c1-260
  echo "=== $t exit=$rc secs=$((SECONDS - s)) ok-lines=$(grep -c '^ok' "$E/suite-$t.out") not-ok-lines=$(grep -c '^not ok' "$E/suite-$t.out")"
done
echo ALL-SUITES-DONE
