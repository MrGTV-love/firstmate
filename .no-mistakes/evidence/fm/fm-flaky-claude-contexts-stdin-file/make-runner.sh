#!/usr/bin/env bash
# make-runner.sh <source-test-file> <out-runner> <test_fn>...
# Copies the definitions (lines before the call list) of fm-turnend-guard.test.sh,
# pins lib.sh to the worktree, and appends only the named test calls.
set -eu
src=$1 out=$2; shift 2
wt=$(cd "$(dirname "$src")/.." && pwd)
start=$(awk '/^test_predicate_healthy_no_inflight$/ {print NR; exit}' "$src")
head -n $((start - 1)) "$src" | sed "s#\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh#$wt/tests/lib.sh#" > "$out"
for t in "$@"; do echo "$t" >> "$out"; done
chmod +x "$out"
