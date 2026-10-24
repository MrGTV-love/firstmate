#!/bin/bash
# Runs the real-Herdr lab suites with an inert unscoped fake 'herdr server' argv present.
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5N7HMQP9FSENDXAMYNE8050
env -u HERDR_SESSION bin/fm-proc-budget.sh -- "/Users/charlesabrooker/tmp/fm-fake-unscoped.VhQs3W/herdr" server &
FAKE=$!
sleep 1
echo "== inert unscoped fake present:"; ps -axww -o pid=,comm=,command= | grep "/Users/charlesabrooker/tmp/fm-fake-unscoped.VhQs3W/herdr server" | grep -v grep; ps -E -ww -p "$(pgrep -f "/Users/charlesabrooker/tmp/fm-fake-unscoped.VhQs3W/herdr server" | head -1)" -o command= | tr " " "\n" | grep -c HERDR_SESSION | sed "s/^/HERDR_SESSION entries in fake env: /"
for t in tests/fm-backend-herdr-smoke.test.sh tests/fm-control-herdr-smoke.test.sh tests/fm-backend-herdr-respawn-idem-e2e.test.sh; do
  echo "== $t"; start=$(date +%s)
  bin/fm-proc-budget.sh -- bash "$t"; echo "== $t rc=$? secs=$(($(date +%s)-start))"
done
pkill -P $FAKE 2>/dev/null; kill $FAKE 2>/dev/null; pkill -f "/Users/charlesabrooker/tmp/fm-fake-unscoped.VhQs3W/herdr server"
echo "== herdr servers after:"; ps -axww -o pid=,command= | grep "herdr server" | grep -v grep
