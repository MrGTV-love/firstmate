#!/usr/bin/env bash
# Live drive of bin/fm-captain-hold.sh hold creation through the intake rule in a disposable lab home.
# Usage: drive-hold.sh <worktree> <lab-home>
set -u
WT=$1; export FM_HOME=$2
cd "$WT"
H=bin/fm-captain-hold.sh; W=bin/fm-tasks-axi.sh
run() { echo; echo "\$ $*"; "$@"; echo "[exit=$?]"; }
step() { echo; echo "=================== $* ==================="; }
B=$FM_HOME/data/backlog.md
step "H1 first teardown recovery hold files and holds"
run $H hold ship-one-bundle --title "Land or drop the bundle-preserved commits of ship-one" --repo firstmate --owner captain --reason "land or drop the bundle"
grep -n 'ship-one-bundle' "$B"; grep 'ship-one-bundle' "$FM_HOME/data/backlog-review.tsv"
step "H2 second templated hold is stopped with hold-correct guidance"
run $H hold ship-two-bundle --title "Land or drop the bundle-preserved commits of ship-two" --repo firstmate --owner captain --reason "land or drop the bundle"
echo "--- ship-two-bundle in backlog (expect none):"; grep -c 'ship-two-bundle' "$B"
step "H3 follow the guidance: --not-dup with BD_DUE_REQUIRED=false, then re-run the same hold"
run env BD_DUE_REQUIRED=false $W add ship-two-bundle "Land or drop the bundle-preserved commits of ship-two" --kind captain --repo firstmate --objective none --objective-reason "captain hold record: tracks a captain decision, not a work item" --not-dup ship-one-bundle
run $H hold ship-two-bundle --title "Land or drop the bundle-preserved commits of ship-two" --repo firstmate --owner captain --reason "land or drop the bundle"
run $H open ship-two-bundle
grep -n 'ship-two-bundle' "$B"
step "H4 an open owner call blocks a --duplicate-of proof close"
run $W done ship-two-bundle --duplicate-of ship-one-bundle
