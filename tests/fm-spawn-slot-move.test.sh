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
# Stop only the processes this test recorded and everything below them (a pane, its launcher, the shell the launcher
# opened), leaves first. Nothing else is signalled.
kill_tree() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$child"; done
  kill "$1" 2>/dev/null || true
}
cleanup_held() {
  local pid
  for pid in ${HELD_PIDS[@]+"${HELD_PIDS[@]}"}; do kill_tree "$pid"; done
  HELD_PIDS=()
}
trap cleanup_held EXIT

# make_world <name> [governed]: origin, a project clone on main, a publisher clone, and a pool slot
# (a detached worktree) at the first commit. Sets W_DIR W_PROJ W_SLOT W_PUB W_BASE.
make_world() {
  local name=$1 governed=${2:-0}
  FM_SLOT_LEFT_HEAD='' FM_SLOT_PREPARE_DETACHED=0 FM_SLOT_PREVIOUS_BRANCH='' FM_SLOT_PREVIOUS_HEAD=''
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

# snapshot <slot> <out-file>: HEAD, the branch, every ref, the index, and a path-sorted sha256 of every file
# outside .git. It FAILS (nonzero, nothing written) when any read fails, so two failed reads can never
# compare equal.
snapshot() {
  local slot=$1 out=$2 tmp head sym
  tmp="$out.part"
  (
    set -o pipefail
    head=$(git -C "$slot" rev-parse HEAD) || exit 1
    printf 'HEAD %s\n' "$head"
    sym=$(git -C "$slot" symbolic-ref -q HEAD) || { [ "$?" = 1 ] || exit 1; sym=detached; }
    printf 'SYMBOLIC %s\n' "$sym"
    git -C "$slot" for-each-ref --format='%(refname) %(objectname)' || exit 1
    git -C "$slot" ls-files -s --debug || exit 1
    cd "$slot" || exit 1
    # A regular file by its sha256, a symlink by where it points (a link to a same-content file is a change).
    # shellcheck disable=SC2016 # The inner sh expands its own $1.
    find . -path ./.git -prune -o \( -type f -o -type l \) -print0 | LC_ALL=C sort -z |
      xargs -0 -n1 sh -c 'if [ -L "$1" ]; then printf "LINK %s -> %s\n" "$1" "$(readlink "$1")"; else shasum -a 256 -- "$1"; fi' _
  ) >"$tmp" 2>&1 || { rm -f "$tmp"; return 1; }
  grep -q '^HEAD [0-9a-f]' "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$out"
}

# expect_skip <label> <reason-code> [<snapshot-after-move-allowed>]: run the move on the current world,
# require the skip code, the reason, the slot path in the message, and a byte-identical slot.
expect_skip() {
  local label=$1 reason=$2 out rc=0
  snapshot "$W_SLOT" "$W_DIR/before" || fail "$label: the slot could not be read before the move"
  out=$(PATH="${MOVE_PATH:-$PATH}" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  [ "$rc" = 20 ] || fail "$label: expected the skip code 20, got $rc: $out"
  assert_contains "$out" "($reason)" "$label: the skip did not name its reason $reason"
  assert_contains "$out" "$W_SLOT" "$label: the skip did not name the slot"
  snapshot "$W_SLOT" "$W_DIR/after" || fail "$label: the slot could not be read after the move"
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
  git -C "$W_SLOT" status --porcelain >"$W_DIR/status.before" || fail "git status failed"
  snapshot "$W_SLOT" "$W_DIR/before" || fail "the first snapshot could not be taken"
  printf 'two\n' >"$W_SLOT/README.md"
  git -C "$W_SLOT" status --porcelain >"$W_DIR/status.after" || fail "git status failed"
  snapshot "$W_SLOT" "$W_DIR/after" || fail "the second snapshot could not be taken"
  [ -s "$W_DIR/before" ] && [ -s "$W_DIR/after" ] || fail "a snapshot file is missing or empty"
  cmp -s "$W_DIR/status.before" "$W_DIR/status.after" || fail "the witness changed the status"
  if cmp -s "$W_DIR/before" "$W_DIR/after"; then fail "the comparison missed changed bytes under an equal status"; fi
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

test_a_switch_back_over_ignored_work_is_refused_and_leaves_the_slot_as_found() {
  make_world checkout-ignored
  git -C "$W_PUB" rm -q old.local
  git -C "$W_PUB" "${GITID[@]}" commit -qm 'drop old.local'
  git -C "$W_PUB" push --quiet origin main
  git -C "$W_PROJ" fetch --quiet origin
  W_TARGET=$(git -C "$W_PROJ" rev-parse origin/main)
  expect_moved "the slot first moves to the target that drops old.local"
  printf 'my ignored work\n' >"$W_SLOT/old.local"
  local out rc=0
  snapshot "$W_SLOT" "$W_DIR/before" || fail "snapshot failed"
  out=$(fm_slot_attach "$W_SLOT" "" "$W_BASE" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a switch back over ignored work succeeded: $out"
  snapshot "$W_SLOT" "$W_DIR/after" || fail "snapshot failed"
  cmp -s "$W_DIR/before" "$W_DIR/after" || fail "the slot changed on a refused switch"
  pass "a switch back over ignored work is refused and leaves the slot as found"
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
  for tool in git python3 bash sed tr mktemp shasum awk grep cat rm dirname find sort xargs cut head readlink basename env uname; do
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
  [ "$(git -C "$W_SLOT" symbolic-ref -q HEAD)" = refs/heads/fm/tid ] || fail "the revert changed HEAD although the owner branch moved: $out"
  pass "a revert after a refusal does not check out an owner branch a writer moved onto ignored work"
}

# Main 1829: a refusal undoes this code's own step by ref only, and only when HEAD, the branch and the commit are exactly
# what it left. Nothing moved here, so the copy returns to the owner branch and no file is touched.
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

test_a_quiet_promotion_refusal_orphans_no_commit() {
  make_branch_slot f2-orphan
  local rc=0 base
  base=$(git -C "$W_SLOT" rev-parse HEAD)
  fm_slot_provision quiet_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "the refused provisioning reported success"
  [ "$(git -C "$W_SLOT" rev-parse refs/heads/old-owner)" = "$base" ] || fail "the owner branch moved"
  [ "$(git -C "$W_SLOT" rev-parse HEAD)" = "$base" ] || fail "HEAD moved"
  pass "a refused provisioning leaves the owner branch and the commit where they were"
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
  # shellcheck disable=SC2016 # The hook's own shell expands the command substitution.
  printf '#!/bin/sh\nprintf hooked >"$(git rev-parse --show-toplevel)/notes.local"\nexit 1\n' >"$hooks/post-checkout"
  chmod +x "$hooks/post-checkout"
  fm_slot_prepare_base "$W_PROJ" "$W_SLOT" tid >/dev/null 2>&1 || true
  grep -q 'private bytes' "$W_SLOT/notes.local" || fail "a post-checkout hook rewrote the ignored bytes"
  pass "no checkout hook runs while a slot is prepared"
}

test_a_merge_hook_does_not_run_during_the_move() {
  make_world f3-merge-hook
  advance_origin advanced.txt
  local hooks
  hooks="$(git -C "$W_PROJ" rev-parse --path-format=absolute --git-common-dir)/hooks"
  mkdir -p "$hooks"
  # shellcheck disable=SC2016 # The hook's own shell expands the command substitution.
  printf '#!/bin/sh\nprintf hooked >"$(git rev-parse --show-toplevel)/hook-ran.local"\n' >"$hooks/post-merge"
  chmod +x "$hooks/post-merge"
  expect_moved "a clean slot behind the target moves although a post-merge hook exists"
  [ ! -e "$W_SLOT/hook-ran.local" ] || fail "a post-merge hook ran during the move"
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

# start_pane <slot> <with-launcher 0|1>: a "pane" shell (a script, so it does not exec its last command). With a
# launcher it runs a treehouse launcher (a renamed copy of bash) that opens a shell in the slot, as `treehouse get`
# does; without one it runs a plain process in the slot, as a user's own tool in the same pane would. Sets PANE_PID.
start_pane() {
  local slot=$1 launcher=$2 dir="$W_DIR/launcher"
  cat >"$W_DIR/pane.sh" <<'SH'
#!/bin/bash
if [ "$2" = 1 ]; then
  "$3" -c 'cd "$1" && sleep 300 & wait' get "$1"
else
  (cd "$1" && exec sleep 300) &
  wait
fi
: done
SH
  chmod +x "$W_DIR/pane.sh"
  if [ "$launcher" = 1 ]; then make_launcher "$dir" || return 1; fi
  "$W_DIR/pane.sh" "$slot" "$launcher" "$dir/treehouse" &
  PANE_PID=$!
  HELD_PIDS+=("$PANE_PID")
  sleep 0.5
}

test_the_panes_own_launcher_tree_is_not_a_holder() {
  make_world f4-pane-launcher
  advance_origin advanced.txt
  start_marker
  sleep 0.4
  start_pane "$W_SLOT" 1 || { pass "SKIPPED: this host cannot run a renamed copy of bash"; return 0; }
  FM_SLOT_PANE_PID=$PANE_PID FM_SLOT_SPAWN_PID=$MARKER_PID expect_moved "the shell a treehouse launcher under the spawn's own pane opened is not a holder"
  cleanup_held
}

test_a_process_under_the_pane_but_not_under_the_launcher_is_a_holder() {
  make_world f4-pane-sibling
  advance_origin advanced.txt
  start_marker
  sleep 0.4
  start_pane "$W_SLOT" 0
  FM_SLOT_PANE_PID=$PANE_PID FM_SLOT_SPAWN_PID=$MARKER_PID expect_skip "a process under the pane that no launcher of this spawn opened is a holder" live_holder
  cleanup_held
}

test_a_process_under_the_pane_that_predates_the_spawn_is_a_holder() {
  make_world f4-pane-old
  advance_origin advanced.txt
  start_pane "$W_SLOT" 1 || { pass "SKIPPED: this host cannot run a renamed copy of bash"; return 0; }
  start_marker
  FM_SLOT_PANE_PID=$PANE_PID FM_SLOT_SPAWN_PID=$MARKER_PID expect_skip "a launcher tree that started before the spawn is not its acquisition, even under the pane" live_holder
  cleanup_held
}

test_a_lsof_row_without_a_working_directory_for_the_pane_is_a_holder() {
  make_world f4-pane-row
  advance_origin advanced.txt
  start_marker
  local bin="$W_DIR/panerow"
  mkdir -p "$bin"
  cat >"$bin/lsof" <<SH
#!/bin/sh
printf 'p$MARKER_PID\ncbash\n'
SH
  chmod +x "$bin/lsof"
  MOVE_PATH="$bin:$PATH" FM_SLOT_PANE_PID=$MARKER_PID FM_SLOT_SPAWN_PID=$MARKER_PID expect_skip "an lsof row with no working directory for the pane's own pid is a holder" live_holder
  cleanup_held
}

# The launcher's own child is the spawn's shell and is excused when lsof shows where it is. When lsof shows no
# working directory for that same process, nothing proves it is in the slot or out of it, so it is a holder.
test_an_lsof_row_with_no_directory_for_a_launcher_child_is_a_holder() {
  make_world f4-launcher-child-row
  advance_origin advanced.txt
  start_marker
  sleep 0.4
  start_pane "$W_SLOT" 1 || { pass "SKIPPED: this host cannot run a renamed copy of bash"; return 0; }
  local launcher child bin="$W_DIR/childrow"
  launcher=$(pgrep -P "$PANE_PID" | head -n 1)
  child=$(pgrep -P "${launcher:-0}" | head -n 1)
  [ -n "$child" ] || fail "the pane's launcher tree has no child process to name"
  mkdir -p "$bin"
  cat >"$bin/lsof" <<SH
#!/bin/sh
printf 'p$child\ncsleep\n'
SH
  chmod +x "$bin/lsof"
  MOVE_PATH="$bin:$PATH" FM_SLOT_PANE_PID=$PANE_PID FM_SLOT_SPAWN_PID=$MARKER_PID expect_skip "an lsof row with no working directory for a process under the spawn's own launcher is a holder" live_holder
  cleanup_held
}

# The same tree is excused only under the pane's own shell. When the backend names another pid as the pane, a
# launcher that runs elsewhere is not this spawn's acquisition.
test_a_launcher_that_does_not_run_under_the_named_pane_is_a_holder() {
  make_world f4-launcher-elsewhere
  advance_origin advanced.txt
  start_marker
  sleep 0.4
  start_pane "$W_SLOT" 1 || { pass "SKIPPED: this host cannot run a renamed copy of bash"; return 0; }
  FM_SLOT_PANE_PID=$MARKER_PID FM_SLOT_SPAWN_PID=$MARKER_PID expect_skip "a launcher that is not under the pane the backend named is not the spawn's own" live_holder
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

# A process that runs under a `treehouse` launcher the spawn started is the spawn's own shell, where the
# backend reports no pane pid. The launcher here is a copy of bash named treehouse, so the kernel's name
# for it is `treehouse`. Hosts that cannot run such a copy skip these two cases and say so.
make_launcher() { # <dir>: a runnable executable named treehouse; returns nonzero when this host cannot make one
  mkdir -p "$1"
  cp /bin/bash "$1/treehouse" 2>/dev/null || return 1
  [ "$(uname)" != Darwin ] || codesign -f -s - "$1/treehouse" >/dev/null 2>&1 || true
  "$1/treehouse" -c true 2>/dev/null
}

test_a_treehouse_launcher_started_after_the_spawn_owns_its_shell() {
  make_world f4-launcher-own
  advance_origin advanced.txt
  local dir="$W_DIR/launcher"
  make_launcher "$dir" || { pass "SKIPPED: this host cannot run a renamed copy of bash"; return 0; }
  start_marker
  sleep 0.5
  # shellcheck disable=SC2016 # The launcher's own shell expands $1.
  "$dir/treehouse" -c 'cd "$1" && sleep 300 & wait' get "$W_SLOT" &
  HELD_PIDS+=("$!")
  sleep 0.5
  FM_SLOT_SPAWN_PID=$MARKER_PID expect_moved "a process under a treehouse launcher that started after the spawn is the spawn's own shell"
  cleanup_held
}

test_a_treehouse_launcher_older_than_the_spawn_does_not_own_its_shell() {
  make_world f4-launcher-old
  advance_origin advanced.txt
  local dir="$W_DIR/launcher"
  make_launcher "$dir" || { pass "SKIPPED: this host cannot run a renamed copy of bash"; return 0; }
  # shellcheck disable=SC2016 # The launcher's own shell expands $1.
  "$dir/treehouse" -c 'cd "$1" && sleep 300 & wait' get "$W_SLOT" &
  HELD_PIDS+=("$!")
  sleep 0.5
  start_marker
  FM_SLOT_SPAWN_PID=$MARKER_PID expect_skip "a process under a treehouse launcher that started before the spawn is somebody else's" live_holder
  cleanup_held
}

# A commit that appears after the proof must never be merged over: git's fast-forward refuses, and the
# move is reported as a failure, with the late commit still HEAD.
test_a_commit_that_appears_after_the_proof_is_never_merged_over() {
  make_world f6-late-commit
  advance_origin advanced.txt
  local bin="$W_DIR/latecommit" real_git out rc=0 late
  real_git=$(command -v git)
  mkdir -p "$bin"
  cat >"$bin/git" <<SH
#!/usr/bin/env bash
case "\$*" in *' merge '*) if [ ! -e '$W_DIR/late-done' ]; then : >'$W_DIR/late-done'; printf 'late\n' >'$W_SLOT/late.txt'; '$real_git' -C '$W_SLOT' add late.txt; '$real_git' -C '$W_SLOT' -c user.name=T -c user.email=t@example.invalid commit -qm late; fi ;; esac
exec '$real_git' "\$@"
SH
  chmod +x "$bin/git"
  out=$(PATH="$bin:$PATH" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a commit that appeared after the proof was merged over: $out"
  late=$(git -C "$W_SLOT" rev-parse HEAD)
  [ "$(git -C "$W_SLOT" log -1 --format=%s "$late")" = late ] || fail "HEAD is no longer the late commit: $out"
  [ "$(git -C "$W_SLOT" rev-list --parents -n1 "$late" | wc -w | tr -d ' ')" = 2 ] || fail "a merge commit was made over the late commit"
  pass "a commit that appears after the proof is kept as HEAD and never merged over"
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
  grep -E '(^| )(reset( .*)? --(hard|merge|keep)|checkout( .*)? (-f|--force|-B)( |$)|checkout( .*)? -- [^ ]|switch( .*)? (-C|-f|--force|--force-create|--discard-changes)( |$)|clean( |$)|branch( .*)? (-D|-d|-f|--force|-M)( |$)|worktree remove|stash( |$)|restore( |$)|update-ref( .*)? (-d|--delete)( |$))' "$1" || true
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

# --- review of 8c6c20ece (Main 027): the cases that review's falsifiers showed ------------------------------

# 1. A refusal on the promotion route (fm_slot_provision with no prepared checkout) never orphans a late commit.
late_commit_runner() {
  git -C "$W_SLOT" -c core.hooksPath=/dev/null checkout -q --detach
  printf 'late\n' >"$W_SLOT/late.txt"
  git -C "$W_SLOT" add late.txt
  git -C "$W_SLOT" "${GITID[@]}" commit -qm late
  git -C "$W_SLOT" rev-parse HEAD >"$W_DIR/late-sha"
  printf '{}\n' >"$2"
  return 3
}
# dangling_commit <slot> <message>: a commit with the slot's tree that no ref holds. Prints its sha.
dangling_commit() {
  git -C "$1" "${GITID[@]}" commit-tree "HEAD^{tree}" -p HEAD -m "$2"
}

# The switch back is allowed only from the commit this spawn left. With no commit recorded, nothing proves that a
# detached HEAD is the spawn's own, so the copy is not switched and the commit it holds is not orphaned.
test_a_refusal_revert_with_no_recorded_left_commit_keeps_a_detached_commit() {
  make_branch_slot m1-attach-unrecorded
  local sha held rc=0
  sha=$(git -C "$W_SLOT" rev-parse HEAD)
  held=$(dangling_commit "$W_SLOT" unrecorded)
  git -C "$W_SLOT" -c core.hooksPath=/dev/null checkout -q --detach "$held"
  (FM_SLOT_LEFT_HEAD='' fm_slot_attach "$W_SLOT" old-owner "$sha") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "the switch back ran although no commit was recorded as the one this spawn left"
  [ "$(git -C "$W_SLOT" rev-parse HEAD)" = "$held" ] || fail "HEAD left a commit no ref holds"
  pass "a switch back with no recorded left commit keeps the detached commit"
}

# When the branch moved and HEAD is at a commit this spawn left (not the commit the branch held), the refusal
# leaves HEAD where it is. It does not detach to the old commit first and refuse afterwards.
test_a_refusal_revert_leaves_head_alone_when_the_branch_moved() {
  make_branch_slot m1-attach-branch-moved
  local sha left moved rc=0
  sha=$(git -C "$W_SLOT" rev-parse HEAD)
  left=$(dangling_commit "$W_SLOT" left)
  moved=$(dangling_commit "$W_SLOT" moved)
  git -C "$W_SLOT" -c core.hooksPath=/dev/null checkout -q --detach "$left"
  git -C "$W_SLOT" update-ref refs/heads/old-owner "$moved"
  (FM_SLOT_LEFT_HEAD=$left fm_slot_attach "$W_SLOT" old-owner "$sha") >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "the switch back reported success although the branch moved"
  [ "$(git -C "$W_SLOT" rev-parse HEAD)" = "$left" ] || fail "HEAD was changed although the branch moved"
  [ "$(git -C "$W_SLOT" rev-parse refs/heads/old-owner)" = "$moved" ] || fail "the moved branch was changed"
  pass "a refused switch back leaves HEAD where it was when the branch moved"
}

# A left commit recorded by an earlier step must not excuse a HEAD the promotion step did not leave.
test_a_promotion_refusal_ignores_a_stale_left_commit() {
  make_branch_slot m1-promotion-stale
  local held
  held=$(dangling_commit "$W_SLOT" stale)
  printf '%s\n' "$held" >"$W_DIR/held-sha"
  (FM_SLOT_LEFT_HEAD=$held; fm_slot_provision held_commit_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts) >/dev/null 2>&1 || true
  [ "$(git -C "$W_SLOT" rev-parse HEAD)" = "$held" ] || fail "the refusal switched away from a commit that no ref holds"
  pass "a stale left commit does not excuse the refusal's switch back"
}
held_commit_runner() {
  git -C "$W_SLOT" -c core.hooksPath=/dev/null checkout -q --detach "$(cat "$W_DIR/held-sha")"
  printf '{}\n' >"$2"
  return 3
}

# Main 1829: the late commit is HEAD when the refusal ends. The undo ran only on proof, and the proof failed.
test_a_promotion_refusal_after_a_late_commit_leaves_head_on_it() {
  make_branch_slot m1-promotion-head
  local late
  fm_slot_provision late_commit_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts >/dev/null 2>&1 || true
  late=$(cat "$W_DIR/late-sha")
  [ "$(git -C "$W_SLOT" rev-parse HEAD)" = "$late" ] || fail "a refusal moved HEAD off a commit made after the provision step"
  ! git -C "$W_SLOT" symbolic-ref -q HEAD >/dev/null || fail "a refusal attached a HEAD that another actor had detached"
  pass "a refusal leaves HEAD on a commit made after the provision step, as it found it"
}

test_a_promotion_refusal_after_a_late_commit_keeps_the_commit() {
  make_branch_slot m1-promotion
  local rc=0 late
  fm_slot_provision late_commit_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "the refused promotion reported success"
  late=$(cat "$W_DIR/late-sha")
  [ "$(git -C "$W_SLOT" rev-parse HEAD)" = "$late" ] || [ -n "$(git -C "$W_SLOT" for-each-ref --contains "$late" refs/)" ] \
    || fail "the late commit is neither HEAD nor held by any ref after the refusal"
  pass "a refused promotion keeps a commit made after its branch setup"
}

# 2. A move refused after the preparation detached a governed copy never calls the changed copy untouched.
# refuse_after_preparation <name> [break-undo]: the copy is proven, prepared (detached from its branch), and git then
# refuses the move. With break-undo the ref write that would put the branch back also fails. Sets REFUSE_OUT, REFUSE_RC.
refuse_after_preparation() {
  make_branch_slot "$1"
  advance_origin advanced.txt
  local bin="$W_DIR/refuse" real_git
  real_git=$(command -v git)
  fm_slot_prove_idle "$W_SLOT" "$W_TARGET" "$W_PROJ" || fail "the proof did not pass"
  fm_slot_prepare_base "$W_PROJ" "$W_SLOT" tid || fail "the preparation failed"
  mkdir -p "$bin"
  {
    printf '#!/bin/sh\ncase " $* " in *" merge --ff-only "*) exit 1 ;; esac\n'
    [ "${2:-}" != break-undo ] || printf 'case " $* " in *" symbolic-ref HEAD "*) exit 1 ;; esac\n'
    printf 'exec %s "$@"\n' "'$real_git'"
  } >"$bin/git"
  chmod +x "$bin/git"
  REFUSE_RC=0
  REFUSE_OUT=$(PATH="$bin:$PATH" fm_slot_apply_move "$W_SLOT" "$W_TARGET" 2>&1) || REFUSE_RC=$?
  [ "$REFUSE_RC" != 0 ] || fail "git refused the move but the apply step reported success: $REFUSE_OUT"
}

# Main 1829: the preparation's detach is undone by ref (no file is touched) when the proof holds.
test_a_refused_move_after_preparation_puts_the_branch_back() {
  refuse_after_preparation m2-refused
  [ "$(git -C "$W_SLOT" symbolic-ref -q HEAD)" = refs/heads/old-owner ] || fail "the branch was not put back: $REFUSE_OUT"
  pass "a refused move after preparation puts the branch back by ref"
}

# When the undo cannot be done, the copy stays as found (detached) and the output says so; it is never called untouched.
test_a_refused_move_after_preparation_says_the_copy_stays_detached() {
  refuse_after_preparation m2-refused-says break-undo
  assert_contains "$REFUSE_OUT" "stays detached" "the output did not say the copy stays detached"
  pass "a refused move whose undo failed says the copy stays detached"
}

test_a_refused_move_after_preparation_never_calls_a_changed_copy_untouched() {
  refuse_after_preparation m2-refused-untouched break-undo
  assert_not_contains "$REFUSE_OUT" "left untouched" "a copy the preparation detached was called untouched"
  pass "a copy the preparation detached and could not put back is never called untouched"
}

test_a_refused_move_after_preparation_leaves_a_detached_copy_where_it_is_when_the_undo_fails() {
  refuse_after_preparation m2-refused-stays break-undo
  ! git -C "$W_SLOT" symbolic-ref -q HEAD >/dev/null || fail "the copy was switched although the undo failed"
  pass "a failed undo leaves the copy detached, as the preparation left it"
}

# The undo of a promotion refusal runs no checkout, even to detach: a detached copy is detached again by ref.
test_a_refusal_undo_runs_no_checkout() {
  make_world a3-nocheckout 1
  local bin="$W_DIR/rec" real_git calls
  real_git=$(command -v git)
  mkdir -p "$bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%s\nexec %s "$@"\n' "'$W_DIR/calls'" "'$real_git'" >"$bin/git"
  chmod +x "$bin/git"
  # shellcheck disable=SC2329 # Called by name from fm_slot_provision.
  recording_runner() { printf 'RUNNER\n' >>"$W_DIR/calls"; printf '{}\n' >"$2"; return 3; }
  : >"$W_DIR/calls"
  PATH="$bin:$PATH" fm_slot_provision recording_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts >/dev/null 2>&1 || true
  calls=$(sed -n '/^RUNNER$/,$p' "$W_DIR/calls")
  case "$calls" in *' checkout '*|checkout\ *) fail "the undo ran a checkout: $(printf '%s' "$calls" | tr '\n' ';')" ;; esac
  pass "the undo of a promotion refusal runs no checkout"
}

# After a move that SUCCEEDED, the copy is at the target and the branch it came from is at the old commit. Switching back
# to that branch by ref would leave the files of the target under a HEAD that is the old commit; only a checkout could
# change the files, and no refusal runs one. So the undo is refused and the copy stays on the target, detached.
test_a_refusal_undo_never_returns_to_a_commit_with_other_files() {
  make_branch_slot m4-undo-other
  advance_origin advanced.txt
  fm_slot_prove_idle "$W_SLOT" "$W_TARGET" "$W_PROJ" || fail "the proof did not pass"
  fm_slot_prepare_base "$W_PROJ" "$W_SLOT" tid || fail "the preparation failed"
  fm_slot_apply_move "$W_SLOT" "$W_TARGET" >/dev/null 2>&1 || fail "the move did not succeed"
  local out rc=0
  out=$(fm_slot_restore_base "$W_SLOT" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "an undo that would change files reported success: $out"
  [ "$(git -C "$W_SLOT" rev-parse HEAD)" = "$W_TARGET" ] || fail "an undo that would change files was done: HEAD is not the target"
  ! git -C "$W_SLOT" symbolic-ref -q HEAD >/dev/null || fail "an undo that would change files was done: the copy was attached"
  [ -f "$W_SLOT/advanced.txt" ] || fail "a file of the target is gone"
  pass "a refusal never switches a moved copy back to a commit whose files differ"
}

# Main 1842: the provisioner commits on the task branch and refuses. The undo by ref is allowed only when HEAD is the
# task branch's tip AND the tree of that tip equals the tree of the commit the copy returns to.
empty_commit_runner() { [ -z "${CALLS_LOG:-}" ] || printf 'RUNNER\n' >>"$CALLS_LOG"; git -C "$W_SLOT" "${GITID[@]}" commit -q --allow-empty -m 'provisioner work'; printf '{}\n' >"$2"; return 3; }
file_commit_runner() { printf 'provisioner file\n' >"$W_SLOT/prov.txt"; git -C "$W_SLOT" add prov.txt; git -C "$W_SLOT" "${GITID[@]}" commit -qm 'provisioner file'; printf '{}\n' >"$2"; return 3; }

test_a_commit_on_the_task_branch_with_an_equal_tree_is_undone_by_ref() {
  make_branch_slot m5-equal-tree
  local h m bin="$W_DIR/rec" real_git calls
  h=$(git -C "$W_SLOT" rev-parse HEAD)
  real_git=$(command -v git)
  mkdir -p "$bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%s\nexec %s "$@"\n' "'$W_DIR/calls'" "'$real_git'" >"$bin/git"
  chmod +x "$bin/git"
  : >"$W_DIR/calls"
  CALLS_LOG="$W_DIR/calls" PATH="$bin:$PATH" fm_slot_provision empty_commit_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts >/dev/null 2>&1 || true
  m=$(git -C "$W_SLOT" rev-parse refs/heads/fm/tid)
  [ "$m" != "$h" ] || fail "the provisioner's commit is missing"
  [ "$(git -C "$W_SLOT" symbolic-ref -q HEAD)" = refs/heads/old-owner ] || fail "an equal tree was not undone by ref"
  [ "$(git -C "$W_SLOT" rev-parse HEAD)" = "$h" ] || fail "HEAD is not the scout head after the undo"
  calls=$(sed -n '/^RUNNER$/,$p' "$W_DIR/calls")
  case "$calls" in *' checkout '*|checkout\ *) fail "the undo ran a checkout: $(printf '%s' "$calls" | tr '\n' ';')" ;; esac
  pass "an equal tree is undone by ref, with no checkout, and the task branch keeps the provisioner's commit"
}

test_a_commit_on_the_task_branch_with_an_equal_tree_keeps_the_task_branch() {
  make_branch_slot m5-equal-keeps
  local m
  fm_slot_provision empty_commit_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts >/dev/null 2>&1 || true
  m=$(git -C "$W_SLOT" rev-parse --verify --quiet refs/heads/fm/tid) || fail "the task branch was deleted"
  [ "$(git -C "$W_SLOT" rev-parse "$m^")" = "$(git -C "$W_SLOT" rev-parse refs/heads/old-owner)" ] || fail "the provisioner's commit is not on the task branch"
  pass "the task branch is kept with the provisioner's commit"
}

test_a_commit_on_the_task_branch_that_changes_a_file_is_not_undone_and_is_reported() {
  make_branch_slot m5-file-differs
  local out rc=0
  out=$(fm_slot_provision file_commit_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts 2>&1) || rc=$?
  [ "$rc" = 3 ] || fail "the refusal did not return the provisioner's code ($rc)"
  [ "$(git -C "$W_SLOT" symbolic-ref -q HEAD)" = refs/heads/fm/tid ] || fail "a tree that differs by one file was undone: $out"
  [ -f "$W_SLOT/prov.txt" ] || fail "the provisioner's file is gone"
  assert_contains "$out" "would change files" "the refusal did not report why it left the copy as found"
  pass "a tree that differs by one file is not undone, and the refusal says why"
}

test_a_refusal_returns_a_detached_copy_to_detached() {
  make_world a3-detached 1
  local rc=0
  fm_slot_provision quiet_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || fail "the refused provisioning reported success"
  ! git -C "$W_SLOT" symbolic-ref -q HEAD >/dev/null || fail "a detached copy was left on a branch"
  pass "a refused provisioning returns a detached copy to detached"
}

# 3. Tracked work hidden by an index flag, and a late edit inside a submodule, are work.
test_tracked_work_hidden_by_an_index_flag_skips_the_copy() {
  local flag label
  for flag in --assume-unchanged --skip-worktree; do
    label=m3${flag#--}
    make_world "$label"
    advance_origin advanced.txt
    git -C "$W_SLOT" update-index "$flag" README.md
    printf 'private tracked bytes\n' >"$W_SLOT/README.md"
    expect_skip "a tracked edit hidden by $flag skips the copy" dirty_tree
    grep -q 'private tracked bytes' "$W_SLOT/README.md" || fail "the hidden edit is gone"
  done
}

make_submodule_world() { # <name> [nested]: a world whose slot has an initialised submodule `sub` (and, with `nested`, an initialised `sub/deep`); sets W_SUB (its source) and W_INNER
  local name=$1 nested=${2:-} subsha innersha
  W_DIR="$TMP_ROOT/$name"; W_PROJ="$W_DIR/project"; W_SLOT="$W_DIR/slot"; W_SUB="$W_DIR/sub-source"; W_INNER="$W_DIR/inner-source"
  FM_SLOT_LEFT_HEAD='' FM_SLOT_PREPARE_DETACHED=0 FM_SLOT_PREVIOUS_BRANCH='' FM_SLOT_PREVIOUS_HEAD=''
  mkdir -p "$W_DIR"
  git init -q -b main "$W_SUB"; printf 'sub base\n' >"$W_SUB/file"; git -C "$W_SUB" add file
  if [ "$nested" = nested ]; then
    git init -q -b main "$W_INNER"; printf 'inner\n' >"$W_INNER/f"; git -C "$W_INNER" add f; git -C "$W_INNER" "${GITID[@]}" commit -qm inner
    innersha=$(git -C "$W_INNER" rev-parse HEAD)
    git -C "$W_SUB" update-index --add --cacheinfo "160000,$innersha,deep"
  fi
  git -C "$W_SUB" "${GITID[@]}" commit -qm sub
  subsha=$(git -C "$W_SUB" rev-parse HEAD)
  git init -q -b main "$W_PROJ"; printf 'base\n' >"$W_PROJ/README.md"; git -C "$W_PROJ" add README.md
  git -C "$W_PROJ" update-index --add --cacheinfo "160000,$subsha,sub"
  git -C "$W_PROJ" "${GITID[@]}" commit -qm base
  W_BASE=$(git -C "$W_PROJ" rev-parse HEAD)
  git -C "$W_PROJ" worktree add -q --detach "$W_SLOT" "$W_BASE"
  mkdir -p "$W_SLOT/sub"; git init -q -b main "$W_SLOT/sub"
  git -C "$W_SLOT/sub" remote add source "$W_SUB"; git -C "$W_SLOT/sub" fetch -q source main; git -C "$W_SLOT/sub" checkout -q --detach "$subsha"
  if [ "$nested" = nested ]; then
    mkdir -p "$W_SLOT/sub/deep"; git init -q -b main "$W_SLOT/sub/deep"
    git -C "$W_SLOT/sub/deep" remote add source "$W_INNER"; git -C "$W_SLOT/sub/deep" fetch -q source main
    git -C "$W_SLOT/sub/deep" checkout -q --detach "$innersha"
  fi
  printf 'advance\n' >"$W_PROJ/advanced.txt"; git -C "$W_PROJ" add advanced.txt; git -C "$W_PROJ" "${GITID[@]}" commit -qm advance
  W_TARGET=$(git -C "$W_PROJ" rev-parse HEAD)
}

test_a_late_edit_inside_a_submodule_fails_the_move() {
  make_submodule_world m3-submodule
  local bin="$W_DIR/subedit" real_git out rc=0
  real_git=$(command -v git)
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase " $* " in *" merge --ff-only "*) printf "late submodule edit\\n" >%s ;; esac\nexec %s "$@"\n' "'$W_SLOT/sub/file'" "'$real_git'" >"$bin/git"
  chmod +x "$bin/git"
  out=$(PATH="$bin:$PATH" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a late edit inside a submodule was admitted: $out"
  grep -q 'late submodule edit' "$W_SLOT/sub/file" || fail "the late submodule edit is gone"
  pass "a late edit inside a submodule fails the move and is kept"
}

test_a_move_that_changes_a_submodule_pin_is_not_called_dirty() {
  make_submodule_world m3-pin
  local sub2 out rc=0
  printf 'sub two\n' >"$W_SUB/file"; git -C "$W_SUB" "${GITID[@]}" commit -qam sub2
  sub2=$(git -C "$W_SUB" rev-parse HEAD)
  git -C "$W_PROJ" fetch -q 2>/dev/null || true
  git -C "$W_PROJ" update-index --add --cacheinfo "160000,$sub2,sub"
  git -C "$W_PROJ" "${GITID[@]}" commit -qm 'move the pin'
  W_TARGET=$(git -C "$W_PROJ" rev-parse HEAD)
  out=$(fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "a legitimate pin move was refused (rc $rc): $out"
  pass "a move that changes a submodule pin succeeds; the stale checkout is for the next spawn to report"
}

# 6. A ref that changes after the proof and before the merge is a difference outside the expected move.
test_a_ref_that_changes_after_the_proof_fails_the_move() {
  make_world m6-late-ref
  advance_origin advanced.txt
  local bin="$W_DIR/lateref" real_git out rc=0
  real_git=$(command -v git)
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase " $* " in *" merge --ff-only "*) %s -C %s update-ref refs/review/custody %s ;; esac\nexec %s "$@"\n' "'$real_git'" "'$W_SLOT'" "$W_BASE" "'$real_git'" >"$bin/git"
  chmod +x "$bin/git"
  out=$(PATH="$bin:$PATH" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a ref created after the proof was admitted: $out"
  pass "a ref that appears after the proof fails the move"
}

# The HEAD-equals-target rule on its own: a target whose tree equals the slot's, so nothing else differs.
test_a_move_that_ends_elsewhere_than_the_target_fails() {
  make_world m9-head
  git -C "$W_PUB" "${GITID[@]}" commit -q --allow-empty -m 'same tree'
  git -C "$W_PUB" push --quiet origin main
  git -C "$W_PROJ" fetch --quiet origin
  W_TARGET=$(git -C "$W_PROJ" rev-parse origin/main)
  local bin="$W_DIR/headback" real_git out rc=0
  real_git=$(command -v git)
  mkdir -p "$bin"
  # shellcheck disable=SC2016 # The shim's own shell expands $* and $@.
  printf '#!/bin/sh\ncase " $* " in *" merge --ff-only "*) %s "$@"; rc=$?; %s -C %s update-ref --no-deref HEAD %s; exit $rc ;; esac\nexec %s "$@"\n' "'$real_git'" "'$real_git'" "'$W_SLOT'" "$W_BASE" "'$real_git'" >"$bin/git"
  chmod +x "$bin/git"
  out=$(PATH="$bin:$PATH" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a move that left HEAD off the target was accepted: $out"
  pass "a move that leaves HEAD somewhere other than the target fails"
}

# 8. The witnesses.
test_the_changed_bytes_witness_fails_when_a_snapshot_cannot_be_taken() {
  make_world m8-witness
  local bin="$W_DIR/hashfail" out rc=0
  mkdir -p "$bin"
  printf '#!/bin/sh\nexit 1\n' >"$bin/shasum"
  chmod +x "$bin/shasum"
  out=$(PATH="$bin:$PATH" test_changed_bytes_under_equal_status_are_seen_by_the_comparison 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "the changed-bytes witness passed with no snapshot to compare: $out"
  assert_not_contains "$out" "ok - the before/after comparison" "the witness printed its pass line"
  pass "the changed-bytes witness fails when a snapshot cannot be taken"
}

test_the_snapshot_sees_a_symlink_retarget() {
  make_world m8-symlink
  printf 'equal bytes\n' >"$W_SLOT/first.local"; cp "$W_SLOT/first.local" "$W_SLOT/second.local"
  ln -s first.local "$W_SLOT/link.local"
  snapshot "$W_SLOT" "$W_DIR/before" || fail "snapshot failed"
  rm "$W_SLOT/link.local"; ln -s second.local "$W_SLOT/link.local"
  snapshot "$W_SLOT" "$W_DIR/after" || fail "snapshot failed"
  ! cmp -s "$W_DIR/before" "$W_DIR/after" || fail "a symlink retarget to a same-content file compared equal"
  pass "the snapshot sees a symlink that now points at another file"
}

test_the_git_call_oracle_flags_every_forced_form() {
  local row
  : >"$TMP_ROOT/oracle.pos"; : >"$TMP_ROOT/oracle.neg"
  for row in 'checkout -B owner' 'switch -C owner' 'checkout -f main' 'checkout --force main' 'switch --discard-changes main' 'switch -f main' \
    'reset --hard abc' 'reset --merge abc' 'reset --keep abc' 'clean -fd' 'branch -D x' 'branch -f x abc' 'branch -M x y' 'update-ref -d refs/heads/x' \
    'worktree remove w' 'stash' 'restore --worktree f' 'checkout -- f' 'checkout abc -- f'; do
    printf -- '-C /slot %s\n' "$row" >>"$TMP_ROOT/oracle.pos"
  done
  for row in 'checkout --quiet --detach abc' 'merge --ff-only abc' 'symbolic-ref HEAD refs/heads/x' 'rev-parse HEAD' 'status --porcelain' 'branch --show-current' \
    'checkout -b fm/x' 'switch --detach abc' 'for-each-ref' 'merge-base --is-ancestor a b' 'worktree list --porcelain' 'config --bool --get-regexp x'; do
    printf -- '-C /slot %s\n' "$row" >>"$TMP_ROOT/oracle.neg"
  done
  [ "$(forbidden_git_calls "$TMP_ROOT/oracle.pos" | wc -l | tr -d ' ')" = "$(wc -l <"$TMP_ROOT/oracle.pos" | tr -d ' ')" ] \
    || fail "the oracle missed forced forms: $(grep -vxFf <(forbidden_git_calls "$TMP_ROOT/oracle.pos") "$TMP_ROOT/oracle.pos" | tr '\n' ';')"
  [ -z "$(forbidden_git_calls "$TMP_ROOT/oracle.neg")" ] || fail "the oracle flagged safe calls: $(forbidden_git_calls "$TMP_ROOT/oracle.neg" | tr '\n' ';')"
  pass "the git-call oracle flags every forced form and none of the safe calls"
}

# --- Main 1823 (review of eec8922c): D-A a refusal does nothing, D-B every ref exactly, D-E submodule flags -------

# make_attach_world <name>: the slot is detached at S, which dropped notes.local (ignored) that its parent T tracked.
# Sets A_OLD (T) and A_HEAD (S).
make_attach_world() {
  make_world "$1"
  printf 'tracked bytes\n' >"$W_SLOT/notes.local"
  git -C "$W_SLOT" add -f notes.local
  git -C "$W_SLOT" "${GITID[@]}" commit -qm 'track notes.local'
  A_OLD=$(git -C "$W_SLOT" rev-parse HEAD)
  git -C "$W_SLOT" rm -q --cached notes.local
  rm -f "$W_SLOT/notes.local"
  git -C "$W_SLOT" "${GITID[@]}" commit -qm 'untrack notes.local'
  A_HEAD=$(git -C "$W_SLOT" rev-parse HEAD)
}

# attach_with_late_file: a writer drops private bytes at notes.local just before any checkout runs.
# Sets ATTACH_RC and ATTACH_OUT.
attach_with_late_file() {
  local bin="$W_DIR/late-attach" real_git
  real_git=$(command -v git)
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase " $* " in *" checkout "*) printf "private late work\\n" >%s ;; esac\nexec %s "$@"\n' "'$W_SLOT/notes.local'" "'$real_git'" >"$bin/git"
  chmod +x "$bin/git"
  ATTACH_RC=0
  ATTACH_OUT=$(FM_SLOT_LEFT_HEAD=$A_HEAD PATH="$bin:$PATH" fm_slot_attach "$W_SLOT" '' "$A_OLD" 2>&1) || ATTACH_RC=$?
}

test_attach_never_rewrites_a_late_ignored_file() {
  make_attach_world a1-bytes
  attach_with_late_file
  [ ! -e "$W_SLOT/notes.local" ] || grep -q 'private late work' "$W_SLOT/notes.local" || fail "a checkout replaced the late private bytes: $ATTACH_OUT"
  pass "a switch back never rewrites a file a writer created after the proof"
}

test_attach_leaves_head_where_it_was() {
  make_attach_world a1-head
  attach_with_late_file
  [ "$(git -C "$W_SLOT" rev-parse HEAD)" = "$A_HEAD" ] || fail "a switch back moved HEAD off the commit it found: $ATTACH_OUT"
  pass "a switch back leaves HEAD on the commit it found"
}

test_attach_reports_failure_instead_of_switching() {
  make_attach_world a1-rc
  attach_with_late_file
  [ "$ATTACH_RC" != 0 ] || fail "a switch back from a commit that is not the target reported success"
  pass "a switch back from a commit that is not the target fails"
}

# F5: another actor moved the symbolic HEAD (same commit) between the provision step and the refusal.
switch_runner() { git -C "$W_SLOT" branch other-owner; git -C "$W_SLOT" symbolic-ref HEAD refs/heads/other-owner; printf '{}\n' >"$2"; return 3; }

test_a_promotion_refusal_leaves_a_moved_symbolic_head_as_found() {
  make_branch_slot a2-symref
  fm_slot_provision switch_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts >/dev/null 2>&1 || true
  [ "$(git -C "$W_SLOT" symbolic-ref -q HEAD)" = refs/heads/other-owner ] || fail "a refusal changed the symbolic HEAD another actor had set"
  pass "a refusal leaves a symbolic HEAD another actor set as it found it"
}

test_a_promotion_refusal_returns_the_provisioners_code() {
  make_branch_slot a2-rc
  local rc=0
  fm_slot_provision switch_runner "$W_PROJ" "$W_SLOT" tid fm/tid "$W_DIR/report.json" '' '' scripts >/dev/null 2>&1 || rc=$?
  [ "$rc" = 3 ] || fail "the refusal returned $rc, not the provisioner's 3"
  pass "a refusal returns the provisioner's code"
}

# D-B: every ref is compared exactly. The old allow list is set the way the spawn used to set it; it must not matter.
OLD_ALLOW='refs/remotes/origin/HEAD refs/remotes/origin/main refs/fm/anchor/tid-*'

test_a_rewound_origin_tracking_ref_fails_the_move() {
  make_world b1-rewind
  advance_origin advanced.txt
  local bin="$W_DIR/rewind" real_git out rc=0
  real_git=$(command -v git)
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase " $* " in *" merge --ff-only "*) %s -C %s update-ref refs/remotes/origin/main %s ;; esac\nexec %s "$@"\n' "'$real_git'" "'$W_SLOT'" "$W_BASE" "'$real_git'" >"$bin/git"
  chmod +x "$bin/git"
  out=$(FM_SLOT_REF_ALLOW=$OLD_ALLOW PATH="$bin:$PATH" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "a rewind of origin's tracking ref was admitted: $out"
  pass "a rewind of an origin tracking ref fails the move"
}

test_the_failure_for_a_changed_ref_names_the_ref() {
  make_world b1-names
  advance_origin advanced.txt
  local bin="$W_DIR/names" real_git out rc=0
  real_git=$(command -v git)
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase " $* " in *" merge --ff-only "*) %s -C %s update-ref refs/remotes/origin/main %s ;; esac\nexec %s "$@"\n' "'$real_git'" "'$W_SLOT'" "$W_BASE" "'$real_git'" >"$bin/git"
  chmod +x "$bin/git"
  out=$(FM_SLOT_REF_ALLOW=$OLD_ALLOW PATH="$bin:$PATH" fm_slot_move_forward "$W_SLOT" "$W_TARGET" "$W_PROJ" 2>&1) || rc=$?
  assert_contains "$out" "refs/remotes/origin/main" "the failure did not say which ref changed"
  pass "the failure names the ref that changed"
}

test_an_origin_ref_advanced_before_a_refused_move_is_not_called_untouched() {
  make_world b2-skipref
  advance_origin advanced.txt
  git -C "$W_PROJ" update-ref refs/remotes/origin/main "$W_BASE"
  local bin="$W_DIR/refuse-ref" real_git out rc=0
  real_git=$(command -v git)
  fm_slot_prove_idle "$W_SLOT" "$W_TARGET" "$W_PROJ" || fail "the proof did not pass"
  git -C "$W_SLOT" update-ref refs/remotes/origin/main "$W_TARGET"
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase " $* " in *" merge --ff-only "*) exit 1 ;; esac\nexec %s "$@"\n' "'$real_git'" >"$bin/git"
  chmod +x "$bin/git"
  out=$(FM_SLOT_REF_ALLOW=$OLD_ALLOW PATH="$bin:$PATH" fm_slot_apply_move "$W_SLOT" "$W_TARGET" 2>&1) || rc=$?
  [ "$rc" = 1 ] || fail "a refused move after a ref changed was not reported as a failure (rc $rc): $out"
  pass "a refused move after an origin ref changed is a failure, not a skip"
}

test_an_origin_ref_advanced_before_a_refused_move_does_not_say_untouched() {
  make_world b2-says
  advance_origin advanced.txt
  git -C "$W_PROJ" update-ref refs/remotes/origin/main "$W_BASE"
  local bin="$W_DIR/refuse-says" real_git out rc=0
  real_git=$(command -v git)
  fm_slot_prove_idle "$W_SLOT" "$W_TARGET" "$W_PROJ" || fail "the proof did not pass"
  git -C "$W_SLOT" update-ref refs/remotes/origin/main "$W_TARGET"
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase " $* " in *" merge --ff-only "*) exit 1 ;; esac\nexec %s "$@"\n' "'$real_git'" >"$bin/git"
  chmod +x "$bin/git"
  out=$(FM_SLOT_REF_ALLOW=$OLD_ALLOW PATH="$bin:$PATH" fm_slot_apply_move "$W_SLOT" "$W_TARGET" 2>&1) || rc=$?
  assert_not_contains "$out" "left untouched" "a copy whose refs changed was called untouched"
  pass "a copy whose refs changed is never called untouched"
}

# The one ref change a move admits is the exact anchor its own preparation wrote (absent -> the commit it found).
anchor_world() { # <name>: a governed detached copy, proven and prepared; sets W_TARGET
  make_world "$1" 1
  advance_origin advanced.txt
  fm_slot_prove_idle "$W_SLOT" "$W_TARGET" "$W_PROJ" || fail "the proof did not pass"
  fm_slot_prepare_base "$W_PROJ" "$W_SLOT" tid || fail "the preparation failed"
}

test_the_anchor_the_preparation_wrote_is_admitted() {
  anchor_world b3-anchor-ok
  local out rc=0
  out=$(FM_SLOT_REF_ALLOW='refs/fm/anchor/tid-*' fm_slot_apply_move "$W_SLOT" "$W_TARGET" 2>&1) || rc=$?
  [ "$rc" = 0 ] || fail "the move failed on the anchor its own preparation wrote (rc $rc): $out"
  pass "a move admits the anchor its own preparation wrote"
}

test_an_anchor_the_preparation_did_not_write_fails_the_move() {
  anchor_world b3-anchor-extra
  local bin="$W_DIR/anchor-extra" real_git out rc=0
  real_git=$(command -v git)
  mkdir -p "$bin"
  printf '#!/bin/sh\ncase " $* " in *" merge --ff-only "*) %s -C %s update-ref refs/fm/anchor/tid-0000000 %s ;; esac\nexec %s "$@"\n' "'$real_git'" "'$W_SLOT'" "$W_BASE" "'$real_git'" >"$bin/git"
  chmod +x "$bin/git"
  out=$(FM_SLOT_REF_ALLOW='refs/fm/anchor/tid-*' PATH="$bin:$PATH" fm_slot_apply_move "$W_SLOT" "$W_TARGET" 2>&1) || rc=$?
  [ "$rc" != 0 ] || fail "an anchor ref other than the one the preparation wrote was admitted: $out"
  pass "an anchor ref the preparation did not write fails the move"
}

# D-E: any initialized submodule with an index flag (assume-unchanged, skip-worktree) is doubt, whatever its files hold.
test_an_assume_unchanged_flag_inside_a_submodule_skips_the_copy() {
  make_submodule_world e1-assume
  git -C "$W_SLOT/sub" update-index --assume-unchanged file
  expect_skip "an assume-unchanged flag inside a submodule skips the copy" dirty_tree
}

test_a_skip_worktree_flag_inside_a_submodule_skips_the_copy() {
  make_submodule_world e1-skipwt
  git -C "$W_SLOT/sub" update-index --skip-worktree file
  expect_skip "a skip-worktree flag inside a submodule skips the copy" dirty_tree
}

test_an_index_flag_on_the_submodule_entry_of_the_parent_skips_the_copy() {
  make_submodule_world e1-gitlink
  git -C "$W_SLOT" update-index --assume-unchanged sub
  expect_skip "an index flag on a submodule entry skips the copy" dirty_tree
}

test_an_index_flag_inside_a_nested_submodule_skips_the_copy() {
  make_submodule_world e1-nested nested
  git -C "$W_SLOT/sub/deep" update-index --assume-unchanged f
  expect_skip "an index flag inside a nested submodule skips the copy" dirty_tree
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
  test_a_switch_back_over_ignored_work_is_refused_and_leaves_the_slot_as_found
  test_process_in_the_slot_that_predates_the_spawn_skips_the_copy
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
  test_a_quiet_promotion_refusal_orphans_no_commit
  test_restore_does_not_orphan_a_commit_made_after_preparation
  test_a_checkout_hook_cannot_change_a_slot_during_preparation
  test_a_merge_hook_does_not_run_during_the_move
  test_a_holder_is_seen_when_the_slot_is_already_at_the_target
  test_a_younger_unrelated_process_in_the_slot_is_a_holder
  test_the_panes_own_launcher_tree_is_not_a_holder
  test_a_process_under_the_pane_but_not_under_the_launcher_is_a_holder
  test_a_process_under_the_pane_that_predates_the_spawn_is_a_holder
  test_a_lsof_row_without_a_working_directory_for_the_pane_is_a_holder
  test_an_lsof_row_with_no_directory_for_a_launcher_child_is_a_holder
  test_a_launcher_that_does_not_run_under_the_named_pane_is_a_holder
  test_a_holder_row_without_a_working_directory_is_a_holder
  test_a_malformed_contention_row_counts_as_held
  test_a_treehouse_launcher_started_after_the_spawn_owns_its_shell
  test_a_treehouse_launcher_older_than_the_spawn_does_not_own_its_shell
  test_a_commit_that_appears_after_the_proof_is_never_merged_over
  test_a_tracked_edit_made_after_the_clean_look_fails_the_move
  test_a_failed_head_read_after_the_move_is_not_reported_as_untouched
  test_the_snapshot_fails_when_git_cannot_be_read
  test_no_destroying_git_command_runs_on_any_move_path
  test_a_promotion_refusal_after_a_late_commit_keeps_the_commit
  test_a_promotion_refusal_after_a_late_commit_leaves_head_on_it
  test_a_refusal_revert_with_no_recorded_left_commit_keeps_a_detached_commit
  test_a_refusal_revert_leaves_head_alone_when_the_branch_moved
  test_a_promotion_refusal_ignores_a_stale_left_commit
  test_a_refused_move_after_preparation_puts_the_branch_back
  test_a_refused_move_after_preparation_says_the_copy_stays_detached
  test_a_refused_move_after_preparation_never_calls_a_changed_copy_untouched
  test_a_refused_move_after_preparation_leaves_a_detached_copy_where_it_is_when_the_undo_fails
  test_a_refusal_undo_runs_no_checkout
  test_a_refusal_returns_a_detached_copy_to_detached
  test_a_commit_on_the_task_branch_with_an_equal_tree_is_undone_by_ref
  test_a_commit_on_the_task_branch_with_an_equal_tree_keeps_the_task_branch
  test_a_commit_on_the_task_branch_that_changes_a_file_is_not_undone_and_is_reported
  test_a_refusal_undo_never_returns_to_a_commit_with_other_files
  test_tracked_work_hidden_by_an_index_flag_skips_the_copy
  test_a_late_edit_inside_a_submodule_fails_the_move
  test_a_move_that_changes_a_submodule_pin_is_not_called_dirty
  test_attach_never_rewrites_a_late_ignored_file
  test_attach_leaves_head_where_it_was
  test_attach_reports_failure_instead_of_switching
  test_a_promotion_refusal_leaves_a_moved_symbolic_head_as_found
  test_a_promotion_refusal_returns_the_provisioners_code
  test_a_rewound_origin_tracking_ref_fails_the_move
  test_the_failure_for_a_changed_ref_names_the_ref
  test_an_origin_ref_advanced_before_a_refused_move_is_not_called_untouched
  test_an_origin_ref_advanced_before_a_refused_move_does_not_say_untouched
  test_the_anchor_the_preparation_wrote_is_admitted
  test_an_anchor_the_preparation_did_not_write_fails_the_move
  test_an_assume_unchanged_flag_inside_a_submodule_skips_the_copy
  test_a_skip_worktree_flag_inside_a_submodule_skips_the_copy
  test_an_index_flag_on_the_submodule_entry_of_the_parent_skips_the_copy
  test_an_index_flag_inside_a_nested_submodule_skips_the_copy
  test_a_ref_that_changes_after_the_proof_fails_the_move
  test_a_move_that_ends_elsewhere_than_the_target_fails
  test_the_changed_bytes_witness_fails_when_a_snapshot_cannot_be_taken
  test_the_snapshot_sees_a_symlink_retarget
  test_the_git_call_oracle_flags_every_forced_form
)

fm_test_run_cases "${CASES[@]}" -- "$@"
echo "# all fm-spawn-slot-move tests passed"
