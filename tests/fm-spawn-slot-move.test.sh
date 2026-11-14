#!/usr/bin/env bash
# Tests for the pooled-slot move (bin/fm-slot-provision-lib.sh): a slot is advanced only by a move
# git itself refuses when work would be lost (`merge --ff-only`, plain `checkout`), after a clean-tree
# look, one holder rule and one narrow ignored-work check, and any doubt skips the copy untouched.
# Every case runs on scratch repositories built here; nothing touches a real pool or project.
# The refusal cases record HEAD, `git show-ref`, the index and a path-sorted sha256 list of every file
# outside .git (tracked, untracked and ignored) before and after, and require all four to be equal.
# One case proves the comparison itself: it must see changed bytes under an equal `git status`.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-slot-move)
# A mutated copy of the library may be tested instead (scratch-only mutation runs).
SLOT_LIB=${FM_TEST_SLOT_LIB:-$ROOT/bin/fm-slot-provision-lib.sh}
# shellcheck source=bin/fm-slot-provision-lib.sh
. "$SLOT_LIB"

GITID=(-c user.name='Firstmate Tests' -c user.email='tests@example.invalid')
HELD_PIDS=()
cleanup_held() {
  local pid
  for pid in ${HELD_PIDS[@]+"${HELD_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  HELD_PIDS=()
}
trap cleanup_held EXIT

# make_world <name> [governed]: origin, a project clone on main, a publisher clone, and a pool slot
# (a detached worktree) at the first commit. Sets W_DIR W_PROJ W_SLOT W_PUB W_BASE.
make_world() {
  local name=$1 governed=${2:-0}
  W_DIR="$TMP_ROOT/$name"
  W_PROJ="$W_DIR/project"
  W_SLOT="$W_DIR/slot"
  W_PUB="$W_DIR/publisher"
  mkdir -p "$W_DIR"
  git init --quiet -b main "$W_PROJ"
  printf 'base\n' >"$W_PROJ/README.md"
  printf 'old\n' >"$W_PROJ/old.local"
  printf '*.local\ncache/\n' >"$W_PROJ/.gitignore"
  if [ "$governed" = 1 ]; then
    mkdir -p "$W_PROJ/scripts/git-stability"
    : >"$W_PROJ/scripts/git-stability/provision_existing_slot.py"
  fi
  git -C "$W_PROJ" add -A
  git -C "$W_PROJ" add -f old.local
  git -C "$W_PROJ" "${GITID[@]}" commit -qm initial
  git clone --quiet --bare "$W_PROJ" "$W_DIR/origin.git"
  git -C "$W_PROJ" remote add origin "file://$W_DIR/origin.git"
  W_BASE=$(git -C "$W_PROJ" rev-parse HEAD)
  git -C "$W_PROJ" worktree add --quiet --detach "$W_SLOT" "$W_BASE"
  git clone --quiet "file://$W_DIR/origin.git" "$W_PUB"
}

# advance_origin <file>...: the publisher commits each file (forced past .gitignore) and pushes; the
# project fetches. Sets W_TARGET to origin's new tip.
advance_origin() {
  local file
  for file in "$@"; do
    mkdir -p "$W_PUB/$(dirname "$file")"
    printf 'from origin: %s\n' "$file" >"$W_PUB/$file"
    git -C "$W_PUB" add -f -- "$file"
  done
  git -C "$W_PUB" "${GITID[@]}" commit -qm advance
  git -C "$W_PUB" push --quiet origin main
  git -C "$W_PROJ" fetch --quiet origin
  W_TARGET=$(git -C "$W_PROJ" rev-parse origin/main)
}

# snapshot <slot> <out-file>: HEAD, show-ref, the index, and a path-sorted sha256 of every file outside .git.
snapshot() {
  local slot=$1 out=$2
  {
    printf 'HEAD %s\n' "$(git -C "$slot" rev-parse HEAD)"
    printf 'SYMBOLIC %s\n' "$(git -C "$slot" symbolic-ref -q HEAD || echo detached)"
    git -C "$slot" show-ref
    git -C "$slot" ls-files -s --debug
    (cd "$slot" && find . -path ./.git -prune -o \( -type f -o -type l \) -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
  } >"$out" 2>&1
}

# expect_skip <label> <reason-code> [<snapshot-after-move-allowed>]: run the move on the current world,
# require the skip code, the reason, the slot path in the message, and a byte-identical slot.
expect_skip() {
  local label=$1 reason=$2 out rc=0
  snapshot "$W_SLOT" "$W_DIR/before"
  out=$(PATH="${MOVE_PATH:-$PATH}" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  [ "$rc" = 20 ] || fail "$label: expected the skip code 20, got $rc: $out"
  assert_contains "$out" "($reason)" "$label: the skip did not name its reason $reason"
  assert_contains "$out" "$W_SLOT" "$label: the skip did not name the slot"
  snapshot "$W_SLOT" "$W_DIR/after"
  cmp -s "$W_DIR/before" "$W_DIR/after" || fail "$label: the slot changed:"$'\n'"$(diff "$W_DIR/before" "$W_DIR/after")"
  pass "$label"
}

# expect_moved <label>: the move succeeds and HEAD is the target.
expect_moved() {
  local label=$1 out rc=0
  out=$(fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "$label: the move did not succeed (rc $rc): $out"
  [ "$(git -C "$W_SLOT" rev-parse HEAD)" = "$W_TARGET" ] || fail "$label: HEAD is not the target after the move"
  pass "$label"
}

commit_in_slot() { # <file> [<slot>]
  local slot=${2:-$W_SLOT}
  printf 'unlanded\n' >"$slot/$1"
  git -C "$slot" add -f -- "$1"
  git -C "$slot" "${GITID[@]}" commit -qm unlanded
}

# --- the control and the git refusals ----------------------------------------

test_control_clean_slot_behind_the_target_moves() {
  make_world control
  advance_origin advanced.txt
  expect_moved "a clean slot behind the target moves to it"
  [ -f "$W_SLOT/advanced.txt" ] || fail "the moved slot lacks the target's file"
}

test_detached_extra_commit_is_skipped() {
  make_world detached-extra
  commit_in_slot mine.txt
  advance_origin advanced.txt
  expect_skip "a detached HEAD with one commit the target lacks is skipped, the commit kept" not_fast_forward
  [ -f "$W_SLOT/mine.txt" ] || fail "the unlanded commit's file is gone"
}

test_slot_ahead_of_the_target_is_skipped() {
  make_world ahead
  commit_in_slot mine.txt
  W_TARGET=$W_BASE
  expect_skip "a slot ahead of the target (the target is behind HEAD) is skipped" head_not_target
}

test_attached_branch_with_an_unlanded_commit_is_skipped() {
  make_world attached-diverged
  git -C "$W_SLOT" checkout --quiet -b owner-branch
  commit_in_slot mine.txt
  advance_origin advanced.txt
  local tip
  tip=$(git -C "$W_SLOT" rev-parse owner-branch)
  expect_skip "a branch with an unlanded commit that has diverged from the target is skipped" not_fast_forward
  [ "$(git -C "$W_SLOT" rev-parse owner-branch)" = "$tip" ] || fail "the owner branch moved"
}

test_attached_branch_behind_the_target_moves_forward_keeping_its_tip() {
  make_world attached-behind
  git -C "$W_SLOT" checkout --quiet -b owner-branch
  advance_origin advanced.txt
  expect_moved "a branch behind the target moves forward"
  git -C "$W_SLOT" merge-base --is-ancestor "$W_BASE" owner-branch || fail "the branch's old tip is no longer reachable from it"
  [ "$(git -C "$W_SLOT" symbolic-ref -q HEAD)" = refs/heads/owner-branch ] || fail "the slot left its branch"
}

test_rewound_default_skips_the_copy() {
  make_world rewound
  advance_origin advanced.txt
  git -C "$W_SLOT" -c core.hooksPath=/dev/null merge --quiet --ff-only "$W_TARGET"
  git -C "$W_PUB" reset --quiet --hard HEAD~1 2>/dev/null || true
  W_TARGET=$W_BASE
  expect_skip "an origin default rewound behind the slot's HEAD skips the copy" head_not_target
}


# --- the clean-tree look --------------------------------------------------------

test_modified_tracked_file_is_skipped() {
  make_world dirty-tracked
  advance_origin advanced.txt
  printf 'edited\n' >>"$W_SLOT/README.md"
  expect_skip "a modified tracked file skips the copy" dirty_tree
  grep -q edited "$W_SLOT/README.md" || fail "the edit is gone"
}

test_staged_file_is_skipped() {
  make_world dirty-staged
  advance_origin advanced.txt
  printf 'new\n' >"$W_SLOT/staged.txt"
  git -C "$W_SLOT" add staged.txt
  expect_skip "a staged file skips the copy" dirty_tree
}

test_untracked_file_in_an_untracked_directory_is_skipped() {
  make_world dirty-untracked
  advance_origin advanced.txt
  mkdir -p "$W_SLOT/deep/er"
  printf 'mine\n' >"$W_SLOT/deep/er/file.txt"
  expect_skip "an untracked file inside an untracked directory skips the copy" dirty_tree
}

test_changed_bytes_under_equal_status_are_seen_by_the_comparison() {
  make_world witness
  printf 'one\n' >>"$W_SLOT/README.md"
  git -C "$W_SLOT" status --porcelain >"$W_DIR/status.before"
  snapshot "$W_SLOT" "$W_DIR/before"
  printf 'two\n' >"$W_SLOT/README.md"
  git -C "$W_SLOT" status --porcelain >"$W_DIR/status.after"
  snapshot "$W_SLOT" "$W_DIR/after"
  cmp -s "$W_DIR/status.before" "$W_DIR/status.after" || fail "the witness changed the status"
  ! cmp -s "$W_DIR/before" "$W_DIR/after" || fail "the comparison missed changed bytes under an equal status"
  pass "the before/after comparison sees changed bytes under an equal git status"
}

# --- the narrow ignored-work check ----------------------------------------------

test_ignored_file_at_a_path_the_move_writes_is_skipped() {
  make_world ignored-same
  advance_origin notes.local
  printf 'my ignored work\n' >"$W_SLOT/notes.local"
  expect_skip "an ignored file at a path the target tracks skips the copy" ignored_collision
  grep -q 'my ignored work' "$W_SLOT/notes.local" || fail "the ignored bytes changed"
}

test_ignored_file_where_a_tracked_directory_must_be_created_is_skipped() {
  make_world ignored-ancestor
  advance_origin notes.local/entry.txt
  printf 'my ignored work\n' >"$W_SLOT/notes.local"
  expect_skip "an ignored regular file that is an ancestor of a path the target tracks skips the copy" ignored_collision
  grep -q 'my ignored work' "$W_SLOT/notes.local" || fail "the ignored bytes changed"
}

test_ignored_directory_below_a_path_the_move_writes_is_skipped() {
  make_world ignored-below
  advance_origin dir.local
  mkdir -p "$W_SLOT/dir.local"
  printf 'my ignored work\n' >"$W_SLOT/dir.local/inner.txt"
  expect_skip "an ignored entry inside a path the target tracks skips the copy" ignored_collision
  grep -q 'my ignored work' "$W_SLOT/dir.local/inner.txt" || fail "the ignored bytes changed"
}

test_ignored_file_at_an_untouched_path_survives_the_move() {
  make_world ignored-control
  advance_origin advanced.txt
  printf 'keep me\n' >"$W_SLOT/scratch.local"
  expect_moved "an ignored file at a path the target does not track passes"
  grep -q 'keep me' "$W_SLOT/scratch.local" || fail "the ignored file's bytes changed across the move"
}

test_unreadable_ignored_inventory_skips_the_copy() {
  make_world ignored-inventory
  advance_origin advanced.txt
  local bin="$W_DIR/shimbin" real_git
  real_git=$(command -v git)
  mkdir -p "$bin"
  cat >"$bin/git" <<SH
#!/usr/bin/env bash
case "\$*" in *'ls-files -o -i'*) exit 1 ;; esac
exec '$real_git' "\$@"
SH
  chmod +x "$bin/git"
  MOVE_PATH="$bin:$PATH" expect_skip "a failed ignored inventory skips the copy" unknown_ignored_inventory
}

test_checkout_over_ignored_work_is_skipped() {
  make_world checkout-ignored
  git -C "$W_PUB" rm -q old.local
  git -C "$W_PUB" "${GITID[@]}" commit -qm 'drop old.local'
  git -C "$W_PUB" push --quiet origin main
  git -C "$W_PROJ" fetch --quiet origin
  W_TARGET=$(git -C "$W_PROJ" rev-parse origin/main)
  expect_moved "the slot first moves to the target that drops old.local"
  printf 'my ignored work\n' >"$W_SLOT/old.local"
  local out rc=0
  snapshot "$W_SLOT" "$W_DIR/before"
  out=$(fm_slot_checkout "$W_SLOT" "$W_BASE" --detach "$W_BASE" 2>&1) || rc=$?
  [ "$rc" = 20 ] || fail "a checkout back over ignored work was not skipped (rc $rc): $out"
  assert_contains "$out" '(ignored_collision)' "the checkout skip did not name its reason"
  snapshot "$W_SLOT" "$W_DIR/after"
  cmp -s "$W_DIR/before" "$W_DIR/after" || fail "the slot changed on a skipped checkout"
  pass "a tree-changing checkout over ignored work is skipped and leaves the slot as found"
}

# --- the one holder rule ----------------------------------------------------------

# start_holder <dir>: a process whose working directory is <dir>. Sets HOLDER_PID.
start_holder() {
  (cd "$1" && exec sleep 300) &
  HOLDER_PID=$!
  HELD_PIDS+=("$HOLDER_PID")
}

# start_marker: a process standing in for the spawn. Sets MARKER_PID.
start_marker() {
  sleep 300 &
  MARKER_PID=$!
  HELD_PIDS+=("$MARKER_PID")
}

test_process_in_the_slot_that_predates_the_spawn_skips_the_copy() {
  make_world holder-cwd
  advance_origin advanced.txt
  start_holder "$W_SLOT"
  sleep 0.4
  start_marker
  FM_SLOT_SPAWN_PID=$MARKER_PID expect_skip "a live process that started before the spawn with its working directory in the slot skips the copy" live_holder
  kill "$HOLDER_PID" 2>/dev/null
  wait "$HOLDER_PID" 2>/dev/null
  FM_SLOT_SPAWN_PID=$MARKER_PID expect_moved "the same slot is used once the holder is gone"
  cleanup_held
}

test_process_in_the_slot_that_started_after_the_spawn_is_its_own() {
  make_world holder-own
  advance_origin advanced.txt
  start_marker
  sleep 0.4
  start_holder "$W_SLOT"
  sleep 0.2
  FM_SLOT_SPAWN_PID=$MARKER_PID expect_moved "a process that started after the spawn (the shell treehouse opened for it) is not a holder"
  cleanup_held
}

test_worktree_lock_skips_the_copy() {
  make_world holder-lock
  advance_origin advanced.txt
  git -C "$W_PROJ" worktree lock "$W_SLOT"
  expect_skip "a git worktree lock on the slot skips the copy" live_holder
  git -C "$W_PROJ" worktree unlock "$W_SLOT"
  expect_moved "the slot is used once the lock is released"
}

# write_lease <pid> <status>: a project lease record for the slot, in the store the governed project keeps.
write_lease() {
  local common store name
  common=$(git -C "$W_SLOT" rev-parse --path-format=absolute --git-common-dir)
  store="$common/vernant-worktree-leases"
  mkdir -p "$store"
  name=$(python3 -c 'import hashlib,sys; print("lease-" + hashlib.sha256(("worktree:" + sys.argv[1]).encode()).hexdigest()[:16] + ".json")' "$W_SLOT")
  printf '{"status": "%s", "owner_id": "other-task", "owner_pid": %s}\n' "$2" "$1" >"$store/$name"
}

write_contention() { # <seconds-ago>
  local common store
  common=$(git -C "$W_SLOT" rev-parse --path-format=absolute --git-common-dir)
  store="$common/vernant-worktree-leases"
  mkdir -p "$store"
  python3 -c 'import datetime,json,sys
ts = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=int(sys.argv[2]))
print(json.dumps({"worktree_id": sys.argv[1], "ts_iso": ts.isoformat()}))' "$W_SLOT" "$1" >"$store/contention.jsonl"
}

test_live_foreign_lease_skips_the_copy() {
  make_world holder-lease 1
  advance_origin advanced.txt
  start_marker
  write_lease "$MARKER_PID" active
  expect_skip "a live lease held by another owner skips the copy" live_holder
  kill "$MARKER_PID" 2>/dev/null
  wait "$MARKER_PID" 2>/dev/null
  expect_moved "the slot is used once the lease holder is gone"
  cleanup_held
}

test_contention_inside_the_window_skips_and_outside_it_does_not() {
  make_world holder-contention 1
  advance_origin advanced.txt
  write_contention 3600
  expect_skip "a co-tenant contention row inside 24 hours skips the copy" live_holder
  write_contention $((30 * 3600))
  expect_moved "a contention row older than 24 hours does not"
}

test_unreadable_lease_skips_the_copy() {
  make_world holder-lease-garbage 1
  advance_origin advanced.txt
  local common store name
  common=$(git -C "$W_SLOT" rev-parse --path-format=absolute --git-common-dir)
  store="$common/vernant-worktree-leases"
  mkdir -p "$store"
  name=$(python3 -c 'import hashlib,sys; print("lease-" + hashlib.sha256(("worktree:" + sys.argv[1]).encode()).hexdigest()[:16] + ".json")' "$W_SLOT")
  printf 'not json\n' >"$store/$name"
  expect_skip "an unreadable lease record skips the copy" unknown_holders
}

# --- unknown skips ----------------------------------------------------------------

test_missing_lsof_skips_the_copy() {
  make_world unknown-no-lsof
  advance_origin advanced.txt
  local bin="$W_DIR/nolsof" tool path
  mkdir -p "$bin"
  for tool in git python3 sed tr mktemp shasum awk grep cat rm dirname find sort xargs cut head readlink basename env uname; do
    path=$(command -v "$tool" 2>/dev/null) && ln -sf "$path" "$bin/$tool"
  done
  MOVE_PATH="$bin" expect_skip "an unavailable lsof skips the copy" unknown_holders
}

test_failing_lsof_skips_the_copy() {
  make_world unknown-lsof-fails
  advance_origin advanced.txt
  local bin="$W_DIR/badlsof"
  mkdir -p "$bin"
  printf '#!/bin/sh\necho "lsof: no memory" >&2\nexit 2\n' >"$bin/lsof"
  chmod +x "$bin/lsof"
  MOVE_PATH="$bin:$PATH" expect_skip "a failing lsof skips the copy" unknown_holders
}

test_failed_git_status_skips_the_copy() {
  make_world unknown-git-status
  advance_origin advanced.txt
  local bin="$W_DIR/shimgit" real_git
  real_git=$(command -v git)
  mkdir -p "$bin"
  cat >"$bin/git" <<SH
#!/usr/bin/env bash
case "\$*" in *' status '*) exit 1 ;; esac
exec '$real_git' "\$@"
SH
  chmod +x "$bin/git"
  MOVE_PATH="$bin:$PATH" expect_skip "a failed git status skips the copy" unknown_git_read
}

test_unreadable_target_skips_the_copy() {
  make_world unknown-target
  W_TARGET=0000000000000000000000000000000000000000
  expect_skip "a target commit that cannot be read skips the copy" unknown_target
}


CASES=(
  test_control_clean_slot_behind_the_target_moves
  test_detached_extra_commit_is_skipped
  test_slot_ahead_of_the_target_is_skipped
  test_attached_branch_with_an_unlanded_commit_is_skipped
  test_attached_branch_behind_the_target_moves_forward_keeping_its_tip
  test_rewound_default_skips_the_copy
  test_modified_tracked_file_is_skipped
  test_staged_file_is_skipped
  test_untracked_file_in_an_untracked_directory_is_skipped
  test_changed_bytes_under_equal_status_are_seen_by_the_comparison
  test_ignored_file_at_a_path_the_move_writes_is_skipped
  test_ignored_file_where_a_tracked_directory_must_be_created_is_skipped
  test_ignored_directory_below_a_path_the_move_writes_is_skipped
  test_ignored_file_at_an_untouched_path_survives_the_move
  test_unreadable_ignored_inventory_skips_the_copy
  test_checkout_over_ignored_work_is_skipped
  test_process_in_the_slot_that_predates_the_spawn_skips_the_copy
  test_process_in_the_slot_that_started_after_the_spawn_is_its_own
  test_worktree_lock_skips_the_copy
  test_live_foreign_lease_skips_the_copy
  test_contention_inside_the_window_skips_and_outside_it_does_not
  test_unreadable_lease_skips_the_copy
  test_missing_lsof_skips_the_copy
  test_failing_lsof_skips_the_copy
  test_failed_git_status_skips_the_copy
  test_unreadable_target_skips_the_copy
)

fm_test_run_cases "${CASES[@]}" -- "$@"
echo "# all fm-spawn-slot-move tests passed"
