#!/usr/bin/env bash
# Real bin/fm-teardown.sh on disposable fixture worktrees.
set -u
. "$PWD/tests/fm-teardown-helpers.sh"
show() { echo "  rows: $(jq -sc '[.[]|select(.guard=="teardown-unlanded" or .guard=="backlog-transition")|{guard,decision,rule,task,override,cleared_by}]' "$1" 2>/dev/null || echo '[]')"; }
echo "=== A landed work, no --force: expect exactly one allow, no override ==="
c=$(make_case r5-landed); write_meta "$c" local-only ship; wt_commit "$c" "fix the thing"; add_fork_with_pushed_branch "$c"
rc=0; FM_GUARD_EVENT_LOG="$c/ev" run_teardown "$c" >/dev/null 2>"$c/err" || rc=$?; echo "  rc=$rc worktree gone=$([ -e "$c/wt" ] && echo no || echo yes)"; show "$c/ev"
echo "=== B unpushed work, no --force: refused, deny, no allow ==="
c=$(make_case r5-unpushed); write_meta "$c" local-only ship; wt_commit_file "$c" u.txt "unlanded" "unpushed"
rc=0; FM_GUARD_EVENT_LOG="$c/ev" run_teardown "$c" >/dev/null 2>"$c/err" || rc=$?; echo "  rc=$rc worktree kept=$([ -e "$c/wt" ] && echo yes || echo no) REFUSED lines=$(grep -c REFUSED "$c/err")"; show "$c/ev"
echo "=== C unpushed work, --force: bypass with override, no allow ==="
c=$(make_case r5-force); write_meta "$c" local-only ship; wt_commit_file "$c" u.txt "unlanded" "unpushed"
rc=0; FM_GUARD_EVENT_LOG="$c/ev" run_teardown "$c" --force --drop-file "$(fm_test_drop_file)" >/dev/null 2>"$c/err" || rc=$?; echo "  rc=$rc"; show "$c/ev"
echo "=== D manual backlog backend: one backlog-transition bypass ==="
c=$(make_case r5-manual); write_meta "$c" local-only ship; wt_commit "$c" "fix"; add_fork_with_pushed_branch "$c"; mkdir -p "$c/config"; echo manual >"$c/config/backlog-backend"
rc=0; FM_GUARD_EVENT_LOG="$c/ev" run_teardown "$c" >/dev/null 2>"$c/err" || rc=$?; echo "  rc=$rc"; show "$c/ev"
echo "=== E write failure while refusing: same refusal ==="
c=$(make_case r5-badlog); write_meta "$c" local-only ship; wt_commit_file "$c" u.txt "unlanded" "unpushed"; mkdir "$c/logdir"
rc=0; FM_GUARD_EVENT_LOG="$c/logdir" run_teardown "$c" >/dev/null 2>"$c/err" || rc=$?; echo "  rc=$rc worktree kept=$([ -e "$c/wt" ] && echo yes || echo no) REFUSED lines=$(grep -c REFUSED "$c/err")"
