#!/usr/bin/env bash
set -u
H=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6K6G2DDFTPSGNK9PXHF6D77
B=$(cat /tmp/fmlint-base-path)
W=/tmp/fmlint-live
D=$W/drive.sh
admit() { local lvl; lvl=$(sysctl -n kern.memorystatus_vm_pressure_level); echo "[$1] pressure level before: $lvl" | tee -a $W/pressure.txt; "$H/bin/fm-mem-guard.sh" admit >/dev/null 2>&1 || { echo "[$1] mem-guard refused; stopping" | tee -a $W/pressure.txt; exit 75; }; }
maxrec() { local m=0 v; for f in "$1"/history/*; do [ -f "$f" ] || continue; v=$(cat "$f"); [ "$v" -gt "$m" ] && m=$v; done; echo $m; }
sel=${1:-all}
want() { [ "$sel" = all ] || [ "$sel" = "$1" ]; }
if want p0; then
admit p0; $D "$H/bin/fm-lint.sh" p0-head-unbudgeted 4 $W/pool0 FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=100000000 FM_LINT_ROOT_RSS_KIB=1048576
fi
if want p1; then
R=$(maxrec $W/pool0); BUD=$((R * 5 / 2)); echo "max record from p0 pool: $R KiB; budget = 2.5x = $BUD KiB" | tee $W/budget.txt
admit p1; $D "$H/bin/fm-lint.sh" p1-head-budget-cold 4 $W/pool1 FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=$BUD FM_LINT_ROOT_RSS_KIB=1048576
admit p2; $D "$H/bin/fm-lint.sh" p2-head-budget-warm 4 $W/pool1 FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=$BUD FM_LINT_ROOT_RSS_KIB=1048576
admit p3; $D "$H/bin/fm-lint.sh" p3-head-lone-warm 1 $W/pool1 FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=$BUD FM_LINT_ROOT_RSS_KIB=1048576
fi
if want p4; then
admit p4; $D "$H/bin/fm-lint.sh" p4-head-default-pool-4homes 4 default
ls -la /var/tmp/firstmate-lint-fmlivetest/lint-slots > $W/out/p4-head-default-pool-4homes/pool-listing.txt 2>&1
cat /var/tmp/firstmate-lint-fmlivetest/lint-slots/queue.next > $W/out/p4-head-default-pool-4homes/queue.next.txt 2>&1
for r in 1 2 3 4; do ls -d $W/home.$r/.cache/firstmate/lint-slots 2>/dev/null; done > $W/out/p4-head-default-pool-4homes/per-home-pools.txt
fi
if want p5; then
for r in 1 2 3 4; do rm -rf $W/home.$r/.cache/firstmate; done
admit p5; $D "$B/bin/fm-lint.sh" p5-base-default-pool-4homes 4 default
for r in 1 2 3 4; do ls -d $W/home.$r/.cache/firstmate/lint-slots 2>/dev/null; done > $W/out/p5-base-default-pool-4homes/per-home-pools.txt
fi
echo PHASES-DONE
