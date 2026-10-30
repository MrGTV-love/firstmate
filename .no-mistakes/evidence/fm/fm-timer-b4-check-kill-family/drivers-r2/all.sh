#!/usr/bin/env bash
# Round 2: target = run worktree at 223214c9e; base = 5df96973e (main); prefix = e4fdac934 (before launcher-stop bound).
D=$(cd "$(dirname "$0")" && pwd)
T=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M660RK8MW2W9FJGDSPWM42CN
B=$1/base; P=$1/prefix
pb() { "$T/bin/fm-proc-budget.sh" --own-procs 256 -- "$@"; }
cd "$D"
for s in s1 s2 s3b s7 s8; do pb ./$s.sh $T target > w-$s-target.log 2>&1 & done
pb ./s2.sh $B base > w-s2-base.log 2>&1 &
pb ./s3d.sh $T target > w-s3d-target.log 2>&1 &
pb ./s5.sh $T > w-s5-target.log 2>&1 &
pb ./s6.sh $T > w-s6-target.log 2>&1 &
pb ./s9.sh $T target > w-s9-target.log 2>&1 &
pb ./s9.sh $P prefix > w-s9-prefix.log 2>&1 &
wait
