#!/usr/bin/env bash
# Fixed-count measurement of the exact test_memory_tree_over_limit payload
# through the public wrapper (outer 2 GiB, inner 128 MiB), as
# tests/fm-proc-budget.test.sh runs it. Every trial's exit and full stderr are
# kept. Optional CPU contention: <hogs> busy loops run for the batch only.
# Usage: memory-payload-trials.sh <worktree-root> <trials> <hogs> <label>
set -u
ROOT=$1 N=$2 HOGS=$3 LABEL=$4
WRAP="$ROOT/bin/fm-proc-budget.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-mem-trials.XXXXXX")
cat >"$T/memory-tree.py" <<'PY'
import os
import subprocess
import sys
import time

if len(sys.argv) == 1:
    subprocess.Popen([sys.executable, __file__, "child"])
    time.sleep(60)
else:
    if sys.argv[1] == "child":
        subprocess.Popen([sys.executable, __file__, "grandchild"])
    with open(os.environ["FM_MEMORY_PIDS"], "a") as handle:
        handle.write(str(os.getpid()) + "\n")
    allocation = bytearray(80 * 1024 * 1024)
    time.sleep(60)
PY
hogs=()
for _ in $(seq 1 "$HOGS"); do python3 -c 'while True: pass' & hogs+=($!); done
echo "label=$LABEL trials=$N hogs=$HOGS start=$(date -u +%FT%TZ) python3=$(python3 -c 'import sys;print(sys.version.split()[0], sys.executable)')"
echo "load_before=$(sysctl -n vm.loadavg)"
codes=""
for i in $(seq 1 "$N"); do
  : > "$T/pids.$i"
  t0=$(python3 -c 'import time;print(time.time())')
  FM_MEMORY_PIDS="$T/pids.$i" "$WRAP" --memory-kib 2097152 -- \
    "$WRAP" --memory-kib 131072 -- python3 "$T/memory-tree.py" 2>"$T/err.$i"
  rc=$?
  t1=$(python3 -c 'import time;print(time.time())')
  codes="$codes $rc"
  printf 'trial=%s exit=%s secs=%.2f pids=%s stderr=%s\n' "$i" "$rc" "$(echo "$t1 - $t0" | bc)" \
    "$(tr '\n' ',' <"$T/pids.$i")" "$(tr '\n' '|' <"$T/err.$i")"
done
echo "load_after=$(sysctl -n vm.loadavg)"
[ "${#hogs[@]}" -eq 0 ] || kill "${hogs[@]}" 2>/dev/null; wait 2>/dev/null
echo "summary exits:$codes" ; printf "%s\n" $codes | sort | uniq -c | sed "s/^/summary /"
echo "end=$(date -u +%FT%TZ)"
rm -rf "$T"
