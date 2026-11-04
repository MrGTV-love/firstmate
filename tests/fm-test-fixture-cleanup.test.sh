#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans) and its tracked-stub
# reap (fm_test_reap_processes).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

test_registries_avoid_git_worktree_root() {
  # A TMPDIR pointed at a repository root used to place live `.fm-test-*`
  # registries beside tracked files. A concurrent git add during a suite then
  # committed them (observed on the claim-walk CI fix round). The helper must
  # keep registries and fixture roots outside that root for the whole run.
  local harness repo dirfile child_dir pid tries entry
  harness=$(fm_test_tmproot fm-test-cleanup-gitroot-harness)
  repo="$harness/repo"
  dirfile="$harness/child-dir"
  mkdir -p "$repo"
  git -C "$repo" init -q
  bash -c '
    export TMPDIR="$1"
    # shellcheck source=tests/lib.sh
    . "$2"
    d=$(fm_test_tmproot fm-test-cleanup-gitroot)
    printf "%s\n" "$d" > "$3"
    # Hold the suite open so a concurrent add would see any root-side leak.
    while :; do sleep 0.1; done
  ' _ "$repo" "$LIB" "$dirfile" &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the git-root TMPDIR child never published its fixture root"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the git-root TMPDIR child did not create a fixture root"
  case "$child_dir" in
    "$repo"|"$repo"/*)
      fail "fm_test_tmproot placed a fixture root inside the git worktree root: $child_dir"
      ;;
  esac
  for entry in "$repo"/.fm-test-cleanup.* "$repo"/.fm-test-procevent.* "$repo"/.fm-test-watcher.*; do
    [ ! -e "$entry" ] || fail "a live test registry landed in the git worktree root: $entry"
  done
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  assert_absent "$child_dir" \
    "the git-root TMPDIR child's fixture root survived SIGTERM"
  pass "test registries and fixture roots stay out of a git worktree TMPDIR"
}

# The tracked-stub reap cases run in a child shell that sources the real helper.
# Stubs are orphans, so only the process registry can reach them. Each case
# changes one step of the race or fault it needs and leaves the reap loop real.
new_reap_harness() {
  local harness
  harness=$(fm_test_tmproot fm-test-cleanup-reap) || return 1
  cat > "$harness/child-lib.sh" <<'SH'
. "$LIB"
start_stub() {  # <pidfile> <seconds>
  local pid
  pid=$(sleep "$2" >/dev/null 2>&1 & printf '%s\n' "$!")
  fm_test_record_process "$1" "$pid" || exit 1
  fm_test_track_process "$1" "sleep $2" || exit 1
}
stub_pid() {  # <pidfile>
  local pid
  IFS=$'\t' read -r pid _ < "$1"
  printf '%s\n' "$pid"
}
pid_gone() {  # <pid>
  local tries=0
  while [ "$tries" -lt 100 ]; do
    fm_test_process_read lstart "$1" >/dev/null || return 0
    sleep 0.05
    tries=$((tries + 1))
  done
  return 1
}
report_stub() {  # <label> <pidfile>
  if pid_gone "$(stub_pid "$2")"; then echo "$1=gone"; else echo "$1=alive"; fi
}
stub_exits_after_alive_check() {  # <pidfile>
  EXITING_STUB=$1
  eval "real_alive() $(declare -f fm_test_process_alive | sed 1d)"
  fm_test_process_alive() {
    real_alive "$@" || return 1
    [ "$1" = "$EXITING_STUB" ] || return 0
    builtin kill -KILL "$FM_TEST_PROCESS_PID"
    pid_gone "$FM_TEST_PROCESS_PID"
  }
}
group_read_fails() {
  eval "real_read() $(declare -f fm_test_process_read | sed 1d)"
  fm_test_process_read() {
    [ "$1" != pgid ] || return 1
    real_read "$@"
  }
}
record_kills() {  # <log>
  KILL_LOG=$1
  kill() {
    printf '%s\n' "$*" >> "$KILL_LOG"
    builtin kill "$@"
  }
}
stub_survives_kill() {  # <pidfile>
  SURVIVING_PID=$(stub_pid "$1")
  kill() {
    [ "${2:-}" != "$SURVIVING_PID" ] || return 0
    builtin kill "$@"
  }
}
SH
  fm_test_track_process "$harness/first.pid" "sleep 61" || return 1
  fm_test_track_process "$harness/second.pid" "sleep 62" || return 1
  printf '%s\n' "$harness"
}

run_reap_child() {  # <harness>, with the child script on stdin
  cat > "$1/child.sh"
  REAP_CHILD_OUT=$(HARNESS="$1" LIB="$LIB" bash "$1/child.sh" 2>&1)
  REAP_CHILD_STATUS=$?
}

test_reap_continues_past_stub_that_exits_after_alive_check() {
  local harness
  harness=$(new_reap_harness) || fail "could not create the reap harness"
  run_reap_child "$harness" <<'SH'
. "$HARNESS/child-lib.sh"
start_stub "$HARNESS/first.pid" 61
start_stub "$HARNESS/second.pid" 62
stub_exits_after_alive_check "$HARNESS/first.pid"
rc=0
fm_test_reap_processes || rc=$?
echo "reap_rc=$rc"
report_stub second "$HARNESS/second.pid"
if [ -e "$FM_TEST_PROCESS_REGISTRY" ]; then echo registry=present; else echo registry=gone; fi
SH
  assert_contains "$REAP_CHILD_OUT" "reap_rc=0" \
    "a stub that exited after the alive check made the reap report a failure"
  assert_contains "$REAP_CHILD_OUT" "second=gone" \
    "a stub that exited after the alive check stopped the reap before the next entry"
  assert_contains "$REAP_CHILD_OUT" "registry=gone" \
    "a stub that exited after the alive check left the process registry behind"
  pass "the stub reap continues past a stub that exits after the alive check"
}

test_reap_signals_only_the_pid_when_group_read_fails() {
  local harness first second
  harness=$(new_reap_harness) || fail "could not create the reap harness"
  run_reap_child "$harness" <<'SH'
. "$HARNESS/child-lib.sh"
start_stub "$HARNESS/first.pid" 61
start_stub "$HARNESS/second.pid" 62
group_read_fails
record_kills "$HARNESS/kills"
rc=0
fm_test_reap_processes || rc=$?
echo "reap_rc=$rc"
report_stub first "$HARNESS/first.pid"
report_stub second "$HARNESS/second.pid"
SH
  assert_contains "$REAP_CHILD_OUT" "reap_rc=0" \
    "a stub gone after its only signal made the reap report a failure"
  assert_contains "$REAP_CHILD_OUT" "first=gone" \
    "a stub with an unknown group was not signalled"
  assert_contains "$REAP_CHILD_OUT" "second=gone" \
    "a failed group read stopped the reap before the next entry"
  IFS=$'\t' read -r first _ < "$harness/first.pid"
  IFS=$'\t' read -r second _ < "$harness/second.pid"
  assert_equals "-KILL $first"$'\n'"-KILL $second" "$(cat "$harness/kills" 2>/dev/null)" \
    "a failed group read did not limit the signal to the PID"
  pass "a failed group read signals only the PID"
}

test_reap_reports_live_stub_with_unknown_group_after_the_loop() {
  local harness
  harness=$(new_reap_harness) || fail "could not create the reap harness"
  run_reap_child "$harness" <<'SH'
. "$HARNESS/child-lib.sh"
start_stub "$HARNESS/first.pid" 61
start_stub "$HARNESS/second.pid" 62
group_read_fails
stub_survives_kill "$HARNESS/first.pid"
rc=0
fm_test_reap_processes || rc=$?
echo "reap_rc=$rc"
report_stub second "$HARNESS/second.pid"
SH
  assert_contains "$REAP_CHILD_OUT" "reap_rc=1" \
    "the reap did not report a live stub whose group stayed unknown"
  assert_contains "$REAP_CHILD_OUT" "second=gone" \
    "a live stub with an unknown group stopped the reap before the next entry"
  pass "the stub reap reports a live stub with an unknown group after the loop"
}

test_cleanup_finishes_under_errexit_after_stub_exit_race() {
  local harness root
  harness=$(new_reap_harness) || fail "could not create the reap harness"
  run_reap_child "$harness" <<'SH'
set -eu
. "$HARNESS/child-lib.sh"
root=$(fm_test_tmproot fm-test-cleanup-reap-errexit)
echo "root=$root"
start_stub "$HARNESS/first.pid" 61
start_stub "$HARNESS/second.pid" 62
stub_exits_after_alive_check "$HARNESS/first.pid"
exit 0
SH
  root=$(printf '%s\n' "$REAP_CHILD_OUT" | sed -n 's/^root=//p')
  [ -n "$root" ] || fail "the errexit child did not publish its fixture root: $REAP_CHILD_OUT"
  assert_equals 0 "$REAP_CHILD_STATUS" "the errexit child changed its exit status in cleanup"
  assert_absent "$root" "a stub that exited after the alive check stopped cleanup under set -e"
  pass "cleanup finishes under set -e when a stub exits after the alive check"
}

test_cleanup_finishes_under_errexit_when_reap_reports_failure() {
  local harness root
  harness=$(new_reap_harness) || fail "could not create the reap harness"
  run_reap_child "$harness" <<'SH'
set -eu
. "$HARNESS/child-lib.sh"
root=$(fm_test_tmproot fm-test-cleanup-reap-term)
echo "root=$root"
start_stub "$HARNESS/first.pid" 61
group_read_fails
stub_survives_kill "$HARNESS/first.pid"
builtin kill -TERM "$$"
exit 9
SH
  root=$(printf '%s\n' "$REAP_CHILD_OUT" | sed -n 's/^root=//p')
  [ -n "$root" ] || fail "the signalled child did not publish its fixture root: $REAP_CHILD_OUT"
  assert_equals 143 "$REAP_CHILD_STATUS" "a reap failure changed the TERM trap's exit status under set -e"
  assert_absent "$root" "a reap failure stopped signal cleanup under set -e"
  assert_contains "$REAP_CHILD_OUT" "unknown process group" \
    "cleanup hid a live stub whose group stayed unknown"
  pass "signal cleanup finishes under set -e and reports a reap failure"
}

fm_test_only

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_registries_avoid_git_worktree_root
test_reap_continues_past_stub_that_exits_after_alive_check
test_reap_signals_only_the_pid_when_group_read_fails
test_reap_reports_live_stub_with_unknown_group_after_the_loop
test_cleanup_finishes_under_errexit_after_stub_exit_race
test_cleanup_finishes_under_errexit_when_reap_reports_failure
