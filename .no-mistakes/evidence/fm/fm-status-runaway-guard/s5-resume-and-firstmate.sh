#!/usr/bin/env bash
# Live, part A: after the S4 stop, the operator resumes the writer with kill -CONT.
# It grows the same log by more than one cap; the re-armed real watcher must wake
# again and stop it again. A watcher armed while it was stopped stays quiet.
# Part B: the firstmate session (line 1 of state/.lock) holding a log open for writing
# is never stopped by the real guard scan, while a zsh writer on the same log is.
set -u
WATCH="$PWD/bin/fm-watch.sh"; DRAIN="$PWD/bin/fm-wake-drain.sh"; GUARD="$PWD/bin/fm-status-cap-guard.sh"
ST="$FM_HOME/state"; F="$ST/d1-intake.status"; OUT="$FM_HOME/data/watch5.out"; CAP=1048576
st(){ ps -p "$1" -o state= 2>/dev/null | tr -d ' ' | cut -c1; }
sz(){ stat -f %z "$1"; }
ack(){ local e="$FM_HOME/data/drain.err" s g; "$DRAIN" >/dev/null 2>"$e" || return 1
  s=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$e")
  g=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$e")
  [ -n "$s" ] && "$DRAIN" --ack-through "$s" --recovery-generation "$g" >/dev/null; }
arm(){ FM_POLL=2 FM_SIGNAL_GRACE=1 FM_STATUS_CAP_BYTES=$CAP FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
  FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 FM_OPEN_LOOPS_INTERVAL=99999999 \
  "$WATCH" > "$OUT" 2> "$OUT.err" & W=$!; }
waitw(){ t=0; while kill -0 $W 2>/dev/null && [ $t -lt "$1" ]; do sleep 1; t=$((t+1)); done; }
echo "== A0: log=$(sz "$F") is over the cap from S4; ack S4's wake, arm a watcher; no growth -> no wake"
ack || echo "ack failed"
arm; waitw 12
if kill -0 $W 2>/dev/null; then echo "watcher still armed after 12 s: no second wake for an unchanged log (good)"; kill $W; wait $W 2>/dev/null; else echo "watcher woke: $(cat "$OUT")"; fi
echo "== A1: a fresh incident writer appends to the same over-cap log (as a resumed/relaunched writer)"
( ulimit -f 65536; exec bash -c 'exec 9>>"$1"; i=0; while [ $i -lt 12000000 ]; do i=$((i+1)); printf "text\n" >&9; done' _ "$F" ) & WR=$!
n=0; while [ $n -lt 6 ]; do n=$((n+1)); arm; waitw 150
  echo "arm #$n wake head: $(head -c 140 "$OUT" | tr '\n' ' ')"
  grep -q 'check: status-log-over-cap' "$OUT" && break; ack || break; done
echo "--- wake ---"; cat "$OUT"
echo "writer pid=$WR state=$(st $WR); log=$(sz "$F"); marker: $(cat "$ST"/.status-cap-alerted.* | tr '\t' ' ')"
kill -CONT $WR; kill -9 $WR 2>/dev/null; wait $WR 2>/dev/null
ack >/dev/null 2>&1
echo "== B: firstmate session on line 1 of state/.lock holds the log for writing; a zsh writer does too"
G="$ST/fmcase.status"; head -c 1100000 /dev/zero | tr '\0' x > "$G"
bash -c 'exec 9>>"$1"; exec sleep 120' _ "$G" & FMS=$!
zsh -c 'exec 9>>"$1"; while :; do sleep 1; done' _ "$G" & ZW=$!
printf '%s\n' "$FMS" > "$ST/.lock"
sleep 1
FM_STATUS_CAP_BYTES=$CAP "$GUARD" scan | grep fmcase | cut -f4
echo "firstmate session pid=$FMS state=$(st $FMS) (must not be T); zsh writer pid=$ZW state=$(st $ZW) (T expected)"
kill -CONT $ZW; kill -9 $FMS $ZW 2>/dev/null; wait 2>/dev/null; rm -f "$ST/.lock"
