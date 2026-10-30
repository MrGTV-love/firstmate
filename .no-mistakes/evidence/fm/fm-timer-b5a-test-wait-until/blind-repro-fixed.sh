#!/usr/bin/env bash
# The fixed (ordered) blind-telemetry case, 20 runs with $BURNERS CPU burners.
set -u
WT=$1; . "$WT/tests/lib.sh"; TMP_ROOT=$(fm_test_tmproot fm-blind-fixed); pids=()
for _ in $(seq "${BURNERS:-54}"); do python3 -c 'while True: sum(range(10000))' & pids+=($!); done
trap 'kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null' EXIT
note_probe() { printf 'probe\n' >> "$1.probes"; [ "$(wc -l < "$1.probes")" -lt 3 ] || : > "$1"; test -s "$2"; }
fakebin=$(fm_fakebin "$TMP_ROOT/blind"); printf '#!/bin/sh\nexit 1\n' > "$fakebin/ps"; chmod +x "$fakebin/ps"
miss=0
for i in $(seq 20); do
  observed="$TMP_ROOT/b$i.observed" result="$TMP_ROOT/b$i.result"
  python3 -c '
import pathlib, sys, time
o, r = map(pathlib.Path, sys.argv[1:])
while not o.exists(): time.sleep(0.05)
time.sleep(1); r.write_text("observed")' "$observed" "$result" &
  publisher=$!
  PATH="$fakebin:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/absent-proc" \
    fm_test_wait_until --while-alive "$publisher" --inactivity 0.1 -- note_probe "$observed" "$result" 2> "$TMP_ROOT/b$i.err"; rc=$?
  wait $publisher
  w=no; grep -q cpu_telemetry_unavailable "$TMP_ROOT/b$i.err" && w=yes
  [ $rc -eq 0 ] && [ $w = yes ] || miss=$((miss+1))
  echo "run $i rc=$rc blind-warning=$w load=$(uptime | sed 's/.*averages: //')"
done
echo "misses=$miss/20"; rm -rf "$TMP_ROOT"
