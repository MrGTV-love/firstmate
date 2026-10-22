#!/usr/bin/env bash
# repeat-case.sh <worktree> <case.sh> <n> <logdir>  -- serial repetitions, natural load
wt=$1 case=$2 n=$3 logdir=$4
mkdir -p "$logdir"
pass=0 fail=0
for i in $(seq 1 "$n"); do
  nice -n 15 bash "$wt/bin/fm-proc-budget.sh" -- bash "$case" > "$logdir/run-$i.log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ] && grep -q '^ok - ' "$logdir/run-$i.log" && ! grep -q '^not ok' "$logdir/run-$i.log"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "run $i rc=$rc FAILED"
  fi
done
echo "cases=$n pass=$pass fail=$fail load=$(uptime | sed 's/.*load averages*: //')"
