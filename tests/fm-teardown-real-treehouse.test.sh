#!/usr/bin/env bash
# Real-path checks for the close of a task whose own nested copy Vernant's closeout
# driver keeps: the pool slot comes from the REAL treehouse binary in a scratch pool
# (leased to the task as fm-spawn leases it), and every treehouse call teardown
# makes runs through that binary. Only the closeout driver is a stand-in (the real
# Vernant driver is never run), and `gh`, `tmux` and the endpoint are the suite's
# usual fakes. The cases cover the three cleanup paths that matter on a real pool:
#   a. unique ignored files are preserved and verified before anything is removed,
#      and the regenerable control is left out of the preserve (kept route and
#      released route);
#   b. a copy with an existing user (a live process inside it, another task's
#      record, another task's claim on the slot) is kept and the slot stays leased;
#   c. a start racing the close (a real `treehouse get`) never receives the slot,
#      and the copy is untouched.
# The suite skips with a one-line reason when no treehouse with `lease --path` is
# installed. Set FM_REAL_EVIDENCE=<absolute dir> to write each case's before and
# after records (status JSON, state-file hash, claim, copy fingerprint, preserve
# listing, tar inventory, driver counter, exit status and output) beneath it.
# Usage: bash tests/fm-teardown-real-treehouse.test.sh [test_function_name ...]

set -u

# shellcheck source=tests/fm-teardown-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-helpers.sh"

REAL_TREEHOUSE=$(command -v treehouse 2>/dev/null || true)
if [ -z "$REAL_TREEHOUSE" ] || ! treehouse lease --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--path([^[:alnum:]_-]|$)' \
   || ! treehouse get --help 2>&1 | grep -q -- '--lease'; then
  echo "skip - no treehouse with lease --path and get --lease is installed; the real-binary cases did not run"
  exit 0
fi
export FM_TEST_REAL_TREEHOUSE=$REAL_TREEHOUSE

retained_field() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# real_case <name>: a retained case on a real pool slot. FM_STUB_CLOSEOUT selects
# the stand-in driver: retained keeps the copy, unset releases and removes it.
real_case() {
  make_retained_case "real-$1" enclosing
  export TREEHOUSE_ROOT=$FOREIGN_CASE/realroot
  # A regenerable control the preserve must leave out, and one the copy keeps.
  printf '%s\n' '.venv/' 'node_modules/' >> "$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$FOREIGN_COPY/.venv/bin" "$FOREIGN_COPY/node_modules/dep"
  printf 'control\n' > "$FOREIGN_COPY/.venv/bin/python"
  printf 'control\n' > "$FOREIGN_COPY/node_modules/dep/index.js"
  # The real pool must not see the real project's lock directory; the case's own
  # home keeps it. No real fm lock, slot or copy is touched.
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  REAL_DIR=
  if [ -n "${FM_REAL_EVIDENCE:-}" ]; then
    REAL_DIR=$FM_REAL_EVIDENCE/$1
    rm -rf "$REAL_DIR"
    mkdir -p "$REAL_DIR"
    real_record before
  fi
}

# The slot's entry in the real `treehouse status --json`, from the project.
real_slot_entry() {
  (cd "$FOREIGN_CASE/project" && treehouse status --json </dev/null 2>/dev/null) \
    | jq -c --arg p "$FOREIGN_SLOT" '[.[] | select(.path == $p)] | map({name, path, status, lease_id, lease_holder, leased_at})'
}

real_tar_inventory() {
  find "$FOREIGN_SLOT/.claude/bug-evidence/worktree-preservation" -name '*.tar' -type f -exec shasum -a 256 {} + 2>/dev/null | sort
}

# real_record <phase>: before and after records of the case, when evidence is wanted.
real_record() {
  [ -n "$REAL_DIR" ] || return 0
  local phase=$1 dir=$REAL_DIR hash preserve
  {
    echo "treehouse $(treehouse --version 2>&1)"
    echo "pool-dir $(cd "$FOREIGN_CASE/project" && treehouse pool-dir </dev/null 2>&1)"
    echo "slot $FOREIGN_SLOT"
    echo "copy $FOREIGN_COPY"
  } > "$dir/$phase.env"
  real_slot_entry > "$dir/$phase.slot.json" 2>&1
  (cd "$FOREIGN_CASE/project" && treehouse status --json </dev/null 2>&1) > "$dir/$phase.status.json"
  shasum -a 256 "$FOREIGN_CASE/pool/treehouse-state.json" > "$dir/$phase.state.sha256" 2>&1
  cp "$FOREIGN_CASE/pool/1/.fm-slot-owner" "$dir/$phase.claim" 2>&1
  held_fingerprint "$FOREIGN_COPY" > "$dir/$phase.copy.fingerprint" 2>&1
  git -C "$FOREIGN_CASE/project" worktree list --porcelain > "$dir/$phase.registrations" 2>&1
  real_tar_inventory > "$dir/$phase.tars" 2>&1
  printf 'driver-counter %s\ntar-count %s\n' "$(retained_call_count)" "$(retained_tar_count)" > "$dir/$phase.counters"
  hash=$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  preserve=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$hash
  [ -d "$preserve" ] && find "$preserve" -type f | sort | sed "s#^$preserve/##" > "$dir/$phase.preserve.list" || : > "$dir/$phase.preserve.list"
  [ ! -f "$preserve/SHA256SUMS" ] || cp "$preserve/SHA256SUMS" "$dir/$phase.preserve.SHA256SUMS"
  [ ! -f "$FOREIGN_CASE/treehouse.calls.log" ] || cp "$FOREIGN_CASE/treehouse.calls.log" "$dir/$phase.treehouse-calls.log"
}

real_teardown() {  # <rc-var> [env...]
  local rc_var=$1
  shift
  run_foreign_teardown "$rc_var" "TREEHOUSE_ROOT=$TREEHOUSE_ROOT" "$@"
  if [ -n "$REAL_DIR" ]; then
    cp "$FOREIGN_CASE/stdout" "$REAL_DIR/teardown.stdout"
    cp "$FOREIGN_CASE/stderr" "$REAL_DIR/teardown.stderr"
    printf 'exit %s\n' "${!rc_var}" > "$REAL_DIR/teardown.exit"
  fi
}

real_returns() {  # the number of treehouse return calls teardown made
  if [ -f "$FOREIGN_CASE/treehouse.calls.log" ]; then
    grep -c '|return ' "$FOREIGN_CASE/treehouse.calls.log" || true
  else
    echo 0
  fi
}

# retained_assert_closed without the byte comparison of the whole pool state
# file: a start that races the close legitimately adds its own slot there, so the
# held slot's own entry is compared instead (real_assert_slot_unchanged).
real_assert_closed() {  # <label>
  local label=$1 case_dir=$FOREIGN_CASE record
  assert_absent "$case_dir/state/task-x1.meta" "$label: the task record survived"
  [ "$(backlog_row_state "$case_dir")" = "done" ] || fail "$label: the backlog item is not done: $(backlog_row_state "$case_dir")"
  held_fingerprint "$FOREIGN_COPY" | cmp -s - "$case_dir/held-before.$(basename "$FOREIGN_COPY")" || fail "$label: the kept copy changed"
  cmp -s "$case_dir/claim-before" "$case_dir/pool/1/.fm-slot-owner" || fail "$label: the slot's claim changed"
  git -C "$case_dir/project" worktree list --porcelain | grep -A4 -F "worktree $FOREIGN_COPY" | grep -q '^locked' \
    || fail "$label: the copy is no longer locked"
  record=$(retained_record_path)
  assert_present "$record" "$label: no retained record was written"
  assert_equals "copy=$FOREIGN_COPY" "$(sed -n 2p "$record")" "$label: the record does not name the copy"
}

real_assert_slot_unchanged() {  # <label>: the slot's real lease entry is what it was
  local want have
  want=$(cat "$REAL_DIR/before.slot.json" 2>/dev/null || true)
  [ -n "$want" ] || want=$SLOT_ENTRY_BEFORE
  have=$(real_slot_entry)
  assert_equals "$want" "$have" "$1: the slot's real lease entry changed"
  [ "$(jq -r '.[0].status' <<<"$have")" = leased ] || fail "$1: the real slot is not leased: $have"
}

SLOT_ENTRY_BEFORE=

# a. Kept route: the close keeps the copy, the real slot stays leased to the same
# holder with the same lease id, every unique ignored file is in a preserve that
# restores to the builder's hashes, and the regenerable control is not in it.
test_a_real_pool_slot_keeps_its_lease_and_the_unique_files_are_preserved_and_the_control_is_left_out() {
  local rc preserve scratch file want have
  real_case a-kept
  SLOT_ENTRY_BEFORE=$(real_slot_entry)
  [ "$(jq -r '.[0].lease_holder' <<<"$SLOT_ENTRY_BEFORE")" = task-x1 ] || fail "a-kept: the real slot is not leased to the task before the close: $SLOT_ENTRY_BEFORE"
  real_teardown rc FM_STUB_CLOSEOUT=retained
  real_record after
  expect_code 0 "$rc" "a-kept: the close must succeed on a real pool slot: $(cat "$FOREIGN_CASE/stderr")"
  retained_assert_closed "a-kept"
  assert_equals 0 "$(real_returns)" "a-kept: the real slot was returned"
  real_assert_slot_unchanged "a-kept"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "a-kept: the driver was not asked exactly once"
  preserve=$(retained_field "$(retained_record_path)" preserve)
  scratch=$FOREIGN_CASE/scratch-restore
  mkdir -p "$scratch"
  (cd "$preserve" && tar -cf - .) | (cd "$scratch" && tar -xf -)
  for file in .claude/channel-outbox/a.jsonl:one .claude/channel-outbox/b.jsonl:two notes/unique.dat:'only here'; do
    want=$(printf '%s\n' "${file#*:}" | shasum -a 256 | awk '{print $1}')
    have=$(shasum -a 256 "$scratch/${file%%:*}" | awk '{print $1}')
    assert_equals "$want" "$have" "a-kept: ${file%%:*} does not restore to the builder's hash"
  done
  [ ! -e "$preserve/.venv" ] && [ ! -e "$preserve/node_modules" ] || fail "a-kept: the regenerable control was preserved"
  assert_present "$FOREIGN_COPY/.venv/bin/python" "a-kept: the kept copy lost its control"
  assert_present "$FOREIGN_COPY/node_modules/dep/index.js" "a-kept: the kept copy lost its control"
  if [ -n "$REAL_DIR" ]; then
    diff -r "$preserve" "$scratch" > "$REAL_DIR/restore.diff" 2>&1 && echo "restore: identical" >> "$REAL_DIR/restore.diff"
    for file in .claude/channel-outbox/a.jsonl:one .claude/channel-outbox/b.jsonl:two notes/unique.dat:'only here'; do
      printf '%s  builder:%s restored:%s\n' "${file%%:*}" "$(printf '%s\n' "${file#*:}" | shasum -a 256 | awk '{print $1}')" "$(shasum -a 256 "$scratch/${file%%:*}" | awk '{print $1}')" >> "$REAL_DIR/restore.hashes"
    done
  fi
  pass "a-kept: on a real pool slot the close keeps the copy and the lease, the unique files restore to the builder's hashes and the control is left out"
}

# a. Released route: the driver releases the copy; the unique file is in the
# preserve with its hash before the copy goes, the control goes with the copy and
# was never preserved, and the real slot is returned by the real binary.
test_a_real_pool_slot_is_returned_after_the_unique_file_is_preserved_and_the_control_is_removed() {
  local rc preserve hash
  real_case a-released
  real_teardown rc
  real_record after
  expect_code 0 "$rc" "a-released: the close must succeed on a real pool slot: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_COPY" "a-released: the copy survived the release"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "a-released: the task record survived"
  hash=$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  preserve=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$hash
  assert_equals "only here" "$(cat "$preserve/notes/unique.dat")" "a-released: the unique file was not preserved before the removal"
  assert_grep "$(printf 'only here\n' | shasum -a 256 | awk '{print $1}')  notes/unique.dat" "$preserve/SHA256SUMS" "a-released: SHA256SUMS does not record the unique file"
  [ ! -e "$preserve/.venv" ] && [ ! -e "$preserve/node_modules" ] || fail "a-released: the regenerable control was preserved"
  assert_grep '|return ' "$FOREIGN_CASE/treehouse.calls.log" "a-released: the real binary was not asked to return the slot"
  [ "$(jq -r '.[0].status // "gone"' <<<"$(real_slot_entry)")" != leased ] || fail "a-released: the real slot is still leased after the return: $(real_slot_entry)"
  pass "a-released: the unique file is preserved with its hash, the control is gone with the copy and unpreserved, and the real binary returned the slot"
}

# b. An existing user keeps the copy and the lease.
real_assert_kept() {  # <label>: nothing moved
  local label=$1
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "$label: the task record was removed"
  held_fingerprint "$FOREIGN_COPY" | cmp -s - "$FOREIGN_CASE/held-before.$(basename "$FOREIGN_COPY")" || fail "$label: the copy changed"
  git -C "$FOREIGN_CASE/project" worktree list --porcelain | cmp -s - "$FOREIGN_CASE/registrations-before" || fail "$label: copy registrations changed"
  assert_equals 0 "$(real_returns)" "$label: the slot was returned"
  real_assert_slot_unchanged "$label"
  assert_present "$FOREIGN_COPY/.venv/bin/python" "$label: the copy lost its control"
}

test_a_copy_with_a_live_process_inside_it_is_kept_and_the_slot_stays_leased() {
  local rc pid
  real_case b-process
  rm -f "$FOREIGN_CASE/fakebin/lsof"
  SLOT_ENTRY_BEFORE=$(real_slot_entry)
  ( cd "$FOREIGN_COPY" && exec sleep 600 ) &
  pid=$!
  sleep 1
  real_teardown rc FM_STUB_CLOSEOUT=retained
  real_record after
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 1 "$rc" "b-process: a copy with a live process inside it must refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'REFUSED' "$FOREIGN_CASE/stderr" "b-process: the refusal named no cause"
  assert_equals 0 "$(retained_call_count)" "b-process: the driver was asked about a copy with a live user"
  real_assert_kept "b-process"
  pass "b-process: a copy with a live process inside it is refused with the copy, the task and the real lease unchanged"
}

test_a_copy_that_another_task_record_names_is_kept_and_the_slot_stays_leased() {
  local rc
  real_case b-record
  SLOT_ENTRY_BEFORE=$(real_slot_entry)
  fm_write_meta "$FOREIGN_CASE/state/task-y1.meta" \
    "window=firstmate:fm-task-y1" "endpoint_task_id=task-y1" \
    "worktree=$FOREIGN_COPY" "branch=fm/task-y1" "project=$FOREIGN_CASE/project" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-y1"
  real_teardown rc FM_STUB_CLOSEOUT=retained
  real_record after
  expect_code 1 "$rc" "b-record: a copy another task's record names must refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'task-y1' "$FOREIGN_CASE/stderr" "b-record: the refusal did not name the other task"
  assert_equals 0 "$(retained_call_count)" "b-record: the driver was asked about a copy with another user"
  real_assert_kept "b-record"
  pass "b-record: a copy another task's record names is refused naming that task, with the copy and the real lease unchanged"
}

test_a_slot_another_task_claims_is_left_untouched_and_stays_leased() {
  local rc
  real_case b-claim
  SLOT_ENTRY_BEFORE=$(real_slot_entry)
  printf 'task=task-y1\nhome=%s\n' "$FOREIGN_CASE/home" > "$FOREIGN_CASE/pool/1/.fm-slot-owner"
  cp "$FOREIGN_CASE/pool/1/.fm-slot-owner" "$FOREIGN_CASE/claim-before"
  fm_write_meta "$FOREIGN_CASE/state/task-y1.meta" \
    "window=firstmate:fm-task-y1" "endpoint_task_id=task-y1" \
    "worktree=$FOREIGN_SLOT/other" "branch=fm/task-y1" "project=$FOREIGN_CASE/project" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-y1"
  real_teardown rc FM_STUB_CLOSEOUT=retained
  real_record after
  expect_code 0 "$rc" "b-claim: the task whose slot another task now claims closes its own record only: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep 'reassigned to task task-y1' "$FOREIGN_CASE/stderr" "b-claim: the output did not say the slot was reassigned"
  assert_equals 0 "$(retained_call_count)" "b-claim: the driver was asked about a copy in another task's slot"
  assert_equals 0 "$(real_returns)" "b-claim: another task's slot was returned"
  held_fingerprint "$FOREIGN_COPY" | cmp -s - "$FOREIGN_CASE/held-before.$(basename "$FOREIGN_COPY")" || fail "b-claim: the copy changed"
  cmp -s "$FOREIGN_CASE/claim-before" "$FOREIGN_CASE/pool/1/.fm-slot-owner" || fail "b-claim: the other task's claim changed"
  real_assert_slot_unchanged "b-claim"
  assert_present "$FOREIGN_COPY/.venv/bin/python" "b-claim: the copy lost its control"
  pass "b-claim: a slot another task now claims is left untouched (no driver call, no return), with the copy, the claim and the real lease unchanged"
}

# c. A start racing the close. The stand-in driver runs a real `treehouse get`
# from the project in the middle of the close (after the driver has written its
# tar and before teardown records the copy); a second get follows the close.
real_race() {  # <label> <rc-var>
  local label=$1 rc_var=$2 project=$FOREIGN_CASE/project
  real_teardown "$rc_var" FM_STUB_CLOSEOUT=retained \
    "FM_STUB_AFTER=(cd '$project' && TREEHOUSE_ROOT='$TREEHOUSE_ROOT' treehouse get --lease --lease-holder racer-1 --json </dev/null > '$FOREIGN_CASE/race1.out' 2> '$FOREIGN_CASE/race1.err'; echo \$? > '$FOREIGN_CASE/race1.rc')"
  (cd "$project" && treehouse get --lease --lease-holder racer-2 --json </dev/null > "$FOREIGN_CASE/race2.out" 2> "$FOREIGN_CASE/race2.err"; echo $? > "$FOREIGN_CASE/race2.rc")
  if [ -n "$REAL_DIR" ]; then
    cp "$FOREIGN_CASE"/race*.out "$FOREIGN_CASE"/race*.err "$FOREIGN_CASE"/race*.rc "$REAL_DIR/" 2>/dev/null || true
  fi
  local n out
  for n in 1 2; do
    [ -f "$FOREIGN_CASE/race$n.rc" ] || fail "$label: racing start $n never ran"
    out=$(jq -r '.path // empty' "$FOREIGN_CASE/race$n.out" 2>/dev/null || true)
    [ "$out" != "$FOREIGN_SLOT" ] || fail "$label: racing start $n was handed the held slot $FOREIGN_SLOT"
  done
}

test_a_start_racing_the_close_never_receives_the_held_slot() {
  local rc
  real_case c-race
  SLOT_ENTRY_BEFORE=$(real_slot_entry)
  real_race c-race rc
  real_record after
  expect_code 0 "$rc" "c-race: the close must succeed around a racing start: $(cat "$FOREIGN_CASE/stderr")"
  real_assert_closed "c-race"
  assert_equals 0 "$(real_returns)" "c-race: the slot was returned"
  real_assert_slot_unchanged "c-race"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "c-race: the driver was not asked exactly once"
  assert_present "$FOREIGN_COPY/.venv/bin/python" "c-race: the racing start reset the copy"
  pass "c-race: a real start racing the close, and one after it, never received the held slot; the copy, the claim and the real lease are unchanged"
}

# c. The same race on a slot the task never leased (a plain get): the close must
# lease it before a racing start can take it, or the racing start must fail; it must
# never reset the copy.
test_a_start_racing_the_close_of_an_unleased_slot_never_resets_the_copy() {
  local rc entry
  FM_TEST_REAL_UNLEASED=1 real_case c-race-unleased
  unset FM_TEST_REAL_UNLEASED
  SLOT_ENTRY_BEFORE=$(real_slot_entry)
  # The slot holds the copy's ignored files, so the real binary reports it dirty,
  # not available; either way it is not leased.
  [ "$(jq -r '.[0].status' <<<"$SLOT_ENTRY_BEFORE")" != leased ] || fail "c-race-unleased: the fixture slot is leased: $SLOT_ENTRY_BEFORE"
  real_race c-race-unleased rc
  real_record after
  entry=$(real_slot_entry)
  held_fingerprint "$FOREIGN_COPY" | cmp -s - "$FOREIGN_CASE/held-before.$(basename "$FOREIGN_COPY")" || fail "c-race-unleased: the copy changed: slot entry $entry"
  assert_present "$FOREIGN_COPY/.venv/bin/python" "c-race-unleased: the racing start reset the copy"
  assert_equals 0 "$(real_returns)" "c-race-unleased: the slot was returned"
  [ "$(jq -r '.[0].status' <<<"$entry")" = leased ] || fail "c-race-unleased: the slot is not leased after the close: $entry"
  [ "$rc" = 0 ] || fail "c-race-unleased: the close did not succeed: $(cat "$FOREIGN_CASE/stderr")"
  pass "c-race-unleased: on an unleased real slot, racing starts never received it, the close leased it, and the copy is unchanged"
}

teardown_test_cases=(
test_a_real_pool_slot_keeps_its_lease_and_the_unique_files_are_preserved_and_the_control_is_left_out
test_a_real_pool_slot_is_returned_after_the_unique_file_is_preserved_and_the_control_is_removed
test_a_copy_with_a_live_process_inside_it_is_kept_and_the_slot_stays_leased
test_a_copy_that_another_task_record_names_is_kept_and_the_slot_stays_leased
test_a_slot_another_task_claims_is_left_untouched_and_stays_leased
test_a_start_racing_the_close_never_receives_the_held_slot
test_a_start_racing_the_close_of_an_unleased_slot_never_resets_the_copy
)

fm_test_run_cases "${teardown_test_cases[@]}" -- "$@"
