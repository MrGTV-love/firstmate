#!/usr/bin/env bash
# real-omp-watcher2.sh <repo> <lab>: real fm-watch.sh (poll 2 s, signal grace 20 s, cap 8 MiB) over a lab state dir,
# then the real omp running the incident's printf. No drain is run afterwards.
REPO=$1; LAB=$2; F=$LAB/state/incident.status; ST=$LAB/state
FM_HOME="$LAB" FM_STATE_OVERRIDE="$ST" FM_POLL=2 FM_SIGNAL_GRACE=20 FM_STATUS_CAP_BYTES=8388608 \
  FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
  FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  "$REPO/bin/fm-watch.sh" > "$LAB/watch.out" 2> "$LAB/watch.err" &
WPID=$!
w=0; while [ ! -e "$ST/.last-watcher-beat" ] && [ "$w" -lt 300 ]; do sleep 0.1; w=$((w+1)); done
echo "watcher pid $WPID up after ${w}x0.1s"
T0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$REPO" -e FM_HOME="$LAB" "bash $LAB/launch.sh; sleep 300"
d=0; while kill -0 "$WPID" 2>/dev/null && [ "$d" -lt 1200 ]; do sleep 0.1; d=$((d+1)); done
T1=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
echo "watcher exited $(perl -e "printf '%.1f', $T1-$T0") s after omp was launched (alive=$(kill -0 "$WPID" 2>/dev/null && echo yes || echo no))"
echo "--- the one wake the watcher printed:"; sed "s#$LAB#<lab>#g" "$LAB/watch.out" | cut -c1-600
pid=$(sed -n 's/.*stopped pid \([0-9][0-9]*\) (omp).*/\1/p' "$LAB/watch.out" | head -1)
echo "--- writer pid named in the wake: ${pid:-none}"
if [ -n "$pid" ]; then
  echo "state of that pid (T = stopped):"; ps -o pid,ppid,state,comm -p "$pid" | tail -1
  s1=$(stat -f %z "$F"); sleep 3; s2=$(stat -f %z "$F"); echo "log size now / 3 s later: $s1 / $s2 (omp hard limit 8589934592)"
fi
echo "--- queued wake rows naming the over-cap check: $(grep -c status-log-over-cap "$ST/.wake-queue" 2>/dev/null)"
echo "--- file intact, $(stat -f %z "$F") bytes"
echo "$pid" > "$LAB/writer.pid"
