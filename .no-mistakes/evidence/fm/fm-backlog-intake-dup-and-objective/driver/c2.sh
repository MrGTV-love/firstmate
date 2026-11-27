. ~/tmp/fm-drv/lib.sh
say "C1b the closed duplicate records its proof as the closing note"
run grep -n -A3 '^- \[x\] dc-dup' $B
say "C5 (redo) refused: an open owner call (a real captain hold with a valid boundary)"
fm add oc-3 "Pick the anchor chain gauge" --objective O7
run bin/fm-captain-hold.sh hold oc-3 --reason "which chain gauge does the owner want" --boundary owner-rule-change --if-no "keep the 8mm chain"
run bin/fm-captain-hold.sh open oc-3
fm done oc-3 --duplicate-of dc-keep
run sh -c "bin/fm-tasks-axi.sh show oc-3 | grep -E 'state:|held:|hold_kind:'"
