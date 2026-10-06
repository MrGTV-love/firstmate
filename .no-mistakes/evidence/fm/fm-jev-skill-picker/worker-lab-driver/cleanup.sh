#!/bin/bash
set -u
cd "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49BAACZ1ZHY95W7KK1JRVBK"
/bin/bash bin/fm-control.sh jev-live-probe exit 2>&1 | tee "/Users/charlesabrooker/.no-mistakes/evidence/01M49BAACZ1ZHY95W7KK1JRVBK/worker-exit-cli.txt"
exit_rc=${PIPESTATUS[0]}
/bin/bash bin/fm-teardown.sh jev-live-probe 2>&1 | tee "/Users/charlesabrooker/.no-mistakes/evidence/01M49BAACZ1ZHY95W7KK1JRVBK/worker-teardown-cli.txt"
rc=${PIPESTATUS[0]}
printf '%s %s\n' "$exit_rc" "$rc" > "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49BAACZ1ZHY95W7KK1JRVBK/.worker-live/cleanup.exit"
exit "$rc"
