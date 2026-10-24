#!/usr/bin/env bash
# drain-live.sh <tree-root> : drive the real bin/fm-wake-drain.sh against a disposable state dir.
set -u
R=$1; LIB="$R/bin/fm-wake-lib.sh"; DRAIN="$R/bin/fm-wake-drain.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-drain-live.XXXXXX"); trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
seed() { mkdir -p "$1"; for i in 1 2 3; do FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_wake_append signal "k$2" "signal: payload $2"' _ "$LIB" "$i"; done; }
hold() { # hold <state> <seconds>  -> live holder pid on stdout
  FM_STATE_OVERRIDE="$1" bash -c '. "$1"; fm_lock_acquire_wait "$2/.wake-queue.lock" || exit 9; : > "$2/held"; sleep "$3"; fm_lock_release "$2/.wake-queue.lock"' _ "$LIB" "$1" "$2" >/dev/null 2>&1 &
  echo $!; while [ ! -e "$1/held" ]; do sleep 0.05; done; }
rows() { awk -F '\t' 'NF==5{c++} END{print c+0}' "$1"; }

echo "### S-live-holder: a live holder keeps the queue lock past the 1s deadline"
S=$W/a; seed $S; cp $S/.wake-queue $W/a.before; H=$(hold $S 30)
FM_STATE_OVERRIDE=$S FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 "$DRAIN" >$W/a.out 2>$W/a.err; rc=$?
echo "holder_pid=$H drain_rc=$rc"; echo "stdout: $(cat $W/a.out)"; echo "stderr: $(cat $W/a.err)"
cmp -s $W/a.before $S/.wake-queue && echo "queue unchanged: yes" || echo "queue unchanged: NO"
kill $H; wait $H 2>/dev/null

echo "### S-malformed-queue-lock: a regular file sits where the queue lock dir belongs"
S=$W/b; seed $S; : > $S/.wake-queue.lock
FM_STATE_OVERRIDE=$S FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 "$DRAIN" >$W/b.out 2>$W/b.err; rc=$?
echo "drain_rc=$rc"; echo "stdout: $(cat $W/b.out)"; echo "stderr: $(cat $W/b.err)"
[ -f $S/.wake-queue.lock ] && echo "malformed lock left in place: yes"

echo "### S-holder-releases-in-window: the holder releases inside the deadline, drain then gets the rows"
S=$W/c; seed $S; H=$(hold $S 0.4)
FM_STATE_OVERRIDE=$S FM_STATUS_PRESENTATION_LOCK_TIMEOUT=5 "$DRAIN" >$W/c.out 2>$W/c.err; rc=$?
wait $H 2>/dev/null; echo "drain_rc=$rc rows_replayed=$(rows $W/c.out)"; grep '^WAKE_ACK_REQUIRED' $W/c.err | sed 's/--recovery-generation .*/--recovery-generation <gen>/'

echo "### S-ack-stays-blocking: an acknowledgement waits for a live holder (no deadline), then consumes"
seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation \(.*\)$/\1/p' $W/c.err)
gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9]* --recovery-generation \(.*\)$/\1/p' $W/c.err)
H=$(hold $S 4); t0=$(date +%s)
FM_STATE_OVERRIDE=$S FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 "$DRAIN" --ack-through "$seq" --recovery-generation "$gen" >$W/d.out 2>$W/d.err; rc=$?
echo "ack_rc=$rc waited_secs=$(( $(date +%s) - t0 )) (holder held 4s, presentation timeout 1s)"; wait $H 2>/dev/null
[ ! -s $S/.wake-queue ] && echo "queue empty after ack: yes" || echo "queue empty after ack: NO ($(wc -l <$S/.wake-queue))"
