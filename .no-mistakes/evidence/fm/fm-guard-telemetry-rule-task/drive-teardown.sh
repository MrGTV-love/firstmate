#!/usr/bin/env bash
# Live driver: real bin/fm-teardown.sh on disposable fixture worktrees (shared
# teardown fixtures). Shows which landed-work rows each outcome writes.
set -u
. "$PWD/tests/fm-teardown-helpers.sh"
show() { echo "  rows: $(jq -sc '[.[] | select(.guard=="teardown-unlanded") | {decision,rule,task,override,cleared_by}]' "$1" 2>/dev/null || echo '[]')"; }

echo "=== A: landed work (branch on fork remote), no --force ==="
case_dir=$(make_case ev-landed); write_meta "$case_dir" local-only ship
wt_commit "$case_dir" "fix the thing"; add_fork_with_pushed_branch "$case_dir"
rc=0; FM_GUARD_EVENT_LOG="$case_dir/ev.jsonl" run_teardown "$case_dir" >/dev/null 2>"$case_dir/err" || rc=$?
echo "  teardown rc=$rc"; show "$case_dir/ev.jsonl"

echo "=== B: unpushed work, no --force (refused) ==="
case_dir=$(make_case ev-unpushed); write_meta "$case_dir" local-only ship
wt_commit_file "$case_dir" unlanded.txt "unlanded work" "unpushed work"
rc=0; FM_GUARD_EVENT_LOG="$case_dir/ev.jsonl" run_teardown "$case_dir" >/dev/null 2>"$case_dir/err" || rc=$?
echo "  teardown rc=$rc; REFUSED line: $(grep -c REFUSED "$case_dir/err")"; show "$case_dir/ev.jsonl"

echo "=== C: unpushed work, --force (escape) ==="
case_dir=$(make_case ev-force); write_meta "$case_dir" local-only ship
wt_commit_file "$case_dir" unlanded.txt "unlanded work" "unpushed work"
rc=0; FM_GUARD_EVENT_LOG="$case_dir/ev.jsonl" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" >/dev/null 2>"$case_dir/err" || rc=$?
echo "  teardown rc=$rc"; show "$case_dir/ev.jsonl"
