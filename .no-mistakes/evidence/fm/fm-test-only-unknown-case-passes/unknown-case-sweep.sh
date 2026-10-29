#!/usr/bin/env bash
# Run each single-case selector with a name that does not exist, at a given tree.
# Usage: unknown-case-sweep.sh <tree-root> <label>
set -u
root=$1 label=$2
cd "$root" || exit 1
env_files=$(cd tests && grep -l '^fm_test_only' *.test.sh; grep -l 'fm-watch-triage-helpers.sh' *.test.sh)
pos_files=$(cd tests && { grep -l 'fm_test_run_cases' *.test.sh; grep -l 'captain_hold_run_tests\|control_relaunch_run\|fm_lint_run\|pr_merge_run\|teardown_test_cases' *.test.sh; } | sort -u)
one() {  # <mode> <file>
  local mode=$1 f=$2 rc out
  if [ "$mode" = env ]; then
    out=$(FM_TEST_ONLY=test_renamed_away /opt/homebrew/bin/timeout 600 bash "tests/$f" 2>&1); rc=$?
  else
    out=$(/opt/homebrew/bin/timeout 600 bash "tests/$f" test_renamed_away 2>&1); rc=$?
  fi
  msg=$(printf '%s\n' "$out" | grep -m1 -E 'Unknown test case|command not found|skip' | cut -c1-110)
  printf '%-8s %-4s rc=%-3s %-48s %s\n' "$label" "$mode" "$rc" "$f" "$msg"
}
export -f one; export label
{ for f in $env_files; do echo "env $f"; done; for f in $pos_files; do echo "pos $f"; done; } \
  | sort -u | xargs -P 6 -n 2 bash -c 'one "$0" "$1"' | sort -k2,2 -k4,4
