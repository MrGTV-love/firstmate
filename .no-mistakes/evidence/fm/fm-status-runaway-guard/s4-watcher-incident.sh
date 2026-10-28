#!/usr/bin/env bash
# Live: the real watcher (bin/fm-watch.sh) in a disposable lab FM_HOME, against the
# incident-shape writer: a bash child that opened state/<task>.status once, holds it,
# and appends "text" lines with no pause. A `tail -f` reader holds the same log.
# The watcher exits on every wake; like the supervision cycle, each ordinary wake is
# drained and acknowledged (bin/fm-wake-drain.sh) and the watcher re-armed until the
# over-cap wake arrives.
set -u
WATCH="$PWD/bin/fm-watch.sh"; DRAIN="$PWD/bin/fm-wake-drain.sh"; ST="$FM_HOME/state"; F="$ST/d1-intake.status"; OUT="$FM_HOME/data/watch.out"
CAP=1048576
st(){ ps -p "$1" -o state= 2>/dev/null | tr -d ' ' | cut -c1; }
sz(){ stat -f %z "$1"; }
ack(){ local e="$FM_HOME/data/drain.err" s g; "$DRAIN" >/dev/null 2>"$e" || return 1
  s=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$e")
  g=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$e")
  [ -n "$s" ] && "$DRAIN" --ack-through "$s" --recovery-generation "$g" >/dev/null; }
arm(){ FM_POLL=2 FM_SIGNAL_GRACE=1 FM_STATUS_CAP_BYTES=$CAP FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
  FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  "$WATCH" > "$OUT" 2> "$OUT.err" & W=$!; }
printf 'working [at=%s]: lane started\n' "$(date +%s)" > "$F"
tail -f "$F" >/dev/null & READER=$!
# The incident writer, bounded: 64 MiB hard file-size limit and a 12,000,000-line count.
( ulimit -f 65536; exec bash -c 'exec 9>>"$1"; i=0; while [ $i -lt 12000000 ]; do i=$((i+1)); printf "text\n" >&9; done' _ "$F" ) & WR=$!
echo "incident writer pid=$WR (bash, holds the log open, no pause); reader tail -f pid=$READER"
n=0; got=0
while [ $n -lt 8 ]; do n=$((n+1)); arm
  t=0; while kill -0 $W 2>/dev/null && [ $t -lt 150 ]; do sleep 1; t=$((t+1)); done
  echo "arm #$n: watcher exited after ~${t}s; wake head: $(head -c 160 "$OUT" | tr '\n' ' ')"
  if grep -q 'check: status-log-over-cap' "$OUT"; then got=1; break; fi
  ack || { echo "ack failed"; break; }
done
echo "--- over-cap wake text (got=$got) ---"; cat "$OUT"
echo "writer state=$(st $WR) (T = stopped)   reader (tail -f) state=$(st $READER)"
s1=$(sz "$F"); sleep 3; s2=$(sz "$F")
echo "log size now=$s1, 3 s later=$s2 (cap $CAP); log still exists: $([ -f "$F" ] && echo yes)"
echo "wake-queue rows naming the check: $(grep -c status-log-over-cap "$ST/.wake-queue" 2>/dev/null)"
echo "alert marker: $(cat "$ST"/.status-cap-alerted.* 2>/dev/null | tr '\t' ' ')"
kill -CONT $WR 2>/dev/null; kill -9 $WR $READER 2>/dev/null; wait 2>/dev/null
