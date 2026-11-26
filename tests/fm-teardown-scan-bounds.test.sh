#!/usr/bin/env bash
# bin/fm-teardown.sh's copy-clearance scan while it holds the shared Treehouse project lock, and its exit on SIGTERM.
#
# The scan reads every task record of every local home. A teardown that spent minutes in it held the project lock
# against every spawn in the home, and one that was stopped could leave a child that ignored SIGTERM
# (data/fm-teardown-pure-bash-spin/report.md, sections Fix and Lock window).
#
# What this pins, with the real teardown over private fixtures (a `git` shim in the scan's per-record command blocks
# on a marker the harness releases; nothing waits a fixed time, and no case ends a process with SIGKILL):
#   1. Each of the three project-lock windows in which a scan runs (bin/fm-teardown.sh: the preflight, the slot
#      reservation, the final return) refuses a scan that outlives FM_TEARDOWN_SCAN_DEADLINE_SECS: exit 1, a message
#      naming the scan deadline and a retry, the lock released, nothing changed since the scan began, and a retry
#      that finishes the teardown.
#   2. SIGTERM to the teardown's own process group while a 300-record scan runs ends every process of the group, the
#      leader by SIGTERM with its EXIT trap run, the lock released, nothing changed.
#   3. SIGTERM while the scan waits on a producer that ignores SIGTERM still ends the teardown (case iii).
#   4. SIGTERM after the first destructive step leaves the task record and the copy for a retry, which finishes.
# Usage: bash tests/fm-teardown-scan-bounds.test.sh [test_function_name ...]
# The cases source libraries inside subshells on purpose, so a variable they set there is not the suite's own.
# The snapshot lists names only, with no newline in any.
# shellcheck disable=SC2012,SC2030,SC2031
set -u

# shellcheck source=tests/fm-record-scan-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-record-scan-helpers.sh"

# FM_SCAN_BIN names the bin directory the cases drive (default: this checkout's); pointing it at an older bin/ shows which
# cases fail without the fix.
SCAN_BIN=${FM_SCAN_BIN:-$ROOT/bin}

# scan_snapshot <case-dir>: what a retry depends on, with the lock artefacts left out (they are asserted apart).
scan_snapshot() {
  local c=$1 f
  (
    # shellcheck disable=SC2012 # names only
    cd "$c" || exit 1
    echo "state:"
    # shellcheck disable=SC2010,SC2012 # names only, none with a newline
    ls -A state | grep -v -e lock -e '^[.]teardown-run[.]' | LC_ALL=C sort
    echo "records:"
    for f in state/*.meta h*/state/*.meta; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done
    echo "slot:"
    ls -A pool/9/repo 2>&1 | LC_ALL=C sort
    echo "pool:"
    ls -A pool/9 2>&1 | LC_ALL=C sort
    cat pool/treehouse-state.json 2>&1
    echo "worktrees:"
    git -C project worktree list --porcelain | grep -c '^worktree '
    echo "data:"
    ls -A data 2>&1 | LC_ALL=C sort
  )
}

lock_artefacts() {  # <case-dir>: a project lock, or a holder or waiter in its holds or queue, still in the state directory
  find "$1/state" -maxdepth 3 \( -name '.treehouse-project-*.lock' -o -path '*.treehouse-project-*.lock.holds/*' \
    -o -path '*.treehouse-project-*.lock.queue/*' \) ! -name sequence 2>/dev/null | LC_ALL=C sort
}

# One window: block the scan of the <w>th lock window at its first record, let the deadline pass, release.
scan_deadline_window_case() {  # <window 1|2|3>
  local w=$1 case_dir n entry after rc
  case_dir=$(make_scan_case "deadline-w$w" 6)
  add_fd_git_shim "$case_dir"
  n=$((5 * (w - 1) + 1))
  start_scan_teardown "$case_dir" "$SCAN_BIN" FM_TEARDOWN_SCAN_DEADLINE_SECS=3 FM_BLOCK_AT="$n"
  wait_for_file "$case_dir/block/blocked.$n"
  entry=$(scan_snapshot "$case_dir")
  [ "$(project_lock_state "$case_dir")" = held ] || fail "window $w: the scan does not hold the project lock (the case would prove nothing)"
  wait_until_clock_passes 4
  : > "$case_dir/block/release.$n"
  finish_scan_teardown "$case_dir"
  rc=$(cat "$case_dir/rc")
  expect_code 1 "$rc" "window $w: the scan past its deadline should refuse: $(tail -3 "$case_dir/out")"
  assert_grep "scan deadline" "$case_dir/out" "window $w: the refusal does not name the scan deadline"
  assert_grep "retry the teardown" "$case_dir/out" "window $w: the refusal does not say a retry is safe"
  assert_grep "FM_TEARDOWN_SCAN_DEADLINE_SECS" "$case_dir/out" "window $w: the refusal does not name its setting"
  after=$(scan_snapshot "$case_dir")
  [ "$entry" = "$after" ] || fail "window $w: the refusal changed state:$(printf '\n'; diff <(printf '%s\n' "$entry") <(printf '%s\n' "$after"))"
  [ "$(project_lock_state "$case_dir")" = free ] || fail "window $w: the project lock was not released by the refusal"
  [ -z "$(lock_artefacts "$case_dir")" ] || fail "window $w: lock entries remain: $(lock_artefacts "$case_dir")"
  assert_present "$case_dir/state/task-x1.meta" "window $w: the refusal removed the task record"
  assert_present "$case_dir/pool/9/repo" "window $w: the refusal removed the copy"
  # Retry: nothing blocks, the default deadline applies, and the teardown finishes.
  run_scan_teardown "$case_dir" "$SCAN_BIN"
  expect_code 0 "$(cat "$case_dir/rc")" "window $w: the retry should finish: $(tail -3 "$case_dir/out")"
  assert_absent "$case_dir/state/task-x1.meta" "window $w: the retry left the task record"
}

test_a_scan_past_its_deadline_refuses_in_the_preflight_window() {
  scan_deadline_window_case 1
  pass "window 1 (preflight): a scan past its deadline refuses, changes nothing, frees the lock, and a retry finishes"
}

test_a_scan_past_its_deadline_refuses_in_the_slot_reservation_window() {
  scan_deadline_window_case 2
  pass "window 2 (slot reservation): a scan past its deadline refuses, changes nothing, frees the lock, and a retry finishes"
}

test_a_scan_past_its_deadline_refuses_in_the_final_return_window() {
  scan_deadline_window_case 3
  pass "window 3 (final return): a scan past its deadline refuses, changes nothing, frees the lock, and a retry finishes"
}

test_a_scan_without_the_lock_is_not_bounded_by_the_deadline() {
  local case_dir
  case_dir=$(make_scan_case deadline-unlocked 6)
  add_fd_git_shim "$case_dir"
  # The scans outside the project lock keep their old behaviour: a teardown whose task has no pool slot never
  # holds the lock, so an expired deadline cannot refuse it.
  rm -rf "$case_dir/pool/treehouse-state.json"
  run_scan_teardown "$case_dir" "$SCAN_BIN" FM_TEARDOWN_SCAN_DEADLINE_SECS=1
  assert_no_grep "scan deadline" "$case_dir/out" "an unlocked teardown was refused by the scan deadline"
  pass "the scan deadline is read only for a scan that holds the project lock"
}

# --- SIGTERM ---------------------------------------------------------------------------------------------------------

test_sigterm_during_the_scan_ends_the_whole_group_with_the_lock_released() {
  local case_dir pid before after waited members
  case_dir=$(make_scan_case sigterm-scan 300)
  add_fd_git_shim "$case_dir"
  FM_SCAN_TRACE=1 start_scan_teardown "$case_dir" "$SCAN_BIN" FM_BLOCK_AT=260
  pid=$SCAN_PID
  wait_for_file "$case_dir/block/blocked.260"
  before=$(scan_snapshot "$case_dir")
  [ "$(project_lock_state "$case_dir")" = held ] || fail "sigterm: the scan does not hold the project lock"
  members=$(group_members "$pid" | tr '\n' ' ')
  case " $members " in *" $pid "*) ;; *) fail "sigterm: the leader $pid is not the process group $pid ($members)" ;; esac
  # The group holds only this run: every member descends from the leader.
  kill -TERM -- "-$pid"
  finish_scan_teardown "$case_dir"
  waited=0
  while [ -n "$(group_members "$pid")" ] && [ "$waited" -lt 40 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  [ -z "$(group_members "$pid")" ] || fail "sigterm: processes of the group are still alive after 8 s: $(group_members "$pid" | tr '\n' ' ')"
  expect_code 143 "$(cat "$case_dir/rc")" "sigterm: the leader should end by SIGTERM (143)"
  assert_grep "teardown_release_locks" "$case_dir/out" "sigterm: the EXIT trap did not run"
  after=$(scan_snapshot "$case_dir")
  [ "$before" = "$after" ] || fail "sigterm: a mutation followed the signal:$(printf '\n'; diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
  [ "$(project_lock_state "$case_dir")" = free ] || fail "sigterm: the project lock was not released"
  [ -z "$(lock_artefacts "$case_dir")" ] || fail "sigterm: lock entries remain: $(lock_artefacts "$case_dir")"
  pass "SIGTERM during a 300-record scan ends every process of the group, the leader by SIGTERM, the lock released, nothing changed"
}

test_sigterm_while_the_scan_waits_on_a_producer_that_ignores_it_still_ends_the_teardown() {
  local case_dir pid before after waited producer rc
  case_dir=$(make_scan_case sigterm-producer 40)
  add_fd_git_shim "$case_dir"
  # The scan's per-record git is a producer that ignores SIGTERM and never exits: Bash 3.2 does not act on SIGTERM
  # while it reads a command substitution's pipe, so a parent reading git that way would stay blocked.
  FM_SCAN_TRACE=1 start_scan_teardown "$case_dir" "$SCAN_BIN" FM_BLOCK_AT=20 FM_BLOCK_IGNORE_TERM=1
  pid=$SCAN_PID
  wait_for_file "$case_dir/block/blocked.20"
  producer=$(cat "$case_dir/block/producer.pid")
  before=$(scan_snapshot "$case_dir")
  [ "$(project_lock_state "$case_dir")" = held ] || fail "producer: the scan does not hold the project lock"
  kill -TERM -- "-$pid"
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 40 ]; do
    sleep 0.2
    waited=$((waited + 1))
  done
  rc=blocked
  if ! kill -0 "$pid" 2>/dev/null; then finish_scan_teardown "$case_dir"; rc=$(cat "$case_dir/rc"); fi
  after=$(scan_snapshot "$case_dir")
  lock=$(project_lock_state "$case_dir")
  producer_alive=0
  kill -0 "$producer" 2>/dev/null && producer_alive=1
  # The result is recorded; only now does the harness remove its own deliberate non-terminating producer.
  # This is the one SIGKILL of the suite: cleanup of the fixture's producer, never how a case passes.
  kill -KILL "$producer" 2>/dev/null
  if [ "$rc" = blocked ]; then
    kill -KILL "$pid" 2>/dev/null
    fail "producer: the teardown was still blocked 8 s after SIGTERM (its EXIT trap never ran)"
  fi
  [ "$producer_alive" = 1 ] || fail "producer: the producer was already gone, so the case proves nothing"
  expect_code 143 "$rc" "producer: the leader should end by SIGTERM (143)"
  assert_grep "teardown_release_locks" "$case_dir/out" "producer: the EXIT trap did not run"
  [ "$lock" = free ] || fail "producer: the project lock was not released"
  [ "$before" = "$after" ] || fail "producer: a mutation followed the signal"
  pass "SIGTERM ends a teardown whose scan waits on a producer that ignores SIGTERM: trap run, lock released, nothing changed"
}

# make_hanging_canonical_bin <dir>: <dir>/bin holds symlinks to every bin file but fm-task-copy-lib.sh, whose copy has a
# fm_task_copy_canonical_dir that, for one filler copy asked by the copy-clearance scan, hangs ignoring SIGTERM (a fork
# child that never finishes, as the stalled teardown's was). FM_HANG_SRC_BIN names the bin directory to copy from (default: this checkout's).
make_hanging_canonical_bin() {
  local dir=$1 src=${FM_HANG_SRC_BIN:-$SCAN_BIN} f
  mkdir -p "$dir/bin"
  for f in "$src"/*; do ln -s "$f" "$dir/bin/${f##*/}"; done
  rm -f "$dir/bin/fm-task-copy-lib.sh"
  python3 -I - "$src/fm-task-copy-lib.sh" "$dir/bin/fm-task-copy-lib.sh" <<'PY' || fail "the library has no fm_task_copy_canonical_dir to make hang"
import sys
text = open(sys.argv[1]).read()
anchor = 'fm_task_copy_canonical_dir() {  # <path>\n  local target=$1\n'
if text.count(anchor) != 1:
    sys.exit(1)
hang = anchor + '  case "$target:${FUNCNAME[1]:-}" in */pool/fill-20/repo:require_cleanup_copy_clearance) trap "" TERM; : > "$FM_BLOCK_DIR/blocked.canon"; while :; do sleep 1; done ;; esac\n'
open(sys.argv[2], "w").write(text.replace(anchor, hang))
PY
}

test_sigterm_while_the_scan_waits_on_a_forked_producer_that_ignores_it_ends_the_teardown() {
  local case_dir pid before after waited rc lock producer_alive producer members
  case_dir=$(make_scan_case sigterm-canon 40)
  add_fd_git_shim "$case_dir"
  make_hanging_canonical_bin "$case_dir/h"
  # Record 20's copy canonicalization is a forked producer that ignores SIGTERM and never closes its pipe. Bash 3.2 does
  # not act on SIGTERM while it reads a command substitution's pipe, so a scan that canonicalizes through one stays
  # blocked; the scan reads the path in-process, so it never forks for it.
  FM_SCAN_TRACE=1 start_scan_teardown "$case_dir" "$case_dir/h/bin"
  pid=$SCAN_PID
  waited=0
  while [ ! -e "$case_dir/block/blocked.canon" ] && kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 3000 ]; do sleep 0.1; waited=$((waited + 1)); done
  if [ ! -e "$case_dir/block/blocked.canon" ]; then
    finish_scan_teardown "$case_dir"
    # The teardown never forked for that path: it ran the scan to its end without the producer.
    expect_code 0 "$(cat "$case_dir/rc")" "canon: the teardown should have run its scan to the end without the producer"
    assert_absent "$case_dir/state/task-x1.meta" "canon: the teardown left its task record"
    pass "the scan canonicalizes copies in-process: a forking producer that ignores SIGTERM is never read, so it cannot hold the teardown"
    return 0
  fi
  producer=$(python3 -I "$ROOT/bin/fm-proc-info.py" table pid,ppid,pgid | awk -v g="$pid" '{ gsub(",", " ") } $3 == g && $2 == g { print $1; exit }')
  before=$(scan_snapshot "$case_dir")
  [ "$(project_lock_state "$case_dir")" = held ] || fail "canon: the scan does not hold the project lock"
  kill -TERM -- "-$pid"
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 40 ]; do sleep 0.2; waited=$((waited + 1)); done
  rc=blocked
  if ! kill -0 "$pid" 2>/dev/null; then finish_scan_teardown "$case_dir"; rc=$(cat "$case_dir/rc"); fi
  after=$(scan_snapshot "$case_dir")
  lock=$(project_lock_state "$case_dir")
  producer_alive=0
  [ -z "$producer" ] || ! kill -0 "$producer" 2>/dev/null || producer_alive=1
  # The result is recorded; only now is the fixture's own deliberate non-terminating producer removed (cleanup, never a pass).
  [ -z "$producer" ] || kill -KILL "$producer" 2>/dev/null
  if [ "$rc" = blocked ]; then
    kill -KILL "$pid" 2>/dev/null
    fail "canon: the teardown was still blocked 8 s after SIGTERM, reading a producer that ignores it (its EXIT trap never ran)"
  fi
  [ "$producer_alive" = 1 ] || fail "canon: the producer was already gone, so the case proves nothing"
  expect_code 143 "$rc" "canon: the leader should end by SIGTERM (143)"
  assert_grep "teardown_release_locks" "$case_dir/out" "canon: the EXIT trap did not run"
  [ "$lock" = free ] || fail "canon: the project lock was not released"
  [ "$before" = "$after" ] || fail "canon: a mutation followed the signal"
  pass "SIGTERM ends a teardown whose scan was blocked reading a forked producer that ignores it"
}

test_sigterm_after_the_first_destructive_step_leaves_a_retry_that_finishes() {
  local case_dir pid
  case_dir=$(make_scan_case sigterm-return 8)
  # A Treehouse whose return waits: the teardown has by then killed its endpoint and removed its runtime state.
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  : > "$FM_BLOCK_DIR/blocked.return"
  waited=0
  while [ ! -e "$FM_BLOCK_DIR/release.return" ] && [ "$waited" -lt 3000 ]; do sleep 0.1; waited=$((waited + 1)); done
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  start_scan_teardown "$case_dir" "$SCAN_BIN"
  pid=$SCAN_PID
  wait_for_file "$case_dir/block/blocked.return"
  kill -TERM -- "-$pid"
  finish_scan_teardown "$case_dir"
  expect_code 143 "$(cat "$case_dir/rc")" "sigterm after return: the leader should end by SIGTERM"
  [ -z "$(group_members "$pid")" ] || fail "sigterm after return: processes of the group are alive: $(group_members "$pid" | tr '\n' ' ')"
  [ "$(project_lock_state "$case_dir")" = free ] || fail "sigterm after return: the project lock was not released"
  assert_present "$case_dir/state/task-x1.meta" "sigterm after return: the record the retry needs is gone"
  assert_present "$case_dir/pool/9/repo" "sigterm after return: the copy is gone before the return ran"
  # The retry has a Treehouse that returns at once.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$case_dir/fakebin/treehouse"
  run_scan_teardown "$case_dir" "$SCAN_BIN"
  expect_code 0 "$(cat "$case_dir/rc")" "sigterm after return: the retry should finish: $(tail -3 "$case_dir/out")"
  assert_absent "$case_dir/state/task-x1.meta" "sigterm after return: the retry left the task record"
  pass "SIGTERM after the first destructive step leaves the record and the copy, and a retry finishes the teardown"
}

CASES=(
  test_a_scan_past_its_deadline_refuses_in_the_preflight_window
  test_a_scan_past_its_deadline_refuses_in_the_slot_reservation_window
  test_a_scan_past_its_deadline_refuses_in_the_final_return_window
  test_a_scan_without_the_lock_is_not_bounded_by_the_deadline
  test_sigterm_while_the_scan_waits_on_a_producer_that_ignores_it_still_ends_the_teardown
  test_sigterm_while_the_scan_waits_on_a_forked_producer_that_ignores_it_ends_the_teardown
  test_sigterm_after_the_first_destructive_step_leaves_a_retry_that_finishes
  test_sigterm_during_the_scan_ends_the_whole_group_with_the_lock_released
)

fm_test_run_cases "${CASES[@]}" -- "$@"
echo "# all fm-teardown-scan-bounds tests passed"
