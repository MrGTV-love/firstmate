#!/usr/bin/env bash
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M56FRCDWDJ3656WKSNB7AN30 || exit 1
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M56FRCDWDJ3656WKSNB7AN30
{
echo "== tmux copy: $(date -u +%FT%TZ) load: $(uptime | sed 's/.*load averages*: //')"
bin/fm-test-run.sh tests/fm-spawn-acquisition-cleanup.test.sh; echo "tmux exit=$?"
for i in 1 2 3; do
  echo "== herdr e2e run $i: $(date -u +%FT%TZ) load: $(uptime | sed 's/.*load averages*: //')"
  bin/fm-test-run.sh tests/fm-spawn-acquisition-herdr-e2e.test.sh; echo "herdr run $i exit=$?"
  echo "== after herdr run $i load: $(uptime | sed 's/.*load averages*: //')"
done
echo ALL_DONE
} > $EV/acquisition.log 2>&1
