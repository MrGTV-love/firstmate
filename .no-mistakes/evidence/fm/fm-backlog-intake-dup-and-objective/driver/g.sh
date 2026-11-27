. ~/tmp/fm-drv/lib.sh
say "G1 a hold that creates a new row records objective none with the fixed reason"
run bin/fm-captain-hold.sh hold ch-1 --title "Decide the spinnaker storage locker" --repo firstmate --reason "where should the spinnaker live" --boundary owner-rule-change --if-no "keep it in the forepeak"
run bin/fm-captain-hold.sh open ch-1
run sh -c "bin/fm-tasks-axi.sh show ch-1 | grep -E 'state:|held:|hold_kind:|kind:'"
run grep ch-1 $LAB/data/backlog-review.tsv
NEIGH_BEFORE=$(cd $W && bin/fm-tasks-axi.sh show ch-1 --full)
say "G2 a hold whose new title overlaps ch-1 stops with guidance and holds nothing"
out=$(cd $W && bin/fm-captain-hold.sh hold ch-2 --title "Decide the spinnaker storage locker size" --repo firstmate --reason "how big should the locker be" --boundary owner-rule-change --if-no "keep the current size" 2>&1); rc=$?
printf '$ bin/fm-captain-hold.sh hold ch-2 --title "Decide the spinnaker storage locker size" --repo firstmate --reason "how big should the locker be" --boundary owner-rule-change --if-no "keep the current size"\n%s\n[exit %s]\n' "$out" "$rc"
run bin/fm-captain-hold.sh open ch-2
fm show ch-2
run grep -c ch-2 $LAB/data/backlog-review.tsv
if [ "$NEIGH_BEFORE" = "$(cd $W && bin/fm-tasks-axi.sh show ch-1 --full)" ]; then echo "neighbour ch-1 unchanged"; else echo "NEIGHBOUR ch-1 CHANGED"; fi
say "G3 the printed recovery works: the --not-dup command with BD_DUE_REQUIRED=false, then the same hold again"
cmd=$(printf '%s\n' "$out" | grep -A1 'is different from' | tail -1 | sed 's/^ *//')
echo "recovery command taken from the refusal: BD_DUE_REQUIRED=false $cmd"
(cd $W && eval "BD_DUE_REQUIRED=false $cmd" >/dev/null 2>&1; echo "[exit $?]")
run bin/fm-captain-hold.sh hold ch-2 --title "Decide the spinnaker storage locker size" --repo firstmate --reason "how big should the locker be" --boundary owner-rule-change --if-no "keep the current size"
run bin/fm-captain-hold.sh open ch-2
run sh -c "bin/fm-tasks-axi.sh show ch-2 | grep -E 'state:|held:|hold_kind:|kind:'"
run grep ch- $LAB/data/backlog-review.tsv
run grep '"ch-' $LAB/state/fleet-ledger.jsonl
