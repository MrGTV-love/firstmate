#!/usr/bin/env bash
set -u
. /Users/charlesabrooker/tmp/fm-sweep-live-scripts/common.sh
LAB=$1; TH=$LAB/th
echo "##### A) first-ever cut check, budget tripped by the first clones it reaches: wake names only what it measured #####"
printf 'pool big 0.001\ninterval 0\n' > "$LAB/config/copy-budget"
rm -f "$LAB/state/copy-sweep."*
t0=$(date +%s); FM_CHECK_TIMEOUT=6 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/a.out" 2>&1; echo "exit=$? wall=$(( $(date +%s)-t0 ))s wake lines=$(grep -c '^copy-sweep:' "$LAB/a.out")"
sed 's/\/Users\/charlesabrooker\/tmp\/fm-lab.1T3WtT\/th\/big\///g' "$LAB/a.out" | cut -c1-600
echo "record:"; cat "$LAB/state/copy-sweep.record"; echo "(cut run => no last_scan)"
echo
echo "##### B) check that is BOTH cut (FM_CHECK_TIMEOUT=6) AND load-skipped on every poll: still reaches the skip wake after 6 intervals (interval=2s here) #####"
printf 'load-limit 0.01\ninterval 2\n' > "$LAB/config/copy-budget"
rm -f "$LAB/state/copy-sweep."*
for i in $(seq 1 9); do
  FM_CHECK_TIMEOUT=6 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/b$i.out" 2>&1
  printf 'poll %s: out="%s" skip-record="%s"\n' "$i" "$(cut -c1-120 "$LAB/b$i.out")" "$(awk -F'\t' '$1=="skip"{print "runs=" $2 " at=" $3}' "$LAB/state/copy-sweep.record")"
  sleep 2.2
done
echo "record:"; cat "$LAB/state/copy-sweep.record"
echo
echo "##### C) two polls inside ONE interval while cut+skipped count only once #####"
printf 'load-limit 0.01\ninterval 3600\n' > "$LAB/config/copy-budget"
rm -f "$LAB/state/copy-sweep."*
for i in 1 2 3 4; do FM_CHECK_TIMEOUT=6 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check >/dev/null 2>&1; printf 'poll %s: %s\n' "$i" "$(awk -F'\t' '$1=="skip"{print "runs=" $2}' "$LAB/state/copy-sweep.record")"; done
echo "(expect runs=1 on every poll: the cut polls fall inside one 3600s interval)"
