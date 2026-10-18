#!/usr/bin/env bash
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M56FRCDWDJ3656WKSNB7AN30; R3=/Users/charlesabrooker/.no-mistakes/evidence/01M56FRCDWDJ3656WKSNB7AN30/round3
cd $W || exit 1
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-r3-lock.XXXXXX"); echo "$T" > /tmp/fm-nm-live-dir.txt
echo "HEAD=$(git rev-parse HEAD) load=$(uptime | sed 's/.*load averages*: //')"
echo "== project lock: busy holder vs idle holder (real fm-project-lock-lib.sh, 4s allowance)"
bash $R3/lock-driver.sh HEAD $W busy 2>&1
bash $R3/lock-driver.sh HEAD $W idle 2>&1
rm -rf "$T"; rm -f /tmp/fm-nm-live-dir.txt
echo "== CPU sampler, native ps"; bash $R3/cpu-sampler-check.sh $W 2>&1
echo "== CPU sampler, ps that rejects -S"; bash $R3/cpu-sampler-check.sh $W $R3/ps-no-S 2>&1
echo "== native omp live e2e (real omp, scripted providers)"; FM_JEV_GUARD_OMP_LIVE=1 bin/fm-test-run.sh tests/fm-jev-guard-omp-live-e2e.test.sh 2>&1 | grep -v '^ledger'
echo "== native claude live e2e (real claude CLI hooks)"; FM_JEV_GUARD_CLAUDE_LIVE=1 bin/fm-test-run.sh tests/fm-jev-guard-claude-live-e2e.test.sh 2>&1 | grep -v '^ledger'
echo ALL_DONE
