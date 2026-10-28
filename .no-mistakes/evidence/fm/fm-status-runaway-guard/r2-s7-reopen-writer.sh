#!/usr/bin/env bash
# Adversarial live drive: the literal 2026-10-18 command shape, which re-opens the log on
# every append:  while :; do printf 'text\n' "$(date +%s)" >> state/<task>.status; done
# run by a bash child in a disposable lab FM_HOME (bin/fm-lab-home.sh), against the real
# watcher (bin/fm-watch.sh) with a 16 KiB cap. Bounded: ulimit -f and 20000 iterations.
# Expected: one over-cap wake that names the file, size and growth; the writer is either
# named and stopped, or reported as none found / unknown (lsof sees a held descriptor
# only); the log is never deleted or rewritten. Run from the gate worktree.
set -u
REPO=$PWD
eval "$("$REPO/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME; WPID=
cleanup() { [ -z "$WPID" ] || { kill -CONT "$WPID" 2>/dev/null; kill -9 "$WPID" 2>/dev/null; }; pkill -f "$LAB" 2>/dev/null; "$REPO/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"; echo "lab removed: $LAB"; }
trap cleanup EXIT
: > "$LAB/config/supervision-host-off"; printf "## In flight\n\n## Queued\n\n## Done\n" > "$LAB/data/backlog.md"
F="$LAB/state/d1-intake.status"; : > "$F"; CAP=16384
( ulimit -f 2048; bash -c 'i=0; while [ $i -lt 20000 ]; do i=$((i+1)); printf "text\n" "$(date +%s)" >> "$1"; done' _ "$F" & echo $! > "$LAB/writer.pid"; wait ) &
while [ ! -s "$LAB/writer.pid" ]; do sleep 0.1; done; WPID=$(cat "$LAB/writer.pid")
echo "lab FM_HOME=$LAB cap=$CAP writer pid $WPID (re-opens the log per append)"
out="$LAB/watch.out"
FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_STATUS_CAP_BYTES=$CAP FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
  FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  "$REPO/bin/fm-watch.sh" > "$out" 2> "$out.err" & wp=$!
attempt=0; t0=$SECONDS
while [ $attempt -lt 30 ]; do
  attempt=$((attempt+1)); w=0
  while kill -0 $wp 2>/dev/null && [ $w -lt 1200 ]; do sleep 0.1; w=$((w+1)); done
  echo "watcher run $attempt exited after $((SECONDS-t0)) s; log $(stat -f %z "$F") bytes: $(head -c 260 "$out" | tr '\n' ' ')"
  grep -q 'status-log-over-cap' "$out" && break
  s=$(FM_HOME="$LAB" "$REPO/bin/fm-wake-drain.sh" 2>&1 >/dev/null | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1 \2/p')
  FM_HOME="$LAB" "$REPO/bin/fm-wake-drain.sh" --ack-through "${s% *}" --recovery-generation "${s#* }" >/dev/null 2>&1
  FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_STATUS_CAP_BYTES=$CAP FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
    FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
    "$REPO/bin/fm-watch.sh" > "$out" 2> "$out.err" & wp=$!
done
echo "--- over-cap wake ---"; grep 'status-log-over-cap' "$out" || echo "RESULT: no over-cap wake"
echo "writer state: $(ps -p $WPID -o state= 2>/dev/null | tr -d ' ' || echo gone) ; log exists: $([ -f "$F" ] && echo yes) ; size $(stat -f %z "$F")"
