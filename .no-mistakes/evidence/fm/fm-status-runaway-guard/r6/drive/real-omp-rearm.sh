#!/usr/bin/env bash
# real-omp-rearm.sh <repo> <lab>: the supervision cycle the tests copy. Drain, ack, re-arm the real watcher
# until it exits on the over-cap wake itself.
REPO=$1; LAB=$2; ST=$LAB/state; F=$ST/incident.status
export FM_CONFIG_OVERRIDE="$LAB/config"
mkdir -p "$LAB/config"; : > "$LAB/config/supervision-host-off"
for attempt in 1 2 3 4 5 6 7 8; do
  err="$ST/.cycle-drain.err"
  FM_STATE_OVERRIDE="$ST" "$REPO/bin/fm-wake-drain.sh" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] && FM_STATE_OVERRIDE="$ST" "$REPO/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$ST" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_STATUS_CAP_BYTES=8388608 \
    FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
    "$REPO/bin/fm-watch.sh" > "$LAB/watch.out.$attempt" 2> "$LAB/watch.err.$attempt" &
  WPID=$!
  d=0; while kill -0 "$WPID" 2>/dev/null && [ "$d" -lt 900 ]; do sleep 0.1; d=$((d+1)); done
  echo "attempt $attempt: watcher exited after ~$((d/10)) s; size=$(stat -f %z "$F"); wake: $(cut -c1-60 "$LAB/watch.out.$attempt")"
  if grep -q 'check: status-log-over-cap' "$LAB/watch.out.$attempt"; then echo "$attempt" > "$LAB/over-cap-attempt"; break; fi
done
