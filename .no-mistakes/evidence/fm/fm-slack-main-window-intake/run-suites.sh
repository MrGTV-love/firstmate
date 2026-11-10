#!/usr/bin/env bash
# Runs the four targeted Slack suites from the worktree root; logs go beside this script.
# Usage: run-suites.sh <worktree-root>
set -uo pipefail
cd "${1:?worktree root}" || exit 2
E=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
unset SLACK_BOT_TOKEN SLACK_SIGNING_SECRET FM_SLACK_GRADER_RUN FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
export FM_SLACK_NO_NETWORK=1
run() {
  local n=$1 s rc; shift; s=$(date +%s)
  "$@" > "$E/suite-$n.log" 2>&1; rc=$?
  echo "== $* rc=$rc secs=$(( $(date +%s) - s )) ok-lines=$(grep -c '^ok' "$E/suite-$n.log")"
  grep -n '^skip\|^not ok\|FAIL\|^fail' "$E/suite-$n.log" | cut -c1-300 | head -8
  tail -2 "$E/suite-$n.log" | cut -c1-300
}
run fm_slack_watch_test python3 tests/fm_slack_watch_test.py
run fm-slack-secret-scan bash tests/fm-slack-secret-scan.test.sh
run fm-slack-intake-unchanged bash tests/fm-slack-intake-unchanged.test.sh
run fm-slack-watch bash tests/fm-slack-watch.test.sh
echo "git status --porcelain:"; git status --porcelain; echo "(end)"
