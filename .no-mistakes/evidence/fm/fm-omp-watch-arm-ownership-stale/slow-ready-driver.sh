#!/usr/bin/env bash
# Live driver: real omp primary in a marked lab home on the private fm-lab tmux socket.
# Usage: stale-owner-driver.sh <source-tree> <label>
# Variant: a 1 ms readiness notice window, so every successor arm is 'slow'.
# Fires a real signal wake, then checks the successor is kept and a repair call is a no-op.
set -u
SRC=$1; LABEL=$2; E=$(cd "$(dirname "$0")" && pwd)
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6122TV4ZRDN5XE6AT06QGZR
cd "$SRC"
eval "$("$WT/bin/fm-lab-home.sh" env 2>"$E/$LABEL-labenv.txt")"
TEARDOWN=$(grep -o "$WT/bin/fm-lab-home.sh teardown [^ ]* && rm -rf [^ ]*" "$E/$LABEL-labenv.txt")
L=$FM_HOME/state/extensions/omp-primary-watch/lifecycle.log
cap() { tmux -L fm-lab capture-pane -p -S -3000 -t primary | grep -v '^\s*$'; }
spin() { tmux -L fm-lab capture-pane -p -t primary | tail -3 | grep -q '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'; }
waitidle() { local n=0 quiet=0; sleep 5; while [ $quiet -lt 4 ]; do if spin; then quiet=0; else quiet=$((quiet+1)); fi; sleep 1; n=$((n+1)); [ $n -gt 300 ] && return 1; done; return 0; }
say() { tmux -L fm-lab send-keys -t primary -l "$1"; sleep 1; tmux -L fm-lab send-keys -t primary Enter; waitidle; }
finish() {
  cap > "$E/$LABEL-primary-pane.txt"; cp "$L" "$E/$LABEL-lifecycle.log" 2>/dev/null
  tmux -L fm-lab kill-server 2>/dev/null; sleep 3
  for p in $(ps -axo pid=,command= | awk -v h="$FM_HOME" 'index($0,h){print $1}'); do kill -TERM $p 2>/dev/null; done
  eval "$TEARDOWN" && echo "lab torn down: $FM_HOME"
}
trap finish EXIT
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u CLAUDECODE \
  tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$PWD" -e FM_HOME="$FM_HOME" -e FM_OMP_HARNESS=omp -e OMP_SKIP_SETUP=1 \
  -e FM_POLL=1 -e FM_SIGNAL_GRACE=0 -e FM_HEARTBEAT=600 -e FM_OMP_ARM_READY_TIMEOUT_MS=1 \
  omp --config "$PWD/.omp/fm-session-overlay.yml" --auto-approve --model openai-codex/gpt-6-astra --thinking low
n=0; until [ -f "$FM_HOME/state/.omp-watch-extension-loaded" ]; do sleep 1; n=$((n+1)); [ $n -gt 60 ] && { echo "extension never loaded"; exit 1; }; done
sleep 8
say 'Run `bin/fm-session-start.sh` with bash now, exactly once, and reply with only OK.'
say 'Call the fm_watch_arm_omp tool exactly once now, then reply with its result text verbatim and nothing else.'
OMP=$(sed -n 1p "$FM_HOME/state/.lock")
n=0; until ARM=$(pgrep -P "$OMP" -f "$SRC/bin/fm-watch-arm.sh" | head -1) && [ -n "$ARM" ]; do sleep 1; n=$((n+1)); [ $n -gt 120 ] && break; done
sleep 5; ARM=$(pgrep -P "$OMP" -f "$SRC/bin/fm-watch-arm.sh" | head -1)
echo "omp=$OMP arm=$ARM"; [ -n "$ARM" ] || { echo "no arm child"; exit 1; }
waitidle
: > "$FM_HOME/state/slowprobe.meta"; printf 'done: slow readiness probe\n' > "$FM_HOME/state/slowprobe.status"
n=0; until cap | grep -q "slowprobe"; do sleep 1; n=$((n+1)); [ $n -gt 120 ] && break; done; waitidle
echo "== wake lines in pane:"; cap | grep -E "WATCHER WAKE: signal|still starting" | cut -c1-220 | tail -4
echo "== arm children of omp now:"; pgrep -P "$OMP" -fl fm-watch-arm.sh || echo "(none)"
echo "== cycle exits:"; cut -f1,2,6,7,8,9,14 "$FM_HOME/state/.watch-cycle-exits.log"
say 'Call the fm_watch_arm_omp tool exactly once now, then reply with its result text verbatim and nothing else.'
echo "== repair-call result in pane:"; cap | grep -E '^ ?watcher: ' | tail -1
echo "== arm children of omp after repair call:"; pgrep -P "$OMP" -fl fm-watch-arm.sh || echo "(none)"
echo "== lifecycle:"; grep -vE "generation-(create|activate)" "$L" | tail -8
