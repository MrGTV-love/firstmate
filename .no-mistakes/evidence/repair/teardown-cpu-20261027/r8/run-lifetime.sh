#!/bin/bash
# Runs the committed lifetime regression block (lifetime-block-head.sh) against c1361 and HEAD trees.
set -u
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M60X7EHPFP3WC1T7VVP0W6VM/r8; S=$(cat $EV/trees.path); mkdir -p $EV/harness
for t in c1361 head; do for c in nested-bash nested-default held-worker escape; do
  T=$(mktemp -d "$HOME/tmp/nm-r8-life-$t-$c.XXXXXX") || exit 1
  s=$(date +%s)
  (cd "$S/$t" && TMPDIR=$T bash "$EV/lifetime-harness.sh" "$S/$t" "$c") > "$EV/harness/$t-$c.out" 2>&1; rc=$?
  sleep 5; if [ -z "$(find "$T" -mindepth 1 | head -1)" ]; then rmdir -- "$T"; own=empty_rmdir_ok; else own="kept:$T"; fi
  echo "$t $c rc=$rc secs=$(( $(date +%s)-s )) owned_tmp=$own" | tee -a "$EV/harness/receipts.txt"
done; done
