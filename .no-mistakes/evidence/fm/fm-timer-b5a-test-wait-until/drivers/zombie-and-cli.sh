#!/usr/bin/env bash
# Zombie peer on Darwin (no /proc, so --while-alive uses the ps stat fallback)
# and the new progress-check CLI argument surface.
set -u
WT=$1
. "$WT/tests/lib.sh"
TMP=$(fm_test_tmproot fm-zombie-cli-driver)
now() { python3 -c 'import time; print(time.time())'; }
dt() { python3 -c "print('%.1f' % ($2 - $1))"; }

echo "== I. zombie peer: child exits at once, parent never reaps it =="
python3 -c '
import os, sys, time
pid = os.fork()
if pid == 0:
    os._exit(0)
open(sys.argv[1], "w").write(str(pid))
time.sleep(30)
' "$TMP/zombie.pid" &
parent=$!
fm_test_wait_until --while-alive "$parent" -- test -s "$TMP/zombie.pid" || echo "zombie pid never written"
z=$(cat "$TMP/zombie.pid")
echo "zombie pid=$z ps stat=$(ps -o stat= -p "$z") kill-0=$(kill -0 "$z" 2>/dev/null && echo succeeds || echo fails)"
t0=$(now); rc=0
fm_test_wait_until --while-alive "$z" -- test -s "$TMP/never" 2> "$TMP/z.err" || rc=$?
t1=$(now)
echo "wait_rc=$rc waited=$(dt "$t0" "$t1")s stderr: $(cat "$TMP/z.err")"
kill "$parent"; wait "$parent" 2>/dev/null

echo "== J. progress-check CLI argument surface =="
PC=(python3 "$WT/bin/fm-duration.py" progress-check)
rc=0; "${PC[@]}" "$TMP/r1" 0 1 2>/dev/null || rc=$?; echo "PID 0 without watched files: rc=$rc"
rc=0; "${PC[@]}" "$TMP/r2" 0 1 "$TMP/x" --while-alive 2>/dev/null || rc=$?; echo "PID 0 with --while-alive: rc=$rc"
rc=0; "${PC[@]}" "$TMP/r3" -5 1 2>/dev/null || rc=$?; echo "negative PID: rc=$rc"
sleep 1000 & silent=$!
out=''
for _ in $(seq 1 10); do
  rc=0; FM_DURATION_NO_PROGRESS_SECS=1 "${PC[@]}" "$TMP/r4" "$silent" default 2>/dev/null || rc=$?
  out="$out $rc"; [ "$rc" = 124 ] && break; sleep 0.5
done
echo "inactivity 'default' with FM_DURATION_NO_PROGRESS_SECS=1 on a silent sleep, sampled every 0.5s:$out"
rc=0; "${PC[@]}" "$TMP/r5" "$silent" default 2>/dev/null || rc=$?
sleep 1.5
rc2=0; "${PC[@]}" "$TMP/r5" "$silent" default 2>/dev/null || rc2=$?
echo "inactivity 'default' (operational 15-minute policy) after 1.5s of silence: rc=$rc then rc=$rc2 (expect 0 0)"
kill "$silent"; wait "$silent" 2>/dev/null
