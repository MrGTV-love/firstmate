#!/usr/bin/env bash
# Run the helper's own suite with 18 CPU-burning neighbours (one per core) on top of host load.
set -u
WT=$1; pids=()
for _ in $(seq 18); do python3 -c 'while True: sum(range(10000))' & pids+=($!); done
trap 'kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null' EXIT
sleep 2; echo "== host with burners: $(uptime)"
bash "$WT/tests/fm-test-wait-until.test.sh"; rc=$?
echo "== host after: $(uptime)"; echo "suite rc=$rc"; exit $rc
