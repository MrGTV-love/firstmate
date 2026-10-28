#!/usr/bin/env bash
# Live drive of the real bin/fm-teardown.sh on a disposable landed task (fixtures built by
# the repository's own tests/fm-teardown-helpers.sh in a temp root), with the watcher's
# wait-identity cache state/.task-x1.wait-identity present. Expected: teardown succeeds and
# removes the cache with the task's other watcher state; another task's cache stays.
# Run from the gate worktree: bash <this> "$PWD"
set -u
REPO=${1:?repo}
# shellcheck source=/dev/null
. "$REPO/tests/fm-teardown-helpers.sh"
case_dir=$(make_case wait-identity-teardown)
write_meta "$case_dir" local-only ship
wt_commit "$case_dir" "fix the thing"
add_fork_with_pushed_branch "$case_dir"
printf 'fid\t100\t25\t60\t123\tpaused\tdeploy\t999\n' > "$case_dir/state/.task-x1.wait-identity"
printf 'fid\t100\t25\t60\t123\tpaused\tdeploy\t999\n' > "$case_dir/state/.other-task.wait-identity"
echo "before teardown: $(cd "$case_dir/state" && ls -a | grep wait-identity | tr '\n' ' ')"
set +e
run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"; rc=$?
set -e
echo "fm-teardown.sh exit=$rc ; last stdout line: $(tail -1 "$case_dir/stdout")"
echo "after teardown:  $(cd "$case_dir/state" && ls -a | grep wait-identity | tr '\n' ' ')"
[ ! -e "$case_dir/state/.task-x1.wait-identity" ] && echo "task-x1 cache removed: yes" || echo "task-x1 cache removed: NO"
[ -e "$case_dir/state/.other-task.wait-identity" ] && echo "other task's cache kept: yes" || echo "other task's cache kept: NO"
