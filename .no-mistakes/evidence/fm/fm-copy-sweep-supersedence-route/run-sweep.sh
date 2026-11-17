#!/usr/bin/env bash
# Runs each named sweep scenario alone; logs ok/fail per scenario.
cd "$1"; shift; out=$1; shift
for t in "$@"; do
  s=$(date +%s)
  FM_TEST_ONLY=$t bash tests/fm-copy-sweep.test.sh > "$out.$t.log" 2>&1; rc=$?
  printf '%s rc=%s %ss\n' "$t" "$rc" "$(( $(date +%s)-s ))" >> "$out.summary"
done
