#!/usr/bin/env bash
# Behavior tests for the orphan sweep tests/lib.sh runs in every sourcing shell
# (fm_test_reap_orphans) and for the per-shell record it reads.
#
# The sweep must (1) remove only directories that carry the .fm-test-fixture
# marker and whose owner is provably dead, (2) keep a live owner's roots and
# every unmarked entry, (3) leave exactly one marked entry behind when a shell is
# KILLed, and (4) not slow down as unrelated fm-* entries pile up in the shared
# temp dir (3.2 s with 50000 of them against 0.47 s with none before the record
# existed; tests/fm-test-fixture-cleanup.test.sh pins the ownership rules).
# The bash -c scripts below expand their own variables in the child shell.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-sweep)

# sourcing_shell <tmpdir> [env...] -- run one shell that sources tests/lib.sh and exits.
sourcing_shell() {
  local tmp=$1
  shift
  env TMPDIR="$tmp" "$@" bash -c '. "$1"' _ "$LIB"
}

# killed_shell <tmpdir> <root-file>: a shell that made a fixture root and was KILLed.
killed_shell() {
  {
    env TMPDIR="$1" bash -c '
      . "$1"
      d=$(fm_test_tmproot fm-test-sweep-killed)
      printf "%s\n" "$d" > "$2"
      kill -KILL $$
    ' _ "$LIB" "$2" >/dev/null 2>&1 || true
  } 2>/dev/null
}

test_killed_shell_leaves_one_marked_entry_and_sweep_removes_it() {
  local tmp="$TMP_ROOT/killed" root records
  mkdir -p "$tmp"
  killed_shell "$tmp" "$TMP_ROOT/killed-root"
  root=$(cat "$TMP_ROOT/killed-root")
  assert_present "$root" "the killed shell's fixture root was not made"
  records=$(find "$tmp/fm-test-owners" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')
  assert_equals 1 "$records" "a killed shell must leave exactly one record (registries and helper roots live inside it)"
  [ -f "$(find "$tmp/fm-test-owners" -mindepth 2 -maxdepth 2 -name .fm-test-fixture | head -1)" ] \
    || fail "the killed shell's record carries no ownership marker"
  # Everything else the shell made is a dotfile-free, prefix-free entry: only
  # the root and the owners container exist at the top.
  assert_equals 2 "$(find "$tmp" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" \
    "a killed shell left more than its fixture root and its record: $(find "$tmp" -mindepth 1 -maxdepth 1 | tr '\n' ' ')"
  # The record was made when lib.sh was sourced, so it ages past the floor first.
  touch -t 202001010000 "$tmp"/fm-test-owners/*/.fm-test-fixture
  sourcing_shell "$tmp" FM_TEST_ORPHAN_MAX_AGE_SECONDS=3600
  assert_present "$root" "the sweep removed a fixture root younger than the age floor"
  assert_equals 1 "$(find "$tmp/fm-test-owners" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" \
    "the sweep removed an old record while a fixture root it names was still kept"
  sourcing_shell "$tmp" FM_TEST_ORPHAN_MAX_AGE_SECONDS=0
  assert_absent "$root" "the sweep left the fixture root of a dead shell"
  assert_equals 0 "$(find "$tmp/fm-test-owners" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" \
    "the sweep left the record of a dead shell"
  pass "a KILLed shell leaves one marked record and the next sweep removes the record and its roots"
}

test_sweep_keeps_live_owner_and_unmarked_entries() {
  local tmp="$TMP_ROOT/keep" pid tries=0 root unmarked unmarked_old dead_pid
  mkdir -p "$tmp"
  env TMPDIR="$tmp" bash -c '
    . "$1"
    d=$(fm_test_tmproot fm-test-sweep-live)
    printf "%s\n" "$d" > "$2"
    while :; do sleep 0.1; done
  ' _ "$LIB" "$TMP_ROOT/live-root" >/dev/null 2>&1 &
  pid=$!
  while [ ! -s "$TMP_ROOT/live-root" ] && [ "$tries" -lt 200 ]; do tries=$((tries + 1)); sleep 0.05; done
  [ -s "$TMP_ROOT/live-root" ] || fail "the live shell never made its fixture root"
  root=$(cat "$TMP_ROOT/live-root")
  unmarked="$tmp/fm-test-unmarked.AAAAAA"
  unmarked_old="$tmp/fm-unmarked-old.BBBBBB"
  mkdir -p "$unmarked/inner" "$unmarked_old/inner"
  touch -t 202001010000 "$unmarked" "$unmarked/inner" "$unmarked_old" "$unmarked_old/inner"
  touch -t 202001010000 "$root/.fm-test-fixture" "$tmp"/fm-test-owners/*/.fm-test-fixture
  # Registries the old lib.sh left beside the roots, named by their owner's PID.
  bash -c 'exit 0' &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  : > "$tmp/.fm-test-cleanup.$pid.CCCCCC"
  : > "$tmp/.fm-test-watcher.$pid.DDDDDD"
  : > "$tmp/.fm-test-cleanup.$dead_pid.EEEEEE"
  touch -t 202001010000 "$tmp/.fm-test-cleanup.$pid.CCCCCC" "$tmp/.fm-test-watcher.$pid.DDDDDD" \
    "$tmp/.fm-test-cleanup.$dead_pid.EEEEEE"
  sourcing_shell "$tmp" FM_TEST_ORPHAN_MAX_AGE_SECONDS=0
  sourcing_shell "$tmp" FM_TEST_ORPHAN_MAX_AGE_SECONDS=0 FM_TEST_SWEEP_ALL=1
  assert_present "$root" "the sweep removed a fixture root whose owner is still running"
  assert_present "$unmarked" "the sweep removed an unmarked fm-test-* entry"
  assert_present "$unmarked_old" "the wide sweep removed an unmarked fm-* entry"
  assert_present "$tmp/.fm-test-cleanup.$pid.CCCCCC" "the wide sweep removed a live owner's legacy cleanup registry"
  assert_present "$tmp/.fm-test-watcher.$pid.DDDDDD" "the wide sweep removed a live owner's legacy watcher registry"
  assert_absent "$tmp/.fm-test-cleanup.$dead_pid.EEEEEE" "the wide sweep left a dead owner's legacy registry"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  assert_absent "$root" "the live shell's own teardown left its fixture root"
  pass "the sweep keeps a live owner's roots and registries and every unmarked entry, narrow or wide"
}

test_sweep_cost_does_not_follow_unrelated_entries() {
  local tmp_few="$TMP_ROOT/cost-few" tmp_many="$TMP_ROOT/cost-many" i dir few many
  mkdir -p "$tmp_few" "$tmp_many"
  # Unrelated fm-* entries as other tools leave them: some plain files, some
  # directories with contents, none carrying a marker.
  for i in $(seq 1 12000); do
    dir="$tmp_many/fm-gh-rest.U$i"
    if [ $((i % 2)) -eq 0 ]; then : > "$dir"; else mkdir "$dir"; fi
  done
  few=$(sweep_seconds "$tmp_few")
  many=$(sweep_seconds "$tmp_many")
  # Before the per-shell record the sweep cost about 0.0000643 s per entry here
  # (0.77 s for 12000); a margin of 0.35 s keeps a loaded host from failing it
  # while still rejecting any per-entry loop.
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 0.35 ? 0 : 1)' "$few" "$many" \
    || fail "the sweep slowed from ${few}s to ${many}s with 12000 unrelated fm-* entries"
  pass "the sweep takes ${few}s with no unrelated entries and ${many}s with 12000"
}

# sweep_seconds <tmpdir>: the best of three timings of fm_test_reap_orphans alone.
sweep_seconds() {
  local tmp=$1 best='' t
  for _ in 1 2 3; do
    t=$(env TMPDIR="$tmp" FM_TEST_SKIP_ORPHAN_REAP=1 bash -c '
      . "$1"
      s=$(perl -MTime::HiRes=time -e "printf q(%.3f), time")
      fm_test_reap_orphans
      e=$(perl -MTime::HiRes=time -e "printf q(%.3f), time")
      perl -e "printf q(%.3f), $e - $s"
    ' _ "$LIB")
    if [ -z "$best" ] || perl -e 'exit($ARGV[0] < $ARGV[1] ? 0 : 1)' "$t" "$best"; then best=$t; fi
  done
  printf '%s\n' "$best"
}

test_owners_dir_must_be_ours() {
  local tmp="$TMP_ROOT/planted" elsewhere="$TMP_ROOT/planted-target" out status=0
  mkdir -p "$tmp" "$elsewhere/evil"
  ln -s "$elsewhere" "$tmp/fm-test-owners"
  printf '%s\n' "$elsewhere/victim" > "$elsewhere/evil/cleanup"
  mkdir -p "$elsewhere/victim"
  printf '1\nnot-an-identity\n' > "$elsewhere/victim/.fm-test-fixture"
  touch -t 202001010000 "$elsewhere/victim/.fm-test-fixture"
  out=$(sourcing_shell "$tmp" FM_TEST_ORPHAN_MAX_AGE_SECONDS=0 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "sourcing tests/lib.sh accepted an owners directory that is a symlink"
  assert_contains "$out" "is not a directory this user owns" "the refusal did not name the owners directory"
  assert_present "$elsewhere/victim" "a sweep removed a root named by a record behind a symlinked owners directory"
  [ -z "$(find "$elsewhere" -mindepth 1 -maxdepth 1 ! -name evil ! -name victim)" ] \
    || fail "sourcing tests/lib.sh wrote a record through a symlinked owners directory"
  pass "tests/lib.sh refuses an owners directory it does not own and touches nothing behind it"
}

test_killed_shell_leaves_one_marked_entry_and_sweep_removes_it
test_owners_dir_must_be_ours
test_sweep_keeps_live_owner_and_unmarked_entries
test_sweep_cost_does_not_follow_unrelated_entries
