#!/usr/bin/env bash
# Live slow-host demo: main's capped helper vs this branch's progress-aware helper.
# Usage: slow-host-demo.sh <worktree> <evidence-dir>
set -u
WT=$1 E=$2
. "$WT/tests/lib.sh"
. "$E/main-helper.sh"
T=$(fm_test_tmproot slow-host-demo)
burners=()
for i in 1 2 3 4; do python3 -c 'while True: sum(range(1000))' & burners+=($!); done
trap 'kill "${burners[@]}" 2>/dev/null' EXIT
echo "host load with 4 CPU-burn neighbours: $(uptime | sed 's/.*load/load/')"
publisher() {  # <journal> <result> <dilation>
  python3 -c '
import pathlib, sys, time
j, r = map(pathlib.Path, sys.argv[1:3])
for step in range(20):
    time.sleep(0.1 * int(sys.argv[3])); j.write_text(str(step))
r.write_text("published")' "$@" &
}
for helper in main branch; do
  for dilation in 1 5; do
    j="$T/$helper-$dilation.journal" r="$T/$helper-$dilation.result"
    publisher "$j" "$r" "$dilation"; pub=$!
    start=$SECONDS rc=0
    if [ "$helper" = main ]; then
      main_fm_test_wait_until 5 test -s "$r" || rc=$?   # a typical 5s caller ceiling on main
    else
      fm_test_wait_until --while-alive "$pub" --progress-file "$j" -- test -s "$r" || rc=$?
    fi
    wait "$pub"
    echo "helper=$helper dilation=${dilation}x rc=$rc waited=$((SECONDS-start))s result=$(cat "$r" 2>/dev/null || echo none-at-verdict)"
  done
done
echo "--- harm still caught (branch helper, default 900s inactivity) ---"
python3 -c 'import time; time.sleep(1)' & dead=$!   # peer exits without publishing
start=$SECONDS rc=0
fm_test_wait_until --while-alive "$dead" -- test -s "$T/never" 2>"$T/dead.err" || rc=$?
echo "dead peer: rc=$rc waited=$((SECONDS-start))s stderr=$(cat "$T/dead.err")"
sleep 300 & silent=$!
start=$SECONDS rc=0
fm_test_wait_until --while-alive "$silent" --inactivity 2 -- test -s "$T/never" 2>"$T/silent.err" || rc=$?
alive=no; kill -0 "$silent" 2>/dev/null && alive=yes
kill "$silent"
echo "silent live peer (--inactivity 2): rc=$rc waited=$((SECONDS-start))s peer_still_alive=$alive stderr=$(tr '\n' ' ' < "$T/silent.err")"
python3 -c '
import os, pathlib, sys, time
c = pathlib.Path(sys.argv[1]); n = 0
while True:
    time.sleep(0.5); n += 1
    c.with_suffix(".tmp").write_text(str(n)); os.replace(c.with_suffix(".tmp"), c)' "$T/poll.count" & poller=$!
start=$SECONDS rc=0
fm_test_wait_until --while-alive "$poller" --cycles 4 "$T/poll.count" -- test -s "$T/never" 2>"$T/poll.err" || rc=$?
kill "$poller"
echo "live poller never publishing (--cycles 4, 0.5s cycles): rc=$rc waited=$((SECONDS-start))s stderr=$(cat "$T/poll.err")"
