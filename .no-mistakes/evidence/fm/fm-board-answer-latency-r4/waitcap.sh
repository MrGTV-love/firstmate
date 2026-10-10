#!/usr/bin/env bash
# Wait up to <secs> for a captured result on <source-id> containing <text>; print how long it took.
# Usage: waitcap.sh <source-id> <text> <click-epoch> [secs]
set -u
id=$1 text=$2 t0=$3 max=${4-90}
inbox=$FM_HOME/state/procevent-inbox
for _ in $(seq 1 $((max*2))); do
  f=$(grep -l -F -- "$text" "$inbox/$id".*.result 2>/dev/null | head -1)
  if [ -n "$f" ]; then echo "capture $(basename "$f") visible $(( $(date +%s) - t0 ))s after the click (whole seconds)"; exit 0; fi
  sleep 0.5
done
echo "NO capture containing '$text' within ${max}s"; exit 1
