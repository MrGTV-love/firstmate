#!/usr/bin/env bash
# fm-spawn.sh's pre-allocation gate for Treehouse pool slots a task left or
# still works inside (bin/fm-task-copy-lib.sh
# fm_task_copy_pool_slots_hold_no_current_copy):
#   1. A slot that contains a live task record's current copy (the nested
#      replacement-copy case) refuses allocation before treehouse get, and
#      changes nothing; once that record is retired the gate lets it through.
#   2. A slot a reassociated task left behind does not block allocation: a new
#      spawn acquires and claims it, whatever its commits.
#   3. A registered local Firstmate home that cannot be read is named in one
#      warning line and skipped: the spawn still proceeds.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-retained-copy)
fm_git_identity fmtest fmtest@example.invalid

make_retained_case() {
  local name=$1
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  SLOT_DIR="$CASE_DIR/pool/1/project"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "new-$name"
  mkdir -p "$HOME_DIR/user-home"
  fm_git_worktree "$PROJECT_DIR" "$SLOT_DIR" "retained-$name"
  printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":99999999,"owner_started_at":1}]}\n' "$SLOT_DIR" > "$CASE_DIR/pool/treehouse-state.json"
  : > "$CASE_DIR/pane-log"
  : > "$CASE_DIR/launch-log"
}

retained_fingerprint() {
  git -C "$SLOT_DIR" rev-parse HEAD
  git -C "$SLOT_DIR" symbolic-ref --quiet HEAD || true
  git -C "$SLOT_DIR" reflog
  git -C "$SLOT_DIR" status --porcelain --untracked-files=all
  (cd "$SLOT_DIR" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s ' "$file"
    cksum < "$file"
  done)
}

run_retained_spawn() {
  FM_FAKE_PANE_LOG="$CASE_DIR/pane-log" FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch-log" \
    fm_test_run_spawn "$HOME_DIR" "$SLOT_DIR" "$FAKEBIN_DIR" \
    "new-$1" "$PROJECT_DIR" --scout
}

assert_retained_refusal() {
  local name=$1 reason=$2 out rc=0
  retained_fingerprint > "$CASE_DIR/before-copy"
  out=$(run_retained_spawn "$name") || rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted an unsafe pool slot: $out"
  assert_contains "$out" "$reason" "allocation refusal lost its reason"
  assert_contains "$out" "before treehouse get" "allocation did not refuse at the pre-acquisition boundary"
  ! grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "refused allocation sent treehouse get"
  ! grep -Eq 'reset|treehouse return' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "refused allocation sent a destructive command"
  retained_fingerprint | cmp -s - "$CASE_DIR/before-copy" || fail "refused allocation changed the slot"
  [ ! -e "$CASE_DIR/pool/1/.fm-slot-owner" ] || fail "refused allocation claimed the slot"
  [ ! -e "$HOME_DIR/state/new-$name.meta" ] || fail "refused allocation published metadata"
}

assert_retained_spawn() {
  local name=$1 msg=$2 out rc=0
  out=$(run_retained_spawn "$name") || rc=$?
  expect_code 0 "$rc" "$msg"$'\n'"$out"
  assert_contains "$out" "spawned new-$name" "$msg: spawn did not launch"
  grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" || fail "$msg: spawn never acquired a slot"
  assert_grep "task=new-$name" "$CASE_DIR/pool/1/.fm-slot-owner" "$msg: spawn did not claim the slot"
  assert_grep "worktree=$SLOT_DIR" "$HOME_DIR/state/new-$name.meta" "$msg: spawn did not publish the slot"
}

test_slot_holding_live_nested_current_copy_refuses() {
  local spelling name nested out
  for spelling in direct alias; do
    name="nested-live-$spelling"
    make_retained_case "$name"
    nested="$SLOT_DIR/.claude/worktrees/replacement"
    mkdir -p "$SLOT_DIR/.claude/worktrees"
    git -C "$PROJECT_DIR" worktree add --quiet -b "nested-$name" "$nested"
    printf 'nested unlanded commit\n' > "$nested/nested-owned.txt"
    git -C "$nested" add nested-owned.txt
    git -C "$nested" commit -qm nested-unlanded
    if [ "$spelling" = alias ]; then
      ln -s "$nested" "$CASE_DIR/nested-alias"
      nested="$CASE_DIR/nested-alias"
    fi
    fm_write_meta "$HOME_DIR/state/holder.meta" "window=fmses:fm-holder" \
      "worktree=$nested" "prior_worktree=$SLOT_DIR" "project=$PROJECT_DIR" "kind=ship"
    cp "$HOME_DIR/state/holder.meta" "$CASE_DIR/before-meta"
    assert_retained_refusal "$name" "contains task holder's current copy"
    cmp -s "$CASE_DIR/before-meta" "$HOME_DIR/state/holder.meta" || fail "refusal changed the holder's record"
    assert_grep 'nested unlanded commit' "$nested/nested-owned.txt" "refusal lost the nested work"
    rm "$HOME_DIR/state/holder.meta"
    : > "$CASE_DIR/pane-log"
    : > "$CASE_DIR/launch-log"
    out=$(run_retained_spawn "$name") || true
    assert_not_contains "$out" "contains task holder's current copy" "a retired record still blocked allocation"
    grep -Fq 'treehouse get' "$CASE_DIR/pane-log" "$CASE_DIR/launch-log" \
      || fail "a slot whose nested copy no record names did not reach treehouse get: $out"
  done
  pass "a pool slot holding a live record's nested current copy refuses allocation until that record is retired"
}

test_slot_left_by_reassociated_task_is_allocatable() {
  local name=left-behind
  make_retained_case "$name"
  printf 'anchored unlanded commit\n' > "$SLOT_DIR/owned.txt"
  git -C "$SLOT_DIR" add owned.txt
  git -C "$SLOT_DIR" commit -qm unlanded
  git -C "$PROJECT_DIR" update-ref "refs/fm/anchor/mover-$(git -C "$SLOT_DIR" rev-parse --short HEAD)" \
    "$(git -C "$SLOT_DIR" rev-parse HEAD)"
  git -C "$PROJECT_DIR" worktree add --quiet -b mover-v2 "$CASE_DIR/replacement"
  fm_write_meta "$HOME_DIR/state/mover.meta" "window=fmses:fm-mover" \
    "worktree=$CASE_DIR/replacement" "released_worktree=$SLOT_DIR" "project=$PROJECT_DIR" "kind=ship"
  assert_retained_spawn "$name" "a slot a reassociated task left must not block allocation"
  pass "a pool slot a reassociated task left is acquired and claimed by a new task"
}

test_unreadable_local_home_warns_and_proceeds() {
  local name=unreadable-home out warnings
  make_retained_case "$name"
  printf -- '- ghost - ghost (home: %s; scope: fixture; projects: P; added 2026-10-08)\n' \
    "$CASE_DIR/missing-home" > "$HOME_DIR/data/secondmates.md"
  out=$(run_retained_spawn "$name") || fail "an unavailable registered local home stopped the spawn: $out"
  warnings=$(printf '%s\n' "$out" | grep -c "^warning: registered local Firstmate home is unavailable: $CASE_DIR/missing-home" || true)
  [ "$warnings" = 1 ] || fail "expected one warning line naming the unavailable home, got $warnings: $out"
  assert_contains "$out" "spawned new-$name" "the spawn did not launch past the unavailable home"
  assert_grep "task=new-$name" "$CASE_DIR/pool/1/.fm-slot-owner" "the spawn did not claim the slot"
  assert_grep "worktree=$SLOT_DIR" "$HOME_DIR/state/new-$name.meta" "the spawn did not publish the slot"
  pass "an unavailable registered local home is named in one warning and the spawn proceeds"
}

test_slot_holding_live_nested_current_copy_refuses
test_slot_left_by_reassociated_task_is_allocatable
test_unreadable_local_home_warns_and_proceeds
