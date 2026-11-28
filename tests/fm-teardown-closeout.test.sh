#!/usr/bin/env bash
# Post-close cleanup for bin/fm-teardown.sh: leaked processes and the bounded
# reap, foreign and held copies with their closeout driver, private no-mistakes
# launch agents, Docker stacks and their retained records, Herdr projection
# journals, and secondmate delivery and retirement.
# The landed-work proof matrix lives in tests/fm-teardown.test.sh; pool slots
# and returns live in tests/fm-teardown-pool.test.sh. Shared fixtures:
# tests/fm-teardown-helpers.sh.
# Usage: bash tests/fm-teardown-closeout.test.sh [test_function_name ...]

set -u

# shellcheck source=tests/fm-teardown-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-helpers.sh"

# A landing check that could not run is not a copy that is not landed: when
# fetching the default branch fails, the copy is refused, never held, so a
# rerun can check again and release a copy that did land.
test_a_foreign_copy_whose_landing_could_not_be_checked_is_not_held() {
  local rc shape real_git
  real_git=$(command -v git)
  for shape in landed unlanded; do
    make_held_case "held-unchecked-$shape"
    if [ "$shape" = unlanded ]; then
      held_foreign_unlanded "$FOREIGN_COPY"
    fi
    printf '#!/usr/bin/env bash\necho "error: simulated forge outage" >&2\nexit 1\n' > "$FOREIGN_CASE/fakebin/gh"
    cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${2:-}" = "$FOREIGN_COPY" ] && [ "\${3:-}" = fetch ]; then
  echo "fatal: unable to access 'origin': simulated outage" >&2
  exit 128
fi
exec "$real_git" "\$@"
SH
    chmod +x "$FOREIGN_CASE/fakebin/git"
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    run_foreign_teardown rc
    expect_code 1 "$rc" "held-unchecked-$shape: a copy whose landing could not be checked must refuse the close: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "error: foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: its landing could not be checked (" \
      "$FOREIGN_CASE/stderr" "held-unchecked-$shape: the refusal did not say the landing could not be checked: $(cat "$FOREIGN_CASE/stderr")"
    assert_no_grep "is not proved landed" "$FOREIGN_CASE/stderr" "held-unchecked-$shape: the refusal calls an unchecked copy not landed"
    assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "held-unchecked-$shape: the refusal changed"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-unchecked-$shape: the task record was removed"
    [ "$(backlog_row_state "$FOREIGN_CASE")" != "done" ] || fail "held-unchecked-$shape: the backlog item was closed by a refused close"
    assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-unchecked-$shape: a refused close wrote a held-copy record"
    held_assert_untouched "held-unchecked-$shape" "$FOREIGN_CASE" "$FOREIGN_COPY"
    rm -f "$FOREIGN_CASE/fakebin/git"
    add_gh_pr_merged_for_head "$FOREIGN_CASE" "$(git -C "$FOREIGN_CASE/project" rev-parse main)"
    run_foreign_teardown rc
    if [ "$shape" = landed ]; then
      expect_code 0 "$rc" "held-unchecked-$shape: the rerun must release a copy that did land: $(cat "$FOREIGN_CASE/stderr")"
      assert_absent "$FOREIGN_COPY" "held-unchecked-$shape: the rerun did not release the landed copy"
      assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "held-unchecked-$shape: the rerun did not return the slot"
    else
      expect_code 0 "$rc" "held-unchecked-$shape: the rerun must hold a copy that really is unlanded: $(cat "$FOREIGN_CASE/stderr")"
      held_assert_closed "held-unchecked-$shape"
      assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" "held-unchecked-$shape: the rerun did not write one record line"
    fi
  done
  pass "a foreign copy whose landing could not be checked is refused with nothing removed and no record line, and a rerun releases a landed copy and holds an unlanded one"
}

# The held notices and the record are written once the task record and the own
# nested copies are gone, so a later failure, here the backlog close, still
# leaves them.
test_a_failure_after_the_point_of_no_return_still_leaves_the_held_notice_and_record() {
  local rc real_axi
  real_axi=$(command -v tasks-axi)
  make_held_case held-after-no-return
  held_foreign_unlanded "$FOREIGN_COPY"
  cat > "$FOREIGN_CASE/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = done ]; then
  echo "error: simulated backlog failure" >&2
  exit 1
fi
exec "$real_axi" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/tasks-axi"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-after-no-return: a failing backlog close must fail the run: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "its backlog item could not be closed atomically" "$FOREIGN_CASE/stderr" \
    "held-after-no-return: the run did not fail at the backlog close: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "held-after-no-return: the task record survived, so the point of no return was not passed"
  assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: its HEAD " \
    "$FOREIGN_CASE/stdout" "held-after-no-return: the held notice was lost with the later failure"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" \
    "held-after-no-return: the record does not hold exactly one line"
  held_assert_untouched "held-after-no-return" "$FOREIGN_CASE" "$FOREIGN_COPY"
  pass "a failure after the task record and own copies are gone still leaves the held notice and one record line, and the foreign copy untouched"
}

test_a_forced_close_never_holds_a_foreign_copy() {
  local rc
  make_held_case held-forced
  held_foreign_unlanded "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
  run_foreign_teardown rc
  FOREIGN_TEARDOWN_ARGS=()
  expect_code 1 "$rc" "held-forced: --force must not hold a foreign copy: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "held-forced: the refusal is not the custody refusal"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "held-forced: the task record was removed"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-forced: a refused close wrote a held-copy record"
  held_assert_untouched held-forced "$FOREIGN_CASE" "$FOREIGN_COPY"
  pass "--force waives nothing: it never holds a foreign copy and still refuses"
}

test_a_slot_with_no_foreign_copy_closes_and_returns_as_before() {
  local rc
  make_held_case held-none
  git -C "$FOREIGN_CASE/project" worktree remove "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-none: an ordinary landed close must succeed: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "held-none: the slot was not returned"
  assert_grep "teardown task-x1 complete (window firstmate:fm-task-x1, worktree $FOREIGN_SLOT)" "$FOREIGN_CASE/stdout" \
    "held-none: the ordinary completion line changed"
  assert_no_grep "deferred" "$FOREIGN_CASE/stdout" "held-none: an ordinary close mentions a deferred slot return"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "held-none: an ordinary close wrote a held-copy record"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "held-none: the task record survived"
  pass "a slot with no foreign copy closes and returns exactly as before and writes no held-copy record"
}

test_foreign_copy_named_by_an_alias_in_an_active_record_is_refused() {
  local rc
  make_foreign_copy_case foreign-alias-lease
  ln -s "$FOREIGN_COPY" "$FOREIGN_CASE/copy-alias"
  fm_write_meta "$FOREIGN_CASE/state/other.meta" "kind=ship" "worktree=$FOREIGN_CASE/copy-alias"
  run_foreign_teardown rc
  expect_code 1 "$rc" "alias-lease: a copy another active record names must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "task other's active record names it as its worktree" "$FOREIGN_CASE/stderr" \
    "alias-lease: the refusal did not name the owning record"
  assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "alias-lease: the refusal changed"
  assert_foreign_copy_untouched alias-lease
  pass "a foreign copy that another active record names through a symlink alias is refused"
}

test_half_removed_foreign_copy_is_refused_as_before() {
  local rc
  make_foreign_copy_case foreign-half-removed
  rm -f "$FOREIGN_COPY/.git"
  run_foreign_teardown rc
  expect_code 1 "$rc" "half-removed: a registered remnant without its .git must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "half-removed: the refusal changed"
  assert_present "$FOREIGN_COPY" "half-removed: the remnant was removed"
  assert_absent "$FOREIGN_CASE/closeout.log" "half-removed: the closeout driver ran"
  assert_absent "$FOREIGN_CASE/treehouse.log" "half-removed: the pool slot was returned"
  pass "a half-removed registered foreign copy refuses with the same custody refusal and nothing changes"
}

test_recycled_launcher_pid_does_not_own_a_foreign_copy() {
  local rc pid admin
  sleep 300 &
  pid=$!
  make_foreign_copy_case foreign-recycled-pid "$pid"
  admin=$(git -C "$FOREIGN_COPY" rev-parse --absolute-git-dir)
  # The lock file is older than the process, so the pid cannot be its launcher.
  fm_touch_epoch "$(( $(date +%s) - 3600 ))" "$admin/locked"
  run_foreign_teardown rc
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$rc" "recycled-pid: a live but recycled launcher pid must not block release: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "recycled-pid: the driver was not run once"
  assert_absent "$FOREIGN_COPY" "recycled-pid: the copy survived"
  pass "a live pid that started after the creation lock was written is a recycled pid and does not own the copy"
}

test_live_launcher_keeps_its_foreign_copy() {
  local rc pid
  sleep 300 &
  pid=$!
  sleep 3
  make_foreign_copy_case foreign-live-launcher "$pid"
  run_foreign_teardown rc
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 1 "$rc" "live-launcher: a launcher that predates its lock must keep the copy: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "creation-lock launcher process $pid may still be running" "$FOREIGN_CASE/stderr" \
    "live-launcher: the refusal did not name the launcher"
  assert_grep "human-only-exit: Is launcher $pid, named in the creation lock on $FOREIGN_COPY, still running, and who owns it?" "$FOREIGN_CASE/stderr" \
    "live-launcher: the question did not name the launcher and the lock"
  assert_foreign_copy_untouched live-launcher
  pass "a live launcher that started before its creation lock keeps its foreign copy"
}

# The creation lock names a launcher pid. Teardown itself ends the task's own
# session, so a launcher that is that session, or runs under it, must not hold
# the copy: retire signals the descendant that the cwd sweep cannot reach.
test_task_own_session_as_lock_launcher_does_not_block_release() {
  local rc shape
  for shape in agent child; do
    start_foreign_session_case "foreign-own-$shape" "$shape"
    run_foreign_teardown rc
    kill "$FOREIGN_LAUNCHER" 2>/dev/null && fail "own-$shape: the launcher survived teardown"
    expect_code 0 "$rc" "own-$shape: the task's own session as launcher must not block release: $(cat "$FOREIGN_CASE/stderr")"
    kill -0 "$FOREIGN_AGENT" 2>/dev/null && fail "own-$shape: the task's session survived teardown"
    assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
      "own-$shape: the driver was not run once"
    assert_absent "$FOREIGN_COPY" "own-$shape: the copy survived"
    assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "own-$shape: the slot was not returned"
    if [ "$shape" = child ]; then
      assert_grep "	TERM	$FOREIGN_LAUNCHER	" "$FOREIGN_CASE/state/task-x1.teardown-processes" \
        "own-$shape: the descendant launcher's signal was not recorded"
    fi
  done
  pass "a lock launcher that is the task's own session, or a descendant the cwd sweep cannot reach, is ended by retire and released with the slot"
}

# A live launcher outside the task's session keeps its copy untouched. One inside
# it that survives the signal and the bounded wait keeps it too, named by pid,
# after the session itself was ended.
test_unrelated_or_stubborn_lock_launcher_keeps_its_foreign_copy() {
  local rc shape
  for shape in unrelated stubborn; do
    start_foreign_session_case "foreign-held-$shape" "$shape"
    run_foreign_teardown rc
    if [ "$shape" = unrelated ]; then
      kill -0 "$FOREIGN_AGENT" 2>/dev/null || fail "held-$shape: a refused teardown stopped the task's session"
    else
      kill -0 "$FOREIGN_AGENT" 2>/dev/null && fail "held-$shape: the task's session survived retire"
      kill -0 "$FOREIGN_LAUNCHER" 2>/dev/null || fail "held-$shape: the launcher did not ignore TERM"
    fi
    kill -KILL "$FOREIGN_LAUNCHER" 2>/dev/null || true
    wait "$FOREIGN_LAUNCHER" 2>/dev/null || true
    expect_code 1 "$rc" "held-$shape: a live launcher must keep the copy: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "creation-lock launcher process $FOREIGN_LAUNCHER may still be running" "$FOREIGN_CASE/stderr" \
      "held-$shape: the refusal did not name the launcher"
    assert_foreign_copy_untouched "held-$shape"
  done
  pass "a live lock launcher outside the task's session, or one that outlives retire's signal, keeps its foreign copy and is named by pid"
}

test_process_in_foreign_copy_keeps_it() {
  local rc pid
  make_foreign_copy_case foreign-process-inside
  teardown_fixture_start "$FOREIGN_COPY" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*) if kill -0 $pid 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $pid '$FOREIGN_COPY'; fi; exit 0 ;;
esac
exit 1
SH
  run_foreign_teardown rc
  kill -0 "$pid" 2>/dev/null || fail "process-inside: teardown stopped the process running in the foreign copy"
  expect_code 1 "$rc" "process-inside: a copy with a process outside the task running in it must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "process $pid is running in it" "$FOREIGN_CASE/stderr" "process-inside: the refusal did not name the process"
  assert_grep "human-only-exit: Which task or person owns process $pid, which is running in $FOREIGN_COPY? Stop it or tell me it is yours." "$FOREIGN_CASE/stderr" \
    "process-inside: the question did not name the process"
  assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "process-inside: the refusal changed"
  assert_foreign_copy_untouched process-inside
  pass "a foreign copy with a process outside the task running in it is refused and the process is left alone"
}

# A process running in a foreign copy keeps it unless it is the task's own: here
# it descends from the task's session, whose cwd is the slot. Retire ends it
# before the sweep, which refuses any process inside a nested copy; one that
# ignores TERM keeps the copy and the session, and is named by pid.
test_task_own_process_inside_foreign_copy_is_ended_and_released() {
  local rc shape agent child pidfile i
  # shellcheck disable=SC2016 # perl, not the shell, expands these variables.
  local script='my $child = fork(); if (!$child) { $SIG{TERM} = "IGNORE" if $ARGV[2]; chdir $ARGV[1]; exec "sleep", "300"; } $SIG{CHLD} = "IGNORE"; open my $fh, ">", $ARGV[0]; print $fh $child; close $fh; sleep 300;'
  for shape in own stubborn; do
    make_foreign_copy_case "foreign-incopy-$shape"
    pidfile=$FOREIGN_CASE/child-pid
    teardown_fixture_start "$FOREIGN_SLOT" KILL perl -e "$script" "$pidfile" "$FOREIGN_COPY" "$([ "$shape" = stubborn ] && echo 1 || true)"
    agent=$TEARDOWN_FIXTURE_PID
    for i in $(seq 100); do [ -s "$pidfile" ] && break; sleep 0.05; done
    child=$(cat "$pidfile")
    cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*)
    if kill -0 $agent 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $agent '$FOREIGN_SLOT'; fi
    if kill -0 $child 2>/dev/null; then printf 'p%s\nfcwd\nn%s\n' $child '$FOREIGN_COPY'; fi
    exit 0 ;;
esac
exit 1
SH
    run_foreign_teardown rc
    if [ "$shape" = own ]; then
      expect_code 0 "$rc" "incopy-own: the task's own process inside the copy must not block release: $(cat "$FOREIGN_CASE/stderr")"
      kill -0 "$child" 2>/dev/null && fail "incopy-own: the process inside the copy survived teardown"
      kill -0 "$agent" 2>/dev/null && fail "incopy-own: the task's session survived teardown"
      assert_grep "	TERM	$child	" "$FOREIGN_CASE/state/task-x1.teardown-processes" \
        "incopy-own: the signal to the process inside the copy was not recorded"
      assert_absent "$FOREIGN_COPY" "incopy-own: the copy survived"
      assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "incopy-own: the slot was not returned"
    else
      kill -0 "$child" 2>/dev/null || fail "incopy-stubborn: the process inside the copy did not ignore TERM"
      kill -0 "$agent" 2>/dev/null || fail "incopy-stubborn: the task's session was signalled although the sweep refused"
      kill -KILL "$child" "$agent" 2>/dev/null || true
      expect_code 1 "$rc" "incopy-stubborn: a process that outlives the signal must keep the copy: $(cat "$FOREIGN_CASE/stderr")"
      assert_grep "process $child" "$FOREIGN_CASE/stderr" "incopy-stubborn: the refusal did not name the process"
      assert_foreign_copy_untouched incopy-stubborn
    fi
  done
  pass "a task-own process running inside a foreign copy is ended by retire and the copy is released, and one that outlives the signal keeps the copy by pid"
}

test_two_foreign_copies_are_released_together_or_not_at_all() {
  local rc second
  dead_launcher_pid
  make_foreign_copy_case foreign-two-copies "$FOREIGN_DEAD_PID"
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/task-x1-v3 "$second" main
  printf 'edit\n' > "$second/untracked.txt"
  run_foreign_teardown rc
  expect_code 1 "$rc" "two-copies: one unprovable copy must refuse the slot: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "contains registered copy $second" "$FOREIGN_CASE/stderr" "two-copies: the refusal did not name the unprovable copy"
  assert_present "$second/untracked.txt" "two-copies: the unprovable copy lost its file"
  assert_foreign_copy_untouched two-copies
  rm -f "$second/untracked.txt"
  run_foreign_teardown rc
  expect_code 0 "$rc" "two-copies: two landed copies must both be released: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_COPY" "two-copies: the locked copy survived"
  assert_absent "$second" "two-copies: the unlocked copy survived"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "two-copies: only the locked copy goes through the driver, once"
  assert_grep "removed landed foreign copy $FOREIGN_COPY from pool slot $FOREIGN_SLOT" "$FOREIGN_CASE/stderr" \
    "two-copies: the locked copy's removal was not reported"
  assert_grep "removed landed foreign copy $second from pool slot $FOREIGN_SLOT" "$FOREIGN_CASE/stderr" \
    "two-copies: the unlocked copy's removal was not reported"
  git -C "$FOREIGN_CASE/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v3 >/dev/null \
    || fail "two-copies: the second copy's branch was deleted"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "two-copies: the slot was not returned"
  pass "a slot's foreign copies are all proved before any is removed, and then all are released"
}

test_foreign_copy_is_released_before_the_project_lock_wait() {
  local rc lock
  dead_launcher_pid
  make_foreign_copy_case foreign-lock-order "$FOREIGN_DEAD_PID"
  lock=$(FM_HOME="$FOREIGN_CASE/home" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$ROOT" "$FOREIGN_CASE/project") \
    || fail "lock-order: cannot resolve the shared Treehouse project lock"
  cat > "$FOREIGN_CASE/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FOREIGN_CASE/treehouse.log"
case "\${1:-}" in
  return) if [ -d "$lock" ]; then echo held; else echo free; fi >> "$FOREIGN_CASE/return.lock-state" ;;
esac
exit 0
SH
  run_foreign_teardown rc FM_STUB_LOCK="$lock"
  expect_code 0 "$rc" "lock-order: a landed Vernant-locked copy must be released: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "held" "$(cat "$FOREIGN_CASE/return.lock-state" 2>/dev/null || true)" \
    "lock-order: the slot return did not run under the shared project lock, so the probe proves nothing"
  assert_equals "free" "$(cat "$FOREIGN_CASE/closeout.lock-state" 2>/dev/null || true)" \
    "lock-order: the closeout driver ran while the shared project lock was held"
  assert_absent "$FOREIGN_COPY" "lock-order: the copy survived"
  pass "the closeout driver runs before the shared project lock is taken, and the slot return still runs under it"
}

test_closeout_uses_the_slots_default_interpreter() {
  local rc
  dead_launcher_pid
  make_foreign_copy_case foreign-default-python "$FOREIGN_DEAD_PID"
  mkdir -p "$FOREIGN_SLOT/.venv/bin"
  cp "$FOREIGN_CASE/vernant-python" "$FOREIGN_SLOT/.venv/bin/python"
  run_foreign_teardown rc FM_TEARDOWN_VERNANT_PYTHON=
  expect_code 0 "$rc" "default-python: the slot's own interpreter must run the driver: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "default-python: the driver was not run once from the slot with the copy and the execute flag"
  assert_absent "$FOREIGN_COPY" "default-python: the copy survived"
  pass "without FM_TEARDOWN_VERNANT_PYTHON the driver runs under the slot's own .venv interpreter"
}

test_missing_closeout_driver_or_interpreter_leaves_the_copy_in_place() {
  local rc shape
  for shape in driver interpreter; do
    dead_launcher_pid
    make_foreign_copy_case "foreign-missing-$shape" "$FOREIGN_DEAD_PID"
    if [ "$shape" = driver ]; then
      rm -f "$FOREIGN_SLOT/scripts/git-stability/closeout_pr.py"
      run_foreign_teardown rc
    else
      run_foreign_teardown rc FM_TEARDOWN_VERNANT_PYTHON="$FOREIGN_CASE/no-such-python"
    fi
    expect_code 1 "$rc" "missing-$shape: a locked copy with no driver to release it must refuse: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: Vernant's closeout driver" "$FOREIGN_CASE/stderr" \
      "missing-$shape: the proof did not refuse the copy whose driver cannot start"
    assert_grep "is not available, so it cannot be released" "$FOREIGN_CASE/stderr" "missing-$shape: the refusal did not say what was missing"
    assert_foreign_copy_untouched "missing-$shape"
    assert_absent "$FOREIGN_CASE/state/task-x1.teardown-return-pending" "missing-$shape: a return-pending record was written before the refusal"
  done
  pass "a Vernant-locked copy whose closeout driver or interpreter is missing is refused at entry and stays"
}

test_foreign_copy_nested_in_another_is_removed_first() {
  local rc inner
  make_foreign_copy_case foreign-nested-in-foreign
  inner=$FOREIGN_COPY/.claude/worktrees/fc-inner
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/task-x1-v3 "$inner" main
  run_foreign_teardown rc
  expect_code 0 "$rc" "nested-in-foreign: a copy inside another foreign copy must not block the removal: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$inner" "nested-in-foreign: the inner copy survived"
  assert_absent "$FOREIGN_COPY" "nested-in-foreign: the outer copy survived"
  assert_grep "removed landed foreign copy $inner from pool slot $FOREIGN_SLOT" "$FOREIGN_CASE/stderr" \
    "nested-in-foreign: the inner copy's removal was not reported"
  assert_grep "removed landed foreign copy $FOREIGN_COPY from pool slot $FOREIGN_SLOT" "$FOREIGN_CASE/stderr" \
    "nested-in-foreign: the outer copy's removal was not reported"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "nested-in-foreign: the slot was not returned"
  pass "a foreign copy nested in another foreign copy is removed before the copy that holds it"
}

test_closeout_refusal_and_foreign_locks_leave_the_copy_in_place() {
  local rc shape
  for shape in driver-refuses human-lock; do
    dead_launcher_pid
    make_foreign_copy_case "foreign-$shape" "$FOREIGN_DEAD_PID"
    if [ "$shape" = human-lock ]; then
      git -C "$FOREIGN_CASE/project" worktree unlock "$FOREIGN_COPY"
      git -C "$FOREIGN_CASE/project" worktree lock --reason 'held by a human' "$FOREIGN_COPY"
      run_foreign_teardown rc
      assert_grep "locked by something other than Vernant's creation lock (held by a human)" "$FOREIGN_CASE/stderr" \
        "$shape: the refusal did not name the foreign lock"
    else
      run_foreign_teardown rc FM_STUB_CLOSEOUT=refuse
      assert_grep "Vernant's closeout driver did not release foreign copy $FOREIGN_COPY (exit 3)" "$FOREIGN_CASE/stderr" \
        "$shape: the driver refusal was not reported"
      assert_grep 'stub_refusal' "$FOREIGN_CASE/stderr" "$shape: the driver's reason was not reported"
      assert_present "$FOREIGN_CASE/closeout.log" "$shape: the driver was not asked"
    fi
    expect_code 1 "$rc" "$shape: must refuse: $(cat "$FOREIGN_CASE/stderr")"
    assert_present "$FOREIGN_COPY/.git" "$shape: the copy was removed"
    assert_absent "$FOREIGN_CASE/treehouse.log" "$shape: the pool slot was returned"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "$shape: the task record was removed"
  done
  pass "a driver refusal or a lock that is not Vernant's leaves the foreign copy, the slot and the record in place"
}

test_locked_own_nested_copy_is_released_by_the_closeout_driver() {
  local rc shape head
  for shape in enclosing reverse; do
    dead_launcher_pid
    make_own_locked_copy_case "own-locked-$shape" "$shape" "$FOREIGN_DEAD_PID"
    head=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
    run_foreign_teardown rc
    expect_code 0 "$rc" "own-locked-$shape: a landed, clean, Vernant-locked own copy must be released: $(cat "$FOREIGN_CASE/stderr")"
    assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
      "own-locked-$shape: the driver was not run once from the slot with the copy and the execute flag"
    assert_absent "$FOREIGN_COPY" "own-locked-$shape: the copy survived"
    git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -F "worktree $FOREIGN_COPY" >/dev/null \
      && fail "own-locked-$shape: the copy is still registered"
    assert_equals "$head" "$(git -C "$FOREIGN_CASE/project" rev-parse refs/heads/fm/task-x1-v2)" \
      "own-locked-$shape: the copy's branch moved"
    assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "own-locked-$shape: the slot was not returned"
    assert_absent "$FOREIGN_CASE/state/task-x1.meta" "own-locked-$shape: the task record survived"
    assert_absent "$FOREIGN_CASE/pool/1/.fm-slot-owner" "own-locked-$shape: the slot claim survived the task"
  done
  pass "a landed, clean own nested copy locked by Vernant is released through the closeout driver, removed, and the slot is returned"
}

test_locked_own_nested_copy_with_a_recycled_launcher_pid_is_released() {
  local rc pid admin
  sleep 300 &
  pid=$!
  make_own_locked_copy_case own-locked-recycled enclosing "$pid"
  admin=$(git -C "$FOREIGN_COPY" rev-parse --absolute-git-dir)
  # The lock file is older than the process, so the pid cannot be its launcher.
  fm_touch_epoch "$(( $(date +%s) - 3600 ))" "$admin/locked"
  run_foreign_teardown rc
  kill -0 "$pid" 2>/dev/null || fail "own-recycled: teardown ended the unrelated process that holds the recycled pid"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$rc" "own-recycled: a live but recycled launcher pid must not block release: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "own-recycled: the driver was not run once"
  assert_absent "$FOREIGN_COPY" "own-recycled: the copy survived"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "own-recycled: the slot was not returned"
  pass "an own copy whose lock names a pid that started after the lock was written is released by the same driver path"
}

test_live_launcher_outside_the_task_keeps_its_locked_own_copy() {
  local rc pid
  sleep 300 &
  pid=$!
  sleep 3
  make_own_locked_copy_case own-locked-live-launcher enclosing "$pid"
  run_foreign_teardown rc
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 1 "$rc" "own-live-launcher: a launcher outside the task that predates its lock must keep the copy: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "creation-lock launcher process $pid may still be running" "$FOREIGN_CASE/stderr" \
    "own-live-launcher: the refusal did not name the launcher"
  assert_own_locked_copy_untouched own-live-launcher
  pass "a live lock launcher outside the task keeps a locked own copy and is named by pid"
}

test_locked_own_nested_copy_that_is_not_proved_is_refused() {
  local rc shape
  for shape in unlanded dirty human-lock; do
    dead_launcher_pid
    make_own_locked_copy_case "own-locked-$shape" enclosing "$FOREIGN_DEAD_PID"
    case "$shape" in
      unlanded)
        printf 'unlanded\n' > "$FOREIGN_COPY/unlanded.txt"
        git -C "$FOREIGN_COPY" add unlanded.txt
        git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm 'unlanded own work'
        ;;
      dirty)
        printf 'edit\n' > "$FOREIGN_COPY/untracked.txt"
        ;;
      human-lock)
        git -C "$FOREIGN_CASE/project" worktree unlock "$FOREIGN_COPY"
        git -C "$FOREIGN_CASE/project" worktree lock --reason 'held by a human' "$FOREIGN_COPY"
        ;;
    esac
    run_foreign_teardown rc
    expect_code 1 "$rc" "own-locked-$shape: a locked own copy that is not proved must be refused: $(cat "$FOREIGN_CASE/stderr")"
    case "$shape" in
      human-lock)
        assert_grep "locked by something other than Vernant's creation lock (held by a human)" "$FOREIGN_CASE/stderr" \
          "own-locked-$shape: the refusal did not name the foreign lock"
        ;;
      dirty) assert_present "$FOREIGN_COPY/untracked.txt" "own-locked-$shape: the file was lost" ;;
    esac
    assert_own_locked_copy_untouched "own-locked-$shape"
    assert_equals "" "$(git -C "$FOREIGN_CASE/project" for-each-ref 'refs/fm/anchor/*')" \
      "own-locked-$shape: an anchor was written for a copy that was refused"
  done
  pass "a locked own copy with unlanded commits, unsaved files, or a lock that is not Vernant's is refused and nothing changes"
}

test_locked_own_nested_copy_with_unique_ignored_file_is_preserved_and_released() {
  local rc exclude preserved hash sums
  dead_launcher_pid
  make_own_locked_copy_case own-locked-ignored enclosing "$FOREIGN_DEAD_PID"
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf 'unique.dat\n' >> "$exclude"
  printf 'only here\n' > "$FOREIGN_COPY/unique.dat"
  run_foreign_teardown rc
  expect_code 0 "$rc" "own-locked-ignored: a unique ignored file must be preserved rather than refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_COPY" "own-locked-ignored: the copy survived"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "own-locked-ignored: the slot was not returned"
  preserved=$(find "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" -name unique.dat -type f 2>/dev/null | head -n 1)
  [ -n "$preserved" ] || fail "own-locked-ignored: the ignored file was not preserved in the task data directory"
  assert_equals "only here" "$(cat "$preserved")" "own-locked-ignored: the preserved file changed"
  sums="$(dirname "$(dirname "$preserved")")/meta/SHA256SUMS"
  assert_present "$sums" "own-locked-ignored: no SHA-256 manifest was written"
  hash=$(shasum -a 256 "$preserved" | awk '{print $1}')
  assert_grep "$hash  unique.dat" "$sums" "own-locked-ignored: the manifest does not record the preserved content"
  pass "a locked own copy's unique ignored file is preserved with its SHA-256 and the copy is released"
}

test_locked_own_nested_copy_stays_when_a_foreign_copy_is_refused() {
  local rc second
  dead_launcher_pid
  make_own_locked_copy_case own-locked-foreign-refused enclosing "$FOREIGN_DEAD_PID"
  second=$FOREIGN_SLOT/.claude/worktrees/fc-two
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$second" main
  fm_write_meta "$FOREIGN_CASE/state/other.meta" "kind=ship" "worktree=$second"
  run_foreign_teardown rc
  expect_code 1 "$rc" "own-foreign-refused: a foreign copy another record owns must refuse the slot: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "task other's active record names it as its worktree" "$FOREIGN_CASE/stderr" \
    "own-foreign-refused: the refusal did not name the owning record"
  assert_grep "contains registered copy $second" "$FOREIGN_CASE/stderr" "own-foreign-refused: the refusal changed"
  assert_present "$second/.git" "own-foreign-refused: the foreign copy was removed"
  assert_own_locked_copy_untouched own-foreign-refused
  pass "a foreign copy that is still refused keeps the locked own copy, the slot and the record in place"
}

test_locked_own_nested_copy_is_released_before_the_project_lock_wait() {
  local rc lock
  dead_launcher_pid
  make_own_locked_copy_case own-lock-order enclosing "$FOREIGN_DEAD_PID"
  lock=$(FM_HOME="$FOREIGN_CASE/home" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$ROOT" "$FOREIGN_CASE/project") \
    || fail "own-lock-order: cannot resolve the shared Treehouse project lock"
  cat > "$FOREIGN_CASE/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FOREIGN_CASE/treehouse.log"
case "\${1:-}" in
  return) if [ -d "$lock" ]; then echo held; else echo free; fi >> "$FOREIGN_CASE/return.lock-state" ;;
esac
exit 0
SH
  run_foreign_teardown rc FM_STUB_LOCK="$lock"
  expect_code 0 "$rc" "own-lock-order: a landed Vernant-locked own copy must be released: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "held" "$(cat "$FOREIGN_CASE/return.lock-state" 2>/dev/null || true)" \
    "own-lock-order: the slot return did not run under the shared project lock, so the probe proves nothing"
  assert_equals "free" "$(cat "$FOREIGN_CASE/closeout.lock-state" 2>/dev/null || true)" \
    "own-lock-order: the closeout driver ran while the shared project lock was held"
  assert_absent "$FOREIGN_COPY" "own-lock-order: the copy survived"
  pass "the closeout driver releases a locked own copy before the shared project lock is taken, and the slot return still runs under it"
}

test_closeout_refusal_reports_tail_and_preserves_complete_output() {
  local rc ownership length n output_file line log
  for ownership in foreign own; do
    for length in long short; do
      dead_launcher_pid
      if [ "$ownership" = own ]; then
        make_own_locked_copy_case "closeout-output-$ownership-$length" enclosing "$FOREIGN_DEAD_PID"
      else
        make_foreign_copy_case "closeout-output-$ownership-$length" "$FOREIGN_DEAD_PID"
      fi
      if [ "$length" = long ]; then
        printf '.env warning: leading diagnostic must not hide the refusal\n' > "$FOREIGN_CASE/driver-output"
        for n in $(seq 1 40); do
          printf 'warning %s: %0100d\n' "$n" 0 >> "$FOREIGN_CASE/driver-output"
        done
      else
        printf 'short closeout diagnostic\n' > "$FOREIGN_CASE/driver-output"
      fi
      printf 'actual refusal after warnings\n\n' >> "$FOREIGN_CASE/driver-output"
      cp "$FOREIGN_CASE/driver-output" "$FOREIGN_CASE/expected-output"
      printf '%s\n' '{"allowed": false, "reason": "stub_refusal"}' >> "$FOREIGN_CASE/expected-output"
      run_foreign_teardown rc FM_STUB_CLOSEOUT=refuse FM_STUB_CLOSEOUT_OUTPUT="$FOREIGN_CASE/driver-output"
      expect_code 1 "$rc" "$ownership-$length: driver refusal must retain teardown's exit code"
      assert_grep '(exit 3)' "$FOREIGN_CASE/stderr" "$ownership-$length: driver exit code was lost"
      assert_grep 'actual refusal after warnings' "$FOREIGN_CASE/stderr" "$ownership-$length: warning hid the real refusal"
      if [ "$length" = long ]; then
        assert_no_grep '.env warning: leading diagnostic' "$FOREIGN_CASE/stderr" "$ownership-$length: refusal printed the head instead of the tail"
      else
        assert_grep 'short closeout diagnostic' "$FOREIGN_CASE/stderr" "$ownership-$length: short output was truncated"
      fi
      output_file=
      while IFS= read -r line; do
        case "$line" in *'full output: '*) output_file=${line##*full output: } ;; esac
      done < "$FOREIGN_CASE/stderr"
      case "$output_file" in
        "$FOREIGN_CASE/data/task-x1/"*) ;;
        *) fail "$ownership-$length: refusal did not name output in the task's data directory" ;;
      esac
      assert_present "$output_file" "$ownership-$length: named output file is missing"
      cmp -s "$FOREIGN_CASE/expected-output" "$output_file" || fail "$ownership-$length: saved output is not byte-identical to the driver's complete output"
      assert_present "$FOREIGN_COPY/.git" "$ownership-$length: refusal removed the copy"
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "$ownership-$length: refusal removed the task record"
      assert_absent "$FOREIGN_CASE/treehouse.log" "$ownership-$length: refusal returned the slot"
    done
    dead_launcher_pid
    if [ "$ownership" = own ]; then
      make_own_locked_copy_case "closeout-output-$ownership-success" enclosing "$FOREIGN_DEAD_PID"
    else
      make_foreign_copy_case "closeout-output-$ownership-success" "$FOREIGN_DEAD_PID"
    fi
    printf 'successful closeout diagnostic\n' > "$FOREIGN_CASE/driver-output"
    run_foreign_teardown rc FM_STUB_CLOSEOUT_OUTPUT="$FOREIGN_CASE/driver-output"
    expect_code 0 "$rc" "$ownership: successful closeout must still succeed"
    assert_no_grep 'successful closeout diagnostic' "$FOREIGN_CASE/stderr" "$ownership: successful driver output was printed"
    assert_no_grep 'full output:' "$FOREIGN_CASE/stderr" "$ownership: successful closeout printed a refusal log"
    for log in "$FOREIGN_CASE/data/task-x1"/vernant-closeout.*; do
      assert_absent "$log" "$ownership: successful closeout left a durable output file"
    done
  done
  pass 'own and foreign closeout refusals show the tail and save byte-identical full output; short output stays complete and successful output stays silent without a durable log'
}

test_closeout_driver_refusal_leaves_a_locked_own_copy_and_its_records() {
  local rc shape
  for shape in enclosing reverse; do
    dead_launcher_pid
    make_own_locked_copy_case "own-driver-refuses-$shape" "$shape" "$FOREIGN_DEAD_PID"
    run_foreign_teardown rc FM_STUB_CLOSEOUT=refuse
    expect_code 1 "$rc" "own-driver-refuses-$shape: a driver refusal must refuse the teardown: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "Vernant's closeout driver did not release own nested copy $FOREIGN_COPY (exit 3)" "$FOREIGN_CASE/stderr" \
      "own-driver-refuses-$shape: the driver refusal was not reported"
    assert_grep 'stub_refusal' "$FOREIGN_CASE/stderr" "own-driver-refuses-$shape: the driver's reason was not reported"
    assert_present "$FOREIGN_CASE/closeout.log" "own-driver-refuses-$shape: the driver was not asked"
    assert_present "$FOREIGN_COPY/.git" "own-driver-refuses-$shape: the copy was removed"
    git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -F "worktree $FOREIGN_COPY" >/dev/null \
      || fail "own-driver-refuses-$shape: the copy is no longer registered"
    git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -A4 -F "worktree $FOREIGN_COPY" | grep -q '^locked' \
      || fail "own-driver-refuses-$shape: the copy is no longer locked"
    assert_absent "$FOREIGN_CASE/treehouse.log" "own-driver-refuses-$shape: the pool slot was returned"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "own-driver-refuses-$shape: the task record was removed"
    cmp -s "$FOREIGN_CASE/treehouse-state.before" "$FOREIGN_CASE/pool/treehouse-state.json" \
      || fail "own-driver-refuses-$shape: Treehouse's lease record changed"
    cmp -s "$FOREIGN_CASE/slot-owner.before" "$FOREIGN_CASE/pool/1/.fm-slot-owner" \
      || fail "own-driver-refuses-$shape: the slot claim changed"
  done
  pass "a closeout driver refusal leaves a locked own copy, the slot claim, the lease and the task record in place"
}


# --- Kept own copies (bin/fm-teardown-nested-lib.sh "Kept own copies") -----------------------
#
# When Vernant's closeout driver keeps an own nested copy (exit 3 with
# cleanup_ignored_payload_archived_tree_retained), teardown runs no destructive step on it and
# only (a) proves it landed and clean, (b) proves its unique ignored files saved (the driver's
# verified archive and the task's preserve), (c) writes one record with the driver's answer and
# (d) closes when (a) and (b) hold. The helper-level cases below call the library functions
# directly in a scratch directory (a scratch Git repository stands for the copy) with the
# driver, the creation lock and the landed-work test as controlled stand-ins; the cases after
# them run bin/fm-teardown.sh on the teardown fixture.

# kept_assert_lacks <text> <file> <message>: <file> is a readable regular file that does not
# hold <text>. Unlike the shared assert_no_grep (tests/lib.sh), a missing or unreadable file
# fails here instead of passing as "no match"; the shared helper is left as it is because 63
# suites call it and some pass a file that may rightly be absent.
kept_assert_lacks() {
  { [ -f "$2" ] && [ -r "$2" ]; } || fail "$3 (the file $2 to search is missing or unreadable)"
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# kept_helper_env: the shell text a helper-level case evals in its subshell: the libraries
# bin/fm-teardown.sh sources for this route, then stand-ins for the creation lock (a file in
# the case directory), the landed-work test and the telemetry, and a closeout driver stand-in
# that counts its calls in $KC/calls, writes one tar per call in $KC/tars and answers with the
# JSON in $KC/answer, in which @ARCHIVE@ and @SHA@ stand for the tar it wrote and its SHA-256.
kept_helper_env() {
  cat <<'SH'
set +e
for l in fm-task-copy-lib fm-lock-lib fm-refuse-lib fm-teardown-nested-lib; do
  # shellcheck source=/dev/null
  . "$ROOT/bin/$l.sh" || exit 9
done
ID=task-x1
DATA=$KC/data
TEARDOWN_NESTED_COPIES=("$KC/copy")
teardown_copy_lock_file() {
  TEARDOWN_FOREIGN_LOCK_FILE=$KC/lock
  TEARDOWN_FOREIGN_LOCK=$(cat "$KC/lock")
  return 0
}
teardown_vernant_lock_pid() { printf '%s\n' 1; }
teardown_landed() { [ ! -e "$KC/unlanded" ]; }
teardown_own_nested_other_repos() { return 0; }
teardown_friction_outcome() { :; }
report_worktree_dirt() { :; }
teardown_refuse_copy() { printf 'REFUSED: %s\n' "$2" >&2; return 1; }
teardown_foreign_copy_present() { return 1; }
teardown_closeout_ready_in() { return 0; }
teardown_run_closeout() {
  local n tar sha
  # A plan call (Main 2056) answers like the real driver for a tree with unique ignored files,
  # unless $KC/plan-answer and $KC/plan-exit say otherwise; it is counted in $KC/plan-calls.
  if [ "${3:-}" = plan ]; then
    printf '%s\n' "$2" >> "$KC/plan-calls"
    TEARDOWN_CLOSEOUT_STDOUT=$(cat "$KC/plan-answer" 2>/dev/null || printf '%s' '{"allowed": true, "ignored_payload_disposition": "archive_then_retain_tree"}')
    TEARDOWN_CLOSEOUT_OUT=$TEARDOWN_CLOSEOUT_STDOUT
    return "$(cat "$KC/plan-exit" 2>/dev/null || echo 0)"
  fi
  n=$(( $(cat "$KC/calls" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$n" > "$KC/calls"
  mkdir -p "$KC/tars"
  tar=$KC/tars/$n.tar
  printf 'archive %s\n' "$n" > "$tar"
  sha=$(teardown_ignored_sha256 "$tar")
  [ ! -e "$KC/after" ] || . "$KC/after"
  TEARDOWN_CLOSEOUT_STDOUT=$(sed -e "s#@ARCHIVE@#$tar#g" -e "s#@SHA@#$sha#g" "$KC/answer")
  TEARDOWN_CLOSEOUT_OUT=$TEARDOWN_CLOSEOUT_STDOUT
  return "$(cat "$KC/exit" 2>/dev/null || echo 3)"
}
# $KC/after-preserve, when present, runs right after the product's own preserve writer
# (whichever name it has), to change the copy or the preserve at that boundary.
if [ -e "$KC/after-preserve" ]; then
  for kept_fn in teardown_own_preserve teardown_preserve_ignored; do
    declare -F "$kept_fn" >/dev/null || continue
    eval "kept_orig_$(declare -f "$kept_fn")"
    eval "$kept_fn() { kept_orig_$kept_fn \"\$@\"; local r=\$?; . \"\$KC/after-preserve\"; return \$r; }"
    break
  done
fi
SH
}

# kept_helper_case <dir>: a scratch copy (a Git repository with one commit and one ignored file
# preservation selects, notes/unique.dat), a creation-lock file and the recorded answer shape of
# the driver for it (two unique .claude paths and a verified archive).
kept_helper_case() {
  local kc=$1
  mkdir -p "$kc/copy/notes" "$kc/copy/.claude/channel-outbox" "$kc/data"
  git -C "$kc/copy" init -q
  printf 'tracked\n' > "$kc/copy/tracked.txt"
  git -C "$kc/copy" add tracked.txt
  git -C "$kc/copy" -c user.email=t@t -c user.name=t commit -qm base
  printf '%s\n' '.claude/' 'notes/' >> "$kc/copy/.git/info/exclude"
  printf 'only here\n' > "$kc/copy/notes/unique.dat"
  printf 'one\n' > "$kc/copy/.claude/channel-outbox/a.jsonl"
  printf 'vernant-session-active owner=launcher:1 launcher=1\n' > "$kc/lock"
  kept_helper_answer "$kc" '[".claude/channel-outbox/a.jsonl"]' 1
}

# kept_helper_answer <dir> <unique-json> <path-count> [<archive-path-json>]: the driver's answer.
kept_helper_answer() {
  local copy
  copy=$(cd "$1/copy" && pwd -P)
  printf '{"allowed": false, "ignored_payload_disposition": "archive_then_retain_tree", "ignored_payload_preservation": [{"archive_path": %s, "archive_sha256": "@SHA@", "path_count": %s, "restore_verified": true, "stage": "ordinary_cleanup"}], "reason": "cleanup_ignored_payload_archived_tree_retained", "retained_worktree_path": "%s", "tracked_uncovered_paths": [], "uncovered_paths": [], "untracked_uncovered_paths": [], "unique_ignored_paths": %s}\n' \
    "${4:-\"@ARCHIVE@\"}" "$3" "$copy" "$2" > "$1/answer"
}

# kept_helper_dispose <dir> <runs>: runs teardown_own_copy_dispose <runs> times, each in a fresh
# shell (a new teardown run), and prints one line per run: its exit status, whether it closed
# around the copy, and the driver calls so far.
kept_helper_dispose() {
  local kc=$1 runs=$2 run copy
  copy=$(cd "$kc/copy" && pwd -P)
  for run in $(seq 1 "$runs"); do
    KC=$kc ROOT=$ROOT COPY=$copy bash -c "$(kept_helper_env)"'
TEARDOWN_NESTED_COPIES=("$COPY")
# A product whose dispose needs the proof'"'"'s lock note (round 4) gets it here, so the round-4
# product is judged on the same path; the current product has no such note.
! declare -F teardown_lock_proved_note >/dev/null || { teardown_copy_lock_file "$COPY"; teardown_lock_proved_note "$COPY"; }
teardown_own_copy_dispose "$KC" "$COPY" 2>>"$KC/stderr"
rc=$?
kept=no
! teardown_copy_retained "$COPY" || kept=yes
printf "rc=%s kept=%s calls=%s\n" "$rc" "$kept" "$(cat "$KC/calls" 2>/dev/null || echo 0)"
' | tee -a "$kc/runs"
  done
  # VC: each run's observation, written by the run itself, when FM_RETAINED_EVIDENCE names a file.
  if [ -n "${FM_RETAINED_EVIDENCE:-}" ]; then
    printf '%s | case=%s | runs: %s | tars=%s | preserves=%s | refusal-records=%s | causes: %s\n' \
      "${FUNCNAME[1]:-?}" "${kc##*/}" "$(tail -n "$runs" "$kc/runs" | paste -sd ';' -)" \
      "$(find "$kc/tars" -name '*.tar' 2>/dev/null | wc -l | tr -d ' ')" \
      "$(find "$kc/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')" \
      "$(find "$kc/data/task-x1/closeout-refused" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')" \
      "$(grep -o 'REFUSED: .\{0,160\}' "$kc/stderr" 2>/dev/null | tail -n 2 | paste -sd '|' -)" >> "$FM_RETAINED_EVIDENCE"
  fi
}

# (c) and (d) helper level, the controls of every case below: a valid kept answer closes around
# the copy with one driver call, the record carries the answer and the state, the copy is not
# changed, and a second run judges the record again without the driver.
test_kept_copy_helper_a_valid_answer_is_recorded_once_and_judged_again_without_the_driver() {
  local tmp kc out rec before after
  tmp=$(fm_test_tmproot kept-helper-valid)
  kc=$tmp/case
  kept_helper_case "$kc"
  before=$(cd "$kc/copy" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | xargs shasum -a 256)
  out=$(kept_helper_dispose "$kc" 2)
  assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-valid: a valid kept answer must close once and be judged again without the driver: $(cat "$kc/stderr")"
  rec=$(find "$kc/data/copy-sweep/retained" -type f | head -n 1)
  assert_present "$rec" "kept-helper-valid: no record was written"
  assert_equals "copy=$(cd "$kc/copy" && pwd -P)" "$(sed -n 2p "$rec")" "kept-helper-valid: the record does not name the copy"
  assert_equals "task slot preserve reason recorded-at head status-sha256 payload-sha256 answer-base64" "$(sed -n '5,$p' "$rec" | sed 's/=.*//' | paste -sd ' ' -)" "kept-helper-valid: the record does not hold exactly its fields"
  assert_equals "$kc/tars/1.tar" "$(sed -n 's/^answer-base64=//p' "$rec" | perl -MMIME::Base64 -0777 -ne 'print decode_base64($_)' | jq -r '.ignored_payload_preservation[-1].archive_path')" "kept-helper-valid: the record does not carry the driver's answer"
  after=$(cd "$kc/copy" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | xargs shasum -a 256)
  assert_equals "$before" "$after" "kept-helper-valid: the kept copy changed"
  rm -rf "$tmp"
  pass "a valid kept answer is recorded once with the answer and the state, closes around the unchanged copy, and is judged again on the next run without the driver"
}

# F6 (1), (b): an answer that keeps the copy but names an empty unique path, or a recorded archive
# whose SHA-256 does not match, inside the copy, or of a different path count, is recorded at once
# and refused; the unchanged retry refuses again from the record and asks the driver nothing.
test_kept_copy_helper_an_invalid_kept_answer_is_recorded_and_never_asked_again() {
  local tmp kc out shape
  tmp=$(fm_test_tmproot kept-helper-invalid)
  for shape in empty-path wrong-sha inside-copy count; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    case "$shape" in
      empty-path) kept_helper_answer "$kc" '[""]' 1 ;;
      wrong-sha) sed -i.bak 's/@SHA@/0000000000000000000000000000000000000000000000000000000000000000/' "$kc/answer" ;;
      inside-copy)
        # The stand-in names a copy of its tar placed in the copy's own .git folder: inside the
        # copy, and a change neither its status nor its payload fingerprint sees.
        # shellcheck disable=SC2016 # expanded by the stand-in driver's shell.
        printf 'cp "$tar" "$KC/copy/.git/in.tar"; tar=$KC/copy/.git/in.tar; sha=$(teardown_ignored_sha256 "$tar")\n' > "$kc/after"
        ;;
      count) kept_helper_answer "$kc" '[".claude/channel-outbox/a.jsonl"]' 2 ;;
    esac
    out=$(kept_helper_dispose "$kc" 3)
    assert_equals $'rc=1 kept=no calls=1\nrc=1 kept=no calls=1\nrc=1 kept=no calls=1' "$out" "kept-helper-invalid-$shape: an invalid kept answer must refuse and never ask the driver again: $(cat "$kc/stderr")"
    assert_equals 1 "$(find "$kc/data/copy-sweep/retained" -type f | wc -l | tr -d ' ')" "kept-helper-invalid-$shape: the kept answer was not recorded once"
    assert_equals 1 "$(find "$kc/tars" -name '*.tar' | wc -l | tr -d ' ')" "kept-helper-invalid-$shape: more than one archive was written"
    assert_grep 'REFUSED' "$kc/stderr" "kept-helper-invalid-$shape: the refusal named no cause"
    assert_present "$kc/copy/notes/unique.dat" "kept-helper-invalid-$shape: the copy lost a file"
  done
  rm -rf "$tmp"
  pass "a kept answer with an empty path, an archive whose hash does not match, an archive inside the copy or a wrong path count is recorded once and refused, and two unchanged retries ask the driver nothing"
}

# F6 (2), (c): the driver is asked only when its answer can be recorded. A record folder that is
# searchable but not writable, a record that exists but cannot be read, and a copy whose
# repository cannot be read each refuse before the driver; the repaired state asks it once.
test_kept_copy_helper_the_driver_is_asked_only_when_its_answer_can_be_recorded() {
  local tmp kc out shape rec
  tmp=$(fm_test_tmproot kept-helper-unrecordable)
  for shape in unwritable-folder unreadable-record unreadable-copy; do
    # A permission bit does not stop root, so the two permission shapes need another user.
    case "$shape" in unwritable-folder|unreadable-record) [ "$(id -u)" != 0 ] || continue ;; esac
    kc=$tmp/$shape
    kept_helper_case "$kc"
    mkdir -p "$kc/data/copy-sweep/retained"
    rec=$kc/data/copy-sweep/retained/$(printf '%s' "$(cd "$kc/copy" && pwd -P)" | shasum -a 256 | awk '{print $1}')
    case "$shape" in
      unwritable-folder) chmod 555 "$kc/data/copy-sweep/retained" ;;
      unreadable-record) printf 'x\n' > "$rec"; chmod 000 "$rec" ;;
      unreadable-copy) mv "$kc/copy/.git" "$kc/copy/.git-aside" ;;
    esac
    out=$(kept_helper_dispose "$kc" 2)
    assert_equals $'rc=1 kept=no calls=0\nrc=1 kept=no calls=0' "$out" "kept-helper-unrecordable-$shape: the driver was asked while its answer could not be recorded: $(cat "$kc/stderr")"
    assert_absent "$kc/tars" "kept-helper-unrecordable-$shape: an archive was written"
    case "$shape" in
      unwritable-folder) chmod 755 "$kc/data/copy-sweep/retained" ;;
      unreadable-record) chmod 644 "$rec"; rm -f "$rec" ;;
      unreadable-copy) mv "$kc/copy/.git-aside" "$kc/copy/.git" ;;
    esac
    out=$(kept_helper_dispose "$kc" 2)
    assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-unrecordable-$shape: the repaired state did not ask the driver exactly once: $(cat "$kc/stderr")"
  done
  rm -rf "$tmp"
  pass "a record folder that cannot be written, a record that cannot be read and a copy whose repository cannot be read each refuse before the driver, and the repaired state asks it once"
}

# (a) and (d) from the record: a kept copy refused because it is not landed stays refused on
# the unchanged retry without the driver, and closes without the driver once its cause has gone.
# A preserve that lost a selected file is rebuilt by the next run's preservation and the record
# then closes, again without the driver.
test_kept_copy_helper_a_refused_kept_copy_is_judged_again_from_its_record() {
  local tmp kc out
  tmp=$(fm_test_tmproot kept-helper-rejudge)
  kc=$tmp/unlanded
  kept_helper_case "$kc"
  : > "$kc/unlanded"
  out=$(kept_helper_dispose "$kc" 2)
  assert_equals $'rc=1 kept=no calls=1\nrc=1 kept=no calls=1' "$out" "kept-helper-rejudge-unlanded: an unlanded kept copy must refuse and not be asked again: $(cat "$kc/stderr")"
  assert_grep 'not landed' "$kc/stderr" "kept-helper-rejudge-unlanded: the refusal did not name the cause"
  rm -f "$kc/unlanded"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-rejudge-unlanded: the landed copy did not close from its record: $(cat "$kc/stderr")"
  kc=$tmp/preserve
  kept_helper_case "$kc"
  # shellcheck disable=SC2016 # expanded by the stand-in driver's shell.
  printf 'rm -f "$DATA/$ID/nested-copy-preserved/"*/files/notes/unique.dat\n' > "$kc/after"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=1 kept=no calls=1' "$out" "kept-helper-rejudge-preserve: a preserve without a selected file must refuse: $(cat "$kc/stderr")"
  assert_grep 'does not hold every ignored file' "$kc/stderr" "kept-helper-rejudge-preserve: the refusal did not name the preserve"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-rejudge-preserve: the rebuilt preserve did not close from the record: $(cat "$kc/stderr")"
  rm -rf "$tmp"
  pass "a refused kept copy is judged again from its record without the driver: it stays refused while its cause holds and closes once the cause has gone"
}

# Main 1889: on a retry whose record matches, the kept copy is no swept root of the retire step:
# no run is concluded, no agent retired and no process scanned or signalled in it, while every
# other root is swept as before. The retire phase of teardown_nested_slot runs with its steps
# replaced by recorders.
test_kept_copy_helper_the_retire_step_leaves_a_matching_kept_copy_out() {
  local tmp log
  tmp=$(fm_test_tmproot kept-helper-retire)
  mkdir -p "$tmp/wt" "$tmp/slot/kept" "$tmp/slot/other" "$tmp/tasktmp"
  log=$tmp/log
  # The extraction runs outside the -c text: bash 3.2 misparses a parenthesis in a sed
  # pattern inside eval "$(...)".
  sed -n '/^teardown_nested_slot() {/,/^}/p' "$ROOT/bin/fm-teardown.sh" > "$tmp/fn.sh"
  KC=$tmp ROOT=$ROOT LOG=$log bash -c '
set +e
for l in fm-task-copy-lib fm-lock-lib fm-refuse-lib fm-teardown-nested-lib; do . "$ROOT/bin/$l.sh" || exit 9; done
. "$KC/fn.sh"
WT=$KC/wt; TEARDOWN_RETURN_SLOT=$KC/slot; TASK_TMP=$KC/tasktmp
TEARDOWN_NESTED_COPIES=("$KC/slot/kept" "$KC/slot/other")
conclude_task_no_mistakes_run() { printf "conclude %s\n" "$1" >> "$LOG"; }
retire_task_private_nm_launch_agents() { printf "agents %s\n" "$1" >> "$LOG"; }
teardown_foreign_procs_retire() { printf "foreign-procs\n" >> "$LOG"; }
reap_task_worktree_processes() { shift; printf "reap %s\n" "$*" >> "$LOG"; }
teardown_retained_copy_held() { [ "$1" = "$KC/slot/kept" ]; }
teardown_retained_matches() { [ "$1" = "$KC/slot/kept" ]; }
teardown_nested_slot retire
' 2>"$tmp/stderr"
  kept_assert_lacks "$tmp/slot/kept" "$log" "kept-helper-retire: the retire step reached the matching kept copy: $(cat "$log")"
  assert_grep "conclude $tmp/slot/other" "$log" "kept-helper-retire: another nested copy was not swept: $(cat "$log" "$tmp/stderr")"
  assert_grep "conclude $tmp/wt" "$log" "kept-helper-retire: the task's worktree was not swept"
  assert_grep "reap $tmp/wt $tmp/slot $tmp/slot/other $tmp/tasktmp" "$log" "kept-helper-retire: the reaper's roots are not the other roots"
  rm -rf "$tmp"
  pass "on a retry whose record matches, the retire step concludes, retires and reaps every root but the kept copy"
}

# Main 1889: on a retry whose record matches, the proof of the kept copy still runs (and still
# refuses what it refuses), but nothing it queues for the retire signal is kept; another locked
# own copy's queue is kept.
test_kept_copy_helper_the_proof_queues_no_signal_for_a_matching_kept_copy() {
  local tmp out
  tmp=$(fm_test_tmproot kept-helper-queue)
  mkdir -p "$tmp/kept" "$tmp/other"
  out=$(KC=$tmp ROOT=$ROOT bash -c '
set +e
for l in fm-task-copy-lib fm-lock-lib fm-refuse-lib fm-teardown-nested-lib; do . "$ROOT/bin/$l.sh" || exit 9; done
TEARDOWN_NESTED_COPIES=("$KC/kept" "$KC/other")
TEARDOWN_FOREIGN_PROCS=()
printf "vernant-session-active owner=launcher:1 launcher=1\n" > "$KC/lock"
teardown_copy_lock_file() { TEARDOWN_FOREIGN_LOCK_FILE=$KC/lock; TEARDOWN_FOREIGN_LOCK=$(cat "$KC/lock"); return 0; }
teardown_vernant_lock_pid() { printf "1\n"; }
teardown_foreign_copy_unowned() { TEARDOWN_FOREIGN_PROCS+=("4242	identity	$1"); return 0; }
teardown_retained_copy_held() { [ "$1" = "$KC/kept" ]; }
teardown_retained_matches() { [ "$1" = "$KC/kept" ]; }
teardown_refuse_copy() { printf "REFUSED: %s\n" "$2" >&2; return 1; }
teardown_closeout_ready_in() { return 0; }
teardown_run_closeout() { TEARDOWN_CLOSEOUT_STDOUT="{\"allowed\": true}"; TEARDOWN_CLOSEOUT_OUT=$TEARDOWN_CLOSEOUT_STDOUT; return 0; }
teardown_own_locked_copies_prove; rc=$?
printf "rc=%s\n" "$rc"
printf "%s\n" "${TEARDOWN_FOREIGN_PROCS[@]}"
' 2>&1)
  assert_equals "rc=0"$'\n'"4242	identity	$tmp/other" "$out" "kept-helper-queue: the proof kept a signal queued for the matching kept copy, or dropped another copy's"
  rm -rf "$tmp"
  pass "on a retry whose record matches, the kept copy's proof runs but queues nothing for the retire signal, and another copy's queue stays"
}

# F7, sweep side: a retained receipt that is not a regular readable file (here a readable
# directory) is never stale, so --apply never clears it, and another home's such receipt holds
# the copy; a regular matching receipt is the control, and a receipt whose copy is gone is stale.
test_kept_copy_helper_a_receipt_that_is_not_a_regular_file_still_holds_the_copy() {
  local tmp out
  tmp=$(fm_test_tmproot kept-helper-receipt)
  mkdir -p "$tmp/copy" "$tmp/own/data" "$tmp/other/state" "$tmp/other/data/copy-sweep/retained"
  git -C "$tmp/copy" init -q
  sed -n '/^receipt_is_stale() {/,/^}/p; /^other_home_dir_blocked() {/,/^}/p; /^other_home_retained() {/,/^}/p' "$ROOT/bin/fm-copy-sweep.sh" > "$tmp/fn.sh"
  out=$(KC=$tmp ROOT=$ROOT bash -c '
set +e
for l in fm-task-copy-lib fm-lock-lib fm-refuse-lib fm-teardown-nested-lib; do . "$ROOT/bin/$l.sh" || exit 9; done
. "$KC/fn.sh"
printf "vernant-session-active owner=launcher:1 launcher=1\n" > "$KC/lock"
teardown_copy_lock_file() { TEARDOWN_FOREIGN_LOCK_FILE=$KC/lock; return 0; }
DATA_DIR=$KC/own/data; CHECK_ID=copy-sweep
FM_LOCAL_FIRSTMATE_STATES=("$KC/other/state")
copy=$(cd "$KC/copy" && pwd -P)
rec=$(teardown_retained_receipt "$KC/other/data" "$copy")
printf "lock-sha256=%s\ncopy=%s\nidentity=%s\nkept\n" "$(teardown_ignored_sha256 "$KC/lock")" "$copy" "$(copy_identity "$copy")" > "$rec"
receipt_is_stale "$rec"; printf "regular-stale=%s\n" "$?"
CLASS=; other_home_retained "$copy"; printf "regular-held=%s %s\n" "$?" "$CLASS"
rm -f "$rec"; mkdir "$rec"
receipt_is_stale "$rec"; printf "directory-stale=%s\n" "$?"
CLASS=; other_home_retained "$copy"; printf "directory-held=%s %s\n" "$?" "$CLASS"
rmdir "$rec"
printf "lock-sha256=%s\ncopy=%s/gone\nidentity=1:1\nkept\n" "$(teardown_ignored_sha256 "$KC/lock")" "$copy" > "$KC/gone-receipt"
receipt_is_stale "$KC/gone-receipt"; printf "gone-stale=%s\n" "$?"
' 2>/dev/null)
  assert_equals $'regular-stale=1\nregular-held=0 HELD-LOCKED\ndirectory-stale=1\ndirectory-held=0 HELD-LOCKED\ngone-stale=0' "$out" "kept-helper-receipt: a receipt that is not a regular file did not hold the copy, or a control changed"
  rm -rf "$tmp"
  pass "a retained receipt that is not a regular readable file is never stale and another home's such receipt holds the copy, while a matching receipt holds and a gone copy's receipt is stale"
}

# kept_tree <dir>: one line per file, symlink and FIFO under <dir> (type, path, SHA-256 or the
# link target's bytes in hex), sorted, read independently of the product.
kept_tree() {
  [ -d "$1" ] || { echo "absent"; return 0; }
  (cd "$1" && perl -MFile::Find -MDigest::SHA -e '
    my @l;
    find({ no_chdir => 1, wanted => sub {
      my $p = $File::Find::name; return if $p eq ".";
      if (-l $p) { push @l, "L $p " . unpack("H*", readlink $p) }
      elsif (-f $p) { open(my $f, "<:raw", $p) or die; push @l, "F $p " . Digest::SHA->new(256)->addfile($f)->hexdigest }
      elsif (-p $p) { push @l, "P $p" }
    } }, ".");
    print "$_\n" for sort @l;')
}

# kept_preserve_base <dir>: the first preserve directory of the case's copy.
kept_preserve_base() {
  printf '%s/data/task-x1/nested-copy-preserved/%s\n' "$1" "$(printf '%s' "$(cd "$1/copy" && pwd -P)" | shasum -a 256 | awk '{print $1}')"
}

# Item 1 (C2 unchanged, closed end state): a retry of a task whose close completed around a kept
# copy is told it is already closed, naming the record, before any copy lookup; a task record
# that is damaged rather than gone, a task record still present, a pending backlog close, or a
# kept copy's record without the mark of a completed close is not a completed close.
test_kept_copy_helper_a_retry_of_a_closed_task_says_it_is_already_closed() {
  local tmp kc out shape
  tmp=$(fm_test_tmproot kept-helper-closed)
  for shape in closed meta-damaged meta-present close-pending not-marked; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    out=$(kept_helper_dispose "$kc" 1)
    assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-closed-$shape: the kept copy did not close: $(cat "$kc/stderr")"
    mkdir -p "$kc/state"
    case "$shape" in
      meta-damaged) mkdir "$kc/state/task-x1.meta" ;;
      meta-present) printf 'kind=ship\n' > "$kc/state/task-x1.meta" ;;
      close-pending) printf 'id=task-x1\n' > "$kc/state/task-x1.backlog-close" ;;
    esac
    out=$(KC=$kc ROOT=$ROOT COPY="$(cd "$kc/copy" && pwd -P)" SHAPE=$shape bash -c "$(kept_helper_env)"'
. "$ROOT/bin/fm-backlog-transition-lib.sh" 2>/dev/null || true
TEARDOWN_RETAINED=("$COPY")
[ "$SHAPE" = not-marked ] || teardown_retained_mark_closed 2>>"$KC/stderr"
teardown_lookups=0
teardown_copy_lock_file() { teardown_lookups=$((teardown_lookups + 1)); return 1; }
TEARDOWN_RETAINED=()
if teardown_retained_closed_note "$KC/state/task-x1.meta" "$KC/state" 2>>"$KC/stderr"; then printf "closed lookups=%s\n" "$teardown_lookups"; else printf "refused rc=%s\n" "$?"; fi
' 2>&1)
    case "$shape" in
      closed)
        assert_contains "$out" "teardown task-x1: already closed" "kept-helper-closed: a retry of a closed task did not say it is already closed: $out"
        assert_contains "$out" "$(find "$kc/data/copy-sweep/retained" -type f | head -n 1)" "kept-helper-closed: the message does not name the record: $out"
        assert_contains "$out" "closed lookups=0" "kept-helper-closed: a copy was looked up: $out"
        ;;
      *)
        assert_contains "$out" "refused rc=" "kept-helper-closed-$shape: a task that is not proved closed was reported closed: $out"
        case "$out" in *"already closed"*) fail "kept-helper-closed-$shape: printed already closed: $out" ;; esac
        ;;
    esac
    assert_equals 1 "$(cat "$kc/calls")" "kept-helper-closed-$shape: the driver was asked again"
  done
  rm -rf "$tmp"
  pass "a retry of a task closed around a kept copy says it is already closed, names the record and looks up no copy, and a damaged or present task record, a pending backlog close or an unmarked record does not"
}

# Item 2 (C2 changed, A-8): no earlier preserved byte is overwritten or removed, and a new ignored
# entry under .claude or .opencode, a name differing only after a tab and a symlink whose target
# ends in a newline are copied into teardown's own preserve. A changed payload asks the driver
# once (P3) and is preserved beside the earlier preserve, which stays byte for byte as it was;
# the same payload again asks nothing, and a return to the earlier payload asks once and reuses
# the earlier preserve. Also: a pre-existing preserve of the copy, a preserve that did not hold,
# and a refusal after the driver's answer each leave every earlier preserved byte in place.
test_kept_copy_helper_a_changed_copy_is_preserved_beside_its_earlier_preserve_which_is_never_replaced() {
  local tmp kc out base first second dirs
  tmp=$(fm_test_tmproot kept-helper-beside)
  kc=$tmp/change
  kept_helper_case "$kc"
  printf '%s\n' '.opencode/' >> "$kc/copy/.git/info/exclude"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-beside: the first run did not close: $(cat "$kc/stderr")"
  base=$(kept_preserve_base "$kc")
  assert_equals 'only here' "$(cat "$base/files/notes/unique.dat" 2>/dev/null)" "kept-helper-beside: the first preserve is not at the base path in the files/ and meta/ layout"
  assert_equals 'one' "$(cat "$base/files/.claude/channel-outbox/a.jsonl" 2>/dev/null)" "kept-helper-beside: the .claude entry is not in teardown's own preserve"
  first=$(kept_tree "$base")
  # The new population: a new .opencode entry, a new .claude entry, two names that differ only
  # after a tab, a symlink whose target ends in a newline, and changed bytes of a selected file.
  mkdir -p "$kc/copy/.opencode"
  printf 'oc\n' > "$kc/copy/.opencode/new.json"
  printf 'two\n' > "$kc/copy/.claude/channel-outbox/b.jsonl"
  printf 'tab-a\n' > "$kc/copy/notes/x	a"
  printf 'tab-b\n' > "$kc/copy/notes/x	b"
  perl -e 'symlink("target\n", $ARGV[0]) or die' "$kc/copy/notes/link"
  printf 'changed\n' > "$kc/copy/notes/unique.dat"
  out=$(kept_helper_dispose "$kc" 2)
  assert_equals $'rc=0 kept=yes calls=2\nrc=0 kept=yes calls=2' "$out" "kept-helper-beside: a changed payload must ask once and then nothing: $(cat "$kc/stderr")"
  assert_equals "$first" "$(kept_tree "$base")" "kept-helper-beside: the earlier preserve changed"
  dirs=$(find "$kc/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | LC_ALL=C sort)
  assert_equals 2 "$(printf '%s\n' "$dirs" | wc -l | tr -d ' ')" "kept-helper-beside: the changed payload was not preserved in one directory beside the first: $dirs"
  second=$(printf '%s\n' "$dirs" | grep -v -x -F "$base")
  case "$second" in "$base".????????????????) ;; *) fail "kept-helper-beside: the beside directory is not named by 16 characters of the payload fingerprint: $second" ;; esac
  assert_equals 'oc' "$(cat "$second/files/.opencode/new.json" 2>/dev/null)" "kept-helper-beside: the new .opencode entry is not preserved"
  assert_equals 'two' "$(cat "$second/files/.claude/channel-outbox/b.jsonl" 2>/dev/null)" "kept-helper-beside: the new .claude entry is not preserved"
  assert_equals 'tab-a tab-b' "$(cat "$second/files/notes/x	a" 2>/dev/null) $(cat "$second/files/notes/x	b" 2>/dev/null)" "kept-helper-beside: the tab names are not preserved apart"
  assert_equals "$(printf 'target\n' | od -An -tx1 | tr -d ' \n')" "$(perl -e 'print unpack("H*", readlink($ARGV[0]) // "")' "$second/files/notes/link")" "kept-helper-beside: the symlink's trailing newline was not preserved"
  assert_equals 'changed' "$(cat "$second/files/notes/unique.dat")" "kept-helper-beside: the changed bytes are not preserved"
  assert_equals "$(sed -n 's/^preserve=//p' "$(find "$kc/data/copy-sweep/retained" -type f | head -n 1)")" "$second" "kept-helper-beside: the record does not name the preserve that holds the copy"
  # A return to the earlier payload is a change (P3): it asks once and reuses the first preserve.
  rm -rf "$kc/copy/.opencode" "$kc/copy/.claude/channel-outbox/b.jsonl" "$kc/copy/notes/x	a" "$kc/copy/notes/x	b" "$kc/copy/notes/link"
  printf 'only here\n' > "$kc/copy/notes/unique.dat"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=3' "$out" "kept-helper-beside: a return to the earlier payload must ask once: $(cat "$kc/stderr")"
  assert_equals 2 "$(find "$kc/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' ')" "kept-helper-beside: the earlier payload made a third preserve"
  assert_equals "$first" "$(kept_tree "$base")" "kept-helper-beside: the earlier preserve changed on the return"
  # A pre-existing preserve of the copy (an earlier teardown's) is kept as it is.
  kc=$tmp/existing
  kept_helper_case "$kc"
  base=$(kept_preserve_base "$kc")
  mkdir -p "$base/files/notes"
  printf 'earlier bytes\n' > "$base/files/notes/unique.dat"
  printf 'earlier only\n' > "$base/files/notes/gone.dat"
  first=$(kept_tree "$base")
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-beside-existing: the close failed: $(cat "$kc/stderr")"
  assert_equals "$first" "$(kept_tree "$base")" "kept-helper-beside-existing: the pre-existing preserve changed"
  # A pre-existing preserve that agrees with the copy is kept and only gains what it lacks: its
  # files and every SHA256SUMS line it had stay as they were, and the copied-in file's line is added.
  kc=$tmp/agreeing
  kept_helper_case "$kc"
  base=$(kept_preserve_base "$kc")
  mkdir -p "$base/files/notes" "$base/meta"
  printf 'only here\n' > "$base/files/notes/unique.dat"
  printf '%s\n' "$(cd "$kc/copy" && pwd -P)" > "$base/meta/copy-path"
  printf 'an earlier line an older run wrote\n%s  notes/unique.dat\n' "$(printf 'only here\n' | shasum -a 256 | awk '{print $1}')" > "$base/meta/SHA256SUMS"
  cp "$base/meta/SHA256SUMS" "$kc/sums.before"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-beside-agreeing: the close failed: $(cat "$kc/stderr")"
  assert_equals 1 "$(find "$kc/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' ')" "kept-helper-beside-agreeing: an agreeing preserve was not reused"
  assert_equals "$(cat "$kc/sums.before")" "$(head -n 2 "$base/meta/SHA256SUMS")" "kept-helper-beside-agreeing: an earlier SHA256SUMS line changed"
  assert_grep "$(printf 'one\n' | shasum -a 256 | awk '{print $1}')  .claude/channel-outbox/a.jsonl" "$base/meta/SHA256SUMS" "kept-helper-beside-agreeing: the copied-in file has no SHA256SUMS line"
  assert_equals 'only here' "$(cat "$base/files/notes/unique.dat")" "kept-helper-beside-agreeing: an earlier preserved file changed"
  # A preserve that did not hold (a selected file lost from it during the driver call): the run
  # refuses, the unchanged retry asks nothing and preserves beside it, and the damaged
  # preserve keeps every byte it still had.
  kc=$tmp/unheld
  kept_helper_case "$kc"
  # shellcheck disable=SC2016 # expanded by the stand-in driver's shell.
  printf 'rm -f "$DATA/$ID/nested-copy-preserved/"*/files/notes/unique.dat\n' > "$kc/after"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=1 kept=no calls=1' "$out" "kept-helper-beside-unheld: a preserve that does not hold must refuse: $(cat "$kc/stderr")"
  rm -f "$kc/after"
  base=$(kept_preserve_base "$kc")
  first=$(kept_tree "$base")
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-beside-unheld: the unchanged retry must close beside it without the driver: $(cat "$kc/stderr")"
  assert_equals "$first" "$(kept_tree "$base")" "kept-helper-beside-unheld: the earlier preserve changed"
  # A refusal after the driver's answer (not landed), then a changed payload: asked once more,
  # and the earlier preserve stays.
  kc=$tmp/refused
  kept_helper_case "$kc"
  : > "$kc/unlanded"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=1 kept=no calls=1' "$out" "kept-helper-beside-refused: an unlanded kept copy must refuse: $(cat "$kc/stderr")"
  base=$(kept_preserve_base "$kc")
  first=$(kept_tree "$base")
  rm -f "$kc/unlanded"
  printf 'changed\n' > "$kc/copy/notes/unique.dat"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=2' "$out" "kept-helper-beside-refused: the changed copy must ask once and close: $(cat "$kc/stderr")"
  assert_equals "$first" "$(kept_tree "$base")" "kept-helper-beside-refused: the earlier preserve changed"
  rm -rf "$tmp"
  pass "a changed kept copy is preserved beside its earlier preserve, with new .claude and .opencode entries, tab names and a newline-ended link target, and no earlier preserved byte is ever overwritten or removed"
}

# Item 2, a copy with nothing selected (only .claude files): its preserve is made when its payload
# is copied in, and every later run reuses that one preserve, its record unchanged.
test_kept_copy_helper_a_copy_with_nothing_selected_keeps_one_preserve_across_retries() {
  local tmp kc out rec
  tmp=$(fm_test_tmproot kept-helper-unselected)
  kc=$tmp/case
  kept_helper_case "$kc"
  rm -f "$kc/copy/notes/unique.dat"
  rmdir "$kc/copy/notes"
  : > "$kc/unlanded"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=1 kept=no calls=1' "$out" "kept-helper-unselected: an unlanded kept copy must refuse: $(cat "$kc/stderr")"
  rm -f "$kc/unlanded"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-unselected: the landed copy must close from its record: $(cat "$kc/stderr")"
  rec=$(find "$kc/data/copy-sweep/retained" -type f | head -n 1)
  cp "$rec" "$kc/record.closed"
  out=$(kept_helper_dispose "$kc" 2)
  assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-unselected: later runs must close without the driver: $(cat "$kc/stderr")"
  assert_equals 1 "$(find "$kc/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | wc -l | tr -d ' ')" "kept-helper-unselected: a later run made a second preserve"
  cmp -s "$kc/record.closed" "$rec" || fail "kept-helper-unselected: a later run rewrote the record: $(diff "$kc/record.closed" "$rec")"
  assert_equals 'one' "$(cat "$(kept_preserve_base "$kc")/files/.claude/channel-outbox/a.jsonl" 2>/dev/null)" "kept-helper-unselected: the .claude file is not in the preserve"
  rm -rf "$tmp"
  pass "a kept copy with nothing selected gets one preserve when its payload is copied in, and later runs reuse it with the record unchanged"
}

# kept_preserve_dirs <dir>: the case's preserve directories, one per line, sorted.
kept_preserve_dirs() {
  find "$1/data/task-x1/nested-copy-preserved" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | LC_ALL=C sort
}

# kept_preserve_trees <dirs>: kept_tree of each directory named in <dirs> (one per line).
kept_preserve_trees() {
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    printf '== %s\n' "$d"
    kept_tree "$d"
  done <<< "$1"
}

# kept_selected_states_case <dir> <exit>: kept_helper_case with a top-level .cache/ that the
# default selection keeps and the payload fingerprint leaves out, and the driver's exit code.
kept_selected_states_case() {
  kept_helper_case "$1"
  printf '%s\n' '.cache/' >> "$1/copy/.git/info/exclude"
  mkdir -p "$1/copy/.cache"
  printf 'A\n' > "$1/copy/.cache/x"
  printf '%s\n' "$2" > "$1/exit"
}

# kept_selected_states_run <dir> <want> <dirs-after> <label>: one run; the run's line must be
# <want>, there must then be <dirs-after> preserve directories, and every directory that existed
# before the run must be byte for byte as it was.
kept_selected_states_run() {
  local kc=$1 want=$2 count=$3 label=$4 before trees out
  before=$(kept_preserve_dirs "$kc")
  trees=$(kept_preserve_trees "$before")
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals "$want" "$out" "$label: the run did not progress as expected: $(cat "$kc/stderr")"
  assert_equals "$count" "$(kept_preserve_dirs "$kc" | wc -l | tr -d ' ')" "$label: wrong number of preserve directories: $(kept_preserve_dirs "$kc")"
  assert_equals "$trees" "$(kept_preserve_trees "$before")" "$label: an earlier preserve directory changed"
}

# Main 2007 (R7-1), released route: three selected states of .cache/x with one payload
# fingerprint each keep one preserve directory, in <sha256>, <sha256>.<P16> and <sha256>.<P16>.2;
# a run whose selected state equals an earlier one reuses its directory and builds nothing, and
# the third state is preserved and asks the driver instead of refusing on every retry.
test_kept_copy_helper_each_distinct_selected_state_keeps_one_preserve_on_the_released_route() {
  local tmp kc base third
  tmp=$(fm_test_tmproot kept-helper-states-released)
  kc=$tmp/case
  kept_selected_states_case "$kc" 4
  kept_selected_states_run "$kc" 'rc=1 kept=no calls=1' 1 "kept-helper-states-released-A"
  base=$(kept_preserve_base "$kc")
  assert_equals 'A' "$(cat "$base/files/.cache/x" 2>/dev/null)" "kept-helper-states-released: the first state is not in the first preserve"
  printf 'B\n' > "$kc/copy/.cache/x"
  kept_selected_states_run "$kc" 'rc=1 kept=no calls=2' 2 "kept-helper-states-released-B"
  kept_selected_states_run "$kc" 'rc=1 kept=no calls=3' 2 "kept-helper-states-released-B-again"
  printf 'C\n' > "$kc/copy/.cache/x"
  printf '0\n' > "$kc/exit"
  kept_selected_states_run "$kc" 'rc=0 kept=no calls=4' 3 "kept-helper-states-released-C"
  third=$(kept_preserve_dirs "$kc" | grep -x -F -v "$base" | grep '\.2$')
  case "$third" in "$base".????????????????.2) ;; *) fail "kept-helper-states-released: the third preserve is not <sha256>.<P16>.2: $(kept_preserve_dirs "$kc")" ;; esac
  assert_equals 'C' "$(cat "$third/files/.cache/x" 2>/dev/null)" "kept-helper-states-released: the third state is not in the third preserve"
  rm -rf "$tmp"
  pass "on the released route each distinct selected state keeps one preserve directory in the next free name, an equal state reuses its directory, and no earlier directory changes"
}

# Main 2007 (R7-1), kept route: the record matches while the selected-only .cache/x changes
# twice; each run closes from the record without the driver, the last in <sha256>.<P16>.2, and
# no earlier preserve directory changes.
test_kept_copy_helper_each_distinct_selected_state_keeps_one_preserve_on_the_kept_route() {
  local tmp kc base
  tmp=$(fm_test_tmproot kept-helper-states-kept)
  kc=$tmp/case
  kept_selected_states_case "$kc" 3
  kept_selected_states_run "$kc" 'rc=0 kept=yes calls=1' 1 "kept-helper-states-kept-A"
  base=$(kept_preserve_base "$kc")
  printf 'B\n' > "$kc/copy/.cache/x"
  kept_selected_states_run "$kc" 'rc=0 kept=yes calls=1' 2 "kept-helper-states-kept-B"
  printf 'C\n' > "$kc/copy/.cache/x"
  kept_selected_states_run "$kc" 'rc=0 kept=yes calls=1' 3 "kept-helper-states-kept-C"
  case "$(kept_preserve_dirs "$kc" | grep '\.2$')" in "$base".????????????????.2) ;; *) fail "kept-helper-states-kept: the third preserve is not <sha256>.<P16>.2: $(kept_preserve_dirs "$kc")" ;; esac
  assert_equals 'C' "$(cat "$(kept_preserve_dirs "$kc" | grep '\.2$')/files/.cache/x" 2>/dev/null)" "kept-helper-states-kept: the third state is not in the third preserve"
  assert_equals "$(kept_preserve_dirs "$kc" | grep '\.2$')" "$(sed -n 's/^preserve=//p' "$(find "$kc/data/copy-sweep/retained" -type f | head -n 1)")" "kept-helper-states-kept: the record does not name the preserve that holds the copy"
  rm -rf "$tmp"
  pass "on the kept route each distinct selected state keeps one preserve directory in the next free name and the task closes from its record without the driver"
}

# Main 2056: the entry proof's plan call (PR 366) and the kept route. For an own locked copy, an
# allowed plan whose disposition is archive_then_retain_tree (the real driver's answer for a tree
# with unique ignored files) is not an entry refusal: the copy goes on to the kept route and
# closes. Every other plan refusal still refuses at entry: not allowed, a non-zero exit with the
# keep-tree answer, no verdict. A copy whose record still matches asks the driver nothing, not
# even a plan.
test_kept_copy_helper_the_entry_plan_lets_a_kept_own_copy_through_and_a_matching_record_skips_it() {
  local tmp kc out shape copy
  tmp=$(fm_test_tmproot kept-helper-plan)
  for shape in keep-tree not-allowed keep-tree-nonzero no-verdict allowed matching; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    case "$shape" in
      not-allowed) printf '%s' '{"allowed": false, "reason": "cleanup_policy_not_allowed"}' > "$kc/plan-answer"; echo 3 > "$kc/plan-exit" ;;
      keep-tree-nonzero) echo 3 > "$kc/plan-exit" ;;
      no-verdict) printf '%s' 'no verdict here' > "$kc/plan-answer" ;;
      allowed) printf '%s' '{"allowed": true}' > "$kc/plan-answer" ;;
      matching)
        out=$(kept_helper_dispose "$kc" 1)
        assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-plan-matching: the first close failed: $(cat "$kc/stderr")"
        ;;
    esac
    copy=$(cd "$kc/copy" && pwd -P)
    out=$(KC=$kc ROOT=$ROOT COPY=$copy bash -c "$(kept_helper_env)"'
TEARDOWN_NESTED_COPIES=("$COPY")
mkdir -p "$KC/slot"
TEARDOWN_RETURN_SLOT=$KC/slot
TEARDOWN_FOREIGN_PROCS=()
teardown_foreign_copy_unowned() { return 0; }
prove=0; teardown_own_locked_copies_prove 2>>"$KC/stderr" || prove=$?
dispose=-
if [ "$prove" = 0 ]; then dispose=0; teardown_own_copy_dispose "$KC/slot" "$COPY" 2>>"$KC/stderr" || dispose=$?; fi
kept=no; ! teardown_copy_retained "$COPY" || kept=yes
printf "prove=%s dispose=%s kept=%s calls=%s plans=%s\n" "$prove" "$dispose" "$kept" "$(cat "$KC/calls" 2>/dev/null || echo 0)" "$(if [ -f "$KC/plan-calls" ]; then wc -l < "$KC/plan-calls" | tr -d " "; else echo 0; fi)"
')
    [ -n "${FM_RETAINED_EVIDENCE:-}" ] && printf '%s | case=%s | %s\n' "${FUNCNAME[0]}" "$shape" "$out" >> "$FM_RETAINED_EVIDENCE"
    case "$shape" in
      keep-tree) assert_equals 'prove=0 dispose=0 kept=yes calls=1 plans=1' "$out" "kept-helper-plan-keep-tree: an own copy the plan says the driver keeps must reach the kept route and close: $(cat "$kc/stderr")" ;;
      allowed) assert_equals 'prove=0 dispose=0 kept=yes calls=1 plans=1' "$out" "kept-helper-plan-allowed: the allowed plan must go on: $(cat "$kc/stderr")" ;;
      matching) assert_equals 'prove=0 dispose=0 kept=yes calls=1 plans=0' "$out" "kept-helper-plan-matching: a copy whose record matches asked the driver for a plan: $(cat "$kc/stderr")" ;;
      *)
        assert_equals 'prove=1 dispose=- kept=no calls=0 plans=1' "$out" "kept-helper-plan-$shape: the plan refusal must refuse at entry: $(cat "$kc/stderr")"
        assert_grep "would not release it" "$kc/stderr" "kept-helper-plan-$shape: the entry refusal does not name the plan"
        ;;
    esac
  done
  rm -rf "$tmp"
  pass "an own locked copy whose plan keeps the tree reaches the kept route and closes, every other plan refusal refuses at entry, and a matching record asks for no plan"
}

# Item 3 (C2 post-driver, Main 006): when the copy's record cannot be written, the close refuses
# and a refusal record names the copy, its state and the cause in data/<task>/closeout-refused/;
# every unchanged retry adds no driver call; once the record can be written the next run asks
# once (P2), closes and deletes the refusal record. Before the driver the record folder is probed
# first, so that run asks nothing; after the driver, a failed write keeps the answer in the
# refusal record.
test_kept_copy_helper_a_record_that_cannot_be_written_leaves_a_refusal_record() {
  local tmp kc out shape rdir refused
  [ "$(id -u)" != 0 ] || { pass "skipped as root: a permission bit does not stop root"; return 0; }
  tmp=$(fm_test_tmproot kept-helper-refused)
  for shape in before-driver after-driver; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    rdir=$kc/data/copy-sweep/retained
    mkdir -p "$rdir"
    refused=$kc/data/task-x1/closeout-refused/$(printf '%s' "$(cd "$kc/copy" && pwd -P)" | shasum -a 256 | awk '{print $1}')
    case "$shape" in
      before-driver)
        chmod 555 "$rdir"
        out=$(kept_helper_dispose "$kc" 2)
        assert_equals $'rc=1 kept=no calls=0\nrc=1 kept=no calls=0' "$out" "kept-helper-refused-$shape: the driver was asked while the record could not be written: $(cat "$kc/stderr")"
        ;;
      after-driver)
        # The stand-in takes the folder's write bit away after its answer, as a disk that fills does.
        printf 'chmod 555 "%s"\n' "$rdir" > "$kc/after"
        out=$(kept_helper_dispose "$kc" 1)
        rm -f "$kc/after"
        out=$out$'\n'$(kept_helper_dispose "$kc" 1)
        assert_equals $'rc=1 kept=no calls=1\nrc=1 kept=no calls=1' "$out" "kept-helper-refused-$shape: an unchanged retry asked the driver again: $(cat "$kc/stderr")"
        assert_grep 'answer-base64=' "$refused" "kept-helper-refused-$shape: the refusal record does not hold the driver's answer"
        ;;
    esac
    assert_present "$refused" "kept-helper-refused-$shape: no refusal record was written"
    assert_grep "copy=$(cd "$kc/copy" && pwd -P)" "$refused" "kept-helper-refused-$shape: the refusal record does not name the copy"
    assert_grep 'cause=' "$refused" "kept-helper-refused-$shape: the refusal record names no cause"
    assert_grep 'payload-sha256=' "$refused" "kept-helper-refused-$shape: the refusal record holds no payload fingerprint"
    assert_grep 'REFUSED' "$kc/stderr" "kept-helper-refused-$shape: the refusal printed no cause line"
    chmod 755 "$rdir"
    out=$(kept_helper_dispose "$kc" 2)
    case "$shape" in
      before-driver) assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-refused-$shape: once writable the next run must ask once and close: $(cat "$kc/stderr")" ;;
      after-driver) assert_equals $'rc=0 kept=yes calls=2\nrc=0 kept=yes calls=2' "$out" "kept-helper-refused-$shape: once writable the next run must ask once more (P2) and close: $(cat "$kc/stderr")" ;;
    esac
    assert_absent "$refused" "kept-helper-refused-$shape: the refusal record outlived its cause"
  done
  rm -rf "$tmp"
  pass "a kept copy whose record cannot be written refuses with a durable refusal record, unchanged retries ask the driver nothing, and once writable the next run asks once, closes and deletes the refusal record"
}

# Item 4 (C3 (c), C2 post-driver): every path the driver names is judged as it wrote it and its
# bytes are checked against the copy in the task's preserve. The first or the second of two
# named paths differing in the preserve, a selected-only file changed after it was preserved,
# and a preserved selected file removed after it was verified each refuse with the task kept;
# a named path the preserve lacks is copied in, checked and closes. Each name that is not an
# object inside the copy refuses, recorded (unchanged retries ask nothing); an in-copy link, a
# link to the copy's root and a real directory named with a trailing slash close.
test_kept_copy_helper_every_driver_named_path_is_judged_as_written_and_checked_against_the_copy() {
  local tmp kc out shape json count want base
  tmp=$(fm_test_tmproot kept-helper-named)
  for shape in first-differs second-differs selected-changed selected-removed lacking \
      absolute dotdot empty-component dot dir-symlink link-outside link-dangling link-slash file-slash only-slashes \
      in-copy-link root-link dir-slash; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    printf 'two\n' > "$kc/copy/.claude/channel-outbox/b.jsonl"
    base=$(kept_preserve_base "$kc")
    json='[".claude/channel-outbox/a.jsonl", ".claude/channel-outbox/b.jsonl"]' count=2 want=refuse
    case "$shape" in
      first-differs) printf 'mkdir -p "%s/.claude/channel-outbox" && printf "different\\n" > "%s/.claude/channel-outbox/a.jsonl"\n' "$base/files" "$base/files" > "$kc/after" ;;
      second-differs) printf 'mkdir -p "%s/.claude/channel-outbox" && printf "different\\n" > "%s/.claude/channel-outbox/b.jsonl"\n' "$base/files" "$base/files" > "$kc/after" ;;
      selected-changed) printf 'printf "changed\\n" > "%s/notes/unique.dat"\n' "$kc/copy" > "$kc/after-preserve" ;;
      selected-removed) printf 'rm -f "%s/notes/unique.dat"\n' "$base/files" > "$kc/after" ;;
      lacking)
        # .cache is in the regenerable class, so the preserve does not select it before the
        # driver names it; the named file is copied in and checked.
        mkdir -p "$kc/copy/.cache"; printf 'blob\n' > "$kc/copy/.cache/blob"
        printf '%s\n' '.cache/' >> "$kc/copy/.git/info/exclude"
        json='[".claude/channel-outbox/a.jsonl", ".cache/blob"]' want=close
        ;;
      absolute) json='["/etc/hosts", ".claude/channel-outbox/b.jsonl"]' ;;
      dotdot) json='[".claude/channel-outbox/a.jsonl", ".claude/../outside.dat"]' ;;
      empty-component) json='[".claude//channel-outbox/a.jsonl", ".claude/channel-outbox/b.jsonl"]' ;;
      dot) json='["./.claude/channel-outbox/a.jsonl", ".claude/channel-outbox/b.jsonl"]' ;;
      dir-symlink) ln -s channel-outbox "$kc/copy/.claude/via"; json='[".claude/via/a.jsonl", ".claude/channel-outbox/b.jsonl"]' ;;
      link-outside) ln -s /etc "$kc/copy/.claude/out"; json='[".claude/out", ".claude/channel-outbox/b.jsonl"]' ;;
      link-dangling) ln -s missing.jsonl "$kc/copy/.claude/dang"; json='[".claude/dang", ".claude/channel-outbox/b.jsonl"]' ;;
      link-slash) ln -s channel-outbox "$kc/copy/.claude/dl"; json='[".claude/dl/", ".claude/channel-outbox/b.jsonl"]' ;;
      file-slash) json='[".claude/channel-outbox/a.jsonl/", ".claude/channel-outbox/b.jsonl"]' ;;
      only-slashes) json='["///", ".claude/channel-outbox/b.jsonl"]' ;;
      in-copy-link) ln -s channel-outbox/a.jsonl "$kc/copy/.claude/inl"; json='[".claude/inl", ".claude/channel-outbox/b.jsonl"]' want=close ;;
      root-link) ln -s .. "$kc/copy/.claude/root"; json='[".claude/root", ".claude/channel-outbox/b.jsonl"]' want=close ;;
      dir-slash) json='[".claude/channel-outbox/"]' count=1 want=close ;;
    esac
    kept_helper_answer "$kc" "$json" "$count"
    out=$(kept_helper_dispose "$kc" 2)
    case "$want" in
      close)
        assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-named-$shape: the case must close: $(cat "$kc/stderr")"
        [ "$shape" != lacking ] || assert_equals 'blob' "$(cat "$base/files/.cache/blob" 2>/dev/null)" "kept-helper-named-lacking: the named file the preserve lacked was not copied in"
        ;;
      refuse)
        case "$shape" in
          selected-changed) assert_equals 'rc=1 kept=no calls=0' "$(printf '%s\n' "$out" | head -n 1)" "kept-helper-named-$shape: a file changed after it was preserved must refuse before the driver: $(cat "$kc/stderr")" ;;
          first-differs|second-differs|selected-removed) assert_equals 'rc=1 kept=no calls=1' "$(printf '%s\n' "$out" | head -n 1)" "kept-helper-named-$shape: the case must refuse after the driver: $(cat "$kc/stderr")" ;;
          *) assert_equals $'rc=1 kept=no calls=1\nrc=1 kept=no calls=1' "$out" "kept-helper-named-$shape: the name must refuse, recorded, and the retry ask nothing: $(cat "$kc/stderr")" ;;
        esac
        assert_grep 'REFUSED' "$kc/stderr" "kept-helper-named-$shape: the refusal printed no cause"
        assert_present "$kc/copy/.claude/channel-outbox/a.jsonl" "kept-helper-named-$shape: the copy lost a file"
        ;;
    esac
  done
  rm -rf "$tmp"
  pass "every driver-named path is judged as written and checked against the copy: mismatches, late changes, lost preserved files and names that are not objects inside the copy refuse, a lacking named file is copied in, and in-copy links and a trailing-slash directory close"
}

# Item 5 (C9 (a), F2): on the released route, a file changed after it was preserved refuses
# before the driver (no call, the copy stays) and the next run preserves it again; the unchanged
# control is released with the preserve holding its bytes; and a preserve that loses bytes while
# the driver releases the copy is caught after the release, the task not closed.
test_kept_copy_helper_a_file_changed_after_it_was_preserved_is_never_released_unpreserved() {
  local tmp kc out shape base
  tmp=$(fm_test_tmproot kept-helper-release)
  for shape in changed unchanged preserve-lost; do
    kc=$tmp/$shape
    kept_helper_case "$kc"
    printf '0\n' > "$kc/exit"
    base=$(kept_preserve_base "$kc")
    case "$shape" in
      changed) printf 'printf "new source\\n" > "%s/notes/unique.dat"\n' "$kc/copy" > "$kc/after-preserve" ;;
      preserve-lost) printf 'printf "lost\\n" > "%s/notes/unique.dat"\n' "$base/files" > "$kc/after" ;;
    esac
    out=$(kept_helper_dispose "$kc" 1)
    case "$shape" in
      changed)
        assert_equals 'rc=1 kept=no calls=0' "$out" "kept-helper-release-changed: a file changed after it was preserved reached the driver: $(cat "$kc/stderr")"
        assert_equals 'new source' "$(cat "$kc/copy/notes/unique.dat")" "kept-helper-release-changed: the copy's current bytes are gone"
        rm -f "$kc/after-preserve"
        out=$(kept_helper_dispose "$kc" 1)
        assert_equals 'rc=0 kept=no calls=1' "$out" "kept-helper-release-changed: the next run did not preserve and release: $(cat "$kc/stderr")"
        grep -R -q -F 'new source' "$kc/data/task-x1/nested-copy-preserved" || fail "kept-helper-release-changed: the current bytes were not preserved before the release"
        ;;
      unchanged)
        assert_equals 'rc=0 kept=no calls=1' "$out" "kept-helper-release-unchanged: the control was not released: $(cat "$kc/stderr")"
        assert_equals 'only here' "$(cat "$base/files/notes/unique.dat")" "kept-helper-release-unchanged: the preserve does not hold the released bytes"
        ;;
      preserve-lost)
        assert_equals 'rc=1 kept=no calls=1' "$out" "kept-helper-release-preserve-lost: a release whose preserve lost bytes closed: $(cat "$kc/stderr")"
        assert_grep 'no longer holds' "$kc/stderr" "kept-helper-release-preserve-lost: the refusal does not name the preserve"
        ;;
    esac
  done
  rm -rf "$tmp"
  pass "a file changed after it was preserved is never released unpreserved: it refuses before the driver and is preserved by the next run, the unchanged copy is released with its bytes held, and a preserve that loses bytes during the release is caught"
}

# F10: a root ignored file named like one of the preserve's own files (copy-path, SHA256SUMS) is
# preserved byte for byte and the kept copy closes; its preserve holds the payload in files/ and
# its meta/SHA256SUMS lists every preserved file there. Every copy uses that layout (PR 366).
test_kept_copy_helper_root_files_named_like_the_preserves_own_files_are_preserved() {
  local tmp kc out base
  tmp=$(fm_test_tmproot kept-helper-reserved)
  kc=$tmp/reserved
  kept_helper_case "$kc"
  printf '%s\n' '/SHA256SUMS' '/copy-path' >> "$kc/copy/.git/info/exclude"
  printf 'the project'"'"'s own sums\n' > "$kc/copy/SHA256SUMS"
  printf 'the project'"'"'s own copy-path\n' > "$kc/copy/copy-path"
  out=$(kept_helper_dispose "$kc" 2)
  assert_equals $'rc=0 kept=yes calls=1\nrc=0 kept=yes calls=1' "$out" "kept-helper-reserved: root files named like the preserve's own files must close: $(cat "$kc/stderr")"
  base=$(kept_preserve_base "$kc")
  assert_equals "the project's own sums" "$(cat "$base/files/SHA256SUMS" 2>/dev/null)" "kept-helper-reserved: SHA256SUMS of the copy is not preserved byte for byte"
  assert_equals "the project's own copy-path" "$(cat "$base/files/copy-path" 2>/dev/null)" "kept-helper-reserved: copy-path of the copy is not preserved byte for byte"
  assert_equals "$(cd "$kc/copy" && pwd -P)" "$(cat "$base/meta/copy-path")" "kept-helper-reserved: the preserve's own copy-path does not name the copy"
  (cd "$base/files" && shasum -a 256 -c ../meta/SHA256SUMS >/dev/null 2>&1) || fail "kept-helper-reserved: the preserve's SHA256SUMS does not check: $(cat "$base/meta/SHA256SUMS")"
  assert_grep '  SHA256SUMS' "$base/meta/SHA256SUMS" "kept-helper-reserved: SHA256SUMS does not list the payload's SHA256SUMS"
  kc=$tmp/ordinary
  kept_helper_case "$kc"
  out=$(kept_helper_dispose "$kc" 1)
  assert_equals 'rc=0 kept=yes calls=1' "$out" "kept-helper-reserved-ordinary: the control did not close: $(cat "$kc/stderr")"
  base=$(kept_preserve_base "$kc")
  assert_equals 'only here' "$(cat "$base/files/notes/unique.dat" 2>/dev/null)" "kept-helper-reserved-ordinary: an ordinary copy's preserve does not hold its file in files/"
  assert_grep '  notes/unique.dat' "$base/meta/SHA256SUMS" "kept-helper-reserved-ordinary: meta/SHA256SUMS does not list the preserved file"
  rm -rf "$tmp"
  pass "root files named copy-path and SHA256SUMS are preserved byte for byte in files/ and the kept copy closes, and an ordinary copy uses the same files/ and meta/ layout"
}

retained_field() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1; sed -n "s/^$2=//p" "$1" | sed -n '2,$p'
}

# retained_preserved_is <label> <relative-file>: the task's preserve holds the copy's bytes of
# <relative-file>, compared with hashes of the copy itself, and its SHA256SUMS lists it.
retained_preserved_is() {
  local want have preserve
  # The preserve the record names, or the first preserve when there is no record yet.
  preserve=$(sed -n 's/^preserve=//p' "$(retained_record_path)" 2>/dev/null | head -n 1)
  [ -n "$preserve" ] || preserve=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  want=$(shasum -a 256 "$FOREIGN_COPY/$2" | awk '{print $1}')
  have=$(shasum -a 256 "$preserve/files/$2" 2>/dev/null | awk '{print $1}')
  assert_equals "$want" "$have" "$1: the preserved $2 is not the copy's bytes"
  assert_grep "$want  $2" "$preserve/meta/SHA256SUMS" "$1: SHA256SUMS does not record $2"
}

# retained_recorded_answer: the driver's answer the record carries.
retained_recorded_answer() {
  sed -n 's/^answer-base64=//p' "$(retained_record_path)" | perl -MMIME::Base64 -0777 -ne 'print decode_base64($_)'
}

# retained_physical <path>: <path> with its folder resolved (pwd -P).
retained_physical() {
  printf '%s/%s\n' "$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" "${1##*/}"
}

# retained_tar_listing: the path and SHA-256 of every tar the stand-in driver wrote, read here.
retained_tar_listing() {
  find "$FOREIGN_SLOT/.claude/bug-evidence/worktree-preservation" -name '*.tar' -type f -exec shasum -a 256 {} + 2>/dev/null | LC_ALL=C sort
}

test_a_landed_task_closes_around_an_own_copy_the_driver_keeps() {
  local rc shape record answer
  for shape in enclosing reverse; do
    make_retained_case "retained-close-$shape" "$shape"
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 0 "$rc" "retained-close-$shape: a landed, clean copy the driver keeps with its files saved must close the task: $(cat "$FOREIGN_CASE/stderr")"
    assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-close-$shape: the driver was not asked exactly once for one tar"
    retained_assert_closed "retained-close-$shape"
    retained_preserved_is "retained-close-$shape" notes/unique.dat
    record=$(retained_record_path)
    assert_equals "$(cd "$FOREIGN_SLOT" && pwd -P)" "$(retained_field "$record" slot)" "retained-close-$shape: the record names another slot"
    assert_equals cleanup_ignored_payload_archived_tree_retained "$(retained_field "$record" reason)" "retained-close-$shape: the record does not carry the driver's reason"
    case "$(retained_field "$record" recorded-at)" in 20*Z) ;; *) fail "retained-close-$shape: the record carries no time" ;; esac
    case "$(sed -n 3p "$record")" in identity=[0-9]*:[0-9]*) ;; *) fail "retained-close-$shape: the record carries no identity" ;; esac
    assert_equals "task slot preserve reason recorded-at head status-sha256 payload-sha256 answer-base64 task-closed" "$(sed -n '5,$p' "$record" | sed 's/=.*//' | paste -sd ' ' -)" "retained-close-$shape: the record does not hold exactly its fields"
    assert_equals task-x1 "$(retained_field "$record" task-closed)" "retained-close-$shape: the completed close did not mark the record"
    retained_preserved_is "retained-close-$shape" .claude/channel-outbox/a.jsonl
    answer=$(retained_recorded_answer)
    assert_equals '[".claude/channel-outbox/a.jsonl",".claude/channel-outbox/b.jsonl"]' "$(printf '%s' "$answer" | jq -c .unique_ignored_paths)" "retained-close-$shape: the record does not carry the driver's unique paths"
    # Both paths are compared physically (on macOS /tmp is /private/tmp).
    assert_equals "$(retained_physical "$(retained_tar_listing | awk '{print $2}')")" "$(retained_physical "$(printf '%s' "$answer" | jq -r '.ignored_payload_preservation[-1].archive_path')")" "retained-close-$shape: the recorded archive is not the tar the driver wrote"
    assert_equals "$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')" "$(retained_field "$record" preserve)" "retained-close-$shape: the record does not name the preserve"
    kept_assert_lacks 'REFUSED' "$FOREIGN_CASE/stderr" "retained-close-$shape: a close that succeeded printed a refusal"
    assert_equals 1 "$(cat "$FOREIGN_CASE/stdout" "$FOREIGN_CASE/stderr" | grep -c "notice: own nested copy $FOREIGN_COPY was kept")" "retained-close-$shape: the kept copy was not reported exactly once"
    assert_absent "$FOREIGN_CASE/data/task-x1/vernant-closeout."* "retained-close-$shape: a close saved a refusal output"
  done
  pass "a landed task whose own copy the driver keeps closes: the copy, the slot and its lease are untouched, the driver's verified archive and the task's preserve hold the unique files, and one record names the copy and the answer"
}

test_a_retry_of_an_unchanged_kept_copy_asks_the_driver_nothing() {
  local rc record
  make_retained_case retained-retry enclosing
  held_plain_get_slot "$FOREIGN_CASE"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  : > "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "retained-retry: a slot that cannot be leased must refuse the close: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'could not be durably leased' "$FOREIGN_CASE/stderr" "retained-retry: the refusal did not say why"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-retry: run 1 should have asked the driver once"
  record=$(retained_record_path)
  assert_present "$record" "retained-retry: run 1 wrote no record"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-retry: the refused close removed the task record"
  cp "$record" "$FOREIGN_CASE/record.run1"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "retained-retry: run 2 must refuse for the same cause: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-retry: an unchanged copy asked the driver again"
  assert_absent "$FOREIGN_CASE/data/task-x1/vernant-closeout."* "retained-retry: a retry saved another driver output"
  cmp -s "$FOREIGN_CASE/record.run1" "$record" || fail "retained-retry: the unchanged copy's record was rewritten"
  rm -f "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-retry: run 3 with a lease must close: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-retry: the closing run asked the driver again"
  assert_equals 1 "$(find "$FOREIGN_CASE/data/copy-sweep/retained" -type f | wc -l | tr -d ' ')" "retained-retry: a second record was written"
  pass "a retry of an unchanged kept copy makes no driver call, writes no tar, no saved output and no second record, and closes once the slot can be leased"
}

test_a_changed_kept_copy_is_assessed_afresh() {
  local rc record change
  local base first added
  for change in more-ignored opencode-entry tab-name link-newline dirty-tracked unlanded; do
    make_retained_case "retained-changed-$change" enclosing
    held_plain_get_slot "$FOREIGN_CASE"
    : > "$FOREIGN_CASE/no-lease-command"
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 1 "$rc" "retained-changed-$change: run 1 must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
    record=$(retained_record_path)
    cp "$record" "$FOREIGN_CASE/record.run1"
    base=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
    first=$(kept_tree "$base")
    cp "$base/meta/SHA256SUMS" "$FOREIGN_CASE/sums.run1"
    case "$change" in
      more-ignored) printf 'more\n' > "$FOREIGN_COPY/notes/unique.dat" ;;
      opencode-entry)
        printf '%s\n' '.opencode/' >> "$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)"
        mkdir -p "$FOREIGN_COPY/.opencode"; printf 'oc\n' > "$FOREIGN_COPY/.opencode/new.json"
        ;;
      tab-name) printf 'tab\n' > "$FOREIGN_COPY/.claude/channel-outbox/a	b.jsonl" ;;
      link-newline) perl -e 'symlink("a.jsonl\n", $ARGV[0]) or die' "$FOREIGN_COPY/.claude/channel-outbox/link" ;;
      dirty-tracked) printf 'edit\n' > "$FOREIGN_COPY/untracked.txt" ;;
      unlanded) held_foreign_unlanded "$FOREIGN_COPY" ;;
    esac
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 1 "$rc" "retained-changed-$change: run 2 must refuse: $(cat "$FOREIGN_CASE/stderr")"
    case "$change" in
      more-ignored|opencode-entry|tab-name|link-newline)
        assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "retained-changed-$change: a changed copy that passes every proof was not evaluated again"
        assert_grep 'could not be durably leased' "$FOREIGN_CASE/stderr" "retained-changed-$change: run 2 did not reach the lease check"
        cmp -s "$FOREIGN_CASE/record.run1" "$record" && fail "retained-changed-$change: the stale record was not replaced"
        # No earlier preserved byte is overwritten or removed. A changed selected file goes
        # beside the earlier preserve; a new payload-only entry is copied into the earlier
        # preserve, which still agrees with the copy, and only that entry and its line are added.
        case "$change" in
          more-ignored) assert_equals "$first" "$(kept_tree "$base")" "retained-changed-$change: the earlier preserve changed" ;;
          *)
            case "$change" in
              opencode-entry) added=.opencode/new.json ;;
              tab-name) added=".claude/channel-outbox/a	b.jsonl" ;;
              link-newline) added=.claude/channel-outbox/link ;;
            esac
            assert_equals "$(printf '%s\n' "$first" | grep -v '^F \./meta/SHA256SUMS ')" "$(kept_tree "$base" | grep -v '^F \./meta/SHA256SUMS ' | grep -vF " ./files/$added ")" "retained-changed-$change: the earlier preserve lost or changed an entry, or gained one other than $added"
            { [ -e "$base/files/$added" ] || [ -L "$base/files/$added" ]; } || fail "retained-changed-$change: $added was not copied into the agreeing earlier preserve"
            assert_equals "$(cat "$FOREIGN_CASE/sums.run1")" "$(head -n "$(wc -l < "$FOREIGN_CASE/sums.run1")" "$base/meta/SHA256SUMS")" "retained-changed-$change: an earlier SHA256SUMS line changed"
            ;;
        esac
        case "$change" in
          more-ignored) retained_preserved_is "retained-changed-$change" notes/unique.dat ;;
          opencode-entry) retained_preserved_is "retained-changed-$change" .opencode/new.json ;;
          tab-name) retained_preserved_is "retained-changed-$change" ".claude/channel-outbox/a	b.jsonl" ;;
          link-newline)
            assert_equals "$(printf 'a.jsonl\n' | od -An -tx1 | tr -d ' \n')" "$(perl -e 'print unpack("H*", readlink($ARGV[0]) // "")' "$(sed -n 's/^preserve=//p' "$record")/files/.claude/channel-outbox/link")" "retained-changed-$change: the link target's trailing newline was not preserved"
            ;;
        esac
        ;;
      *)
        assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-changed-$change: a changed copy that fails a proof reached the driver"
        assert_grep 'REFUSED' "$FOREIGN_CASE/stderr" "retained-changed-$change: the refusal named no cause"
        cmp -s "$FOREIGN_CASE/record.run1" "$record" || fail "retained-changed-$change: a refused copy's record was rewritten"
        ;;
    esac
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-changed-$change: the task record was removed"
    assert_present "$FOREIGN_COPY/.git" "retained-changed-$change: the copy was removed"
  done
  pass "a kept copy whose ignored files, tracked status or HEAD changed is assessed afresh: still-eligible goes to the driver again, failing a proof refuses before any driver call"
}

# A kept copy in a slot another live task still works in (the peer route) cannot
# be held under this task's lease, so the close refuses, and its retry, with the
# record matching, asks the driver nothing.
test_a_kept_copy_in_a_slot_a_peer_works_in_refuses_and_its_retry_asks_the_driver_nothing() {
  local rc record peer run
  make_retained_case retained-peer enclosing
  peer=$FOREIGN_SLOT/peer-copy
  mkdir -p "$peer"
  fm_write_meta "$FOREIGN_CASE/state/task-y1.meta" \
    "window=firstmate:fm-task-y1" "endpoint_task_id=task-y1" \
    "worktree=$peer" "branch=fm/task-y1" "project=$FOREIGN_CASE/project" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-y1" \
    "prior_worktree=$FOREIGN_SLOT"
  record=$(retained_record_path)
  for run in 1 2; do
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 1 "$rc" "retained-peer: run $run of a kept-copy close in the peer route must refuse: $(cat "$FOREIGN_CASE/stderr")"
    assert_grep "REFUSED: own nested copy $FOREIGN_COPY was kept by Vernant's closeout driver (record $record)" "$FOREIGN_CASE/stderr" "retained-peer: run $run did not name the kept copy and its record"
    assert_grep 'which another live task still works in' "$FOREIGN_CASE/stderr" "retained-peer: run $run did not say why"
    assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-peer: run $run did not leave the driver asked exactly once"
    assert_present "$record" "retained-peer: run $run left no record"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-peer: run $run removed the task record"
    assert_equals in_flight "$(backlog_row_state "$FOREIGN_CASE")" "retained-peer: run $run moved the backlog item"
    held_fingerprint "$FOREIGN_COPY" | cmp -s - "$FOREIGN_CASE/held-before.$(basename "$FOREIGN_COPY")" || fail "retained-peer: run $run changed the kept copy"
    assert_absent "$FOREIGN_CASE/treehouse.log" "retained-peer: run $run returned the pool slot"
    [ "$run" = 2 ] || cp "$record" "$FOREIGN_CASE/record.run1"
  done
  cmp -s "$FOREIGN_CASE/record.run1" "$record" || fail "retained-peer: the retry rewrote the matching record"
  pass "a kept-copy close in a slot a peer still works in refuses with the copy and its record named, and its retry asks the driver nothing"
}

# retained_variant <variant> <plain|force> [label]: the C1 fixture with one fact changed
# (or none, for c1-input), run with or without --force and the --drop-file it needs.
# Sets RV_DISPOSITION to what survived and the exit class.
retained_variant() {
  local variant=$1 mode=$2 hash preserve inner exclude
  local -a driver_env=(FM_STUB_CLOSEOUT=retained)
  make_retained_case "retained-$variant-$mode${3:+-$3}" enclosing
  hash=$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  preserve=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$hash
  case "$variant" in
    c1-input) ;;
    unlanded) held_foreign_unlanded "$FOREIGN_COPY" ;;
    dirty) printf 'edit\n' > "$FOREIGN_COPY/untracked.txt" ;;
    changed-during-driver) driver_env+=("FM_STUB_AFTER=printf 'changed\\n' > '$FOREIGN_COPY/notes/unique.dat'") ;;
    removed-from-preserve) driver_env+=("FM_STUB_AFTER=rm -f '$preserve/files/notes/unique.dat'") ;;
    driver-path-directory) driver_env+=("FM_STUB_UNIQUE=.claude/channel-outbox/") ;;
    driver-path-differs) driver_env+=("FM_STUB_AFTER=mkdir -p '$preserve/files/.claude/channel-outbox' && printf 'different\\n' > '$preserve/files/.claude/channel-outbox/a.jsonl'") ;;
    driver-path-differs-second) driver_env+=("FM_STUB_AFTER=mkdir -p '$preserve/files/.claude/channel-outbox' && printf 'different\\n' > '$preserve/files/.claude/channel-outbox/b.jsonl'") ;;
    driver-path-gone) driver_env+=("FM_STUB_UNIQUE=.claude/channel-outbox/a.jsonl .claude/channel-outbox/missing.jsonl") ;;
    driver-path-escapes) driver_env+=("FM_STUB_UNIQUE=.claude/channel-outbox/a.jsonl ../outside.dat") ;;
    empty-path) driver_env+=('FM_STUB_UNIQUE_JSON=[""]') ;;
    archive-sha-differs) driver_env+=(FM_STUB_ARCHIVE_SHA=0000000000000000000000000000000000000000000000000000000000000000) ;;
    lease-conflict) driver_env+=(FM_STUB_REASON=cleanup_lease_conflict) ;;
    live-or-unknown) driver_env+=(FM_STUB_REASON=cleanup_skipped_live_or_unknown) ;;
    policy-not-allowed) driver_env+=(FM_STUB_REASON=cleanup_policy_not_allowed) ;;
    other-exit) driver_env+=(FM_STUB_EXIT=4) ;;
    json-broken) driver_env+=(FM_STUB_JSON=broken) ;;
    json-two) driver_env+=(FM_STUB_JSON=two) ;;
    json-no-unique) driver_env+=(FM_STUB_JSON=nounique) ;;
    json-unique-string) driver_env+=(FM_STUB_JSON=uniquestring) ;;
    reason-invented) driver_env+=(FM_STUB_REASON=cleanup_reason_no_list_holds) ;;
    same-repo-worktree)
      # A linked worktree of the same repository: the existing predicate lets it
      # stand, so the kept route is not what refuses this copy.
      git -C "$FOREIGN_CASE/project" worktree add -q -b fm/inner-lane "$FOREIGN_COPY/inner-wt" main
      exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
      printf '%s\n' 'inner-wt/' >> "$exclude"
      ;;
    other-repo)
      inner=$FOREIGN_COPY/other-repo
      mkdir -p "$inner"
      git -C "$inner" init -q
      exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
      printf '%s\n' 'other-repo/' >> "$exclude"
      ;;
  esac
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  RV_DRIVER_ENV=("${driver_env[@]}")
  retained_variant_run "$mode"
}

# retained_variant_run <plain|force>: runs teardown once more on the current
# variant case with its driver environment; sets RV_DISPOSITION.
retained_variant_run() {
  local rc=0
  FOREIGN_TEARDOWN_ARGS=()
  [ "$1" = plain ] || FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
  run_foreign_teardown rc "${RV_DRIVER_ENV[@]}"
  FOREIGN_TEARDOWN_ARGS=()
  RV_DISPOSITION="exit=$([ "$rc" = 0 ] && echo 0 || echo nonzero) task-record=$([ -e "$FOREIGN_CASE/state/task-x1.meta" ] && echo kept || echo removed)"
  RV_DISPOSITION="$RV_DISPOSITION backlog=$(backlog_row_state "$FOREIGN_CASE") copy=$([ -e "$FOREIGN_COPY/.git" ] && echo kept || echo gone)"
  RV_DISPOSITION="$RV_DISPOSITION slot-returned=$([ -e "$FOREIGN_CASE/treehouse.log" ] && echo yes || echo no) record=$([ -e "$(retained_record_path)" ] && echo written || echo none)"
  RV_DISPOSITION="$RV_DISPOSITION driver-calls=$(retained_call_count) tars=$(retained_tar_count)"
}

# C3: every other state refuses with its cause and leaves the copy, the slot and the task
# record; --force waives none of the kept route's proofs. An answer that keeps the copy is
# recorded whatever else it holds; any other driver answer refuses as before, unrecorded.
test_every_other_state_of_an_own_copy_the_driver_keeps_still_refuses() {
  local variant plain force want
  for variant in c1-input same-repo-worktree driver-path-directory unlanded dirty changed-during-driver removed-from-preserve driver-path-differs driver-path-differs-second driver-path-gone driver-path-escapes empty-path archive-sha-differs json-no-unique json-unique-string other-repo lease-conflict live-or-unknown policy-not-allowed other-exit json-broken json-two reason-invented; do
    retained_variant "$variant" plain
    plain=$RV_DISPOSITION
    case "$variant" in
      c1-input|same-repo-worktree|driver-path-directory) want="exit=0 task-record=removed backlog=done copy=kept slot-returned=no record=written driver-calls=1 tars=1" ;;
      unlanded|dirty) want="exit=nonzero task-record=kept backlog=in_flight copy=kept slot-returned=no record=none driver-calls=0 tars=0" ;;
      changed-during-driver|removed-from-preserve|driver-path-differs|driver-path-differs-second|driver-path-gone|driver-path-escapes|empty-path|archive-sha-differs|json-no-unique|json-unique-string|other-repo)
        want="exit=nonzero task-record=kept backlog=in_flight copy=kept slot-returned=no record=written driver-calls=1 tars=1" ;;
      *) want="exit=nonzero task-record=kept backlog=in_flight copy=kept slot-returned=no record=none driver-calls=1 tars=1" ;;
    esac
    assert_equals "$want" "$plain" "$variant: wrong disposition: $plain"
    case "$variant" in
      c1-input|same-repo-worktree|driver-path-directory) ;;
      unlanded) assert_grep 'not landed' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      changed-during-driver) assert_grep 'changed while Vernant' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      removed-from-preserve|driver-path-differs|driver-path-differs-second) assert_grep 'does not hold every ignored file' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      driver-path-gone|driver-path-escapes) assert_grep 'which is not a plain path inside the copy' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      archive-sha-differs) assert_grep 'does not have the SHA-256 it recorded' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      empty-path|json-no-unique|json-unique-string) assert_grep 'its recorded answer does not name a restore-verified archive' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      dirty|other-repo) assert_grep 'REFUSED' "$FOREIGN_CASE/stderr" "$variant: the refusal named no cause" ;;
      *) assert_grep "Vernant's closeout driver did not release own nested copy $FOREIGN_COPY (exit" "$FOREIGN_CASE/stderr" "$variant: the driver refusal was not reported" ;;
    esac
    retained_variant "$variant" force
    force=$RV_DISPOSITION
    case "$variant" in
      # --force already waives the task's own landed and clean proof before the driver (the
      # captain's authorization to discard assigned work), so the driver is asked once here,
      # as on the base; the kept route's own proof then refuses the copy it keeps.
      unlanded|dirty) assert_equals "exit=nonzero task-record=kept backlog=in_flight copy=kept slot-returned=no record=written driver-calls=1 tars=1" "$force" "$variant: --force changed what survived: $force" ;;
      *) assert_equals "$plain" "$force" "$variant: --force changed the disposition: $force" ;;
    esac
  done
  pass "each other state of an own copy the driver keeps refuses with its cause and the same disposition with and without --force, and the clean input closes the same way with --force"
}

# F6, C2 (post-driver): a kept copy refused from the driver's recorded answer refuses again on
# two unchanged retries without the driver, a tar or a saved output, with and without --force.
test_a_stable_refusal_after_the_driver_asks_the_driver_nothing_on_retry() {
  local entry variant mode run want
  want="exit=nonzero task-record=kept backlog=in_flight copy=kept slot-returned=no record=written driver-calls=1 tars=1"
  for entry in empty-path:plain archive-sha-differs:plain json-no-unique:plain other-repo:plain unlanded:force dirty:force; do
    variant=${entry%:*}
    mode=${entry#*:}
    retained_variant "$variant" "$mode" stable
    assert_equals "$want" "$RV_DISPOSITION" "stable-$variant: run 1 wrong disposition"
    retained_tar_listing > "$FOREIGN_CASE/tars.run1"
    for run in 2 3; do
      retained_variant_run "$mode"
      assert_equals "$want" "$RV_DISPOSITION" "stable-$variant: run $run asked the driver again or changed what survived"
      retained_tar_listing | cmp -s - "$FOREIGN_CASE/tars.run1" || fail "stable-$variant: run $run changed the tars"
      assert_absent "$FOREIGN_CASE/data/task-x1/vernant-closeout."* "stable-$variant: run $run saved a driver output"
      assert_grep 'REFUSED' "$FOREIGN_CASE/stderr" "stable-$variant: run $run did not refuse by name"
    done
  done
  pass "a kept copy refused from the driver's recorded answer (an empty path, an archive hash that does not match, no unique list, another repository, a forced unlanded or dirty copy) asks the driver once across two retries"
}

# (d) from the record: a kept copy whose preserve lost a selected file refuses; the next run's
# preservation rebuilds the preserve from the unchanged copy, and the record then closes the
# task without asking the driver.
test_a_kept_copy_whose_cause_went_closes_from_its_record_without_the_driver() {
  local rc preserve
  make_retained_case retained-cause-went enclosing
  preserve=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained "FM_STUB_AFTER=rm -f '$preserve/files/notes/unique.dat'"
  expect_code 1 "$rc" "retained-cause-went: a preserve without a selected file must refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-cause-went: run 1 did not ask the driver once"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-cause-went: the copy preserved again beside the first must let the record close the task: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-cause-went: the closing run asked the driver"
  retained_assert_closed retained-cause-went
  retained_preserved_is retained-cause-went notes/unique.dat
  pass "a kept copy whose cause went (preserved again beside the preserve that lost a file, which is left as it is) closes from its record without the driver"
}

# A kept copy whose only ignored files are under .claude has nothing the entry plan preserves,
# so the entry check never compares the preserve parent with the run directory. When the
# preserve parent is on another filesystem (a `stat` stand-in, with a `perl` stand-in whose
# rename fails across devices as rename(2) does), the widened preserve must still be built and
# the task must close.
test_a_kept_copy_with_only_claude_files_closes_when_its_preserve_is_on_another_filesystem() {
  local rc root real_perl
  make_retained_case retained-xdev-preserve enclosing
  rm -f "$FOREIGN_COPY/notes/unique.dat"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  root="$FOREIGN_CASE/data/task-x1/nested-copy-preserved"
  mkdir -p "$root"
  teardown_test_fake_other_device "$FOREIGN_CASE/fakebin" "$root"
  real_perl=$(command -v perl)
  cat > "$FOREIGN_CASE/fakebin/perl" <<SH
#!/usr/bin/env bash
if [ "\$#" = 5 ] && [ "\$1" = -e ] && [ "\$2" = 'rename(\$ARGV[0], \$ARGV[1]) or exit 1' ] && [ "\$3" = -- ]; then
  case "\$(uname -s)" in Darwin|*BSD) flag=-f ;; *) flag=-c ;; esac
  [ "\$(stat \$flag %d "\${4%/*}")" = "\$(stat \$flag %d "\${5%/*}")" ] || exit 1
fi
exec "$real_perl" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/perl"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-xdev-preserve: a kept copy whose preserve is on another filesystem must close: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-xdev-preserve: the driver was not asked exactly once for one tar"
  retained_assert_closed retained-xdev-preserve
  retained_preserved_is retained-xdev-preserve .claude/channel-outbox/a.jsonl
  retained_preserved_is retained-xdev-preserve .claude/channel-outbox/b.jsonl
  assert_equals '' "$(find "$root" "$FOREIGN_CASE/state" -name '.staging-own-*' -o -name 'ignored-own-*' 2>/dev/null)" "retained-xdev-preserve: a staging directory was left behind"
  pass "a kept copy with only .claude ignored files closes, its widened preserve built, when the preserve parent is on another filesystem from the run directory"
}

# C1 (f): the close and every later run leave the task's preserve, the driver's tars and the
# saved outputs as they were before (each tar's SHA-256 read before the close).
test_the_preserve_and_the_archives_survive_the_close_and_every_later_run() {
  local rc tardir tars_before outputs_before run
  make_retained_case retained-survive enclosing
  tardir=$FOREIGN_SLOT/.claude/bug-evidence/worktree-preservation
  mkdir -p "$tardir" "$FOREIGN_CASE/data/task-x1"
  printf 'earlier archive\n' > "$tardir/stub-ordinary_cleanup-0.tar"
  printf 'earlier output\n' > "$FOREIGN_CASE/data/task-x1/vernant-closeout.seed1"
  tars_before=$(retained_tar_listing)
  outputs_before=$(shasum -a 256 "$FOREIGN_CASE/data/task-x1/vernant-closeout.seed1")
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-survive: the close must succeed: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "$tars_before" "$(retained_tar_listing | grep -F "$tardir/stub-ordinary_cleanup-0.tar")" "retained-survive: the close changed a tar that existed before it"
  retained_tar_listing > "$FOREIGN_CASE/tars.after-close"
  for run in 1 2; do
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    assert_equals "1 2" "$(retained_call_count) $(retained_tar_count)" "retained-survive: later run $run asked the driver or wrote a tar"
    retained_tar_listing | cmp -s - "$FOREIGN_CASE/tars.after-close" || fail "retained-survive: later run $run changed a tar"
    assert_equals "$outputs_before" "$(shasum -a 256 "$FOREIGN_CASE/data/task-x1/vernant-closeout.seed1")" "retained-survive: later run $run changed a saved output"
    retained_preserved_is "retained-survive run $run" notes/unique.dat
  done
  pass "the task's preserve, every tar and every saved output that existed before the close keep their bytes through the close and later runs"
}

# C1 (config): the production default interpreter (<slot>/.venv/bin/python, with
# FM_TEARDOWN_VERNANT_PYTHON truly unset, and set to an empty string) and the explicit
# override give the same close; a missing default interpreter refuses and removes nothing.
test_the_default_driver_interpreter_and_the_override_close_the_same_way() {
  local rc mode
  for mode in default default-empty override missing missing-empty override-missing; do
    make_retained_case "retained-config-$mode" enclosing
    case "$mode" in
      default)
        mkdir -p "$FOREIGN_SLOT/.venv/bin"
        cp "$FOREIGN_CASE/vernant-python" "$FOREIGN_SLOT/.venv/bin/python"
        chmod +x "$FOREIGN_SLOT/.venv/bin/python"
        RETAINED_UNSET_PYTHON=1 run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
        ;;
      default-empty)
        mkdir -p "$FOREIGN_SLOT/.venv/bin"
        cp "$FOREIGN_CASE/vernant-python" "$FOREIGN_SLOT/.venv/bin/python"
        chmod +x "$FOREIGN_SLOT/.venv/bin/python"
        run_foreign_teardown rc FM_STUB_CLOSEOUT=retained FM_TEARDOWN_VERNANT_PYTHON=
        ;;
      override) run_foreign_teardown rc FM_STUB_CLOSEOUT=retained ;;
      missing) RETAINED_UNSET_PYTHON=1 run_foreign_teardown rc FM_STUB_CLOSEOUT=retained ;;
      missing-empty) run_foreign_teardown rc FM_STUB_CLOSEOUT=retained FM_TEARDOWN_VERNANT_PYTHON= ;;
      override-missing)
        mkdir -p "$FOREIGN_SLOT/.venv/bin"
        cp "$FOREIGN_CASE/vernant-python" "$FOREIGN_SLOT/.venv/bin/python"
        chmod +x "$FOREIGN_SLOT/.venv/bin/python"
        run_foreign_teardown rc FM_STUB_CLOSEOUT=retained "FM_TEARDOWN_VERNANT_PYTHON=$FOREIGN_CASE/no-such-python"
        ;;
    esac
    if [ "$mode" = missing ] || [ "$mode" = missing-empty ] || [ "$mode" = override-missing ]; then
      assert_grep 'is not available' "$FOREIGN_CASE/stderr" "retained-config-$mode: the refusal did not say the interpreter is not available"
      expect_code 1 "$rc" "retained-config-$mode: a missing default interpreter must refuse: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals "0 0" "$(retained_call_count) $(retained_tar_count)" "retained-config-$mode: the driver ran without an interpreter"
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-config-$mode: the refusal removed the task record"
      assert_present "$FOREIGN_COPY/.git" "retained-config-$mode: the copy was removed"
      kept_assert_lacks 'complete' "$FOREIGN_CASE/stdout" "retained-config-$mode: the task closed"
    else
      expect_code 0 "$rc" "retained-config-$mode: the close must succeed: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-config-$mode: the driver was not asked exactly once"
      retained_assert_closed "retained-config-$mode"
    fi
  done
  pass "the default interpreter and the explicit override close the kept-copy task the same way, and a missing default interpreter refuses with nothing removed"
}

# C2 (legacy): a copy that already holds driver tars and saved outputs, with no
# retained record, is asked once on the first teardown after the change (one named
# extra tar), and the later runs add nothing.
test_the_first_teardown_of_a_copy_that_already_holds_tars_asks_the_driver_once() {
  local rc run tardir
  make_retained_case retained-legacy enclosing
  tardir=$FOREIGN_SLOT/.claude/bug-evidence/worktree-preservation
  mkdir -p "$tardir" "$FOREIGN_CASE/data/task-x1"
  for run in 1 2 3; do
    printf 'archive %s\n' "$run" > "$tardir/stub-ordinary_cleanup-$run.tar"
  done
  printf '{"allowed": false, "reason": "cleanup_ignored_payload_archived_tree_retained", "retained_worktree_path": "%s"}\n' "$FOREIGN_COPY" > "$FOREIGN_CASE/data/task-x1/vernant-closeout.seed1"
  assert_equals "0 3" "$(retained_call_count) $(retained_tar_count)" "retained-legacy: the seeded state is wrong"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-legacy: the first run must close: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 4" "$(retained_call_count) $(retained_tar_count)" "retained-legacy: the first run did not ask the driver once for exactly one more tar"
  retained_assert_closed retained-legacy
  for run in 2 3; do
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    assert_equals "1 4" "$(retained_call_count) $(retained_tar_count)" "retained-legacy: run $run added a driver call or a tar"
  done
  pass "a copy that already holds driver tars is asked once on the first teardown, with one more tar, and later runs add none"
}

# C2 (changed) (head-only): a move of HEAD to another landed commit, with the ignored
# payload unchanged, asks the driver exactly once more (one named extra tar), and a
# further unchanged run adds nothing.
test_a_head_only_change_of_a_kept_copy_asks_the_driver_exactly_once_more() {
  local rc record head
  make_retained_case retained-head-only enclosing
  held_plain_get_slot "$FOREIGN_CASE"
  : > "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "retained-head-only: run 1 must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-head-only: run 1 should have asked the driver once"
  record=$(retained_record_path)
  cp "$record" "$FOREIGN_CASE/record.run1"
  git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'another landed commit'
  head=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
  git -C "$FOREIGN_CASE/project" fetch -q "$FOREIGN_COPY" HEAD
  git -C "$FOREIGN_CASE/project" update-ref refs/heads/main FETCH_HEAD
  add_gh_pr_merged_for_head "$FOREIGN_CASE" "$head"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "retained-head-only: run 2 must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "retained-head-only: a HEAD-only change did not ask the driver exactly once more"
  cmp -s "$FOREIGN_CASE/record.run1" "$record" && fail "retained-head-only: the stale record was not replaced"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "retained-head-only: an unchanged run after the change asked the driver again"
  pass "a move of HEAD alone asks the driver exactly once more, with one more tar, and the next unchanged run adds none"
}

# C2 (changed): a genuinely changed ignored payload is assessed again with exactly one driver
# call and one tar per change of the payload, whatever changed (a new entry the driver does not
# name, changed bytes, a second distinct change, a return to an earlier payload), and the same
# payload never asks again.
test_a_changed_payload_is_archived_once_per_change_and_never_again_while_unchanged() {
  local rc step want=1 run
  make_retained_case retained-p3 enclosing
  held_plain_get_slot "$FOREIGN_CASE"
  : > "$FOREIGN_CASE/no-lease-command"
  for step in none new-entry changed-bytes second-change earlier-payload; do
    case "$step" in
      none) ;;
      new-entry) printf 'three\n' > "$FOREIGN_COPY/.claude/channel-outbox/c.jsonl"; want=$((want + 1)) ;;
      changed-bytes) printf 'two2\n' > "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl"; want=$((want + 1)) ;;
      second-change) printf 'two3\n' > "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl"; want=$((want + 1)) ;;
      earlier-payload) printf 'two2\n' > "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl"; want=$((want + 1)) ;;
    esac
    for run in 1 2; do
      run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
      expect_code 1 "$rc" "retained-p3 $step run $run: must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals "$want $want" "$(retained_call_count) $(retained_tar_count)" "retained-p3 $step run $run: wrong driver calls and tars"
    done
  done
  pass "each change of the ignored payload causes exactly one driver call and one tar, a return to an earlier payload counts as a change, and the same payload never asks again"
}

# C2 (changed): a replaced creation lock is a different copy state and is asked again.
test_a_replaced_creation_lock_of_a_kept_copy_asks_the_driver_once_more() {
  local rc pid
  make_retained_case retained-lock enclosing
  held_plain_get_slot "$FOREIGN_CASE"
  : > "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-lock: run 1 should have asked the driver once"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-lock: an unchanged retry asked the driver"
  git -C "$FOREIGN_CASE/project" worktree unlock "$FOREIGN_COPY"
  sleep 0.1 & pid=$!
  wait "$pid" 2>/dev/null || true
  git -C "$FOREIGN_CASE/project" worktree lock --reason "vernant-session-active owner=launcher:$pid launcher=$pid" "$FOREIGN_COPY"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "retained-lock: a replaced creation lock was not assessed again exactly once"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "retained-lock: the retry after the replaced lock asked the driver"
  pass "a replaced creation lock of a kept copy asks the driver exactly once more and its retry asks nothing"
}

# (a): an anchored but unlanded commit, or an untracked .claude file, is refused; without
# --force before the driver, with --force by the kept route's own proof after it; the retry asks
# the driver nothing either way.
test_the_kept_route_refuses_an_anchored_but_unlanded_commit_and_an_untracked_claude_file() {
  local rc shape sha mode want
  for shape in anchored-unlanded untracked-claude; do
    for mode in plain force; do
      make_retained_case "retained-proof-$shape-$mode" enclosing
      case "$shape" in
        anchored-unlanded)
          printf 'new work\n' > "$FOREIGN_COPY/work.txt"
          git -C "$FOREIGN_COPY" add work.txt
          git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm "unlanded work"
          sha=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
          git -C "$FOREIGN_CASE/project" update-ref "refs/fm/anchor/task-x1-$sha" "$sha"
          ;;
        untracked-claude)
          printf 'new work\n' > "$FOREIGN_COPY/.claude/new-work.txt"
          ;;
      esac
      held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
      FOREIGN_TEARDOWN_ARGS=()
      [ "$mode" = plain ] || FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
      run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
      expect_code 1 "$rc" "retained-proof-$shape-$mode: work that is not landed or not clean must not be closed over: $(cat "$FOREIGN_CASE/stderr")"
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-proof-$shape-$mode: the task record was removed"
      assert_present "$FOREIGN_COPY/.git" "retained-proof-$shape-$mode: the copy was removed"
      assert_grep 'REFUSED' "$FOREIGN_CASE/stderr" "retained-proof-$shape-$mode: no cause was printed"
      want=$(retained_call_count)
      run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
      FOREIGN_TEARDOWN_ARGS=()
      expect_code 1 "$rc" "retained-proof-$shape-$mode: the retry must refuse again: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals "$want" "$(retained_call_count)" "retained-proof-$shape-$mode: an unchanged retry asked the driver again"
    done
  done
  pass "a kept copy with an anchored but unlanded commit or an untracked .claude file is refused, with and without --force, and its retry asks the driver nothing"
}

# C3 (a2), the shape where the ordinary proof passes: the task's current copy is the pool slot
# (clean and landed), and its prior copy, nested in the slot and locked by Vernant, holds a
# commit only a refs/fm/anchor ref keeps. The pre-driver proof accepts an anchored prior copy, so
# the driver IS asked (1 call, 1 tar); the kept route then proves the copy itself and refuses it
# (an anchor ref alone does not land it), and keeps the task, the copy, the slot and its claim.
# Two retries, with and without --force, add no driver call and no tar.
test_an_anchor_only_prior_copy_passes_the_ordinary_proof_and_is_refused_by_the_kept_route_after_the_driver() {
  local rc mode sha run
  for mode in plain force; do
    make_retained_case "retained-anchor-after-driver-$mode" reverse
    printf 'new work\n' > "$FOREIGN_COPY/work.txt"
    git -C "$FOREIGN_COPY" add work.txt
    git -C "$FOREIGN_COPY" -c user.email=t@t -c user.name=t commit -qm "unlanded work"
    sha=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
    git -C "$FOREIGN_CASE/project" update-ref "refs/fm/anchor/task-x1-$sha" "$sha"
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    FOREIGN_TEARDOWN_ARGS=()
    [ "$mode" = plain ] || FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
    for run in 1 2 3; do
      run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
      expect_code 1 "$rc" "anchor-after-driver-$mode run $run: an anchor-only prior copy must not be closed over: $(cat "$FOREIGN_CASE/stderr")"
      assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "anchor-after-driver-$mode run $run: the driver must have been asked once and written one tar, and never again"
      kept_assert_lacks 'ship deliverable is not landed' "$FOREIGN_CASE/stderr" "anchor-after-driver-$mode run $run: the ordinary proof refused before the driver, so this is not the kept route's refusal"
      assert_grep 'a refs/fm/anchor ref alone does not land it' "$FOREIGN_CASE/stderr" "anchor-after-driver-$mode run $run: the kept route's cause was not printed"
      assert_present "$(retained_record_path)" "anchor-after-driver-$mode run $run: the driver's answer was not recorded"
      assert_present "$FOREIGN_CASE/state/task-x1.meta" "anchor-after-driver-$mode run $run: the task record was removed"
      assert_present "$FOREIGN_COPY/work.txt" "anchor-after-driver-$mode run $run: the unlanded work was removed"
      assert_absent "$FOREIGN_CASE/treehouse.log" "anchor-after-driver-$mode run $run: the pool slot was returned"
    done
    FOREIGN_TEARDOWN_ARGS=()
  done
  pass "an anchor-only prior copy passes the ordinary proof, is refused by the kept route after the driver's one call and one tar with its answer recorded, and two retries, with and without --force, ask the driver nothing"
}

test_the_retained_record_states_the_disposition_facts() {
  local rc record
  make_retained_case retained-text enclosing
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-text: the close must succeed"
  record=$(retained_record_path)
  assert_grep "--execute-cleanup" "$record" "retained-text: the record does not say what the driver's --execute-cleanup does"
  assert_grep "writes another archive" "$record" "retained-text: the record does not say the driver writes another archive"
  assert_grep "teardown changes nothing in it" "$record" "retained-text: the record does not say teardown changes nothing in the copy"
  assert_grep "removing the copy depends on Vernant's driver" "$record" "retained-text: the record does not say who removes the copy"
  pass "the retained record states why the copy is kept, that teardown changes nothing in it, that the driver's --execute-cleanup writes another archive and that removing it depends on Vernant's driver"
}


# F-round probes, two real processes on one kept copy. The first teardown holds in
# the driver (the stand-in sleeps after it wrote its tar); the second starts while
# it is there. Whatever the second does, the driver is asked once and one tar exists.
# Two overlapping activations with a deterministic handshake: the first teardown's stand-in
# driver writes `entered` and waits for `release`, the second command starts only after
# `entered`, its attempt and output are recorded by the caller, and only then is `release`
# written. No wait here has a cut-off: a wait that runs long prints one slow-alarm line and
# keeps waiting (the first run dying ends the wait for `entered`, the second returning writes
# `release`).
# C2 (unchanged), closed end state: a retry of a task that closed around a kept copy says it is
# already closed, names the record, exits 0 and asks the driver nothing.
test_a_retry_of_a_closed_kept_copy_task_says_it_is_already_closed() {
  local rc
  make_retained_case retained-closed-retry enclosing
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-closed-retry: the close must succeed: $(cat "$FOREIGN_CASE/stderr")"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-closed-retry: a retry of a closed task must say so and succeed: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'already closed' "$FOREIGN_CASE/stdout" "retained-closed-retry: the retry did not say the task is already closed"
  assert_grep "$(retained_record_path)" "$FOREIGN_CASE/stdout" "retained-closed-retry: the retry did not name the record"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-closed-retry: the retry asked the driver"
  pass "a retry of a closed kept-copy task says it is already closed, names the record and asks the driver nothing"
}

# F8: a task record that is damaged rather than gone, one removed by hand after a refused close,
# and a pending backlog close are never reported as already closed; a completed close is.
test_a_damaged_or_unclosed_task_record_is_never_reported_as_already_closed() {
  local rc
  make_retained_case retained-closed-shape enclosing
  held_plain_get_slot "$FOREIGN_CASE"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  : > "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "closed-shape: the close without a durable lease must refuse"
  assert_present "$(retained_record_path)" "closed-shape: the refused close wrote no retained record, so the case tests nothing"
  mv "$FOREIGN_CASE/state/task-x1.meta" "$FOREIGN_CASE/meta.saved"
  mkdir "$FOREIGN_CASE/state/task-x1.meta"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "closed-shape: a task record that is a directory must refuse"
  kept_assert_lacks 'already closed' "$FOREIGN_CASE/stdout" "closed-shape: a damaged task record was reported as already closed"
  rmdir "$FOREIGN_CASE/state/task-x1.meta"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "closed-shape: a record removed by hand after a refused close must refuse"
  kept_assert_lacks 'already closed' "$FOREIGN_CASE/stdout" "closed-shape: a refused close was reported as already closed once its record went"
  assert_equals in_flight "$(backlog_row_state "$FOREIGN_CASE")" "closed-shape: the backlog item moved"
  make_retained_case retained-closed-control enclosing
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "closed control: the close must succeed: $(grep -m 3 -E 'REFUSED|error' "$FOREIGN_CASE/stderr")"
  printf 'id=task-x1\n' > "$FOREIGN_CASE/state/task-x1.backlog-close"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  kept_assert_lacks 'already closed' "$FOREIGN_CASE/stdout" "closed control: a pending backlog close was reported as already closed"
  rm -f "$FOREIGN_CASE/state/task-x1.backlog-close"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "closed control: the retry of a closed task must succeed"
  assert_grep 'already closed' "$FOREIGN_CASE/stdout" "closed control: the retry of a closed task did not say it is already closed"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "closed control: the retry asked the driver"
  pass "a damaged task record, one removed after a refused close and a pending backlog close are never reported as already closed; a completed close is"
}

# C2 (post-driver): the copy's record cannot be written (its folder takes no new file): every
# run refuses before the driver with a refusal record in data/<task>/closeout-refused/, and once
# the folder can be written the next run asks once, closes and deletes the refusal record.
test_an_unwritable_retained_record_never_makes_an_unchanged_retry_ask_the_driver() {
  local rc dir run refused
  make_retained_case retained-unwritable-retry enclosing
  dir=$FOREIGN_CASE/data/copy-sweep/retained
  mkdir -p "$dir"
  chmod a-w "$dir"
  if [ "$(id -u)" = 0 ]; then chmod u+w "$dir"; pass "skipped as root"; return 0; fi
  refused=$FOREIGN_CASE/data/task-x1/closeout-refused/$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  for run in 1 2 3; do
    run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
    expect_code 1 "$rc" "retained-unwritable-retry: run $run must refuse: $(cat "$FOREIGN_CASE/stderr")"
    assert_equals "0 0" "$(retained_call_count) $(retained_tar_count)" "retained-unwritable-retry: run $run asked the driver"
    assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-unwritable-retry: run $run removed the task record"
    assert_grep 'cause=' "$refused" "retained-unwritable-retry: run $run left no refusal record with its cause"
  done
  chmod u+w "$dir"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-unwritable-retry: once the record can be written the close must succeed: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-unwritable-retry: the close after the cause went asked more than once"
  assert_absent "$refused" "retained-unwritable-retry: the refusal record outlived its cause"
  pass "an unwritable retained record refuses every unchanged retry before the driver with a refusal record, and the close follows with one call once it is writable"
}

retained_overlap_run() {  # <label> <second-command...>: first run in the background
  local label=$1 first_pid releaser_pid n after
  shift
  rm -f "$FOREIGN_CASE/entered" "$FOREIGN_CASE/release"
  after=": > '$FOREIGN_CASE/entered'; n=0; until [ -e '$FOREIGN_CASE/release' ]; do sleep 0.1; n=\$((n + 1)); [ \"\$n\" -ne 300 ] || echo 'slow: the stand-in driver is still waiting for release' >&2; done"
  (
    env FM_TEARDOWN_VERNANT_PYTHON="$FOREIGN_CASE/vernant-python" FM_STUB_CLOSEOUT=retained \
      "FM_STUB_AFTER=$after" FM_HOME="$FOREIGN_CASE/home" \
      FM_ROOT_OVERRIDE="$FOREIGN_CASE/code-root" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
      FM_DATA_OVERRIDE="$FOREIGN_CASE/data" FM_CONFIG_OVERRIDE="$FOREIGN_CASE/config" \
      NM_HOME="$FOREIGN_CASE/nm" PATH="$FOREIGN_CASE/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
      "$TEARDOWN" task-x1 > "$FOREIGN_CASE/stdout.first" 2> "$FOREIGN_CASE/stderr.first"
    echo $? > "$FOREIGN_CASE/rc.first"
  ) &
  first_pid=$!
  n=0
  until [ -f "$FOREIGN_CASE/entered" ]; do
    kill -0 "$first_pid" 2>/dev/null || break
    sleep 0.2
    n=$((n + 1))
    [ "$n" -ne 150 ] || echo "slow: $label: the first teardown has not entered the driver yet" >&2
  done
  [ -f "$FOREIGN_CASE/entered" ] || fail "$label: the first run ended without entering the driver"
  # The second activation either refuses at once or queues behind the first for a lock it
  # holds. A releaser writes `release` once the second is observed waiting (the lock monitor's
  # wait marker exists in the state folder); the second's own return writes it too.
  (
    n=0
    until [ -e "$FOREIGN_CASE/release" ]; do
      ls "$FOREIGN_CASE"/state/.lock-monitor.wait.* > /dev/null 2>&1 && break
      sleep 0.2
      n=$((n + 1))
      [ "$n" -ne 150 ] || echo "slow: $label: the second activation is not waiting yet" >&2
    done
    cat "$FOREIGN_CASE"/state/.lock-monitor.wait.* > "$FOREIGN_CASE/waiting-at-release.txt" 2>/dev/null || true
    : > "$FOREIGN_CASE/release"
  ) &
  releaser_pid=$!
  "$@" || true
  : > "$FOREIGN_CASE/release"
  wait "$releaser_pid" 2>/dev/null || true
  wait "$first_pid" 2>/dev/null || true
}

test_two_overlapping_teardowns_of_one_kept_copy_make_one_archive() {
  local rc
  make_retained_case retained-overlap-teardown enclosing
  retained_overlap_run retained-overlap-teardown run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  cp "$FOREIGN_CASE/stderr" "$FOREIGN_CASE/stderr.second"
  # The second activation queued behind the first (the lock monitor's wait marker was seen) or, on a
  # host whose lifecycle lock does not queue, was refused at once because another lifecycle action
  # holds the task; either way it never reached the driver while the first was in it. A second run
  # that did neither would have run beside the first, and the count below would not mean anything.
  if [ ! -s "$FOREIGN_CASE/waiting-at-release.txt" ]; then
    assert_grep "another lifecycle action is already running for task task-x1" "$FOREIGN_CASE/stderr.second" \
      "retained-overlap-teardown: the second teardown neither waited on the first one's lock nor was refused because of it: $(tail -3 "$FOREIGN_CASE/stderr.second")"
  fi
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-overlap-teardown: two overlapping teardowns made more than one driver call or tar (first rc $(cat "$FOREIGN_CASE/rc.first"), second rc $rc: $(tail -3 "$FOREIGN_CASE/stderr.second"))"
  pass "two overlapping teardowns of one kept copy ask the driver once and write one tar (first rc $(cat "$FOREIGN_CASE/rc.first"), second rc $rc; the second waited on: $(sed -n 2p "$FOREIGN_CASE/waiting-at-release.txt" 2>/dev/null | sed "s#$FOREIGN_CASE/##" | tr '\n' ' '))"
}

test_a_file_created_in_the_copy_while_the_driver_runs_is_not_closed_over() {
  local rc
  make_retained_case retained-late-file enclosing
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained "FM_STUB_AFTER=printf 'late\n' > '$FOREIGN_COPY/notes/late.dat'"
  expect_code 1 "$rc" "retained-late-file: a unique ignored file created during the driver call must not be closed over: $(cat "$FOREIGN_CASE/stderr")"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "retained-late-file: the task record was removed"
  assert_present "$FOREIGN_COPY/notes/late.dat" "retained-late-file: the late file is gone"
  assert_equals "late" "$(cat "$FOREIGN_COPY/notes/late.dat")" "retained-late-file: the late file changed"
  pass "a unique ignored file created in the copy while the driver runs refuses the close and stays in the copy"
}


test_an_aged_record_of_an_unchanged_kept_copy_still_asks_the_driver_nothing() {
  local rc record aged_at age
  # 400 days proves non-expiration across >1 year without duplicating the 4-run sandbox.
  age=400
  make_retained_case "retained-aged-$age" enclosing
  held_plain_get_slot "$FOREIGN_CASE"
  : > "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "retained-aged-$age: run 1 must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
  record=$(retained_record_path)
  aged_at=$(date -u -v-"$age"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$age days ago" +%Y-%m-%dT%H:%M:%SZ)
  sed "s/^recorded-at=.*/recorded-at=$aged_at/" "$record" > "$record.aged" && mv "$record.aged" "$record"
  find "$FOREIGN_CASE/data" -type f -exec touch -t "$(date -u -v-"$age"d +%Y%m%d%H%M 2>/dev/null || date -u -d "$age days ago" +%Y%m%d%H%M)" {} +
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 1 "$rc" "retained-aged-$age: the aged run must refuse for the lease: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-aged-$age: an aged record asked the driver again"
  rm -f "$FOREIGN_CASE/no-lease-command"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  expect_code 0 "$rc" "retained-aged-$age: the aged record must still close the task: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-aged-$age: the closing run asked the driver again"
  run_foreign_teardown rc FM_STUB_CLOSEOUT=retained
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "retained-aged-$age: a run after the close asked the driver"
  pass "a record 30 and 400 days old (its time fields and every file time) of an unchanged kept copy still asks the driver nothing, before and after the close"
}


teardown_test_cases=(
test_a_foreign_copy_whose_landing_could_not_be_checked_is_not_held
test_a_failure_after_the_point_of_no_return_still_leaves_the_held_notice_and_record
test_a_forced_close_never_holds_a_foreign_copy
test_a_slot_with_no_foreign_copy_closes_and_returns_as_before
test_foreign_copy_named_by_an_alias_in_an_active_record_is_refused
test_half_removed_foreign_copy_is_refused_as_before
test_recycled_launcher_pid_does_not_own_a_foreign_copy
test_live_launcher_keeps_its_foreign_copy
test_task_own_session_as_lock_launcher_does_not_block_release
test_unrelated_or_stubborn_lock_launcher_keeps_its_foreign_copy
test_process_in_foreign_copy_keeps_it
test_task_own_process_inside_foreign_copy_is_ended_and_released
test_two_foreign_copies_are_released_together_or_not_at_all
test_foreign_copy_nested_in_another_is_removed_first
test_foreign_copy_is_released_before_the_project_lock_wait
test_closeout_uses_the_slots_default_interpreter
test_missing_closeout_driver_or_interpreter_leaves_the_copy_in_place
test_closeout_refusal_and_foreign_locks_leave_the_copy_in_place
test_locked_own_nested_copy_is_released_by_the_closeout_driver
test_locked_own_nested_copy_with_a_recycled_launcher_pid_is_released
test_live_launcher_outside_the_task_keeps_its_locked_own_copy
test_locked_own_nested_copy_that_is_not_proved_is_refused
test_locked_own_nested_copy_with_unique_ignored_file_is_preserved_and_released
test_locked_own_nested_copy_stays_when_a_foreign_copy_is_refused
test_locked_own_nested_copy_is_released_before_the_project_lock_wait
test_closeout_refusal_reports_tail_and_preserves_complete_output
test_closeout_driver_refusal_leaves_a_locked_own_copy_and_its_records
test_kept_copy_helper_a_valid_answer_is_recorded_once_and_judged_again_without_the_driver
test_kept_copy_helper_an_invalid_kept_answer_is_recorded_and_never_asked_again
test_kept_copy_helper_the_driver_is_asked_only_when_its_answer_can_be_recorded
test_kept_copy_helper_a_refused_kept_copy_is_judged_again_from_its_record
test_kept_copy_helper_the_retire_step_leaves_a_matching_kept_copy_out
test_kept_copy_helper_the_proof_queues_no_signal_for_a_matching_kept_copy
test_kept_copy_helper_a_receipt_that_is_not_a_regular_file_still_holds_the_copy
test_a_retry_of_a_closed_kept_copy_task_says_it_is_already_closed
test_a_damaged_or_unclosed_task_record_is_never_reported_as_already_closed
test_an_unwritable_retained_record_never_makes_an_unchanged_retry_ask_the_driver
test_kept_copy_helper_a_retry_of_a_closed_task_says_it_is_already_closed
test_kept_copy_helper_a_changed_copy_is_preserved_beside_its_earlier_preserve_which_is_never_replaced
test_kept_copy_helper_a_copy_with_nothing_selected_keeps_one_preserve_across_retries
test_kept_copy_helper_each_distinct_selected_state_keeps_one_preserve_on_the_released_route
test_kept_copy_helper_each_distinct_selected_state_keeps_one_preserve_on_the_kept_route
test_kept_copy_helper_the_entry_plan_lets_a_kept_own_copy_through_and_a_matching_record_skips_it
test_kept_copy_helper_a_record_that_cannot_be_written_leaves_a_refusal_record
test_kept_copy_helper_every_driver_named_path_is_judged_as_written_and_checked_against_the_copy
test_kept_copy_helper_a_file_changed_after_it_was_preserved_is_never_released_unpreserved
test_kept_copy_helper_root_files_named_like_the_preserves_own_files_are_preserved
test_a_landed_task_closes_around_an_own_copy_the_driver_keeps
test_a_retry_of_an_unchanged_kept_copy_asks_the_driver_nothing
test_a_changed_kept_copy_is_assessed_afresh
test_a_kept_copy_in_a_slot_a_peer_works_in_refuses_and_its_retry_asks_the_driver_nothing
test_every_other_state_of_an_own_copy_the_driver_keeps_still_refuses
test_a_stable_refusal_after_the_driver_asks_the_driver_nothing_on_retry
test_a_kept_copy_whose_cause_went_closes_from_its_record_without_the_driver
test_a_kept_copy_with_only_claude_files_closes_when_its_preserve_is_on_another_filesystem
test_the_preserve_and_the_archives_survive_the_close_and_every_later_run
test_the_default_driver_interpreter_and_the_override_close_the_same_way
test_the_first_teardown_of_a_copy_that_already_holds_tars_asks_the_driver_once
test_a_head_only_change_of_a_kept_copy_asks_the_driver_exactly_once_more
test_a_changed_payload_is_archived_once_per_change_and_never_again_while_unchanged
test_a_replaced_creation_lock_of_a_kept_copy_asks_the_driver_once_more
test_the_kept_route_refuses_an_anchored_but_unlanded_commit_and_an_untracked_claude_file
test_an_anchor_only_prior_copy_passes_the_ordinary_proof_and_is_refused_by_the_kept_route_after_the_driver
test_the_retained_record_states_the_disposition_facts
test_two_overlapping_teardowns_of_one_kept_copy_make_one_archive
test_a_file_created_in_the_copy_while_the_driver_runs_is_not_closed_over
test_an_aged_record_of_an_unchanged_kept_copy_still_asks_the_driver_nothing
)

# Restore errexit before the first case of this slice to match the original combined run.
errexit_restored=false
fm_test_before_case() {
  if [ "$errexit_restored" = false ] && [ "$1" = test_a_foreign_copy_whose_landing_could_not_be_checked_is_not_held ]; then
    set -e
    errexit_restored=true
  fi
}
fm_test_run_cases "${teardown_test_cases[@]}" -- "$@"
