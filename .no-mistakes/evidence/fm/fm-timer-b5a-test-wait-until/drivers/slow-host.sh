#!/usr/bin/env bash
# Slow-host scenario: the same publisher, slowed >=5x by a sleep dilation and a
# CPU-burn neighbour, awaited by the base capped helper and the new helper.
set -u
WT=$1
. "$WT/tests/lib.sh"
TMP=$(fm_test_tmproot fm-slow-host-driver)

old_wait_until() {  # verbatim body of base 28bb500b2 tests/lib.sh
  local limit=$1 ticks=0
  shift
  while ! "$@" >/dev/null 2>&1; do
    ticks=$((ticks + 1))
    [ "$ticks" -le $((limit * 10)) ] || return 1
    sleep 0.1
  done
}

publisher() {  # <journal> <result> <dilation>
  python3 -c '
import pathlib, sys, time
journal, result = map(pathlib.Path, sys.argv[1:3])
for step in range(20):
    time.sleep(0.1 * int(sys.argv[3]))
    journal.write_text(str(step))
result.write_text("published")
' "$@" &
}

burners=()
ncpu=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
start_burn() {
  for _ in $(seq 1 "$ncpu"); do python3 -c 'while True: sum(range(10000))' & burners+=($!); done
}
stop_burn() { kill "${burners[@]}" 2>/dev/null; wait "${burners[@]}" 2>/dev/null; burners=(); }

run() {  # <helper:old|new> <dilation> <burn:0|1>
  local helper=$1 dilation=$2 burn=$3 j r p rc=0 t0 t1
  j="$TMP/$helper-$dilation.journal"; r="$TMP/$helper-$dilation.result"; rm -f "$j" "$r"
  [ "$burn" = 0 ] || start_burn
  t0=$(python3 -c 'import time; print(time.time())')
  publisher "$j" "$r" "$dilation"; p=$!
  if [ "$helper" = old ]; then
    old_wait_until 5 test -s "$r" || rc=$?
  else
    fm_test_wait_until --while-alive "$p" --progress-file "$j" -- test -s "$r" || rc=$?
  fi
  t1=$(python3 -c 'import time; print(time.time())')
  [ "$burn" = 0 ] || stop_burn
  wait "$p" 2>/dev/null
  printf '%-4s helper  dilation=%sx cpu_burn=%s  wait_rc=%s  waited=%.1fs  publisher_result=%s  load1=%s\n' \
    "$helper" "$dilation" "$burn" "$rc" "$(python3 -c "print($t1-$t0)")" "$(cat "$r" 2>/dev/null || echo none)" \
    "$(sysctl -n vm.loadavg | awk '{print $2}')"
}

echo "== baseline (quiet publisher, ~2s of work) =="
run old 1 0
run new 1 0
echo "== slow host: 6x sleep dilation plus $ncpu CPU-burn neighbours (~12s+ of work) =="
run old 6 1
run new 6 1
