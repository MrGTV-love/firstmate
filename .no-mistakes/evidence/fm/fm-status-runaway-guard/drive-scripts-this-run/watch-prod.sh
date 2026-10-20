#!/usr/bin/env bash
# watch-prod.sh <repo-root> <lab> <trial-name>
# Real fm-watch.sh at the production poll (15 s) and default signal grace; foreign omp-named writer.
set -u
R=$1; LAB=$2; T=$3
D="$LAB/wprod-$T"; mkdir -p "$D/state" "$D/bin" "$D/config" "$D/root"; ln -s "$(command -v bash)" "$D/bin/omp"
: > "$D/config/supervision-host-off"
F="$D/state/victim.status"; : > "$F"
CAP=1048576
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
env -u FM_HOME FM_ROOT_OVERRIDE="$D/root" FM_CONFIG_OVERRIDE="$D/config" FM_STATE_OVERRIDE="$D/state" FM_POLL=15 FM_STATUS_CAP_BYTES=$CAP \
  FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  "$R/bin/fm-watch.sh" > "$D/watch.out" 2> "$D/watch.err" &
WP=$!
w=0; while [ ! -e "$D/state/.last-watcher-beat" ] && [ "$w" -lt 600 ]; do sleep 0.2; w=$((w+1)); done
T0=$(now)
( ulimit -f 102400
  "$D/bin/omp" -c 'exec 9>>"$1"; printf "working: first line is the signal\n" >&9; sleep 3 9>&-; i=0; while [ "$i" -lt 400 ]; do i=$((i+1)); head -c 2000000 /dev/zero | tr "\0" "x" | fold -w 80 >&9; sleep 0.5 9>&-; done' _ "$F" &
  echo $! > "$D/pid"; wait $! 2>/dev/null ) &
while [ ! -s "$D/pid" ]; do sleep 0.1; done; W=$(cat "$D/pid")
w=0; while kill -0 "$WP" 2>/dev/null && [ "$w" -lt 3000 ]; do sleep 0.5; w=$((w+1)); done
T1=$(now)
sz=$(stat -f %z "$F")
st=$(ps -p "$W" -o state= 2>/dev/null | tr -d ' ' | cut -c1)
echo "trial=$T watcher_alive_at_end=$(kill -0 "$WP" 2>/dev/null && echo yes || echo no) secs_from_writer_start_to_watcher_exit=$(perl -e "printf '%.1f', $T1-$T0")"
echo "first_wake: $(head -c 500 "$D/watch.out" | sed "s#$LAB#<lab>#g")"
echo "cap=$CAP final_size=$sz ($(perl -e "printf '%.1f', $sz/$CAP") x cap) writer_pid=$W writer_state=${st:-gone} (T = stopped)"
kill -CONT "$W" 2>/dev/null; kill -9 "$W" 2>/dev/null; kill "$WP" 2>/dev/null; wait 2>/dev/null
echo WPROD-DONE
