#!/usr/bin/env bash
# linger.sh <repo> <lab> <name> : real fm-watch.sh with FM_SIGNAL_GRACE=40, FM_POLL=1, cap 64 KiB; first status line is the signal, growth starts 4 s later
set -u
R=$1; LAB=$2; T=$3
D="$LAB/linger-$T"; mkdir -p "$D/state" "$D/bin" "$D/config" "$D/root"; ln -s "$(command -v bash)" "$D/bin/omp"
: > "$D/config/supervision-host-off"; F="$D/state/linger.status"; : > "$F"
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }
env -u FM_HOME FM_ROOT_OVERRIDE="$D/root" FM_CONFIG_OVERRIDE="$D/config" FM_STATE_OVERRIDE="$D/state" FM_POLL=1 FM_SIGNAL_GRACE=40 FM_STATUS_CAP_BYTES=65536 \
  FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  "$R/bin/fm-watch.sh" > "$D/watch.out" 2> "$D/watch.err" &
WP=$!
w=0; while [ ! -e "$D/state/.last-watcher-beat" ] && [ "$w" -lt 1500 ]; do sleep 0.2; w=$((w+1)); done
T0=$(now); echo "watcher loop started after $((w/5)) s"
( ulimit -f 4096
  "$D/bin/omp" -c 'exec 9>>"$1"; printf "working: the first line is the signal\n" >&9; sleep 4 9>&-; i=0; while [ "$i" -lt 40 ]; do i=$((i+1)); printf "text\n%.0s" {1..13000} >&9; sleep 1 9>&-; done' _ "$F" &
  echo $! > "$D/pid"; wait $! 2>/dev/null ) &
while [ ! -s "$D/pid" ]; do sleep 0.1; done; W=$(cat "$D/pid")
TS=""; w=0; while kill -0 "$WP" 2>/dev/null && [ "$w" -lt 1000 ]; do if [ -z "$TS" ] && [ "$(ps -p "$W" -o state= 2>/dev/null | tr -d " " | cut -c1)" = T ]; then TS=$(now); echo "writer stopped at +$(perl -e "printf '%.1f', $TS-$T0") s"; fi; sleep 0.5; w=$((w+1)); done
T1=$(now)
echo "watcher_exited=$(kill -0 "$WP" 2>/dev/null && echo NO || echo yes) after $(perl -e "printf '%.1f', $T1-$T0") s from writer start (grace was 40 s)"
echo "wake: $(head -c 400 "$D/watch.out" | sed "s#$LAB#<lab>#g")"
echo "size=$(stat -f %z "$F") writer_state=$(ps -p "$W" -o state= 2>/dev/null | tr -d ' ' | cut -c1) load=$(uptime | sed 's/.*averages: //')"
kill -CONT "$W" 2>/dev/null; kill -9 "$W" 2>/dev/null; kill "$WP" 2>/dev/null; wait 2>/dev/null; echo LINGER-DONE
