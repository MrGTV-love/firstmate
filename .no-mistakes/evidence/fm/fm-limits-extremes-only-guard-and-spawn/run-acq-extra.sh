#!/usr/bin/env bash
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M56FRCDWDJ3656WKSNB7AN30 || exit 1
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M56FRCDWDJ3656WKSNB7AN30
{
for i in 4 5; do
  echo "== herdr e2e extra run $i: $(date -u +%FT%TZ) load: $(uptime | sed 's/.*load averages*: //')"
  bin/fm-test-run.sh tests/fm-spawn-acquisition-herdr-e2e.test.sh; echo "herdr run $i exit=$?"
done
echo ALL_DONE
} > $EV/acquisition-extra.log 2>&1
