#!/bin/bash
set -u
cd "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49BAACZ1ZHY95W7KK1JRVBK"
/bin/bash bin/fm-control.sh jev-live-probe relaunch --harness omp --model openai-codex/gpt-6.1-sol --effort low --note 'Continue the same read-only fixture review. Read current generated optional skill advice with ordinary tools, keep the original intent, and refresh the report. Do not modify fixture source or invoke any pipeline.' 2>&1 | tee "/Users/charlesabrooker/.no-mistakes/evidence/01M49BAACZ1ZHY95W7KK1JRVBK/worker-relaunch-cli.txt"
rc=${PIPESTATUS[0]}
printf '%s\n' "$rc" > "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49BAACZ1ZHY95W7KK1JRVBK/.worker-live/relaunch.exit"
exit "$rc"
