#!/usr/bin/env bash
# stress.sh <label> <tree-root> <reps> <outdir> : repeat the unchanged concurrent append/drain case under nice -n 20.
set -u
label=$1 R=$2 reps=$3 out=$4; mkdir -p "$out/$label"
i=$(( $(ls "$out/$label" | grep -c '^rep-') + 1 ))   # resume from last completed rep
while [ "$i" -le "$reps" ]; do
  s=$(date +%s)
  (cd "$R" && nice -n 20 env FM_TEST_ONLY=test_concurrent_append_and_drain bash tests/fm-wake-queue.test.sh) > "$out/$label/run.tmp" 2>&1; rc=$?
  mv "$out/$label/run.tmp" "$out/$label/rep-$(printf %03d $i).log"
  printf '%s rep=%d rc=%d secs=%d load="%s" line="%s"\n' "$label" "$i" "$rc" $(( $(date +%s)-s )) "$(uptime | sed 's/.*averages: //')" "$(grep -E '^(ok|not ok)' "$out/$label/rep-$(printf %03d $i).log" | tr '\n' ' ')" >> "$out/$label/results.txt"
  i=$((i+1))
done
