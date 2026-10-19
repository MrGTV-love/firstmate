#!/usr/bin/env bash
# check must finish inside FM_CHECK_TIMEOUT even with many real clones, still print the wake, and keep standing budgets.
set -u
. /Users/charlesabrooker/tmp/fm-sweep-live-scripts/common.sh
LAB=$1; N=${2:-60}
new_world "$LAB"
echo "building $N real pool slots, each with a 2 MiB nested copy ..."
for i in $(seq 1 "$N"); do make_slot big "$i"; add_copy "$SLOT" "c$i" 2; done
echo "pool big total ~ $((N*2)) MiB"
# budget: 20% of the full total, so a partial scan (first clones) alone is still over once enough clones are reached
printf 'pool big 0.01\ninterval 0\n' > "$LAB/config/copy-budget"   # 0.01 GiB = ~10.24 MiB
echo
echo "##### 1) COMPLETE run (unbounded --apply is not used; report mode is unbounded and read-only) #####"
t0=$(date +%s); sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" | grep -E '^copy-sweep: mode|^budget' ; echo "wall: $(( $(date +%s)-t0 ))s"
echo
echo "##### 2) CUT check: FM_CHECK_TIMEOUT=6 => 1s of scan. Measure wall time and output #####"
rm -f "$LAB/state/copy-sweep."*
t0=$(date +%s)
FM_CHECK_TIMEOUT=6 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/cut1.out" 2>&1; rc=$?
echo "exit=$rc wall: $(( $(date +%s)-t0 ))s (kill limit would be 6s)"
echo "wake lines: $(grep -c '^copy-sweep:' "$LAB/cut1.out")"; cut -c1-330 "$LAB/cut1.out"
echo "record after cut run:"; cat "$LAB/state/copy-sweep.record"
echo "(a cut run must NOT write last_scan)"
echo "cache lines after cut run: $(wc -l < "$LAB/state/copy-sweep.sizes")"
echo
echo "##### 3) CUT check again: same overrun => no second wake; standing budget kept in record #####"
t0=$(date +%s)
FM_CHECK_TIMEOUT=6 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/cut2.out" 2>&1; rc=$?
echo "exit=$rc wall: $(( $(date +%s)-t0 ))s output bytes: $(wc -c < "$LAB/cut2.out")"
cat "$LAB/state/copy-sweep.record"
echo
echo "##### 4) a COMPLETE check (watcher timeout generous) after the cut ones: still over, still no second wake, now writes last_scan #####"
FM_CHECK_TIMEOUT=600 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/full.out" 2>&1; rc=$?
echo "exit=$rc output bytes: $(wc -c < "$LAB/full.out")"; cat "$LAB/state/copy-sweep.record"
echo "cache lines after complete run: $(wc -l < "$LAB/state/copy-sweep.sizes") (expect $N)"
echo
echo "##### 5) cut check keeps cached sizes of clones it never reached #####"
FM_CHECK_TIMEOUT=6 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/cut3.out" 2>&1
echo "cache lines after another cut run: $(wc -l < "$LAB/state/copy-sweep.sizes") (expect still $N)"
