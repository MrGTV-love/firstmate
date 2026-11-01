#!/usr/bin/env bash
# Live driver: a real fm-watch.sh heartbeat in a disposable lab home publishes
# state/.guard-workarounds-next and queues no guard-workarounds wake.
set -u
WT=${1:?worktree}
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fm-lab-env.$$)"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' /tmp/fm-lab-env.$$ | head -1); rm -f /tmp/fm-lab-env.$$
trap 'tmux -L fm-lab kill-server 2>/dev/null; eval "$TEARDOWN" >/dev/null 2>&1' EXIT
ST=$FM_HOME/state
env -u NO_MISTAKES_GATE -u FM_TASK_ID FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=2 bin/fm-watch.sh >"$ST/../watch.out" 2>&1 </dev/null &
PID=$!
for _ in $(seq 1 60); do
  [ -e "$ST/.guard-workarounds-next" ] && break
  kill -0 "$PID" 2>/dev/null || { sleep 2; break; }
  sleep 1
done
sleep 2
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null
echo "watcher output (first lines):"; head -5 "$ST/../watch.out"
echo "report file: $(ls -la "$ST/.guard-workarounds-next" 2>&1)"
echo "report bytes: $(wc -c < "$ST/.guard-workarounds-next" 2>/dev/null)"
echo "temp leftovers: $(ls "$ST"/.guard-workarounds-next.* 2>/dev/null | wc -l | tr -d ' ')"
echo "presented marker: $(ls "$ST/.guard-workarounds-presented" 2>&1)"
echo "wake queue rows:"; cat "$ST/.wake-queue" 2>/dev/null || echo "(none)"
if grep -q guard-workarounds "$ST/.wake-queue" 2>/dev/null; then echo "FAIL: guard-workarounds wake queued"; else echo "no guard-workarounds wake queued"; fi
