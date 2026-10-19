#!/usr/bin/env bash
# Standing overrun stays recorded across cut check runs that only reach part of the pool; no double wake; cache kept.
set -u
. /Users/charlesabrooker/tmp/fm-sweep-live-scripts/common.sh
LAB=$1
TH=$LAB/th
printf 'pool big 0.05\ninterval 0\n' > "$LAB/config/copy-budget"   # 51.2 MiB; pool has 60 x 2 MiB (120 MiB) so a 1s cut reaches only part of it and its partial total is UNDER the budget
rm -f "$LAB/state/copy-sweep."*
echo "pool clones: $(ls -d $TH/big/*/repo | wc -l)"
echo "##### 1) complete check (FM_CHECK_TIMEOUT=600): raises the one wake #####"
t0=$(date +%s); FM_CHECK_TIMEOUT=600 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/full1.out" 2>&1; echo "exit=$? wall=$(( $(date +%s)-t0 ))s wake lines=$(grep -c '^copy-sweep:' "$LAB/full1.out")"; cut -c1-200 "$LAB/full1.out"
cat "$LAB/state/copy-sweep.record"; echo "cache lines: $(wc -l < "$LAB/state/copy-sweep.sizes")"
echo
echo "##### 2) twelve CUT checks (1s of scan each): partial totals sometimes under, sometimes over the budget #####"
wakes=0; kept=0
for i in $(seq 1 12); do
  FM_CHECK_TIMEOUT=6 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/cut$i.out" 2>&1
  w=$(grep -c '^copy-sweep:' "$LAB/cut$i.out"); wakes=$((wakes+w))
  if grep -qx "over	pool:$TH/big" "$LAB/state/copy-sweep.record"; then k=yes; kept=$((kept+1)); else k=NO; fi
  printf 'cut %2s: wake lines=%s record keeps over=%s cache lines=%s last_scan kept=%s\n' "$i" "$w" "$k" "$(wc -l < "$LAB/state/copy-sweep.sizes" | tr -d ' ')" "$(grep -c '^last_scan' "$LAB/state/copy-sweep.record")"
done
echo "total extra wakes from cut runs: $wakes   record kept the standing overrun in $kept of 12 runs"
echo
echo "##### 3) complete check after the cut runs: still over => NO second wake #####"
FM_CHECK_TIMEOUT=600 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/full2.out" 2>&1; echo "exit=$? wake lines=$(grep -c '^copy-sweep:' "$LAB/full2.out")"
cat "$LAB/state/copy-sweep.record"
