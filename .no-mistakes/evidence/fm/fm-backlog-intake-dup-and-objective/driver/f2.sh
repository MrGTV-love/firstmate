. ~/tmp/fm-drv/lib.sh
say "F6b a scout with a written report closes (report given relative to the backlog root, data/<id>/report.md)"
fm done pf-scout --report data/pf-scout/report.md
run sh -c "bin/fm-tasks-axi.sh show pf-scout | grep -E 'state:|links:'"
run grep pf-scout $LAB/state/fleet-ledger.jsonl
say "F6c comparison: the BASE wrapper (commit d25e907c1) with an absolute report path gives the same tasks-axi refusal"
BL=$(mktemp -d ~/tmp/fm-base.XXXXXX)
mkdir -p $BL/data/bs-1 $BL/state $BL/config; printf '## In flight\n\n## Queued\n\n## Done\n' > $BL/data/backlog.md
printf 'r\n' > $BL/data/bs-1/report.md
(export FM_HOME=$BL; cd $W && ~/tmp/fm-drv/base/bin/fm-tasks-axi.sh add bs-1 "Base scout" --kind scout >/dev/null
 run ~/tmp/fm-drv/base/bin/fm-tasks-axi.sh done bs-1 --report $BL/data/bs-1/report.md)
rm -rf $BL
