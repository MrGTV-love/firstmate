#!/usr/bin/env bash
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M56FRCDWDJ3656WKSNB7AN30 || exit 1
echo "HEAD=$(git rev-parse HEAD)"
echo "== tmux copy: $(date -u +%FT%TZ) load: $(uptime | sed 's/.*load averages*: //')"
bin/fm-test-run.sh tests/fm-spawn-acquisition-cleanup.test.sh 2>&1 | grep -v '^ledger'; echo "tmux exit=${PIPESTATUS[0]}"
for i in 1 2 3; do
  echo "== herdr e2e run $i: $(date -u +%FT%TZ) load: $(uptime | sed 's/.*load averages*: //')"
  bin/fm-test-run.sh tests/fm-spawn-acquisition-herdr-e2e.test.sh 2>&1 | grep -v '^ledger'; echo "herdr run $i exit=${PIPESTATUS[0]}"
  echo "== after herdr run $i load: $(uptime | sed 's/.*load averages*: //')"
done
echo ALL_DONE
