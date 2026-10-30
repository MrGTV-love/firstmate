#!/usr/bin/env bash
# Independent live driver for fm_test_wait_until (branch) vs main's capped helper.
set -u
W=$1; E=$2
. "$W/tests/lib.sh"
D=$(fm_test_tmproot drive-wait) || exit 1
now() { python3 -c 'import time; print("%.1f" % time.time())'; }
burners=()
start_burners() { for _ in $(seq 1 "$1"); do python3 -c 'while True: sum(range(10000))' & burners+=($!); done; }
stop_burners() { kill "${burners[@]}" 2>/dev/null; wait "${burners[@]}" 2>/dev/null; burners=(); }
publisher() { # journal result step_sleep steps
  python3 -c '
import pathlib, sys, time
j, r = map(pathlib.Path, sys.argv[1:3])
for s in range(int(sys.argv[4])):
    time.sleep(float(sys.argv[3])); j.write_text(str(s))
r.write_text("published")' "$@" &
}
echo "== load: $(uptime)"
echo "== S1 slow host: publisher slowed 6x (0.1s -> 0.6s per step, 12 steps) with 8 CPU burners"
start_burners 8
echo "-- main helper, ceiling sized on quiet machine (3s; quiet run takes ~1.2s)"
publisher "$D/j1" "$D/r1" 0.6 12; p=$!
( eval "$(cat "$E/main-fm_test_wait_until.sh")"; t0=$(now); fm_test_wait_until 3 test -s "$D/r1"; rc=$?; echo "main rc=$rc after $(python3 -c "print('%.1f'%($(now)-$t0))")s result=$(cat "$D/r1" 2>/dev/null || echo ABSENT)" )
wait $p
echo "-- branch helper, same work"
publisher "$D/j2" "$D/r2" 0.6 12; p=$!
t0=$(now); fm_test_wait_until --while-alive $p --progress-file "$D/j2" --inactivity 3 -- test -s "$D/r2"; rc=$?
echo "branch rc=$rc after $(python3 -c "print('%.1f'%($(now)-$t0))")s result=$(cat "$D/r2")"
wait $p
stop_burners
echo "== S2 dead peer: producer exits without publishing"
python3 -c 'import time; time.sleep(1)' & p=$!
t0=$(now); fm_test_wait_until --while-alive $p -- test -s "$D/never"; rc=$?
echo "rc=$rc after $(python3 -c "print('%.1f'%($(now)-$t0))")s (default inactivity is 900s)"
echo "== S3 silent live peer: alive, no observable change, --inactivity 2"
sleep 300 & p=$!
t0=$(now); fm_test_wait_until --while-alive $p --inactivity 2 -- test -s "$D/never"; rc=$?
echo "rc=$rc after $(python3 -c "print('%.1f'%($(now)-$t0))")s; peer still alive: $(kill -0 $p 2>/dev/null && echo yes || echo no)"
kill $p; wait $p 2>/dev/null
echo "== S4 live poller with no outcome, --cycles 3 (poll every 0.5s, counts to file)"
( n=0; while :; do sleep 0.5; n=$((n+1)); echo $n > "$D/count.tmp"; mv "$D/count.tmp" "$D/count"; done ) & p=$!
t0=$(now); fm_test_wait_until --while-alive $p --cycles 3 "$D/count" -- test -s "$D/never"; rc=$?
echo "rc=$rc after $(python3 -c "print('%.1f'%($(now)-$t0))")s"
kill $p; wait $p 2>/dev/null
echo "== S5 peer exits, its child publishes 1s later"
bash -c '( echo up > "$1.started"; sleep 1; echo done > "$1" ) & sleep 0.6' _ "$D/childres" & p=$!
fm_test_wait_until --while-alive $p -- test -s "$D/childres.started"  # order: sample after fork
t0=$(now); fm_test_wait_until --while-alive $p -- test -s "$D/childres"; rc=$?
echo "rc=$rc after $(python3 -c "print('%.1f'%($(now)-$t0))")s result=$(cat "$D/childres" 2>/dev/null || echo ABSENT)"
echo "== S6 old capped call shape is refused, no fallback"
fm_test_wait_until 10 test -e /; echo "old-shape rc=$?"
fm_test_wait_until -- test -e /; echo "no-observable rc=$?"
fm_test_wait_until --while-alive $$ -- test -e /; echo "own-pid rc=$?"
echo "== S7 outcome already true returns at once"
fm_test_wait_until --progress-file "$D/j2" -- test -s "$D/r2"; echo "rc=$?"
