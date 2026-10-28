#!/usr/bin/env bash
# Live driver: real omp primary in a marked lab home on the private fm-lab tmux socket.
# Usage: stale-owner-driver.sh <source-tree> <label>
# Arms the watcher, SIGKILLs only the arm child (its watcher keeps the output pipe),
# then asks the primary for the documented repair call and records the result.
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
  -e FM_POLL=1 -e FM_SIGNAL_GRACE=0 -e FM_HEARTBEAT=600 -e FM_WATCH_ARM_RETIRE_TIMEOUT_MS=600000 \
  omp --config "$PWD/.omp/fm-session-overlay.yml" --auto-approve --model openai-codex/gpt-6-astra --thinking low
n=0; until [ -f "$FM_HOME/state/.omp-watch-extension-loaded" ]; do sleep 1; n=$((n+1)); [ $n -gt 60 ] && { echo "extension never loaded"; exit 1; }; done
sleep 8
say 'Run `bin/fm-session-start.sh` with bash now, exactly once, and reply with only OK.'
say 'Call the fm_watch_arm_omp tool exactly once now, then reply with its result text verbatim and nothing else.'
OMP=$(sed -n 1p "$FM_HOME/state/.lock")
n=0; until ARM=$(pgrep -P "$OMP" -f "$SRC/bin/fm-watch-arm.sh" | head -1) && [ -n "$ARM" ]; do sleep 1; n=$((n+1)); [ $n -gt 120 ] && break; done
sleep 5; ARM=$(pgrep -P "$OMP" -f "$SRC/bin/fm-watch-arm.sh" | head -1)
echo "omp=$OMP arm=$ARM"; [ -n "$ARM" ] || { echo "no arm child"; exit 1; }
WATCHER=$(pgrep -P "$ARM" -f fm-watch.sh | head -1); echo "watcher=$WATCHER"
lsof -p "$WATCHER" 2>/dev/null | awk '$4 ~ /^[12][uw]/'
waitidle
kill -KILL "$ARM"; sleep 4
echo "after kill: arm alive? $(kill -0 $ARM 2>/dev/null && echo yes || echo no)"
echo "arm children of omp now:"; pgrep -P "$OMP" -fl fm-watch-arm.sh || echo "(none)"
say 'A notification said the watcher cycle is missing. Call the fm_watch_arm_omp tool exactly once now, then reply with its result text verbatim and nothing else.'
echo "== repair-call result in pane:"; cap | grep -E '^ ?watcher: ' | tail -2
echo "== arm children of omp after repair:"; pgrep -P "$OMP" -fl fm-watch-arm.sh || echo "(none)"
echo "== lifecycle tail:"; tail -6 "$L"
