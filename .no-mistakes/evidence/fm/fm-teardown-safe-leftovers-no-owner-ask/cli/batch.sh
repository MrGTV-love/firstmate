#!/bin/bash
# usage: batch.sh <worktree> <scenario>...   one scenario at a time, never in parallel
W=$1; shift
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M87E3DXKY8YXG964RQ01FZ3D/cli
cd "$W" || exit 2
for sc in "$@"; do
  start=$(date +%s)
  {
    echo "\$ bin/fm-proc-budget.sh --own-procs 128 -- bash $EV/cli-scenario.sh $W $sc   (head $(git rev-parse --short HEAD))"
    bin/fm-proc-budget.sh --own-procs 128 -- bash "$EV/cli-scenario.sh" "$W" "$sc" 2>&1
    echo "rc=$? elapsed=$(( $(date +%s) - start ))s"
  } > "$EV/scenario-$sc.txt" 2>&1
  echo "$sc: $(grep -h '^SCENARIO' "$EV/scenario-$sc.txt") $(tail -1 "$EV/scenario-$sc.txt")"
done
