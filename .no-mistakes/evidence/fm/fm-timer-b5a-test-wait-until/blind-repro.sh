#!/usr/bin/env bash
# Repeat the suite's "unavailable CPU telemetry" case with 18 CPU burners; print stderr each run.
set -u
WT=$1; . "$WT/tests/lib.sh"; TMP_ROOT=$(fm_test_tmproot fm-blind-repro); pids=()
for _ in $(seq 18); do python3 -c 'while True: sum(range(10000))' & pids+=($!); done
trap 'kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null' EXIT
fakebin=$(fm_fakebin "$TMP_ROOT/blind"); printf '#!/bin/sh\nexit 1\n' > "$fakebin/ps"; chmod +x "$fakebin/ps"
for i in 1 2 3 4 5 6; do
  result="$TMP_ROOT/blind$i.result"
  s=$(date +%s)
  python3 -c 'import pathlib, sys, time; time.sleep(1); pathlib.Path(sys.argv[1]).write_text("observed")' "$result" &
  publisher=$!
  PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/absent-proc" \
    fm_test_wait_until --while-alive "$publisher" --inactivity 0.1 -- test -s "$result" 2> "$TMP_ROOT/blind$i.err"; rc=$?
  wait $publisher
  echo "run $i rc=$rc load=$(uptime | sed 's/.*averages: //') elapsed=$(( $(date +%s) - s ))s stderr=[$(tr '\n' ' ' < "$TMP_ROOT/blind$i.err" | cut -c1-160)]"
done
rm -rf "$TMP_ROOT"
