#!/usr/bin/env bash
D=$(cd "$(dirname "$0")" && pwd)
T=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M660RK8MW2W9FJGDSPWM42CN
B=/Users/charlesabrooker/tmp/fm-b4-base
pb() { "$T/bin/fm-proc-budget.sh" --own-procs 256 -- "$@"; }
cd "$D"
for s in s1 s2 s3b s7 s8; do pb ./$s.sh $T target > w-$s-target.log 2>&1 & pb ./$s.sh $B base > w-$s-base.log 2>&1 & done
pb ./s5.sh $T > w-s5-target.log 2>&1 &
pb ./s6.sh $T > w-s6-target.log 2>&1 &
wait
