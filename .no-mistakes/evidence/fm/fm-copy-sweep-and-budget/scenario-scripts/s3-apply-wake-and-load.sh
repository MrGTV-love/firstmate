#!/usr/bin/env bash
set -u
. /Users/charlesabrooker/tmp/fm-sweep-live-scripts/common.sh
LAB=$1
new_world "$LAB"
make_slot vernant 1
S=$SLOT; W=$S/.claude/worktrees
printf 'pool vernant 0.004\ninterval 0\n' > "$LAB/config/copy-budget"
add_copy "$S" dirtybig1 3; echo x > "$W/dirtybig1/u.txt"
add_copy "$S" dirtybig2 3; echo x > "$W/dirtybig2/u.txt"
add_copy "$S" reapme 1
echo "##### --apply while over budget: removes reapme, raises ONE wake through the wake queue #####"
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" --apply > "$LAB/a1.out" 2>&1; echo "exit=$?"; grep -E '^copy-sweep: wake|^REMOVED|^budget' "$LAB/a1.out" | cut -c1-260
echo "queue rows: $(wc -l < "$LAB/state/.wake-queue")"; cut -c1-200 "$LAB/state/.wake-queue"
echo "##### --apply again: same budget still over => NO second wake row #####"
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" --apply > "$LAB/a2.out" 2>&1; echo "exit=$?"; grep -c 'wake raised' "$LAB/a2.out"
echo "queue rows: $(wc -l < "$LAB/state/.wake-queue") (expect still 1)"

echo
echo "################ LOAD GUARD ################"
new_world "$LAB"
make_slot vernant 1
S=$SLOT; W=$S/.claude/worktrees
add_copy "$S" a 2; add_copy "$S" b 1
printf 'load-limit 0.01\ninterval 0\n' > "$LAB/config/copy-budget"
echo "real load: $(uptime)"
echo "##### report with load above limit: no du, one skip line, still classifies #####"
sweep "$WT/bin/fm-copy-sweep.sh" | head -6
echo "##### 7 consecutive 'check' runs while load is above limit: quiet until run 6, wake once, then quiet #####"
for i in 1 2 3 4 5 6 7 8; do
  sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/l$i.out" 2>&1
  printf 'run %s: exit=%s output="%s"\n' "$i" "$?" "$(cut -c1-200 "$LAB/l$i.out")"
done
echo "record:"; cat "$LAB/state/copy-sweep.record"
echo "##### load drops (limit raised above real load): streak ends, skip record cleared #####"
printf 'load-limit 100000\ninterval 0\n' > "$LAB/config/copy-budget"
sweep nice -n 20 "$WT/bin/fm-copy-sweep.sh" check > "$LAB/l9.out" 2>&1; echo "exit=$? output bytes=$(wc -c < "$LAB/l9.out")"; cat "$LAB/state/copy-sweep.record"
echo "##### du ran under nice? (sizes now cached) #####"; cat "$LAB/state/copy-sweep.sizes" | awk -F'\t' '{print $1, $4 " KiB"}'
