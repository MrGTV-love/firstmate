#!/usr/bin/env bash
set -u
. /Users/charlesabrooker/tmp/fm-sweep-live-scripts/common.sh
LAB=$1; N=${2:-60}
new_world "$LAB"
for i in $(seq 1 "$N"); do make_slot big "$i"; add_copy "$SLOT" "c$i" 2; done
printf 'pool big 0.01\ninterval 0\n' > "$LAB/config/copy-budget"
t() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
echo "right after building $N slots; load $(uptime | sed 's/.*averages: //')"
for i in 1 2 3 4 5 6; do
  rm -f "$LAB/state/copy-sweep."*
  s=$(t); FM_CHECK_TIMEOUT=6 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/x.out" 2>&1; e=$(t)
  echo "fresh cut run $i: wall $(perl -e "printf '%.2f', $e-$s")s out=$(wc -c < "$LAB/x.out" | tr -d ' ') load1=$(uptime | sed 's/.*averages: //' | cut -d' ' -f1)"
done
echo "--- now a complete report run, then cut again (the s4 order) ---"
s=$(t); sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" >/dev/null 2>&1; e=$(t); echo "report wall $(perl -e "printf '%.2f', $e-$s")s"
for i in 1 2 3 4; do
  rm -f "$LAB/state/copy-sweep."*
  s=$(t); FM_CHECK_TIMEOUT=6 sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/x.out" 2>&1; e=$(t)
  echo "cut run $i after report: wall $(perl -e "printf '%.2f', $e-$s")s out=$(wc -c < "$LAB/x.out" | tr -d ' ')"
done
