#!/usr/bin/env bash
# real-omp-watcher.sh <repo> <lab>
# The real fm-watch.sh over a lab state dir, then the real omp running the incident's printf.
REPO=$1; LAB=$2; F=$LAB/state/incident.status; ST=$LAB/state
: > "$F"
rm -f "$LAB/watch.out" "$LAB/watch.err"
FM_HOME="$LAB" FM_STATE_OVERRIDE="$ST" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_STATUS_CAP_BYTES=8388608 \
  FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
  FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  "$REPO/bin/fm-watch.sh" > "$LAB/watch.out" 2> "$LAB/watch.err" &
WPID=$!
w=0; while [ ! -e "$ST/.last-watcher-beat" ] && [ "$w" -lt 300 ]; do sleep 0.1; w=$((w+1)); done
echo "watcher pid $WPID started (beat file after ${w}x0.1s)"
T0=$SECONDS
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$REPO" -e FM_HOME="$LAB" "bash $LAB/launch.sh; sleep 300"
d=0; while kill -0 "$WPID" 2>/dev/null && [ "$d" -lt 900 ]; do sleep 0.1; d=$((d+1)); done
echo "watcher exited after ~$((d/10)) s of omp running (kill -0 alive? $(kill -0 "$WPID" 2>/dev/null && echo yes || echo no))"
echo "--- wake text printed by the watcher:"; sed "s#$LAB#<lab>#g" "$LAB/watch.out"
echo "--- watcher stderr (first lines):"; head -5 "$LAB/watch.err" | cut -c1-200
pid=$(sed -n 's/.*stopped pid \([0-9][0-9]*\) (omp).*/\1/p' "$LAB/watch.out" | head -1)
echo "--- writer pid named in wake: ${pid:-none}"
if [ -n "$pid" ]; then
  echo "state now:"; ps -o pid,ppid,state,comm -p "$pid" | tail -2
  s1=$(stat -f %z "$F"); sleep 3; s2=$(stat -f %z "$F"); echo "log size now/3 s later: $s1 / $s2 (hard limit is 8589934592)"
fi
echo "--- queued wake rows naming the over-cap check: $(grep -c status-log-over-cap "$ST/.wake-queue" 2>/dev/null)"
echo "--- file intact: $(stat -f %z "$F") bytes"
echo "$pid" > "$LAB/writer.pid"; echo "$WPID" > "$LAB/watcher.pid"
