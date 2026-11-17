#!/usr/bin/env bash
# Runs named cases one at a time; logs each case output and exit code.
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7K6AN82VSNGDDYFX7TVN4BF || exit 9
suite=$1; out=$2; shift 2
: > "$out"
for c in "$@"; do
  echo "=== $suite :: $c" >> "$out"
  FM_SUPERSEDENCE_CASES=/Users/charlesabrooker/firstmate/data/fm-copy-sweep-supersedence-route/cases FM_TEST_ONLY=$c bash "$suite" >> "$out" 2>&1
  echo "=== exit=$? :: $c" >> "$out"
done
