#!/usr/bin/env bash
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M56FRCDWDJ3656WKSNB7AN30 || exit 1
N=18; B=$((N*3)); pids=()
for i in $(seq 1 $B); do ( while :; do :; done ) & pids+=($!); done
trap 'kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null' EXIT
command sleep 20
echo "HEAD=$(git rev-parse HEAD) burners=$B"
for i in 1 2; do
  echo "== stressed herdr e2e run $i: $(date -u +%FT%TZ) load: $(uptime | sed 's/.*load averages*: //')"
  bin/fm-test-run.sh tests/fm-spawn-acquisition-herdr-e2e.test.sh 2>&1 | grep -v '^ledger'; echo "stressed herdr run $i exit=${PIPESTATUS[0]}"
  echo "== after load: $(uptime | sed 's/.*load averages*: //')"
done
echo ALL_DONE
