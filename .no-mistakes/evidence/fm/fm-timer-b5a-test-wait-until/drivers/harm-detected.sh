#!/usr/bin/env bash
# Harm scenarios: the new helper and the progress-check CLI still catch a dead
# peer and genuinely silent work, without killing anything.
set -u
WT=$1
. "$WT/tests/lib.sh"
TMP=$(fm_test_tmproot fm-harm-driver)
now() { python3 -c 'import time; print(time.time())'; }
dt() { python3 -c "print('%.1f' % ($2 - $1))"; }

echo "== A. dead peer: the producer exits without publishing =="
bash -c 'sleep 1; exit 0' & p=$!
t0=$(now); rc=0
fm_test_wait_until --while-alive "$p" -- test -s "$TMP/never" 2> "$TMP/a.err" || rc=$?
t1=$(now)
echo "wait_rc=$rc waited=$(dt "$t0" "$t1")s stderr: $(cat "$TMP/a.err")"

echo "== B. silent live peer: alive, no outcome observable changes (--inactivity 2) =="
sleep 1000 & p=$!
t0=$(now); rc=0
fm_test_wait_until --while-alive "$p" --inactivity 2 -- test -s "$TMP/never" 2> "$TMP/b.err" || rc=$?
t1=$(now)
alive=no; kill -0 "$p" 2>/dev/null && alive=yes
echo "wait_rc=$rc waited=$(dt "$t0" "$t1")s peer_still_alive_after_wait=$alive stderr: $(cat "$TMP/b.err")"
kill "$p"; wait "$p" 2>/dev/null

echo "== C. outcome wins at peer exit: producer publishes then exits at once =="
bash -c "sleep 1; echo done > '$TMP/c.out'" & p=$!
rc=0
fm_test_wait_until --while-alive "$p" -- test -s "$TMP/c.out" 2> "$TMP/c.err" || rc=$?
echo "wait_rc=$rc stderr: $(cat "$TMP/c.err")"

echo "== D. bad arguments are refused (exit 2), not treated as a wait =="
rc=0; fm_test_wait_until 20 true 2>/dev/null || rc=$?; echo "old capped form 'fm_test_wait_until 20 true': rc=$rc"
rc=0; fm_test_wait_until -- true 2>/dev/null || rc=$?; echo "no observable '-- true': rc=$rc"
rc=0; fm_test_wait_until --while-alive $$ -- true 2>/dev/null || rc=$?; echo "own pid as peer: rc=$rc"
