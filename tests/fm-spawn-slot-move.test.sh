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


# --- review round 023: findings the first build missed (red first) ---------------------------

# The slot library needs the isolation predicates only for governed provisioning; these cases test
# the git behaviour of the library, so the predicates are stubbed to "isolated" and "nothing to keep".
fm_task_copy_isolated() { return 0; }
fm_task_copy_preserve() { return 0; }

# make_branch_slot <name>: a governed world whose slot sits on branch old-owner at the first commit.
make_branch_slot() {
  make_world "$1" 1
  git -C "$W_PROJ" fetch --quiet origin
  git -C "$W_SLOT" checkout --quiet -b old-owner
}

# --- finding 1: ignored work under an opened directory, and an archive that is only an alias -----

test_an_ignored_directory_keeps_its_classifier_context() {
  make_world f1-dir
  printf 'data/\n' >>"$(git -C "$W_PROJ" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  advance_origin data
  mkdir -p "$W_SLOT/data"
  printf 'private bytes\n' >"$W_SLOT/data/.DS_Store"
  expect_skip "an ignored directory the target tracks as a file skips the copy, whatever its children are called" ignored_collision
  grep -q 'private bytes' "$W_SLOT/data/.DS_Store" || fail "the ignored bytes changed"
}

test_an_archive_that_is_an_alias_of_the_ignored_file_does_not_excuse_the_collision() {
  make_world f1-alias
  advance_origin notes.local
  printf 'private bytes\n' >"$W_SLOT/notes.local"
  local arch="$W_DIR/archive/task/merge-prune-preserved/20260101T000000Z/x"
  mkdir -p "$arch"
  ln -s "$W_SLOT/notes.local" "$arch/notes.local"
  (cd "$arch" && printf '%s  notes.local\n' "$(shasum -a 256 "$W_SLOT/notes.local" | awk '{print $1}')" >SHA256SUMS)
  FM_SLOT_ARCHIVE_ROOT="$W_DIR/archive" expect_skip "a checksum-valid archive that is a symlink to the ignored file does not hold its bytes" ignored_collision
  grep -q 'private bytes' "$W_SLOT/notes.local" || fail "the ignored bytes changed"
}

# --- finding 2: a refusal-time restore must never check out a moved branch or orphan a commit -----

# provision_refused_after_a_writer_moved_old_owner: the real fm_slot_provision runs; its runner moves
# the old owner branch to a commit that tracks notes.local, then refuses.
moving_runner() { git -C "$W_SLOT" update-ref refs/heads/old-owner "$W_TARGET"; printf '{}\n' >"$2"; return 3; }
quiet_runner() { printf '{}\n' >"$2"; return 3; }

test_a_refusal_revert_does_not_check_out_a_branch_that_moved() {
  make_branch_slot f2-moved
  advance_origin notes.local
  printf 'private bytes\n' >"$W_SLOT/notes.local"
  local rc=0 out
  out=$(fm_slot_provision moving_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "the refused provisioning reported success: $out"
  grep -q 'private bytes' "$W_SLOT/notes.local" || fail "the revert overwrote the ignored bytes: $out"
  pass "a revert after a refusal does not check out an owner branch a writer moved onto ignored work"
}

test_a_refusal_revert_returns_to_an_unchanged_owner_branch() {
  make_branch_slot f2-unchanged
  printf 'private bytes\n' >"$W_SLOT/notes.local"
  local rc=0 out
  out=$(fm_slot_provision quiet_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "the refused provisioning reported success: $out"
  [ "$(git -C "$W_SLOT" symbolic-ref -q HEAD)" = refs/heads/old-owner ] || fail "the control revert did not return to the owner branch: $out"
  grep -q 'private bytes' "$W_SLOT/notes.local" || fail "the ignored bytes changed"
  pass "a revert after a refusal returns to the owner branch when nothing moved it"
}

test_restore_does_not_orphan_a_commit_made_after_preparation() {
  make_world f2-late 1
  git -C "$W_PROJ" fetch --quiet origin
  fm_slot_prepare_base "$W_PROJ" "$W_SLOT" tid || fail "preparation failed"
  commit_in_slot late.txt
  local late
  late=$(git -C "$W_SLOT" rev-parse HEAD)
  advance_origin advanced.txt
  fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" >/dev/null 2>&1 || true
  fm_slot_restore_base "$W_SLOT" >/dev/null 2>&1 || true
  [ "$(git -C "$W_SLOT" rev-parse HEAD)" = "$late" ] || [ -n "$(git -C "$W_SLOT" for-each-ref --contains "$late" refs/)" ] \
    || fail "the late commit is no longer HEAD and no ref holds it"
  pass "a restore after a late commit leaves that commit held by HEAD or a ref"
}

# --- finding 3: a checkout hook must not run on a slot ----------------------------------------

test_a_checkout_hook_cannot_change_a_slot_during_preparation() {
  make_branch_slot f3-hook
  printf 'private bytes\n' >"$W_SLOT/notes.local"
  local hooks
  hooks="$(git -C "$W_PROJ" rev-parse --path-format=absolute --git-common-dir)/hooks"
  mkdir -p "$hooks"
  printf '#!/bin/sh\nprintf hooked >"$(git rev-parse --show-toplevel)/notes.local"\nexit 1\n' >"$hooks/post-checkout"
  chmod +x "$hooks/post-checkout"
  fm_slot_prepare_base "$W_PROJ" "$W_SLOT" tid >/dev/null 2>&1 || true
  grep -q 'private bytes' "$W_SLOT/notes.local" || fail "a post-checkout hook rewrote the ignored bytes"
  pass "no checkout hook runs while a slot is prepared"
}

# --- finding 4: the holder rule ----------------------------------------------------------------

test_a_holder_is_seen_when_the_slot_is_already_at_the_target() {
  make_world f4-equal
  W_TARGET=$W_BASE
  start_holder "$W_SLOT"
  sleep 0.4
  start_marker
  FM_SLOT_SPAWN_PID=$MARKER_PID expect_skip "a live process in a slot already at the target still skips the copy" live_holder
  cleanup_held
}

test_a_younger_unrelated_process_in_the_slot_is_a_holder() {
  make_world f4-younger
  advance_origin advanced.txt
  start_marker
  sleep 0.4
  start_holder "$W_SLOT"
  sleep 0.2
  FM_SLOT_SPAWN_PID=$MARKER_PID expect_skip "a process that started after the spawn but is not the spawn's own acquisition is a holder" live_holder
  cleanup_held
}

test_the_panes_own_process_tree_is_not_a_holder() {
  make_world f4-pane
  advance_origin advanced.txt
  bash -c 'cd "$1" && sleep 300 & wait' _ "$W_SLOT" &
  PANE_PID=$!
  HELD_PIDS+=("$PANE_PID")
  sleep 0.5
  start_marker
  FM_SLOT_PANE_PID=$PANE_PID FM_SLOT_SPAWN_PID=$MARKER_PID expect_moved "the processes under the spawn's own pane are not holders"
  cleanup_held
}

test_a_holder_row_without_a_working_directory_is_a_holder() {
  make_world f4-lsof-incomplete
  advance_origin advanced.txt
  start_holder "$W_DIR"
  local bin="$W_DIR/partiallsof"
  mkdir -p "$bin"
  cat >"$bin/lsof" <<SH
#!/bin/sh
printf 'p$HOLDER_PID\ncsleep\n'
SH
  chmod +x "$bin/lsof"
  MOVE_PATH="$bin:$PATH" expect_skip "an lsof row that names a process but no working directory is a holder" live_holder
  cleanup_held
}

test_a_malformed_contention_row_counts_as_held() {
  make_world f4-contention-malformed 1
  advance_origin advanced.txt
  local common store
  common=$(git -C "$W_SLOT" rev-parse --path-format=absolute --git-common-dir)
  store="$common/vernant-worktree-leases"
  mkdir -p "$store"
  printf '{"worktree_id": "%s", "ts_iso": "not a time"}\n' "$W_SLOT" >"$store/contention.jsonl"
  expect_skip "a contention row that cannot be read counts as held" live_holder
}

# --- finding 6: a tracked edit made after the clean look ----------------------------------------

test_a_tracked_edit_made_after_the_clean_look_fails_the_move() {
  make_world f6-late-edit
  advance_origin advanced.txt
  local bin="$W_DIR/lateedit" real_git out rc=0
  real_git=$(command -v git)
  mkdir -p "$bin"
  cat >"$bin/git" <<SH
#!/usr/bin/env bash
case "\$*" in *' merge '*) printf 'late edit\n' >>"$W_SLOT/README.md" ;; esac
exec '$real_git' "\$@"
SH
  chmod +x "$bin/git"
  out=$(PATH="$bin:$PATH" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a tracked edit that appeared between the clean look and the merge was admitted: $out"
  grep -q 'late edit' "$W_SLOT/README.md" || fail "the late edit is gone"
  pass "a tracked edit that appears after the clean look fails the move and is kept"
}

# --- finding 7: a read that fails after the move must not be reported as untouched ----------------

test_a_failed_head_read_after_the_move_is_not_reported_as_untouched() {
  make_world f7-head-read
  advance_origin advanced.txt
  local bin="$W_DIR/headread" real_git out rc=0
  real_git=$(command -v git)
  mkdir -p "$bin"
  cat >"$bin/git" <<SH
#!/usr/bin/env bash
if [ -e '$W_DIR/merged' ]; then case "\$*" in *' rev-parse '*HEAD*) rm -f '$W_DIR/merged'; exit 1 ;; esac; fi
case "\$*" in *' merge '*) '$real_git' "\$@"; rc=\$?; : >'$W_DIR/merged'; exit \$rc ;; esac
exec '$real_git' "\$@"
SH
  chmod +x "$bin/git"
  out=$(PATH="$bin:$PATH" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a failed read after the move was reported as success: $out"
  [ "$rc" != 20 ] || fail "the slot was reported untouched although the merge had moved it: $out"
  assert_not_contains "$out" "left untouched" "the failure message calls a moved slot untouched"
  pass "a failed HEAD read after the move is a failure, not an untouched skip"
}

# --- finding 10 (validators): the snapshot must fail closed, and the destroying-command witness ------

test_the_snapshot_fails_when_git_cannot_be_read() {
  make_world f10-snapshot
  local bin="$W_DIR/nogit" rc=0
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 128\n' >"$bin/git"
  chmod +x "$bin/git"
  PATH="$bin:$PATH" snapshot "$W_SLOT" "$W_DIR/snap" || rc=$?
  [ "$rc" != 0 ] || fail "the snapshot reported success although every git read failed"
  pass "the snapshot fails when its git reads fail"
}

# forbidden_git_calls <log>: print every recorded git call that could discard or force work.
forbidden_git_calls() {
  grep -E '(^| )(reset( |$).*--hard|checkout .*(-f|--force)|clean( |$)|branch .*(-D|-f|--force)|worktree remove|stash( |$)|restore .*--worktree|update-ref -d)' "$1" || true
}

test_no_destroying_git_command_runs_on_any_move_path() {
  make_world d6-record
  advance_origin advanced.txt
  local bin="$W_DIR/recorder" real_git
  real_git=$(command -v git)
  mkdir -p "$bin"
  cat >"$bin/git" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>'$W_DIR/git-calls.log'
exec '$real_git' "\$@"
SH
  chmod +x "$bin/git"
  : >"$W_DIR/git-calls.log"
  PATH="$bin:$PATH" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" >/dev/null 2>&1 || fail "the recorded move did not succeed"
  printf 'edited\n' >>"$W_SLOT/README.md"
  advance_origin more.txt
  PATH="$bin:$PATH" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" >/dev/null 2>&1 || true
  [ -s "$W_DIR/git-calls.log" ] || fail "the recorder saw no git call"
  [ -z "$(forbidden_git_calls "$W_DIR/git-calls.log")" ] || fail "a destroying git call ran:"$'\n'"$(forbidden_git_calls "$W_DIR/git-calls.log")"
  # The control: the same checker must flag a log that holds one.
  printf 'reset --hard abc\ncheckout -f main\nclean -fd\n' >"$W_DIR/injected.log"
  [ "$(forbidden_git_calls "$W_DIR/injected.log" | wc -l | tr -d ' ')" = 3 ] || fail "the checker missed an injected destroying call"
  pass "no destroying git command runs on a clean move or a skip, and the checker flags one that does"
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
  test_an_ignored_directory_keeps_its_classifier_context
  test_an_archive_that_is_an_alias_of_the_ignored_file_does_not_excuse_the_collision
  test_a_refusal_revert_does_not_check_out_a_branch_that_moved
  test_a_refusal_revert_returns_to_an_unchanged_owner_branch
  test_restore_does_not_orphan_a_commit_made_after_preparation
  test_a_checkout_hook_cannot_change_a_slot_during_preparation
  test_a_holder_is_seen_when_the_slot_is_already_at_the_target
  test_a_younger_unrelated_process_in_the_slot_is_a_holder
  test_the_panes_own_process_tree_is_not_a_holder
  test_a_holder_row_without_a_working_directory_is_a_holder
  test_a_malformed_contention_row_counts_as_held
  test_a_tracked_edit_made_after_the_clean_look_fails_the_move
  test_a_failed_head_read_after_the_move_is_not_reported_as_untouched
  test_the_snapshot_fails_when_git_cannot_be_read
  test_no_destroying_git_command_runs_on_any_move_path
)

fm_test_run_cases "${CASES[@]}" -- "$@"
echo "# all fm-spawn-slot-move tests passed"
