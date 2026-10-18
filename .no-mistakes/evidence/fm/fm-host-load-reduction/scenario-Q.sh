#!/usr/bin/env bash
# Scenario Q: the cost of the longer poll - a status change in a secondmate home (default 30s poll) is still noticed, within one interval.
set -u
ROOT=$1; EV=$2
cd "$ROOT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); echo "$LAB" > "$EV/.qlab"
bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/fakebin"
printf 'sm-test\n' > "$LAB/.fm-secondmate-home"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> %s/sleeps\nexec /bin/sleep "$@"\n' "$LAB" > "$LAB/fakebin/sleep"; chmod +x "$LAB/fakebin/sleep"
unset FM_POLL FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE NO_MISTAKES_GATE
echo "### Scenario Q: status change noticed by a secondmate-home watcher with the default 30s poll"
env PATH="$LAB/fakebin:$PATH" FM_OPEN_LOOPS_BIN=/usr/bin/true FM_HOME="$LAB" FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
  FM_HOME_SUMMARY_INTERVAL=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_IDLE_REAP_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 \
  bin/fm-watch.sh > "$LAB/watch.out" 2> "$LAB/watch.err" &
W=$!
for i in $(seq 1 90); do grep -qx 30 "$LAB/sleeps" 2>/dev/null && break; sleep 0.5; done
echo "watcher reached its first 30s wait (sleeps asked: $(sort -u "$LAB/sleeps" | tr '\n' ' '))"
printf 'blocked: needs a decision\n' > "$LAB/state/task.status"
written=$(date +%s)
for i in $(seq 1 1000); do kill -0 $W 2>/dev/null || break; sleep 0.1; done
noticed=$(date +%s)
echo "watcher exited $((noticed - written))s after the write; output:"
sed 's/^/  /' "$LAB/watch.out"
kill $W 2>/dev/null; wait $W 2>/dev/null
