#!/bin/bash
set -u
cd "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49BAACZ1ZHY95W7KK1JRVBK"
/bin/bash bin/fm-spawn.sh jev-live-probe "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49BAACZ1ZHY95W7KK1JRVBK/.worker-live/home/projects/worker-probe" --scout --backend tmux --harness omp --model openai-codex/gpt-6.1-sol --effort low 2>&1 | tee "/Users/charlesabrooker/.no-mistakes/evidence/01M49BAACZ1ZHY95W7KK1JRVBK/worker-launch-cli.txt"
rc=${PIPESTATUS[0]}
printf '%s\n' "$rc" > "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M49BAACZ1ZHY95W7KK1JRVBK/.worker-live/launch.exit"
exit "$rc"
