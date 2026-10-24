#!/usr/bin/env bash
# deadline-sweep.sh <tree-root> <trials> : a live holder releases the queue lock near the drain's 1s deadline.
# Classify every real fm-wake-drain.sh run: acquired (rc0+rows), skipped (rc0 advisory), error (rc1 "could not be acquired safely").
set -u
R=$1 N=$2 LIB="$1/bin/fm-wake-lib.sh" DRAIN="$1/bin/fm-wake-drain.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-sweep.XXXXXX"); trap 'rm -rf "$W"' EXIT
acq=0 skip=0 err=0 other=0 lost=0
for t in $(seq 1 "$N"); do
  S=$W/s$t; mkdir -p $S
  FM_STATE_OVERRIDE=$S bash -c '. "$1"; fm_wake_append signal k "signal: sweep"' _ "$LIB"
  d=$(awk -v t=$t 'BEGIN{printf "%.2f", 1.00 + (t % 31) * 0.07}')   # 1.00..3.10s
  FM_STATE_OVERRIDE=$S bash -c '. "$1"; fm_lock_acquire_wait "$2/.wake-queue.lock" || exit 9; : > "$2/held"; sleep "$3"; fm_lock_release "$2/.wake-queue.lock"' _ "$LIB" "$S" "$d" >/dev/null 2>&1 & h=$!
  while [ ! -e $S/held ]; do sleep 0.01; done
  FM_STATE_OVERRIDE=$S FM_STATUS_PRESENTATION_LOCK_TIMEOUT=1 "$DRAIN" >$W/o 2>$W/e; rc=$?
  wait $h
  if [ $rc -eq 0 ] && grep -q "$(printf '\tsignal\t')" $W/o; then acq=$((acq+1))
  elif [ $rc -eq 0 ] && grep -q '^WAKE DRAIN SKIPPED: queue lock remains held by live pid' $W/o; then skip=$((skip+1))
  elif [ $rc -eq 1 ] && grep -q 'queue lock could not be acquired safely' $W/e; then err=$((err+1)); echo "error trial=$t hold=${d}s"
  else other=$((other+1)); echo "other trial=$t rc=$rc out=$(cat $W/o) err=$(cat $W/e)"; fi
  [ "$(awk -F '\t' 'NF==5' $S/.wake-queue | wc -l | tr -d ' ')" = 1 ] || { lost=$((lost+1)); echo "queue row count changed trial=$t"; }
done
echo "tree=$R trials=$N acquired=$acq skipped=$skip error=$err other=$other queue_row_changes=$lost load=\"$(uptime | sed 's/.*averages: //')\""
