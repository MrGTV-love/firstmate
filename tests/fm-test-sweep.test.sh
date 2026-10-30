#!/usr/bin/env bash
# Behavior tests for the orphan sweep tests/lib.sh runs in every sourcing shell
# (fm_test_reap_orphans) and for the per-shell record it reads.
#
# The sweep must (1) remove only directories that carry the .fm-test-fixture
# marker and whose owner is provably dead, (2) keep a live owner's roots and
# every unmarked entry, (3) leave exactly one marked entry behind when a shell is
# KILLed, (4) still find and remove a dead owner's marked root of any fm-* name
# that predates the records, and (5) not slow down per entry as unrelated fm-*
# entries pile up in the shared temp dir (2.8 s with 50000 of them against 0.3 s
# with none before the record existed; 0.3 s against 0.14 s now, or 0.7 s on the
# once-per-age-floor sweep that looks at every fm-* entry).
# tests/fm-test-fixture-cleanup.test.sh pins the ownership rules.
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
  records=$(find "$tmp/fm-test-owners" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
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
  assert_equals 1 "$(find "$tmp/fm-test-owners" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" \
    "the sweep removed an old record while a fixture root it names was still kept"
  sourcing_shell "$tmp" FM_TEST_ORPHAN_MAX_AGE_SECONDS=0
  assert_absent "$root" "the sweep left the fixture root of a dead shell"
  assert_equals 0 "$(find "$tmp/fm-test-owners" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" \
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

# Roots a test shell made before the per-shell records existed carry the marker
# but appear in no record, and are not named fm-test-*. Ordinary sourcing must
# still find and remove the ones whose owner is dead, and keep the rest.
test_sweep_finds_legacy_marked_roots() {
  local tmp="$TMP_ROOT/legacy" dead pid tries=0 dead_root young_root unmarked live_root
  mkdir -p "$tmp"
  dead=$(bash -c 'printf "%s" "$$"')
  dead_root="$tmp/fm-drop-words.AAAAAA"
  young_root="$tmp/fm-slots-young.CCCCCC"
  unmarked="$tmp/fm-drop-words.BBBBBB"
  mkdir -p "$dead_root/inner" "$young_root" "$unmarked/inner"
  printf '%s\n' "$dead" > "$dead_root/.fm-test-fixture"
  printf '%s\n' "$dead" > "$young_root/.fm-test-fixture"
  touch -t 202001010000 "$dead_root/.fm-test-fixture" "$dead_root" "$unmarked" "$unmarked/inner"
  # A live owner's root, made the way a test shell makes it and then taken out
  # of its record, which is how a root from before the records looks.
  env TMPDIR="$tmp" bash -c '
    . "$1"
    d=$(fm_test_tmproot fm-drop-words)
    printf "%s\n" "$d" > "$2"
    : > "$FM_TEST_CLEANUP_REGISTRY"
    while :; do sleep 0.1; done
  ' _ "$LIB" "$TMP_ROOT/legacy-live-root" >/dev/null 2>&1 &
  pid=$!
  while [ ! -s "$TMP_ROOT/legacy-live-root" ] && [ "$tries" -lt 200 ]; do tries=$((tries + 1)); sleep 0.05; done
  [ -s "$TMP_ROOT/legacy-live-root" ] || fail "the live shell never made its legacy-shaped root"
  live_root=$(cat "$TMP_ROOT/legacy-live-root")
  touch -t 202001010000 "$live_root/.fm-test-fixture"
  # Ordinary sourcing: no FM_TEST_SWEEP_ALL, the default age floor. The live
  # shell's own sourcing stamped the discovery look; clear it so this sweep is due.
  rm -f "$tmp/fm-test-owners/.legacy-discovery"
  sourcing_shell "$tmp"
  assert_absent "$dead_root" "ordinary sourcing left a marked non-fm-test-* root whose owner is dead"
  assert_present "$young_root" "ordinary sourcing removed a dead owner's root younger than the age floor"
  assert_present "$unmarked" "ordinary sourcing removed an unmarked fm-* entry"
  assert_present "$live_root" "ordinary sourcing removed a legacy-shaped root whose owner is still running"
  sourcing_shell "$tmp" FM_TEST_ORPHAN_MAX_AGE_SECONDS=0
  assert_absent "$young_root" "ordinary sourcing left a dead owner's root past a zero age floor"
  assert_present "$unmarked" "ordinary sourcing at a zero age floor removed an unmarked fm-* entry"
  assert_present "$live_root" "ordinary sourcing at a zero age floor removed a live owner's legacy-shaped root"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "ordinary sourcing removes a dead owner's marked root of any fm-* name and keeps live, young and unmarked ones"
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
  # Before the per-shell record the sweep cost about 0.0000643 s per entry here
  # (0.77 s for 12000); a margin of 0.35 s keeps a loaded host from failing it
  # while still rejecting any per-entry loop. The sweep that looks at every fm-*
  # entry (stamp cleared) and the sweep that does not (stamp fresh) both stay inside it.
  few=$(sweep_seconds "$tmp_few" clear)
  many=$(sweep_seconds "$tmp_many" clear)
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 0.35 ? 0 : 1)' "$few" "$many" \
    || fail "the sweep that looks at every fm-* entry slowed from ${few}s to ${many}s with 12000 unrelated fm-* entries"
  pass "the sweep that looks at every fm-* entry takes ${few}s with no unrelated entries and ${many}s with 12000"
  few=$(sweep_seconds "$tmp_few" keep)
  many=$(sweep_seconds "$tmp_many" keep)
  perl -e 'exit(($ARGV[1] - $ARGV[0]) < 0.35 ? 0 : 1)' "$few" "$many" \
    || fail "the stamped sweep slowed from ${few}s to ${many}s with 12000 unrelated fm-* entries"
  pass "the stamped sweep takes ${few}s with no unrelated entries and ${many}s with 12000"
}

# sweep_seconds <tmpdir> <clear|keep>: the best of three timings of
# fm_test_reap_orphans alone; "clear" removes the discovery stamp first, so the
# sweep has to look at every fm-* entry, and "keep" leaves a fresh one.
sweep_seconds() {
  local tmp=$1 stamp=$2 best='' t
  for _ in 1 2 3; do
    [ "$stamp" = clear ] && rm -f "$tmp/fm-test-owners/.legacy-discovery"
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

# The runner's wide sweep removes dead records too, so it must first stop what
# their owner left running inside them, with the same marker proof.
test_wide_sweep_stops_a_dead_records_process_first() {
  local tmp="$TMP_ROOT/stray" stray record tries=0
  mkdir -p "$tmp"
  {
    env TMPDIR="$tmp" bash -c '
      . "$1"
      cd "$FM_TEST_SHELL_DIR" || exit 1
      sleep 300 >/dev/null 2>&1 &
      printf "%s\n" "$!" > "$2"
      kill -KILL $$
    ' _ "$LIB" "$TMP_ROOT/stray-pid" >/dev/null 2>&1 || true
  } 2>/dev/null
  stray=$(cat "$TMP_ROOT/stray-pid")
  kill -0 "$stray" 2>/dev/null || fail "the stray process in the killed shell's record never started"
  record=$(find "$tmp/fm-test-owners" -mindepth 1 -maxdepth 1 -type d)
  [ -f "$record/.fm-test-fixture" ] || { kill -KILL "$stray" 2>/dev/null; fail "the killed shell left no marked record"; }
  touch -t 202001010000 "$record/.fm-test-fixture"
  sourcing_shell "$tmp" FM_TEST_ORPHAN_MAX_AGE_SECONDS=0 FM_TEST_SWEEP_ALL=1
  while kill -0 "$stray" 2>/dev/null && [ "$tries" -lt 40 ]; do tries=$((tries + 1)); sleep 0.05; done
  if kill -0 "$stray" 2>/dev/null; then
    kill -KILL "$stray" 2>/dev/null || true
    fail "the wide sweep left running a process whose cwd is inside a dead shell's record"
  fi
  assert_absent "$record" "the wide sweep left the record of a dead shell"
  pass "the wide sweep stops a process inside a dead shell's record before it removes the record"
}

test_killed_shell_leaves_one_marked_entry_and_sweep_removes_it
test_wide_sweep_stops_a_dead_records_process_first
test_owners_dir_must_be_ours
test_sweep_keeps_live_owner_and_unmarked_entries
test_sweep_finds_legacy_marked_roots
test_sweep_cost_does_not_follow_unrelated_entries
