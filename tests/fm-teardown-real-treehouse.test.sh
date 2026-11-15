#!/usr/bin/env bash
# Real-path checks for the close of a task whose own nested copy Vernant's closeout
# driver keeps: the pool slot comes from the REAL treehouse binary in a scratch pool
# (leased to the task as fm-spawn leases it), and every treehouse call teardown
# makes runs through that binary. `tmux` and `docker` are the real local tools too (a
# scratch tmux server on its own socket holds the task's window; Docker is the host's
# real daemon, queried and never given an object). The only stand-ins are the closeout
# driver (the real Vernant driver is never run) and `gh`, `gh-axi` and `no-mistakes`: a
# test must not reach the real forge or the shared pipeline daemon, and in every case
# here their true answers are "no pull request" and "no active run".
# The cases cover the three cleanup paths that matter on a real pool:
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
if ! command -v tmux >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "skip - no real tmux, or no Docker with a reachable daemon, is installed; the real-binary cases did not run"
  exit 0
fi

# The task's tmux window lives on a real scratch server: its own socket directory,
# and TMUX unset so a harness inside the user's tmux never reaches that server.
# A unix socket path is limited (104 bytes on macOS), so the directory is made
# under /tmp whatever TMPDIR is, never under a long TMPDIR. Every scratch server
# is stopped on exit.
unset TMUX
REAL_TMUX_REGISTRY=$TMP_ROOT/real-tmux-dirs
real_tmux_stop_all() {
  local dir
  [ -f "$REAL_TMUX_REGISTRY" ] || return 0
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    TMUX_TMPDIR=$dir tmux kill-server >/dev/null 2>&1 || true
    rm -rf "$dir"
  done < "$REAL_TMUX_REGISTRY"
  : > "$REAL_TMUX_REGISTRY"
}
trap 'real_tmux_stop_all; fm_test_cleanup' EXIT
trap 'real_tmux_stop_all; fm_test_cleanup; exit 130' INT
trap 'real_tmux_stop_all; fm_test_cleanup; exit 143' TERM
trap 'real_tmux_stop_all; fm_test_cleanup; exit 129' HUP
trap 'real_tmux_stop_all; fm_test_cleanup; exit 131' QUIT

# real_tmux_scratch_dir: a new short socket directory under /tmp, registered for
# the exit cleanup, in REAL_TMUX_DIR. It never depends on TMPDIR.
real_tmux_scratch_dir() {
  REAL_TMUX_DIR=$(TMPDIR=/tmp mktemp -d /tmp/fm-rtmux.XXXXXX) || fail "no scratch tmux directory"
  printf '%s\n' "$REAL_TMUX_DIR" >> "$REAL_TMUX_REGISTRY"
}

# real_local_tools: drop the case's tmux and docker fakes so teardown reaches the
# real tools, and start a real scratch tmux server holding the task's window.
real_local_tools() {
  local case_dir=$FOREIGN_CASE
  rm -f "$case_dir/fakebin/tmux" "$case_dir/fakebin/docker"
  real_tmux_scratch_dir
  export TMUX_TMPDIR=$REAL_TMUX_DIR
  tmux new-session -d -s firstmate -n fm-task-x1 -c "$case_dir" 'exec sleep 3600' \
    || fail "the real scratch tmux server did not start"
  tmux list-windows -t firstmate -F '#{window_name}' | grep -Fxq fm-task-x1 \
    || fail "the real scratch tmux server has no fm-task-x1 window"
}

# real_assert_window_gone <label>: the real tmux no longer holds the task's window.
real_assert_window_gone() {
  if tmux list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -Fxq fm-task-x1; then
    fail "$1: the real tmux still holds the task's window"
  fi
}

# real_case <name>: a retained case on a real pool slot. FM_STUB_CLOSEOUT selects
# the stand-in driver: retained keeps the copy, unset releases and removes it.
real_case() {
  make_retained_case "real-$1" enclosing
  export TREEHOUSE_ROOT=$FOREIGN_CASE/realroot
  real_local_tools
  # Only the closeout driver, gh, gh-axi and no-mistakes are stand-ins (Main 4400): the
  # retained fixture's empty-cwd lsof fake goes, so every case scans real processes with
  # the real lsof, and the forge stand-ins answer the fixtures' true state, "no pull
  # request" (no pr= in the task record and no merged PR from gh or gh-axi). Landing is
  # proved from Git alone: the task's branch head is on the project's main.
  rm -f "$FOREIGN_CASE/fakebin/lsof"
  add_gh_no_pr "$FOREIGN_CASE"
  sed -i.bak '/^pr=/d' "$FOREIGN_CASE/state/task-x1.meta" && rm -f "$FOREIGN_CASE/state/task-x1.meta.bak"
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
    echo "tmux $(tmux -V 2>&1)"
    echo "docker $(docker --version 2>&1)"
    echo "pool-dir $(cd "$FOREIGN_CASE/project" && treehouse pool-dir </dev/null 2>&1)"
    echo "slot $FOREIGN_SLOT"
    echo "copy $FOREIGN_COPY"
  } > "$dir/$phase.env"
  real_slot_entry > "$dir/$phase.slot.json" 2>&1
  { tmux list-windows -t firstmate -F '#{session_name}:#{window_name}' 2>&1 || true; } > "$dir/$phase.tmux-windows"
  { docker ps -a --filter "label=fm.task=task-x1" --format '{{.ID}} {{.Names}}' 2>&1 || true; } > "$dir/$phase.docker-task-objects"
  (cd "$FOREIGN_CASE/project" && treehouse status --json </dev/null 2>&1) > "$dir/$phase.status.json"
  shasum -a 256 "$FOREIGN_CASE/pool/treehouse-state.json" > "$dir/$phase.state.sha256" 2>&1
  # The claim file is the lease's mark on the slot. A released close returns the slot and the
  # real treehouse removes it, so the record says so instead of leaving no file.
  if [ -f "$FOREIGN_CASE/pool/1/.fm-slot-owner" ]; then
    cp "$FOREIGN_CASE/pool/1/.fm-slot-owner" "$dir/$phase.claim"
  else
    printf 'absent: %s does not exist at the %s record (the slot was returned and its claim released)\n' "$FOREIGN_CASE/pool/1/.fm-slot-owner" "$phase" > "$dir/$phase.claim"
  fi
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
  local rc preserve scratch want have
  real_case a-kept
  SLOT_ENTRY_BEFORE=$(real_slot_entry)
  [ "$(jq -r '.[0].lease_holder' <<<"$SLOT_ENTRY_BEFORE")" = task-x1 ] || fail "a-kept: the real slot is not leased to the task before the close: $SLOT_ENTRY_BEFORE"
  real_teardown rc FM_STUB_CLOSEOUT=retained
  real_record after
  expect_code 0 "$rc" "a-kept: the close must succeed on a real pool slot: $(cat "$FOREIGN_CASE/stderr")"
  retained_assert_closed "a-kept"
  real_assert_window_gone "a-kept"
  assert_equals 0 "$(real_returns)" "a-kept: the real slot was returned"
  real_assert_slot_unchanged "a-kept"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "a-kept: the driver was not asked exactly once"
  # The unique .claude files are saved in the driver's verified archive, which the recorded
  # answer names (the stand-in's archive is a placeholder); the task's preserve holds the
  # selected file, restored here into a scratch path.
  assert_equals '[".claude/channel-outbox/a.jsonl",".claude/channel-outbox/b.jsonl"]' "$(sed -n 's/^answer-base64=//p' "$(retained_record_path)" | perl -MMIME::Base64 -0777 -ne 'print decode_base64($_)' | jq -c .unique_ignored_paths)" "a-kept: the record does not carry the driver's unique paths"
  preserve=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  scratch=$FOREIGN_CASE/scratch-restore
  mkdir -p "$scratch"
  (cd "$preserve" && tar -cf - .) | (cd "$scratch" && tar -xf -)
  want=$(printf 'only here\n' | shasum -a 256 | awk '{print $1}')
  have=$(shasum -a 256 "$scratch/notes/unique.dat" | awk '{print $1}')
  assert_equals "$want" "$have" "a-kept: notes/unique.dat does not restore to the builder's hash"
  [ ! -e "$preserve/.venv" ] && [ ! -e "$preserve/node_modules" ] || fail "a-kept: the regenerable control was preserved"
  assert_present "$FOREIGN_COPY/.venv/bin/python" "a-kept: the kept copy lost its control"
  assert_present "$FOREIGN_COPY/node_modules/dep/index.js" "a-kept: the kept copy lost its control"
  if [ -n "$REAL_DIR" ]; then
    diff -r "$preserve" "$scratch" > "$REAL_DIR/restore.diff" 2>&1 && echo "restore: identical" >> "$REAL_DIR/restore.diff"
    printf 'notes/unique.dat  builder:%s restored:%s\n' "$want" "$have" >> "$REAL_DIR/restore.hashes"
  fi
  pass "a-kept: on a real pool slot the close keeps the copy and the lease, the unique files restore to the builder's hashes and the control is left out"
}

# a. Released route: the driver releases the copy; the unique file is in the
# preserve with its hash before the copy goes, the control goes with the copy and
# was never preserved, and the real slot is returned by the real binary.
test_a_real_pool_slot_is_returned_after_the_unique_file_is_preserved_and_the_control_is_removed() {
  local rc preserve hash pl rl
  real_case a-released
  real_teardown rc
  real_record after
  expect_code 0 "$rc" "a-released: the close must succeed on a real pool slot: $(cat "$FOREIGN_CASE/stderr")"
  real_assert_window_gone "a-released"
  assert_absent "$FOREIGN_COPY" "a-released: the copy survived the release"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "a-released: the task record survived"
  hash=$(printf '%s' "$FOREIGN_COPY" | shasum -a 256 | awk '{print $1}')
  preserve=$FOREIGN_CASE/data/task-x1/nested-copy-preserved/$hash
  assert_equals "only here" "$(cat "$preserve/notes/unique.dat")" "a-released: the unique file was not preserved before the removal"
  assert_grep "$(printf 'only here\n' | shasum -a 256 | awk '{print $1}')  notes/unique.dat" "$preserve/SHA256SUMS" "a-released: SHA256SUMS does not record the unique file"
  [ ! -e "$preserve/.venv" ] && [ ! -e "$preserve/node_modules" ] || fail "a-released: the regenerable control was preserved"
  # The preserve was verified before anything was removed, read from the product's own output
  # order and not from the end state: its "preserved" line comes before its removal line.
  pl=$(grep -n 'teardown: preserved ignored files from' "$FOREIGN_CASE/stderr" | head -n 1 | cut -d: -f1)
  rl=$(grep -n 'teardown: removed ' "$FOREIGN_CASE/stderr" | head -n 1 | cut -d: -f1)
  { [ -n "$pl" ] && [ -n "$rl" ] && [ "$pl" -lt "$rl" ]; } || fail "a-released: the preserve line (${pl:-none}) does not come before the removal line (${rl:-none}): $(grep -v '^●\|^━' "$FOREIGN_CASE/stderr" | tail -6 | tr '\n' '|')"
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

test_a_copy_with_a_foreign_process_inside_it_is_kept_and_the_slot_stays_leased() {
  local rc pid
  real_case b-process
  SLOT_ENTRY_BEFORE=$(real_slot_entry)
  # Its working directory is below the copy's root, so it is not a process the
  # task's own cleanup ends (those have their cwd exactly at a root retire sweeps).
  ( cd "$FOREIGN_COPY/notes" && exec sleep 600 ) &
  pid=$!
  sleep 1
  real_teardown rc FM_STUB_CLOSEOUT=retained
  real_record after
  kill -0 "$pid" 2>/dev/null || fail "b-process: the foreign process was ended"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 1 "$rc" "b-process: a copy with a foreign process inside it must refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "process $pid is running in it" "$FOREIGN_CASE/stderr" "b-process: the refusal did not name the process"
  assert_equals 0 "$(retained_call_count)" "b-process: the driver was asked about a copy with a live user"
  real_assert_kept "b-process"
  pass "b-process: a copy with a foreign process inside it is refused naming the process, the process is left running, and the copy, the task and the real lease are unchanged"
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

# c. A start racing the close, with the deterministic handshake the contract names: the
# stand-in driver writes `entered` and waits for `release`; the racing real `treehouse get`
# starts from the test only after `entered`, independently of the driver, and its outcome is
# recorded before `release` is written. A second get follows the close. No wait has a
# cut-off; a slow one prints one alarm line.
real_race() {  # <label> <rc-var>
  local label=$1 rc_var=$2 project=$FOREIGN_CASE/project first_pid n out
  rm -f "$FOREIGN_CASE/entered" "$FOREIGN_CASE/release"
  (
    first_rc=
    real_teardown first_rc FM_STUB_CLOSEOUT=retained \
      "FM_STUB_AFTER=: > '$FOREIGN_CASE/entered'; n=0; until [ -e '$FOREIGN_CASE/release' ]; do sleep 0.1; n=\$((n + 1)); [ \"\$n\" -ne 300 ] || echo 'slow: the stand-in driver is still waiting for release' >&2; done"
    echo "$first_rc" > "$FOREIGN_CASE/race.teardown.rc"
  ) &
  first_pid=$!
  n=0
  until [ -f "$FOREIGN_CASE/entered" ]; do
    kill -0 "$first_pid" 2>/dev/null || break
    sleep 0.2
    n=$((n + 1))
    [ "$n" -ne 150 ] || echo "slow: $label: the teardown has not entered the driver yet" >&2
  done
  [ -f "$FOREIGN_CASE/entered" ] || fail "$label: the teardown ended without entering the driver"
  (cd "$project" && TREEHOUSE_ROOT="$TREEHOUSE_ROOT" treehouse get --lease --lease-holder racer-1 --json </dev/null > "$FOREIGN_CASE/race1.out" 2> "$FOREIGN_CASE/race1.err"; echo $? > "$FOREIGN_CASE/race1.rc")
  [ ! -e "$FOREIGN_CASE/release" ] || fail "$label: release was written before the racing start's outcome was recorded"
  [ -f "$FOREIGN_CASE/race1.rc" ] || fail "$label: the racing start's outcome was not recorded before release"
  : > "$FOREIGN_CASE/release"
  wait "$first_pid" 2>/dev/null || true
  printf -v "$rc_var" '%s' "$(cat "$FOREIGN_CASE/race.teardown.rc" 2>/dev/null || echo missing)"
  (cd "$project" && treehouse get --lease --lease-holder racer-2 --json </dev/null > "$FOREIGN_CASE/race2.out" 2> "$FOREIGN_CASE/race2.err"; echo $? > "$FOREIGN_CASE/race2.rc")
  if [ -n "$REAL_DIR" ]; then
    cp "$FOREIGN_CASE"/race*.out "$FOREIGN_CASE"/race*.err "$FOREIGN_CASE"/race*.rc "$REAL_DIR/" 2>/dev/null || true
  fi
  for n in 1 2; do
    [ -f "$FOREIGN_CASE/race$n.rc" ] || fail "$label: racing start $n never ran"
    out=$(jq -r '.path // empty' "$FOREIGN_CASE/race$n.out" 2>/dev/null || true)
    [ "$out" != "$FOREIGN_SLOT" ] || fail "$label: racing start $n was handed the held slot $FOREIGN_SLOT"
    # A start either fails safely (a nonzero status) or hands out a real, different slot; a
    # success with no readable path is not evidence that the held slot was kept from it.
    if [ "$(cat "$FOREIGN_CASE/race$n.rc")" = 0 ]; then
      [ -n "$out" ] && [ -d "$out" ] || fail "$label: racing start $n succeeded without naming an existing slot: $(head -c 300 "$FOREIGN_CASE/race$n.out")"
    fi
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

# F2 of the contract review: a copy-sweep apply that starts while a teardown of the
# same kept copy sits in the driver call (no record written yet) must not call the
# driver or archive again. The sweep skips a copy an active task record names.
real_sweep() {  # <label> <mode...>: the real sweep against this case's home and pool
  FM_HOME="$FOREIGN_CASE/home" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" FM_DATA_OVERRIDE="$FOREIGN_CASE/data" \
    FM_CONFIG_OVERRIDE="$FOREIGN_CASE/config" FM_COPY_SWEEP_TREEHOUSE_ROOT="$FOREIGN_CASE/realroot/.treehouse" \
    FM_TEARDOWN_VERNANT_PYTHON="$FOREIGN_CASE/vernant-python" NM_HOME="$FOREIGN_CASE/nm" \
    PATH="$FOREIGN_CASE/fakebin:$PATH" TREEHOUSE_ROOT="$TREEHOUSE_ROOT" \
    "$ROOT/bin/fm-copy-sweep.sh" "${@:2}" > "$FOREIGN_CASE/sweep.$1.out" 2>&1
  echo $? > "$FOREIGN_CASE/sweep.$1.rc"
}

test_a_copy_sweep_apply_during_a_teardown_in_the_driver_makes_no_second_archive() {
  local first_pid n
  real_case f-sweep-race
  rm -f "$FOREIGN_CASE/entered" "$FOREIGN_CASE/release"
  (
    env FM_TEARDOWN_VERNANT_PYTHON="$FOREIGN_CASE/vernant-python" FM_STUB_CLOSEOUT=retained \
      "FM_STUB_AFTER=: > '$FOREIGN_CASE/entered'; n=0; until [ -e '$FOREIGN_CASE/release' ]; do sleep 0.1; n=\$((n + 1)); [ \"\$n\" -ne 300 ] || echo 'slow: the stand-in driver is still waiting for release' >&2; done" FM_HOME="$FOREIGN_CASE/home" \
      FM_ROOT_OVERRIDE="$FOREIGN_CASE/code-root" FM_STATE_OVERRIDE="$FOREIGN_CASE/state" \
      FM_DATA_OVERRIDE="$FOREIGN_CASE/data" FM_CONFIG_OVERRIDE="$FOREIGN_CASE/config" \
      NM_HOME="$FOREIGN_CASE/nm" TREEHOUSE_ROOT="$TREEHOUSE_ROOT" PATH="$FOREIGN_CASE/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
      "$TEARDOWN" task-x1 > "$FOREIGN_CASE/stdout.first" 2> "$FOREIGN_CASE/stderr.first"
    echo $? > "$FOREIGN_CASE/rc.first"
  ) &
  first_pid=$!
  # The handshake: the stand-in driver writes `entered` and waits for `release`; the sweep runs
  # (apply, then report) only after `entered`, its outputs are recorded, and `release` is
  # written afterwards. No wait has a cut-off; a slow one prints one alarm line.
  n=0
  until [ -f "$FOREIGN_CASE/entered" ]; do
    kill -0 "$first_pid" 2>/dev/null || break
    sleep 0.2
    n=$((n + 1))
    [ "$n" -ne 150 ] || echo "slow: f-sweep-race: the teardown has not entered the driver yet" >&2
  done
  [ -f "$FOREIGN_CASE/entered" ] || fail "f-sweep-race: the teardown ended without entering the driver"
  real_sweep apply --apply
  real_sweep report
  : > "$FOREIGN_CASE/release"
  wait "$first_pid" 2>/dev/null || true
  if [ -n "$REAL_DIR" ]; then
    cp "$FOREIGN_CASE"/sweep.*.out "$FOREIGN_CASE"/sweep.*.rc "$REAL_DIR/" 2>/dev/null || true
    cp "$FOREIGN_CASE/stdout.first" "$REAL_DIR/teardown.stdout"
    cp "$FOREIGN_CASE/stderr.first" "$REAL_DIR/teardown.stderr"
    printf 'exit %s\n' "$(cat "$FOREIGN_CASE/rc.first")" > "$REAL_DIR/teardown.exit"
    real_record after
  fi
  grep -q "$FOREIGN_COPY" "$FOREIGN_CASE/sweep.report.out" || fail "f-sweep-race: the sweep never listed the copy, so it proves nothing: $(head -c 600 "$FOREIGN_CASE/sweep.report.out")"
  assert_equals "1 1" "$(retained_call_count) $(retained_tar_count)" "f-sweep-race: a sweep apply during a teardown called the driver or archived again"
  assert_equals 0 "$(cat "$FOREIGN_CASE/rc.first")" "f-sweep-race: the teardown did not close: $(cat "$FOREIGN_CASE/stderr.first")"
  assert_present "$FOREIGN_COPY/.git" "f-sweep-race: the copy was removed"
  pass "f-sweep-race: a real copy-sweep apply and report during a teardown held in the driver listed the copy, called the driver no more and wrote no second tar"
}

# c. A genuinely ignored file created while the driver runs is never closed over: on a real
# pool slot the first close refuses with the copy, the claim and the real lease unchanged and
# no record, and the next run assesses the changed copy once (one more driver call) and
# closes with the late file held in the preserve.
test_an_ignored_file_created_while_the_driver_runs_is_not_closed_over_on_a_real_pool_slot() {
  local rc preserve
  real_case c-late-file
  SLOT_ENTRY_BEFORE=$(real_slot_entry)
  real_teardown rc FM_STUB_CLOSEOUT=retained "FM_STUB_AFTER=printf 'late\n' > '$FOREIGN_COPY/.claude/channel-outbox/late.jsonl'"
  real_record after-run1
  expect_code 1 "$rc" "c-late-file: a file created during the driver call must not be closed over: $(cat "$FOREIGN_CASE/stderr")"
  git -C "$FOREIGN_COPY" check-ignore -q .claude/channel-outbox/late.jsonl || fail "c-late-file: the late file is not an ignored file, so the case proves nothing"
  assert_equals 1 "$(retained_call_count)" "c-late-file: run 1 must make exactly one driver call"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "c-late-file: the task record was removed"
  assert_present "$FOREIGN_COPY/.claude/channel-outbox/late.jsonl" "c-late-file: the late file is gone"
  assert_equals 1 "$(find "$FOREIGN_CASE/data/copy-sweep/retained" -type f 2>/dev/null | wc -l | tr -d ' ')" "c-late-file: the driver's answer was not recorded once"
  cp "$(retained_record_path)" "$FOREIGN_CASE/record.run1"
  assert_equals 0 "$(real_returns)" "c-late-file: the slot was returned"
  real_assert_slot_unchanged "c-late-file"
  # The late file is part of the copy now; the second close must leave the copy as it finds it.
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  real_teardown rc FM_STUB_CLOSEOUT=retained
  real_record after
  expect_code 0 "$rc" "c-late-file: the next run must assess the changed copy and close: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "2 2" "$(retained_call_count) $(retained_tar_count)" "c-late-file: the changed copy must be assessed exactly once more"
  retained_assert_closed "c-late-file"
  real_assert_slot_unchanged "c-late-file"
  cmp -s "$FOREIGN_CASE/record.run1" "$(retained_record_path)" && fail "c-late-file: the record of the state before the change was not replaced"
  assert_equals "late" "$(cat "$FOREIGN_COPY/.claude/channel-outbox/late.jsonl")" "c-late-file: the late file changed in the kept copy"
  pass "c-late-file: an ignored file created while the driver runs refuses the first close with the copy, claim and real lease unchanged, and the next run assesses the changed copy once and closes around it"
}

test_the_scratch_tmux_server_starts_whatever_the_length_of_tmpdir() {
  local long_tmp socket
  long_tmp=$TMP_ROOT/$(printf 'long-tmpdir-segment-%.0s' 1 2 3 4 5 6)
  mkdir -p "$long_tmp"
  assert_equals "1" "$([ "${#long_tmp}" -gt 120 ] && echo 1 || echo 0)" "the TMPDIR under test is longer than a unix socket path allows"
  (
    export TMPDIR=$long_tmp
    real_tmux_scratch_dir
    export TMUX_TMPDIR=$REAL_TMUX_DIR
    tmux new-session -d -s firstmate -n fm-task-x1 'exec sleep 3600' || exit 11
    tmux list-windows -t firstmate -F '#{window_name}' | grep -Fxq fm-task-x1 || exit 12
    socket=$(tmux display-message -p -t firstmate '#{socket_path}') || exit 13
    [ "${#socket}" -lt 104 ] || exit 14
    case $socket in "$long_tmp"/*) exit 15 ;; esac
  ) || fail "the scratch tmux server did not start under a TMPDIR of ${#long_tmp} bytes (exit $?)"
  real_tmux_stop_all
  pass "the scratch tmux server starts and keeps its socket path short under a TMPDIR of ${#long_tmp} bytes"
}

teardown_test_cases=(
test_a_real_pool_slot_keeps_its_lease_and_the_unique_files_are_preserved_and_the_control_is_left_out
test_a_real_pool_slot_is_returned_after_the_unique_file_is_preserved_and_the_control_is_removed
test_a_copy_with_a_foreign_process_inside_it_is_kept_and_the_slot_stays_leased
test_a_copy_that_another_task_record_names_is_kept_and_the_slot_stays_leased
test_a_slot_another_task_claims_is_left_untouched_and_stays_leased
test_a_start_racing_the_close_never_receives_the_held_slot
test_a_start_racing_the_close_of_an_unleased_slot_never_resets_the_copy
test_an_ignored_file_created_while_the_driver_runs_is_not_closed_over_on_a_real_pool_slot
test_a_copy_sweep_apply_during_a_teardown_in_the_driver_makes_no_second_archive
test_the_scratch_tmux_server_starts_whatever_the_length_of_tmpdir
)

fm_test_run_cases "${teardown_test_cases[@]}" -- "$@"
