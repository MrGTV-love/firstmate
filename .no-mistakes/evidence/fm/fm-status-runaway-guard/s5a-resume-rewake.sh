#!/usr/bin/env bash
# Live: the real watcher stops an incident writer; the operator resumes it with
# kill -CONT; it grows the same log by more than one cap; the re-armed watcher wakes
# again and stops the same pid again. Each ordinary wake is drained and acknowledged.
# (The drain exits non-zero while it refuses the incident lane's huge unread span,
#  which is the documented refusal, so the ack reads its stderr regardless.)
set -u
WATCH="$PWD/bin/fm-watch.sh"; DRAIN="$PWD/bin/fm-wake-drain.sh"
ST="$FM_HOME/state"; F="$ST/resume.status"; OUT="$FM_HOME/data/watch5a.out"; CAP=1048576
st(){ ps -p "$1" -o state= 2>/dev/null | tr -d ' ' | cut -c1; }
sz(){ stat -f %z "$1"; }
ack(){ local e="$FM_HOME/data/drain.err" s g; "$DRAIN" >/dev/null 2>"$e"
  s=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$e")
  g=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$e")
  [ -z "$s" ] || "$DRAIN" --ack-through "$s" --recovery-generation "$g" >/dev/null 2>&1; }
arm(){ FM_POLL=2 FM_SIGNAL_GRACE=1 FM_STATUS_CAP_BYTES=$CAP FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
  FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  "$WATCH" > "$OUT" 2> "$OUT.err" & W=$!; }
waitw(){ t=0; while kill -0 $W 2>/dev/null && [ $t -lt "$1" ]; do sleep 1; t=$((t+1)); done; }
until_cap_wake(){ local n=0; while [ $n -lt 10 ]; do n=$((n+1)); arm; waitw 150
  echo "  arm #$n wake: $(head -c 120 "$OUT" | tr '\n' ' ')"
  grep -q "check: status-log-over-cap: file=$1" "$OUT" && return 0; ack; done; return 1; }
ack; ack
printf 'working [at=%s]: lane started\n' "$(date +%s)" > "$F"
( ulimit -f 65536; exec bash -c 'exec 9>>"$1"; i=0; while [ $i -lt 12000000 ]; do i=$((i+1)); printf "text\n" >&9; done' _ "$F" ) </dev/null >/dev/null 2>&1 & WR=$!
echo "== wake 1: incident writer pid=$WR"
until_cap_wake resume.status && grep "file=resume.status" "$OUT"
echo "writer state=$(st $WR); log=$(sz "$F"); marker size=$(cut -f3 "$ST"/.status-cap-alerted.*resume* 2>/dev/null)"
ack
echo "== operator resumes it: kill -CONT $WR"
kill -CONT $WR
until_cap_wake resume.status && grep "file=resume.status" "$OUT"
echo "writer state=$(st $WR) (T = stopped again); log=$(sz "$F"); marker size=$(cut -f3 "$ST"/.status-cap-alerted.*resume* 2>/dev/null)"
kill -CONT $WR 2>/dev/null; kill -9 $WR 2>/dev/null; wait $WR 2>/dev/null; ack
