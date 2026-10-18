#!/usr/bin/env bash
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M56FRCDWDJ3656WKSNB7AN30 || exit 1
echo "HEAD=$(git rev-parse HEAD)"
for t in fm-typesafe-health fm-project-capacity fm-spawn-worktree-settle fm-jev-guard; do
  echo "== $t: $(date -u +%FT%TZ) load: $(uptime | sed 's/.*load averages*: //')"
  bin/fm-test-run.sh tests/$t.test.sh 2>&1 | grep -v '^ledger'; echo "$t exit=${PIPESTATUS[0]}"
done
echo ALL_DONE
