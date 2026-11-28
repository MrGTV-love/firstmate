#!/usr/bin/env bash
# Pool slots, leases, custody, and returns for bin/fm-teardown.sh's destructive
# Treehouse return: reservation before cleanup, proved landing after a wait,
# return-pending records across a refusal, reassigned and enclosing slots,
# reassociated and prior copies, nested slots, and subordinate cleanup custody.
# The landed-work proof matrix and refusal diagnostics live in
# tests/fm-teardown.test.sh; post-close cleanup lives in
# tests/fm-teardown-cleanup.test.sh. Shared fixtures: tests/fm-teardown-helpers.sh.
# Usage: bash tests/fm-teardown-pool.test.sh [test_function_name ...]

set -u

# shellcheck source=tests/fm-teardown-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-helpers.sh"

test_tasktmp_preserves_current_and_prior_reassociated_copies() {
  local case_dir tmp nested current shape force rc
  for shape in current prior; do
    case_dir=$(make_case "tasktmp-custody-$shape")
    mkdir -p "$case_dir/home/state" "$case_dir/tasktmp"
    tmp=$case_dir/tasktmp
    nested=$tmp/B
    git -C "$case_dir/project" worktree move "$case_dir/wt" "$nested"
    printf 'unlanded B bytes\n' > "$nested/scratch.txt"
    current=$nested
    if [ "$shape" = prior ]; then
      current=$case_dir/C
      git -C "$case_dir/project" worktree add -q -b fm/current-C "$current" main
    fi
    git -C "$case_dir/project" worktree add -q -b fm/prior-A "$case_dir/A" main
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$current" "project=$case_dir/project" "kind=ship" \
      "mode=no-mistakes" "spawn_gen=teardown-test-task-x1" \
      "tasktmp=$tmp" "prior_worktree=$case_dir/A"
    [ "$shape" != prior ] || printf 'prior_worktree=%s\n' "$nested" >> "$case_dir/state/task-x1.meta"
    cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
    cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in kill-*) printf '%s\n' "\$*" >> "$case_dir/kill.log" ;; esac
exit 0
SH
    cat > "$case_dir/fakebin/lsof" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/reap.log"
exit 1
SH
    chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/lsof"
    for force in normal force; do
      rc=0
      if [ "$force" = force ]; then
        FM_HOME="$case_dir/home" run_teardown "$case_dir" --force --drop-file "$FM_TEST_DROP_WORDS" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      else
        FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      fi
      expect_code 1 "$rc" "tasktmp-$shape-$force: overlapping cleanup must refuse"
      assert_grep "cleanup target $tmp" "$case_dir/stderr" "tasktmp refusal missed the destructive root"
      cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" || fail "tasktmp refusal changed custody"
      assert_grep "unlanded B bytes" "$nested/scratch.txt" "tasktmp cleanup destroyed B"
      assert_absent "$case_dir/kill.log" "tasktmp refusal closed an endpoint"
      assert_absent "$case_dir/reap.log" "tasktmp refusal reached process reaping"
    done
  done
  pass "tasktmp admission preserves both the current nested replacement and a nested prior copy before signalling"
}

test_tasktmp_checks_all_other_copy_fields_in_both_directions() {
  local case_dir field direction target recorded rc
  for field in worktree home prior_worktree; do
    for direction in ancestor descendant; do
      case_dir=$(make_case "tasktmp-other-$field-$direction")
      mkdir -p "$case_dir/home/state" "$case_dir/tasktmp/nested"
      write_meta "$case_dir" no-mistakes ship
      target=$case_dir/tasktmp
      if [ "$direction" = ancestor ]; then
        target=$case_dir/tasktmp/nested
        recorded=$case_dir/tasktmp
      else
        recorded=$case_dir/tasktmp/nested
      fi
      printf 'tasktmp=%s\n' "$target" >> "$case_dir/state/task-x1.meta"
      fm_write_meta "$case_dir/home/state/other.meta" "$field=$recorded" "kind=ship"
      printf 'other custody bytes\n' > "$recorded/owned.txt"
      rc=0
      FM_HOME="$case_dir/home" run_teardown "$case_dir" --force --drop-file "$FM_TEST_DROP_WORDS" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 1 "$rc" "tasktmp-$field-$direction: foreign custody must refuse"
      assert_grep "task other's recorded $field" "$case_dir/stderr" "foreign tasktmp refusal omitted custody"
      assert_grep "other custody bytes" "$recorded/owned.txt" "foreign tasktmp custody was removed"
      assert_present "$case_dir/state/task-x1.meta" "foreign tasktmp refusal retired the record"
    done
  done
  pass "tasktmp admission counts all cross-home copy fields in both containment directions"
}

test_secondmate_home_preserves_other_tasks_prior_copy() {
  local case_dir home location field force rc
  for location in local peer; do
    for field in worktree home prior_worktree; do
      case_dir=$(make_case "home-other-$location-$field")
      mkdir -p "$case_dir/home/state" "$case_dir/home/data"
      write_meta "$case_dir" local-only secondmate
      home=$case_dir/secondmate-home
      mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
      printf 'task-x1\n' > "$home/.fm-secondmate-home"
      printf 'preserved P bytes\n' > "$home/scratch.txt"
      printf 'home=%s\n' "$home" >> "$case_dir/state/task-x1.meta"
      if [ "$location" = local ]; then
        fm_write_meta "$case_dir/home/state/original.meta" "$field=$home" "kind=ship"
      else
        mkdir -p "$case_dir/peer/state"
        printf '# Secondmates\n- peer - peer charter (home: %s; scope: peer; projects: none; added 2026-10-08)\n' "$case_dir/peer" > "$case_dir/home/data/secondmates.md"
        fm_write_meta "$case_dir/peer/state/original.meta" "$field=$home" "kind=ship"
      fi
      cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
      cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in kill-*) printf '%s\n' "\$*" >> "$case_dir/kill.log" ;; esac
exit 0
SH
      chmod +x "$case_dir/fakebin/tmux"
      for force in normal force; do
        rc=0
        if [ "$force" = force ]; then
          FM_HOME="$case_dir/home" run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        else
          FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        fi
        expect_code 1 "$rc" "secondmate-$location-$field-$force: overlapping custody must refuse"
        assert_grep "task original's recorded $field" "$case_dir/stderr" \
          "secondmate-$location-$field-$force: refusal missed original custody: $(cat "$case_dir/stderr")"
        cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" || fail "secondmate refusal changed its record"
        assert_grep "preserved P bytes" "$home/scratch.txt" "secondmate retirement deleted preserved P"
        assert_absent "$case_dir/kill.log" "secondmate refusal closed an endpoint"
      done
    done
  done
  pass "secondmate retirement preserves original copy custody in this home and registered peer homes"
}

# A stale task's positively reassigned slot belongs to the claimant. Its dirt,
# unlanded commits and live process cannot block records-only retirement.
test_reassigned_dirty_slot_retires_only_finished_task() {
  local case_dir slot delivered head worker rc=0
  case_dir=$(make_case reassigned-dirty-finished)
  wt_commit_file "$case_dir" delivered.txt 'merged task work' 'delivered task'
  delivered=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin HEAD:main
  add_gh_pr_merged_for_head "$case_dir" "$delivered" "$delivered"
  git -C "$case_dir/project" branch archive/task-x1-pipeline-0b0b0b06 "$delivered"
  mkdir -p "$case_dir/pool/1" "$case_dir/primary-home/state"
  slot="$case_dir/pool/1/project"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$slot"
  git -C "$slot" checkout -q -b fm/live-task
  printf 'claimant committed work\n' > "$slot/live.txt"
  git -C "$slot" add live.txt
  git -C "$slot" commit -qm 'unlanded claimant work'
  printf 'claimant tracked edit\n' >> "$slot/live.txt"
  printf 'claimant untracked work\n' > "$slot/scratch.txt"
  mkdir -p "$slot/.claude"
  printf 'claimant hook bytes\n' > "$slot/.claude/settings.local.json"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$slot" \
    > "$case_dir/pool/treehouse-state.json"
  printf 'task=live-task\nhome=%s\n' "$case_dir/primary-home" > "$case_dir/pool/1/.fm-slot-owner"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$slot" "project=$case_dir/project" "kind=ship" \
    "mode=no-mistakes" "branch=fm/task-x1" "spawn_gen=finished" \
    "pr=https://github.com/example/repo/pull/7" "pr_head=$delivered"
  fm_write_meta "$case_dir/state/live-task.meta" \
    "window=firstmate:fm-live-task" "endpoint_task_id=live-task" \
    "worktree=$slot" "project=$case_dir/project" "kind=ship" "spawn_gen=live"
  printf 'finished task\n' > "$case_dir/state/task-x1.status"
  printf 'live task\n' > "$case_dir/state/live-task.status"
  cp "$case_dir/state/live-task.meta" "$case_dir/live-meta.before"
  cp "$case_dir/state/live-task.status" "$case_dir/live-status.before"
  cp "$case_dir/pool/1/.fm-slot-owner" "$case_dir/claim.before"
  cp "$case_dir/pool/treehouse-state.json" "$case_dir/lease.before"
  git -C "$slot" status --porcelain --untracked-files=all > "$case_dir/copy-status.before"
  git -C "$slot" symbolic-ref HEAD > "$case_dir/branch.before"
  git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' > "$case_dir/refs.before"
  head=$(git -C "$slot" rev-parse HEAD)
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/endpoint.log"
exit 0
SH
  teardown_fixture_start "$slot" KILL sleep 300
  worker=$TEARDOWN_FIXTURE_PID
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "a finished task must retire without judging the reassigned claimant copy"$'\n'"$(cat "$case_dir/stderr")"
  kill -0 "$worker" 2>/dev/null || fail 'records-only cleanup killed the claimant process'
  teardown_fixture_stop "$worker"
  assert_absent "$case_dir/state/task-x1.meta" 'finished metadata survived'
  assert_absent "$case_dir/state/task-x1.status" 'finished status survived'
  assert_grep 'kill-window -t =firstmate:=fm-task-x1' "$case_dir/endpoint.log" 'finished endpoint was not closed'
  assert_no_grep 'kill-window -t =firstmate:=fm-live-task' "$case_dir/endpoint.log" 'claimant endpoint was closed'
  assert_absent "$case_dir/treehouse.log" 'records-only cleanup administered the pool'
  cmp -s "$case_dir/live-meta.before" "$case_dir/state/live-task.meta" || fail 'claimant metadata changed'
  cmp -s "$case_dir/live-status.before" "$case_dir/state/live-task.status" || fail 'claimant status changed'
  cmp -s "$case_dir/claim.before" "$case_dir/pool/1/.fm-slot-owner" || fail 'claimant slot claim changed'
  cmp -s "$case_dir/lease.before" "$case_dir/pool/treehouse-state.json" || fail 'claimant pool lease changed'
  [ "$head" = "$(git -C "$slot" rev-parse HEAD)" ] || fail 'claimant HEAD changed'
  git -C "$slot" symbolic-ref HEAD | cmp -s - "$case_dir/branch.before" || fail 'claimant branch changed'
  git -C "$slot" status --porcelain --untracked-files=all | cmp -s - "$case_dir/copy-status.before" || fail 'claimant copy status changed'
  git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' | cmp -s - "$case_dir/refs.before" || fail 'claimant refs changed'
  assert_grep 'claimant tracked edit' "$slot/live.txt" 'claimant tracked work changed'
  assert_grep 'claimant untracked work' "$slot/scratch.txt" 'claimant untracked work changed'
  assert_grep 'claimant hook bytes' "$slot/.claude/settings.local.json" 'claimant hook changed'
  pass 'a finished task on a dirty reassigned slot retires only its own records and endpoint, preserving claimant work and processes'
}

# Reassignment releases the claimant's copy from judgement, not the stale
# task's own delivery: with no merged PR and an unlanded own branch it refuses.
test_reassigned_slot_unlanded_task_refuses() {
  local case_dir slot head rc=0
  case_dir=$(make_case reassigned-unlanded-task)
  wt_commit_file "$case_dir" undelivered.txt 'unlanded task work' 'undelivered task'
  mkdir -p "$case_dir/pool/1" "$case_dir/primary-home/state"
  slot="$case_dir/pool/1/project"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$slot"
  git -C "$slot" checkout -q -b fm/live-task main
  printf 'claimant untracked work\n' > "$slot/scratch.txt"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$slot" \
    > "$case_dir/pool/treehouse-state.json"
  printf 'task=live-task\nhome=%s\n' "$case_dir/primary-home" > "$case_dir/pool/1/.fm-slot-owner"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$slot" "project=$case_dir/project" "kind=ship" \
    "mode=no-mistakes" "branch=fm/task-x1" "spawn_gen=unfinished"
  fm_write_meta "$case_dir/state/live-task.meta" \
    "window=firstmate:fm-live-task" "endpoint_task_id=live-task" \
    "worktree=$slot" "project=$case_dir/project" "kind=ship" "spawn_gen=live"
  printf 'unfinished task\n' > "$case_dir/state/task-x1.status"
  cp "$case_dir/state/task-x1.meta" "$case_dir/task-meta.before"
  cp "$case_dir/pool/1/.fm-slot-owner" "$case_dir/claim.before"
  git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' > "$case_dir/refs.before"
  head=$(git -C "$slot" rev-parse HEAD)
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/endpoint.log"
exit 0
SH
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "an unlanded task must not retire just because its slot was reassigned"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "REFUSED: task task-x1's recorded copy $slot was reassigned to task live-task" "$case_dir/stderr" 'refusal did not name the reassigned slot'
  assert_grep 'its own branch fm/task-x1 is not proved landed' "$case_dir/stderr" 'refusal lost its delivery proof boundary'
  cmp -s "$case_dir/task-meta.before" "$case_dir/state/task-x1.meta" || fail 'unlanded task metadata changed'
  [ -f "$case_dir/state/task-x1.status" ] || fail 'unlanded task status was removed'
  assert_absent "$case_dir/endpoint.log" 'refused teardown touched an endpoint'
  assert_absent "$case_dir/treehouse.log" 'refused teardown administered the pool'
  cmp -s "$case_dir/claim.before" "$case_dir/pool/1/.fm-slot-owner" || fail 'claimant slot claim changed'
  [ "$head" = "$(git -C "$slot" rev-parse HEAD)" ] || fail 'claimant HEAD changed'
  git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' | cmp -s - "$case_dir/refs.before" || fail 'refs changed'
  assert_grep 'claimant untracked work' "$slot/scratch.txt" 'claimant untracked work changed'
  pass 'a task on a reassigned slot with no merged PR and an unlanded own branch refuses and keeps its records'
}

# A fresh spawn that allocates the lapsed slot between the early ownership
# proof and the reservation re-check claims the slot for itself. The retiring
# task then completes records-only: the reaper finishes it with no refusal
# memo, and the new owner's claim, lease, record and copy bytes survive.
test_reservation_window_reassignment_retires_records_only() {
  local case_dir slot rc=0 alloc_rc=0
  make_lease_modeling_pool_case pool-window-reassigned-root ''
  case_dir=$POOL_CASE
  slot=$POOL_SLOT
  fm_write_meta "$case_dir/live-task.meta.new" \
    "window=firstmate:fm-live-task" "endpoint_task_id=live-task" \
    "worktree=$slot" "project=$case_dir/project" "kind=ship" "spawn_gen=live"
  printf 'live task\n' > "$case_dir/live-task.status.new"
  printf 'spawn_gen=%s\nslot=%s\n' 'teardown-test-task-x1' "$slot" \
    > "$case_dir/state/task-x1.teardown-return-pending"
  printf 'g1.1.1\n' > "$case_dir/state/task-x1.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$(date +%s)" \
    > "$case_dir/state/task-x1.busy-state"
  git -C "$slot" rev-parse HEAD > "$case_dir/head.before"
  git -C "$slot" symbolic-ref HEAD > "$case_dir/branch.before"
  git -C "$slot" status --porcelain --untracked-files=all > "$case_dir/copy-status.before"
  git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' > "$case_dir/refs.before"
  add_window_swap_git_shim "$case_dir"
  start_window_fresh_allocator "$case_dir" "$POOL_LOCK" "$slot"
  FM_HOME="$case_dir/primary-home" FM_ROOT_OVERRIDE="$case_dir/code-root" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" NM_HOME="$case_dir/nm" FM_POOL_CASE="$case_dir" \
    PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-idle-session-reap.sh" reap > "$case_dir/reap.out" 2>&1 || rc=$?
  alloc_rc=0
  wait "$WINDOW_ALLOCATOR_PID" || alloc_rc=$?
  [ "$alloc_rc" = 0 ] || fail "window-reassigned-root: the fresh allocator failed"
  [ "$rc" = 0 ] || fail "window-reassigned-root: the reaper run failed: $(cat "$case_dir/reap.out")"
  assert_equals 1 "$(cat "$case_dir/holds-at-swap" 2>/dev/null || true)" \
    "window-reassigned-root: the swap did not land after the early ownership proof"
  [ "$(awk -F'\t' '$2 == "task-x1" { print $1 }' "$case_dir/reap.out")" = reaped ] \
    || fail "window-reassigned-root: the retiring task was not completed records-only: $(cat "$case_dir/reap.out")"
  assert_absent "$case_dir/state/.idle-reap/task-x1.refused" \
    "window-reassigned-root: the reassigned slot parked its record behind a refusal memo"
  assert_absent "$case_dir/state/task-x1.meta" "window-reassigned-root: the retiring record survived"
  assert_absent "$case_dir/state/task-x1.status" "window-reassigned-root: the retiring status survived"
  assert_absent "$case_dir/state/task-x1.teardown-return-pending" \
    "window-reassigned-root: the retiring return-pending record survived"
  assert_absent "$case_dir/treehouse.log" "window-reassigned-root: the retiring task administered the pool"
  cmp -s "$case_dir/claim.after-swap" "${slot%/*}/.fm-slot-owner" \
    || fail "window-reassigned-root: the new owner claim changed"
  jq -e '.worktrees[0].leased == true and .worktrees[0].lease_holder == "live-task"' \
    "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail "window-reassigned-root: the new owner lease changed: $(cat "$case_dir/pool/treehouse-state.json")"
  cmp -s "$case_dir/live-meta.before" "$case_dir/state/live-task.meta" \
    || fail "window-reassigned-root: the new owner record changed"
  cmp -s "$case_dir/live-status.before" "$case_dir/state/live-task.status" \
    || fail "window-reassigned-root: the new owner status changed"
  git -C "$slot" rev-parse HEAD | cmp -s - "$case_dir/head.before" || fail "window-reassigned-root: the claimant HEAD changed"
  git -C "$slot" symbolic-ref HEAD | cmp -s - "$case_dir/branch.before" || fail "window-reassigned-root: the claimant branch changed"
  git -C "$slot" status --porcelain --untracked-files=all | cmp -s - "$case_dir/copy-status.before" \
    || fail "window-reassigned-root: the claimant copy status changed"
  git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' | cmp -s - "$case_dir/refs.before" \
    || fail "window-reassigned-root: the claimant refs changed"
  pass 'a fresh allocation in the reservation window retires only the retiring record, preserving the new owner'
}

# The same window when the fresh allocator has already reset the slot to a
# landed tip: the owned-copy proof read the claimant's copy, so the retiring
# task is proved again from its own record. With its own branch unlanded and no
# merged PR it refuses and keeps its records; with a merged recorded PR it
# completes records-only and its backlog row records that PR, not local main.
test_reservation_window_reassignment_reproves_own_landing() {
  local shape case_dir slot own rc alloc_rc label
  for shape in unlanded merged-pr; do
    label="window-reproof-$shape"
    make_lease_modeling_pool_case "pool-$label" ''
    case_dir=$POOL_CASE
    slot=$POOL_SLOT
    rm -f "$case_dir/config/backlog-backend"
    seed_backlog_in_flight "$case_dir"
    own="$case_dir/own-copy"
    git -C "$case_dir/project" worktree add -q -b fm/task-x1-own "$own" main
    printf 'undelivered\n' > "$own/undelivered.txt"
    git -C "$own" add undelivered.txt
    git -C "$own" -c user.email=t@t -c user.name=t commit -qm 'undelivered task work'
    git -C "$case_dir/project" worktree remove --force "$own"
    fm_write_meta "$case_dir/state/task-x1.meta" \
      'window=firstmate:fm-task-x1' 'endpoint_task_id=task-x1' \
      "worktree=$slot" "project=$case_dir/project" 'kind=ship' 'mode=local-only' \
      'spawn_gen=teardown-test-task-x1' 'branch=fm/task-x1-own'
    if [ "$shape" = merged-pr ]; then
      append_pr_meta_url "$case_dir"
      add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/project" rev-parse fm/task-x1-own)"
    fi
    printf 'unfinished task\n' > "$case_dir/state/task-x1.status"
    cp "$case_dir/state/task-x1.meta" "$case_dir/task-meta.before"
    cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/endpoint.log"
exit 0
SH
    chmod +x "$case_dir/fakebin/tmux"
    fm_write_meta "$case_dir/live-task.meta.new" \
      "window=firstmate:fm-live-task" "endpoint_task_id=live-task" \
      "worktree=$slot" "project=$case_dir/project" "kind=ship" "spawn_gen=live"
    printf 'live task\n' > "$case_dir/live-task.status.new"
    git -C "$slot" rev-parse HEAD > "$case_dir/head.before"
    git -C "$slot" symbolic-ref HEAD > "$case_dir/branch.before"
    git -C "$slot" status --porcelain --untracked-files=all > "$case_dir/copy-status.before"
    git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' > "$case_dir/refs.before"
    add_window_swap_git_shim "$case_dir"
    start_window_fresh_allocator "$case_dir" "$POOL_LOCK" "$slot"
    rc=0
    FM_POOL_CASE="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    alloc_rc=0
    wait "$WINDOW_ALLOCATOR_PID" || alloc_rc=$?
    [ "$alloc_rc" = 0 ] || fail "$label: the fresh allocator failed"
    assert_equals 1 "$(cat "$case_dir/holds-at-swap" 2>/dev/null || true)" \
      "$label: the swap did not land after the early ownership proof"
    if [ "$shape" = unlanded ]; then
      expect_code 1 "$rc" "$label: an unlanded task must not retire records-only on a slot reassigned in the window"$'\n'"$(cat "$case_dir/stderr")"
      assert_grep "REFUSED: task task-x1's recorded copy $slot was reassigned to task live-task" "$case_dir/stderr" \
        "$label: the refusal did not name the reassigned slot"
      assert_grep 'its own branch fm/task-x1-own is not proved landed' "$case_dir/stderr" \
        "$label: the refusal lost its delivery proof boundary"
      cmp -s "$case_dir/task-meta.before" "$case_dir/state/task-x1.meta" || fail "$label: the retiring record changed"
      assert_present "$case_dir/state/task-x1.status" "$label: the retiring status was removed"
      assert_absent "$case_dir/state/task-x1.backlog-close" "$label: a pending backlog close was published"
      assert_absent "$case_dir/endpoint.log" "$label: the refused teardown touched an endpoint"
      [ "$(backlog_row_state "$case_dir")" = in_flight ] || fail "$label: the backlog row left In flight"
    else
      expect_code 0 "$rc" "$label: a merged recorded PR must complete records-only: $(cat "$case_dir/stderr")"
      assert_absent "$case_dir/state/task-x1.meta" "$label: the retiring record survived"
      grep -F "[x] task-x1" "$case_dir/data/backlog.md" >/dev/null || fail "$label: the backlog row was not closed"
      assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
        "$label: the closed row does not record the merged PR"
      assert_no_grep 'local main' "$case_dir/data/backlog.md" \
        "$label: the closed row certifies a local-main landing read from the claimant copy"
    fi
    assert_absent "$case_dir/treehouse.log" "$label: the retiring task administered the pool"
    cmp -s "$case_dir/claim.after-swap" "${slot%/*}/.fm-slot-owner" || fail "$label: the new owner claim changed"
    jq -e '.worktrees[0].leased == true and .worktrees[0].lease_holder == "live-task"' \
      "$case_dir/pool/treehouse-state.json" >/dev/null \
      || fail "$label: the new owner lease changed: $(cat "$case_dir/pool/treehouse-state.json")"
    cmp -s "$case_dir/live-meta.before" "$case_dir/state/live-task.meta" || fail "$label: the new owner record changed"
    cmp -s "$case_dir/live-status.before" "$case_dir/state/live-task.status" || fail "$label: the new owner status changed"
    git -C "$slot" rev-parse HEAD | cmp -s - "$case_dir/head.before" || fail "$label: the claimant HEAD changed"
    git -C "$slot" symbolic-ref HEAD | cmp -s - "$case_dir/branch.before" || fail "$label: the claimant branch changed"
    git -C "$slot" status --porcelain --untracked-files=all | cmp -s - "$case_dir/copy-status.before" \
      || fail "$label: the claimant copy status changed"
    git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' | cmp -s - "$case_dir/refs.before" \
      || fail "$label: the refs changed"
  done
  pass 'a slot reassigned in the reservation window is proved again from the retiring record, never from the claimant copy'
}

# The enclosing-slot variant of the same window: the fresh spawn claims the
# slot the retiring task's nested copy sits in. The retiring task keeps its own
# reassociated copy in place and returns nothing; the new owner's claim, lease,
# record and slot bytes survive, and the reaper parks no refusal memo.
test_enclosing_reservation_window_reassignment_leaves_claimant_slot() {
  local case_dir slot copy lock rc=0 alloc_rc=0 worker own_alive=0
  make_nested_slot_case pool-window-reassigned-enclosing enclosing .claude/worktrees/x
  case_dir=$NESTED_CASE
  slot=$NESTED_SLOT
  copy=$NESTED_COPY
  printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$slot" \
    > "$case_dir/pool/treehouse-state.json"
  fm_write_meta "$case_dir/live-task.meta.new" \
    "window=firstmate:fm-live-task" "endpoint_task_id=live-task" \
    "worktree=$slot" "project=$case_dir/project" "kind=ship" "spawn_gen=live"
  printf 'live task\n' > "$case_dir/live-task.status.new"
  printf 'spawn_gen=%s\nslot=%s\n' 'teardown-test-task-x1' "$slot" \
    > "$case_dir/state/task-x1.teardown-return-pending"
  printf 'g1.1.1\n' > "$case_dir/state/task-x1.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$(date +%s)" \
    > "$case_dir/state/task-x1.busy-state"
  git -C "$slot" rev-parse HEAD > "$case_dir/slot-head.before"
  git -C "$slot" symbolic-ref HEAD > "$case_dir/slot-branch.before"
  git -C "$slot" status --porcelain --untracked-files=all > "$case_dir/slot-status.before"
  git -C "$copy" rev-parse HEAD > "$case_dir/copy-head.before"
  git -C "$copy" symbolic-ref HEAD > "$case_dir/copy-branch.before"
  git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' > "$case_dir/refs.before"
  lock=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' \
    _ "$ROOT" "$case_dir/project") \
    || fail "window-reassigned-enclosing: cannot resolve the shared Treehouse project lock"
  teardown_fixture_start "$copy" KILL sleep 300
  worker=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  add_window_swap_git_shim "$case_dir"
  start_window_fresh_allocator "$case_dir" "$lock" "$slot"
  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/code-root" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" NM_HOME="$case_dir/nm" FM_POOL_CASE="$case_dir" \
    PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-idle-session-reap.sh" reap > "$case_dir/reap.out" 2>&1 || rc=$?
  alloc_rc=0
  wait "$WINDOW_ALLOCATOR_PID" || alloc_rc=$?
  kill -0 "$worker" 2>/dev/null && own_alive=1
  teardown_fixture_stop "$worker"
  [ "$alloc_rc" = 0 ] || fail "window-reassigned-enclosing: the fresh allocator failed"
  [ "$own_alive" = 0 ] || fail "window-reassigned-enclosing: the retiring copy's leaked process survived"
  [ "$rc" = 0 ] || fail "window-reassigned-enclosing: the reaper run failed: $(cat "$case_dir/reap.out")"
  assert_equals 1 "$(cat "$case_dir/holds-at-swap" 2>/dev/null || true)" \
    "window-reassigned-enclosing: the swap did not land after the early ownership proof"
  [ "$(awk -F'\t' '$2 == "task-x1" { print $1 }' "$case_dir/reap.out")" = reaped ] \
    || fail "window-reassigned-enclosing: the retiring task was not completed records-only: $(cat "$case_dir/reap.out")"
  assert_absent "$case_dir/state/.idle-reap/task-x1.refused" \
    "window-reassigned-enclosing: the reassigned slot parked its record behind a refusal memo"
  assert_absent "$case_dir/state/task-x1.meta" "window-reassigned-enclosing: the retiring record survived"
  assert_absent "$case_dir/state/task-x1.status" "window-reassigned-enclosing: the retiring status survived"
  assert_absent "$case_dir/state/task-x1.teardown-return-pending" \
    "window-reassigned-enclosing: the retiring return-pending record survived"
  assert_absent "$case_dir/treehouse.log" "window-reassigned-enclosing: the retiring task administered the pool"
  [ -d "$copy" ] || fail "window-reassigned-enclosing: the retiring reassociated copy was removed"
  cmp -s "$case_dir/claim.after-swap" "${slot%/*}/.fm-slot-owner" \
    || fail "window-reassigned-enclosing: the new owner claim changed"
  jq -e '.worktrees[0].leased == true and .worktrees[0].lease_holder == "live-task"' \
    "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail "window-reassigned-enclosing: the new owner lease changed: $(cat "$case_dir/pool/treehouse-state.json")"
  cmp -s "$case_dir/live-meta.before" "$case_dir/state/live-task.meta" \
    || fail "window-reassigned-enclosing: the new owner record changed"
  cmp -s "$case_dir/live-status.before" "$case_dir/state/live-task.status" \
    || fail "window-reassigned-enclosing: the new owner status changed"
  git -C "$slot" rev-parse HEAD | cmp -s - "$case_dir/slot-head.before" \
    || fail "window-reassigned-enclosing: the claimant slot HEAD changed"
  git -C "$slot" symbolic-ref HEAD | cmp -s - "$case_dir/slot-branch.before" \
    || fail "window-reassigned-enclosing: the claimant slot branch changed"
  git -C "$slot" status --porcelain --untracked-files=all | cmp -s - "$case_dir/slot-status.before" \
    || fail "window-reassigned-enclosing: the claimant slot status changed"
  git -C "$copy" rev-parse HEAD | cmp -s - "$case_dir/copy-head.before" \
    || fail "window-reassigned-enclosing: the retiring copy HEAD changed"
  git -C "$copy" symbolic-ref HEAD | cmp -s - "$case_dir/copy-branch.before" \
    || fail "window-reassigned-enclosing: the retiring copy branch changed"
  git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' | cmp -s - "$case_dir/refs.before" \
    || fail "window-reassigned-enclosing: the claimant refs changed"
  pass 'a fresh allocation in the enclosing-slot window leaves the claimant slot and the retiring copy untouched'
}

test_slot_claim_and_copy_ownership_table() {
  local claimant shape landing label case_dir slot copy rc own_pid claimant_pid
  local own_owned own_alive claimant_alive head
  for claimant in this visible unregistered; do
    for shape in root nested; do
      for landing in landed unlanded; do
        label="ownership-$claimant-$shape-$landing"
        make_ownership_table_case "$label" "$claimant" "$shape" "$landing"
        case_dir=$OWN_TABLE_CASE
        slot=$OWN_TABLE_SLOT
        copy=$OWN_TABLE_COPY
        own_owned=1
        [ "$claimant" = this ] || [ "$shape" = nested ] || own_owned=0
        teardown_fixture_start "$copy" KILL sleep 300
        own_pid=$TEARDOWN_FIXTURE_PID
        claimant_pid=
        if [ "$claimant" != this ] && [ "$shape" = nested ]; then
          teardown_fixture_start "$slot" KILL sleep 300
          claimant_pid=$TEARDOWN_FIXTURE_PID
        fi
        sleep 0.3
        head=$(git -C "$copy" rev-parse HEAD)
        cp "$case_dir/state/task-x1.meta" "$case_dir/task-meta.before"
        cp "$case_dir/pool/1/.fm-slot-owner" "$case_dir/claim.before"
        cp "$case_dir/pool/treehouse-state.json" "$case_dir/lease.before"
        git -C "$slot" rev-parse HEAD > "$case_dir/slot-head.before"
        git -C "$slot" symbolic-ref -q HEAD > "$case_dir/slot-branch.before" || : > "$case_dir/slot-branch.before"
        git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' > "$case_dir/refs.before"
        rc=0
        FM_HOME="$case_dir/home" \
        FM_FAKE_AXI_STATUS="$(parked_axi_status_toon "$OWN_TABLE_BRANCH" "$head")" \
        FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
          run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        own_alive=0
        claimant_alive=0
        kill -0 "$own_pid" 2>/dev/null && own_alive=1
        [ -z "$claimant_pid" ] || ! kill -0 "$claimant_pid" 2>/dev/null || claimant_alive=1
        teardown_fixture_stop "$own_pid"
        [ -z "$claimant_pid" ] || teardown_fixture_stop "$claimant_pid"
        if [ "$landing" = landed ]; then
          expect_code 0 "$rc" "$label: a landed task must finish: $(cat "$case_dir/stderr")"
          assert_absent "$case_dir/state/task-x1.meta" "$label: the finished record survived"
          grep -F "[x] task-x1" "$case_dir/data/backlog.md" >/dev/null \
            || fail "$label: the backlog row was not closed"
          if [ "$own_owned" = 1 ]; then
            [ "$own_alive" = 0 ] || fail "$label: the retiring task's own leaked process survived"
            assert_grep 'abort --run 01RUN' "$case_dir/nm-abort.log" \
              "$label: the retiring task's parked run was not concluded"
          else
            [ "$own_alive" = 1 ] || fail "$label: the claimant's process was reaped"
            assert_absent "$case_dir/nm-abort.log" "$label: a run on the claimant's slot was aborted"
          fi
        else
          expect_code 1 "$rc" "$label: an unlanded task must refuse: $(cat "$case_dir/stderr")"
          cmp -s "$case_dir/task-meta.before" "$case_dir/state/task-x1.meta" \
            || fail "$label: the refusal changed the retiring record"
          assert_present "$case_dir/state/task-x1.status" "$label: the refusal removed the status"
          [ "$(backlog_row_state "$case_dir")" = in_flight ] \
            || fail "$label: the refused task's backlog row left In flight"
          assert_absent "$case_dir/endpoint.log" "$label: the refusal touched an endpoint"
          assert_absent "$case_dir/nm-abort.log" "$label: the refusal aborted a run"
          [ "$own_alive" = 1 ] || fail "$label: the refusal reaped a process before proving landing"
          assert_present "$case_dir/pool/1/.fm-slot-owner" "$label: the refusal dropped the slot claim"
          git -C "$case_dir/project" cat-file -e "$OWN_TABLE_BRANCH:undelivered.txt" \
            || fail "$label: the refusal lost the unlanded work"
        fi
        if [ "$claimant" = this ] && [ "$landing" = landed ]; then
          assert_grep "return --force $slot" "$case_dir/treehouse.log" "$label: the finished task's slot was not returned"
          assert_absent "$case_dir/pool/1/.fm-slot-owner" "$label: the finished task's claim survived"
          [ "$shape" != nested ] || assert_absent "$copy" "$label: the nested copy was not removed"
        else
          assert_absent "$case_dir/treehouse.log" "$label: the slot was administered without an owning claim or a finished record"
          cmp -s "$case_dir/claim.before" "$case_dir/pool/1/.fm-slot-owner" || fail "$label: the slot claim changed"
          cmp -s "$case_dir/lease.before" "$case_dir/pool/treehouse-state.json" || fail "$label: the pool lease changed"
          git -C "$slot" rev-parse HEAD | cmp -s - "$case_dir/slot-head.before" || fail "$label: the slot HEAD changed"
          [ "$claimant" = this ] || {
            git -C "$slot" symbolic-ref -q HEAD | cmp -s - "$case_dir/slot-branch.before" \
              || fail "$label: the claimant branch changed"
            assert_grep 'claimant untracked work' "$slot/scratch.txt" "$label: the claimant's work changed"
          }
          [ "$shape" != nested ] || assert_present "$copy/.git" "$label: the nested copy was removed"
          [ -z "$claimant_pid" ] || [ "$claimant_alive" = 1 ] || fail "$label: the claimant's process was reaped"
          git -C "$case_dir/project" for-each-ref --format='%(refname) %(objectname)' | cmp -s - "$case_dir/refs.before" \
            || fail "$label: refs changed"
        fi
      done
    done
  done
  pass 'a slot claim decides slot administration while the retiring copy decides runtime retirement, for every claimant and copy shape'
}

# A record re-pointed by bin/fm-control.sh reassociate names its earlier copies
# in prior_worktree=. Teardown still runs the landed-work test on the current
# copy, but leaves a current copy that is not a pool slot - and every prior
# copy - exactly as it is: no Treehouse return, no branch deletion.
test_reassociated_copies_are_left_in_place() {
  local case_dir rc old_fp
  case_dir=$(make_case reassociated-keep)
  mkdir -p "$case_dir/home/state"
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  git -C "$case_dir/project" worktree add -q -b fm/task-x1-old "$case_dir/old" main
  printf 'preserved scratch\n' > "$case_dir/old/scratch.txt"
  printf 'prior_worktree=%s\n' "$case_dir/old" >> "$case_dir/state/task-x1.meta"
  old_fp=$(git -C "$case_dir/old" rev-parse HEAD; git -C "$case_dir/old" status --porcelain --untracked-files=all)
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "reassociated-keep: a landed reassociated task should tear down"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "reassociated worktree $case_dir/wt left in place" "$case_dir/stdout" \
    "reassociated-keep: teardown did not report the current copy left in place"
  assert_grep "prior copy $case_dir/old (from a reassociation) was left untouched" "$case_dir/stdout" \
    "reassociated-keep: teardown did not report the preserved prior copy"
  assert_absent "$case_dir/treehouse.log" "reassociated-keep: teardown returned a copy it does not own"
  git -C "$case_dir/wt" symbolic-ref --quiet HEAD >/dev/null \
    || fail "reassociated-keep: the current copy's branch was detached"
  git -C "$case_dir/project" rev-parse --verify --quiet refs/heads/fm/task-x1 >/dev/null \
    || fail "reassociated-keep: the current copy's branch was deleted"
  [ "$old_fp" = "$(git -C "$case_dir/old" rev-parse HEAD; git -C "$case_dir/old" status --porcelain --untracked-files=all)" ] \
    || fail "reassociated-keep: the prior copy changed"
  assert_absent "$case_dir/state/task-x1.meta" "reassociated-keep: the task record was not removed"
  pass "teardown of a reassociated record keeps the non-pool current copy and every prior copy untouched"
}

# A record whose earlier pool slot was released by reassociate names it only as
# released_worktree=: still a reassociated record, so its non-pool current copy
# is left in place, but the released slot is no preserved custody to report.
test_released_slot_record_keeps_current_copy() {
  local case_dir rc
  case_dir=$(make_case reassociated-released)
  mkdir -p "$case_dir/home/state"
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  printf 'released_worktree=%s\n' "$case_dir/released-slot" >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "reassociated-released: a landed reassociated task should tear down"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "reassociated worktree $case_dir/wt left in place" "$case_dir/stdout" \
    "reassociated-released: teardown did not leave the non-pool current copy in place"
  assert_no_grep "prior copy" "$case_dir/stdout" "reassociated-released: a released slot was reported as preserved custody"
  assert_absent "$case_dir/treehouse.log" "reassociated-released: teardown returned a copy it does not own"
  git -C "$case_dir/project" rev-parse --verify --quiet refs/heads/fm/task-x1 >/dev/null \
    || fail "reassociated-released: the current copy's branch was deleted"
  assert_absent "$case_dir/state/task-x1.meta" "reassociated-released: the task record was not removed"
  pass "teardown of a record whose old slot was released keeps the non-pool current copy"
}

test_reassociated_unlanded_copy_still_refuses() {
  local case_dir rc
  case_dir=$(make_case reassociated-unlanded)
  mkdir -p "$case_dir/home/state"
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" unlanded.txt "unlanded work"
  git -C "$case_dir/project" worktree add -q -b fm/task-x1-old "$case_dir/old" main
  printf 'prior_worktree=%s\n' "$case_dir/old" >> "$case_dir/state/task-x1.meta"
  cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "reassociated-unlanded: unlanded work in the current copy must still refuse"
  cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" \
    || fail "reassociated-unlanded: the refusal changed the task record"
  pass "teardown of a reassociated record still refuses unlanded work in the current copy"
}

# Another task's preserved prior copy is live custody: a teardown whose pool slot
# some record still names in prior_worktree= refuses rather than returning it.
test_slot_named_as_another_prior_copy_refuses() {
  local case_dir rc slot
  case_dir=$(make_case prior-copy-collision)
  mkdir -p "$case_dir/home/state" "$case_dir/pool/1"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$case_dir/pool/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"task-x1"}]}\n' \
    "$case_dir/pool/1/project" > "$case_dir/pool/treehouse-state.json"
  slot=$(cd "$case_dir/pool/1/project" && pwd -P)
  wt_commit_at() { git -C "$slot" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1"; }
  wt_commit_at "shippable work"
  git -C "$slot" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$slot" "project=$case_dir/project" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1"
  mkdir -p "$case_dir/elsewhere"
  fm_write_meta "$case_dir/state/other.meta" "worktree=$case_dir/elsewhere" \
    "prior_worktree=$slot" "kind=ship"
  cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "prior-copy-collision: teardown must refuse a slot another record preserves"
  assert_grep "is also task other's recorded prior_worktree" "$case_dir/stderr" \
    "prior-copy-collision: the refusal did not name the preserving record"
  cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" \
    || fail "prior-copy-collision: the refusal changed the task record"
  assert_present "$slot" "prior-copy-collision: the slot was removed"
  pass "teardown refuses to return a pool slot another record preserves as a prior copy"
}

# A task's own prior copies never refuse its own teardown outright. A prior
# copy nested in a pool slot the return sweeps away must be proved disposable,
# and a plain directory cannot be: those cases refuse and change nothing, with
# or without --force. A prior copy that IS the slot (reached through a symlink)
# or that encloses it loses nothing beyond the current copy the landed-work test
# covers, so teardown returns the slot and leaves an enclosing prior untouched.
# A non-pool current copy is never returned, so no prior copy blocks it.
test_own_prior_copies_block_only_an_unproven_pool_return() {
  local case_dir rc slot prior shape force pool label
  for pool in ordinary pool; do
    for shape in return ancestor descendant; do
      for force in normal force; do
        label="nested-prior-$pool-$shape-$force"
        case_dir=$(make_case "$label")
        mkdir -p "$case_dir/home/state"
        slot=$case_dir/wt
        cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
        if [ "$pool" = pool ]; then
          mkdir -p "$case_dir/pool/1"
          git -C "$case_dir/project" worktree move "$slot" "$case_dir/pool/1/project"
          printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"task-x1"}]}\n' \
    "$case_dir/pool/1/project" > "$case_dir/pool/treehouse-state.json"
          slot=$case_dir/pool/1/project
        fi
        ln -s "$slot" "$case_dir/copy-A"
        case "$shape" in
          return) prior=$case_dir/copy-A ;;
          ancestor) prior=${slot%/*} ;;
          descendant)
            mkdir -p "$slot/nested-B"
            printf 'preserved B work\n' > "$slot/nested-B/scratch.txt"
            prior=$case_dir/copy-A/nested-B
            ;;
        esac
        fm_write_meta "$case_dir/state/task-x1.meta" \
          "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
          "worktree=$slot" "project=$case_dir/project" \
          "kind=ship" "mode=no-mistakes" "spawn_gen=teardown-test-task-x1" \
          "prior_worktree=$prior"
        cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
        rc=0
        if [ "$force" = force ]; then
          FM_HOME="$case_dir/home" \
            run_teardown "$case_dir" --force --drop-file "$FM_TEST_DROP_WORDS" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        else
          FM_HOME="$case_dir/home" \
            run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        fi
        if [ "$shape" = descendant ]; then
          assert_absent "$case_dir/treehouse.log" "$label: cleanup returned a copy"
          assert_grep "preserved B work" "$slot/nested-B/scratch.txt" "$label: nested prior content changed"
          if [ "$pool" = ordinary ] && [ "$force" = force ]; then
            expect_code 0 "$rc" "$label: a teardown that returns nothing must not be blocked by its own prior copy: $(cat "$case_dir/stderr")"
            assert_grep "reassociated worktree $slot left in place" "$case_dir/stdout" \
              "$label: the current copy was not left in place"
            assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
            continue
          fi
          expect_code 1 "$rc" "$label: unproven work must refuse cleanup"
          if [ "$pool" = pool ]; then
            assert_grep "recorded prior_worktree" "$case_dir/stderr" "$label: refusal did not identify the prior copy"
            assert_grep "not a Git worktree root" "$case_dir/stderr" "$label: refusal did not name the reason"
          else
            assert_grep "has uncommitted changes" "$case_dir/stderr" \
              "$label: the landed-work test did not report the untracked prior work"
          fi
          cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" || fail "$label: task metadata changed"
          continue
        fi
        expect_code 0 "$rc" "$label: an own prior copy the return does not sweep must not block teardown: $(cat "$case_dir/stderr")"
        assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
        if [ "$pool" = pool ]; then
          assert_grep "return --force $slot" "$case_dir/treehouse.log" "$label: the pool slot was not returned"
        else
          assert_absent "$case_dir/treehouse.log" "$label: a non-pool copy was returned"
          assert_grep "reassociated worktree $slot left in place" "$case_dir/stdout" \
            "$label: the current copy was not left in place"
        fi
        if [ "$shape" = ancestor ]; then
          assert_grep "prior copy $prior (from a reassociation) was left untouched" "$case_dir/stdout" \
            "$label: the enclosing prior copy was not named as left untouched"
          assert_present "$prior" "$label: the enclosing prior copy was removed"
        elif [ "$pool" = pool ]; then
          assert_no_grep "prior copy" "$case_dir/stdout" "$label: the returned slot was still reported as a prior copy"
        fi
      done
    done
  done
  pass "own prior copies refuse only a pool return that cannot prove them landed; a prior that is or encloses the slot does not block it, with or without --force"
}

# The reverse nested shape whose prior copy is not under .claude/: the slot is
# the current copy, and its landed-work test must not count the task's own
# nested prior copy as the slot's dirt. Teardown proves the nested copy,
# removes it, and returns the slot.
test_reverse_nested_prior_outside_claude_tears_down() {
  local case_dir rc
  make_nested_slot_case reverse-nested-plain reverse nested-v2
  case_dir=$NESTED_CASE
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "reverse-nested-plain: a landed slot with its own landed nested prior copy must tear down: $(cat "$case_dir/stderr")"
  assert_no_grep "uncommitted changes" "$case_dir/stderr" "reverse-nested-plain: the nested prior copy was counted as the slot's dirt"
  assert_absent "$NESTED_COPY" "reverse-nested-plain: the nested prior copy was not removed before the return"
  assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" "reverse-nested-plain: the slot was not returned"
  assert_absent "$case_dir/pool/1/.fm-slot-owner" "reverse-nested-plain: the slot claim survived the task"
  git -C "$case_dir/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null \
    || fail "reverse-nested-plain: the nested prior copy's branch was deleted"
  assert_absent "$case_dir/state/task-x1.meta" "reverse-nested-plain: the task record was not removed"
  pass "the reverse nested shape with a prior copy outside .claude/ proves and removes it, then returns the slot"
}

# A stale index.lock in the enclosing slot makes the first return fail; while
# teardown waits, the slot gains work. Once the stale lock is removed the slot is
# proved again before the reset, with or without --force, so the late work stops
# teardown, nothing is returned, and the slot keeps it.
test_nested_slot_stale_lock_cleanup_reproves_the_slot() {
  local case_dir rc lock force label
  for force in normal force; do
    label="nested-stale-lock-$force"
    make_nested_slot_case "$label" enclosing .claude/worktrees/x
    case_dir=$NESTED_CASE
    cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = return ] || exit 0
wt=\${@: -1}
lock=\$(git -C "\$wt" rev-parse --path-format=absolute --git-path index.lock 2>/dev/null || true)
if [ -n "\$lock" ] && [ -e "\$lock" ]; then
  printf 'late slot work\n' > "\$wt/late.txt"
  echo "fatal: Unable to create '\$lock': File exists." >&2
  exit 128
fi
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
    chmod +x "$case_dir/fakebin/treehouse"
    add_lsof_no_holder "$case_dir"
    lock=$(git_index_lock_path "$NESTED_SLOT")
    : > "$lock"
    touch -t 200001010000 "$lock"
    rc=0
    if [ "$force" = force ]; then
      FM_HOME="$case_dir/home" FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
        run_teardown "$case_dir" --force --drop-file "$FM_TEST_DROP_WORDS" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      FM_HOME="$case_dir/home" FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
        run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    expect_code 1 "$rc" "$label: the slot's late work must stop the reset: $(cat "$case_dir/stderr")"
    assert_grep "removed provably-stale git lock" "$case_dir/stderr" "$label: the stale lock was not cleaned up"
    assert_grep "claimed pool slot $NESTED_SLOT, which has uncommitted or untracked-unignored changes" "$case_dir/stderr" \
      "$label: the refusal did not name the slot and the reason"
    assert_absent "$case_dir/treehouse.log" "$label: the slot was returned"
    assert_grep "late slot work" "$NESTED_SLOT/late.txt" "$label: the slot lost its late work"
    assert_present "$case_dir/state/task-x1.meta" "$label: the task record was removed"
  done
  pass "a stale-lock cleanup in the enclosing slot proves it again before the reset, with or without --force"
}

# A refusal at the enclosing slot's post-lock proof comes after the nested
# current copy was already removed. A re-run must still find the slot - through
# the task's own prior copy, or for a record with no prior_worktree= line
# through where the removed copy was - prove it again, and return it only once
# its work is landed or anchored, never retire the record and leave the slot
# claimed but unproved. --force does not waive that proof.
test_nested_slot_reproof_refusal_is_rerunnable() {
  local case_dir rc lock shape label
  for shape in enclosing plain; do
    label="nested-reproof-rerun-$shape"
    nested_fixture "$label" "$shape" mine landed
    case_dir=$NESTED_CASE
    stale_lock_late_work_treehouse "$case_dir"
    lock=$(git_index_lock_path "$NESTED_SLOT")
    : > "$lock"
    touch -t 200001010000 "$lock"
    rc=0
    FM_HOME="$case_dir/home" FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$label: the first teardown must stop at the slot's late work: $(cat "$case_dir/stderr")"
    assert_absent "$NESTED_COPY" "$label: the first teardown had not yet removed the nested copy"
    assert_no_grep "nothing was changed" "$case_dir/stderr" "$label: the post-lock refusal claimed nothing was changed"

    git -C "$NESTED_SLOT" add late.txt
    git -C "$NESTED_SLOT" commit -qm "late slot work"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
    expect_code 1 "$rc" "$label: a plain re-run must prove the slot again: $(cat "$case_dir/stderr2")"
    assert_grep "claimed pool slot $NESTED_SLOT" "$case_dir/stderr2" "$label: the re-run refusal did not name the slot"
    assert_grep "neither landed nor held" "$case_dir/stderr2" "$label: the re-run refusal did not name the reason"
    assert_present "$case_dir/state/task-x1.meta" "$label: the re-run retired the record with the slot unproved"
    assert_present "$case_dir/pool/1/.fm-slot-owner" "$label: the re-run dropped the slot claim"
    assert_absent "$case_dir/treehouse.log" "$label: the re-run returned the unproved slot"

    git -C "$NESTED_SLOT" push -q origin HEAD:main
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout3" 2> "$case_dir/stderr3" || rc=$?
    expect_code 0 "$rc" "$label: a plain re-run with the slot's work landed must finish: $(cat "$case_dir/stderr3")"
    assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" "$label: the landed slot was not returned"
    assert_absent "$case_dir/pool/1/.fm-slot-owner" "$label: the slot claim survived the task"
    assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
    assert_absent "$case_dir/state/task-x1.backlog-close" "$label: the backlog-close marker survived"
    assert_absent "$case_dir/state/task-x1.teardown-return-pending" "$label: the return-pending marker survived"
  done
  pass "a plain re-run after the post-lock refusal proves the enclosing slot again and returns it once its work lands, for a prior and a plain record"
}

# Defect 7: the nested copy is removed before the slot's post-lock proof, so a
# re-run has no copy left to test for landed work. A local-only ship with no
# recorded PR must still finish with a plain re-run, recorded as landed on local
# main and never as dropped, with no --force and no captain words.
test_nested_rerun_local_only_ship_is_recorded_landed() {
  local case_dir rc lock label=nested-rerun-local-only
  make_nested_slot_case "$label" enclosing .claude/worktrees/x local-only
  case_dir=$NESTED_CASE
  seed_backlog_in_flight "$case_dir"
  stale_lock_late_work_treehouse "$case_dir"
  printf 'nested ship work\n' > "$NESTED_COPY/ship.txt"
  git -C "$NESTED_COPY" add ship.txt
  git -C "$NESTED_COPY" -c user.email=t@t -c user.name=t commit -qm "nested ship work"
  git -C "$case_dir/project" merge -q --ff-only fm/task-x1-v2
  lock=$(git_index_lock_path "$NESTED_SLOT")
  : > "$lock"
  touch -t 200001010000 "$lock"
  rc=0
  FM_HOME="$case_dir/home" FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$label: the first teardown must stop at the slot's late work: $(cat "$case_dir/stderr")"
  assert_absent "$NESTED_COPY" "$label: the nested copy was not removed by the first teardown"

  git -C "$NESTED_SLOT" add late.txt
  git -C "$NESTED_SLOT" -c user.email=t@t -c user.name=t commit -qm "late slot work"
  git -C "$case_dir/project" -c user.email=t@t -c user.name=t merge -q --no-edit "$(git -C "$NESTED_SLOT" rev-parse HEAD)"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 0 "$rc" "$label: a plain re-run of a landed local-only ship must finish: $(cat "$case_dir/stderr2")"
  assert_no_grep "get the captain's own words" "$case_dir/stderr2" "$label: the re-run asked for captain words for landed work"
  assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" "$label: the landed slot was not returned"
  assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
  assert_absent "$case_dir/data/task-x1/captain-drop.md" "$label: landed work was recorded as a captain drop"
  grep -F "[x] task-x1" "$case_dir/data/backlog.md" >/dev/null || fail "$label: the backlog row was not closed"
  assert_no_grep "dropped" "$case_dir/data/backlog.md" "$label: landed work was recorded as dropped"
  assert_grep "local main" "$case_dir/data/backlog.md" "$label: the row does not record the local-main landing"
  pass "a plain re-run of a landed local-only nested ship is recorded as landed, not dropped"
}

# A plain nested copy in the task's own claimed slot is removed and the slot
# returned, with and without --force --drop-file (the recorded case's
# invocation): the header's rule for a nested current copy holds whether or not
# the record names a prior_worktree=.
assert_plain_nested_own_slot_closed() {  # <normal|force>
  local case_dir label=plain-nested-own-slot-$1 rc=0
  nested_fixture "$label" plain mine landed
  case_dir=$NESTED_CASE
  if [ "$1" = force ]; then nested_run "$case_dir" --force || rc=$?; else nested_run "$case_dir" || rc=$?; fi
  expect_code 0 "$rc" "$label: a plain nested copy in its own claimed slot must tear down: $(tail -3 "$case_dir/stderr")"
  assert_nested_closed "$case_dir" "$label"
}

test_plain_nested_copy_in_own_slot_is_removed_and_slot_returned() {
  assert_plain_nested_own_slot_closed normal
  pass "a plain nested copy in the task's own claimed slot is removed and the slot returned"
}

test_plain_nested_copy_in_own_slot_is_removed_with_force_and_drop_file() {
  assert_plain_nested_own_slot_closed force
  pass "a plain nested copy in the task's own claimed slot is removed and the slot returned under --force --drop-file"
}

# A refusal decidable from the state at entry removes nothing and writes
# nothing: the slot root's unlanded commit and the nested copy's uncommitted
# change each refuse before the endpoint close, any inbox, status or tasktmp
# removal and any marker write, for both record shapes, and a leftover marker
# pair from an earlier failed run stays byte-identical.
test_nested_entry_refusals_change_nothing() {
  local case_dir shape cause leftovers rc label fragment
  for shape in enclosing plain; do
    for cause in slot-unlanded copy-dirty; do
      for leftovers in none present; do
        label="nested-entry-refusal-$shape-$cause-$leftovers"
        nested_fixture "$label" "$shape" mine "$cause"
        case_dir=$NESTED_CASE
        [ "$leftovers" = none ] || nested_place_leftovers "$case_dir"
        nested_snapshot "$case_dir" "$case_dir/snapshot.before"
        rc=0
        nested_run "$case_dir" || rc=$?
        if [ "$cause" = slot-unlanded ]; then
          fragment="claimed pool slot $NESTED_SLOT, whose HEAD $(git -C "$NESTED_SLOT" rev-parse HEAD)"
        else
          fragment="has uncommitted changes"
        fi
        assert_nested_refused_untouched "$case_dir" "$rc" "$label" "$fragment"
        if [ "$leftovers" = none ]; then
          assert_absent "$case_dir/state/task-x1.backlog-close" "$label: a backlog-close marker was written"
          assert_absent "$case_dir/state/task-x1.teardown-return-pending" "$label: a return-pending marker was written"
        fi
      done
    done
  done
  pass "an entry refusal for the slot root's unlanded commit or the nested copy's dirt changes nothing, for a prior and a plain record"
}

# A pending-close record path that is not a regular file is decidable at entry:
# the later clear of the previous pending-close record always refuses it, so the
# refusal must come before the slot lease and before any marker write, for both
# record shapes, whether the path is a directory or a dangling link. Once the bad
# path is removed, the same teardown closes: the reservation-time marker and the
# late-refusal recovery are untouched (test_nested_slot_reproof_refusal_is_rerunnable).
assert_nested_unusable_pending_close_refused_at_entry() {  # <plain|enclosing> <directory|dangling-link>
  local shape=$1 form=$2 case_dir rc=0 fragment label="nested-pending-close-$2-$1"
  nested_fixture "$label" "$shape" mine landed
  case_dir=$NESTED_CASE
  case "$form" in
    directory) mkdir "$case_dir/state/task-x1.backlog-close"; fragment="is not a regular file" ;;
    dangling-link) ln -s no-such-record "$case_dir/state/task-x1.backlog-close"; fragment="resolves through a different final path" ;;
  esac
  nested_snapshot "$case_dir" "$case_dir/snapshot.before"
  nested_run "$case_dir" || rc=$?
  assert_nested_refused_untouched "$case_dir" "$rc" "$label" "$fragment"
  assert_absent "$case_dir/state/task-x1.teardown-return-pending" "$label: a return-pending marker was written"
  rm -rf "$case_dir/state/task-x1.backlog-close"
  rc=0
  nested_run "$case_dir" || rc=$?
  expect_code 0 "$rc" "$label: the retry after the bad record is removed must close: $(tail -3 "$case_dir/stderr")"
  assert_nested_closed "$case_dir" "$label"
}

test_nested_pending_close_directory_refuses_at_entry_plain() {
  assert_nested_unusable_pending_close_refused_at_entry plain directory
  pass "a pending-close path that is a directory refuses a plain nested close before any lease or marker write, and the retry closes"
}

test_nested_pending_close_directory_refuses_at_entry_enclosing() {
  assert_nested_unusable_pending_close_refused_at_entry enclosing directory
  pass "a pending-close path that is a directory refuses a prior-shape nested close before any lease or marker write, and the retry closes"
}

test_nested_pending_close_dangling_link_refuses_at_entry_plain() {
  assert_nested_unusable_pending_close_refused_at_entry plain dangling-link
  pass "a pending-close path that is a dangling link refuses a plain nested close before any lease or marker write, and the retry closes"
}

test_nested_pending_close_dangling_link_refuses_at_entry_enclosing() {
  assert_nested_unusable_pending_close_refused_at_entry enclosing dangling-link
  pass "a pending-close path that is a dangling link refuses a prior-shape nested close before any lease or marker write, and the retry closes"
}

# Whether this host can make a regular file that rm -f cannot remove with the
# user-immutable flag: not where chflags is missing, and not for root.
pending_close_immutable_supported() {  # <dir>
  local twin=$1/immutable-twin removed=0
  command -v chflags >/dev/null 2>&1 || return 1
  printf 'twin\n' > "$twin"
  chflags uchg "$twin" 2>/dev/null || { rm -f "$twin"; return 1; }
  rm -f "$twin" 2>/dev/null || true
  [ -e "$twin" ] || removed=1
  chflags nouchg "$twin" 2>/dev/null || true
  rm -f "$twin"
  [ "$removed" = 0 ]
}

# A previous pending-close record that is a regular file the clear cannot remove
# (its user-immutable flag, set before the run) is decidable at entry too: on an
# unleased slot, the nested close of either record shape takes no lease and the
# return-pending marker keeps its bytes, or stays absent. Once the flag is
# cleared the same teardown closes.
assert_nested_unremovable_pending_close_refused_at_entry() {  # <plain|enclosing> <absent|present>
  local shape=$1 pending=$2 case_dir rc=0 record label="nested-pending-close-immutable-$1-$2"
  nested_fixture "$label" "$shape" mine landed
  case_dir=$NESTED_CASE
  held_plain_get_slot "$case_dir" "$NESTED_SLOT"
  nested_place_leftovers "$case_dir"
  [ "$pending" = present ] || rm -f "$case_dir/state/task-x1.teardown-return-pending"
  record=$case_dir/state/task-x1.backlog-close
  chflags uchg "$record"
  nested_snapshot "$case_dir" "$case_dir/snapshot.before"
  nested_run "$case_dir" || rc=$?
  chflags nouchg "$record"
  assert_nested_refused_untouched "$case_dir" "$rc" "$label" "pending-close record could not be removed at $record"
  assert_absent "$case_dir/lease.log" "$label: the refused close took a lease"
  jq -e '.worktrees[0].leased == false' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail "$label: the refused close left the slot leased"
  rc=0
  nested_run "$case_dir" || rc=$?
  expect_code 0 "$rc" "$label: the retry after the flag is cleared must close: $(tail -3 "$case_dir/stderr")"
  assert_nested_closed "$case_dir" "$label"
}

assert_nested_unremovable_pending_close_case() {  # <plain|enclosing> <absent|present>
  if ! pending_close_immutable_supported "$TMP_ROOT"; then
    pass "an unremovable pending-close record refuses a $1 nested close before any lease or marker write (skipped: this host cannot make an unremovable file with chflags uchg)"
    return 0
  fi
  assert_nested_unremovable_pending_close_refused_at_entry "$1" "$2"
  pass "an unremovable pending-close record refuses a $1 nested close before any lease or marker write, with the return-pending marker $2, and the retry closes"
}

test_nested_pending_close_immutable_refuses_at_entry_plain_marker_absent() {
  assert_nested_unremovable_pending_close_case plain absent
}

test_nested_pending_close_immutable_refuses_at_entry_plain_marker_present() {
  assert_nested_unremovable_pending_close_case plain present
}

test_nested_pending_close_immutable_refuses_at_entry_enclosing_marker_absent() {
  assert_nested_unremovable_pending_close_case enclosing absent
}

test_nested_pending_close_immutable_refuses_at_entry_enclosing_marker_present() {
  assert_nested_unremovable_pending_close_case enclosing present
}

# A pending-close record that is read-only but removable (mode 0444 in a
# writable state directory) is not refused: the entry check asks whether the
# clear can remove it, not whether it can be written.
test_nested_read_only_pending_close_still_closes() {
  local shape case_dir rc label
  for shape in plain enclosing; do
    label="nested-pending-close-read-only-$shape"
    nested_fixture "$label" "$shape" mine landed
    case_dir=$NESTED_CASE
    held_plain_get_slot "$case_dir" "$NESTED_SLOT"
    nested_place_leftovers "$case_dir"
    chmod 444 "$case_dir/state/task-x1.backlog-close"
    rc=0
    nested_run "$case_dir" || rc=$?
    expect_code 0 "$rc" "$label: a removable read-only record must not refuse: $(tail -3 "$case_dir/stderr")"
    assert_nested_closed "$case_dir" "$label"
  done
  pass "a read-only but removable pending-close record lets a plain and a prior-shape nested close finish"
}

# The same entry refusal holds off the nested route: a ship whose copy is the
# pool slot itself, with no backlog transition, takes no lease and writes no
# return-pending marker when its previous pending-close record is a directory or
# a file it cannot remove, and closes once the record is fixed.
test_pool_slot_root_unremovable_pending_close_refuses_before_lease() {
  local form case_dir slot record rc forms=directory
  ! pending_close_immutable_supported "$TMP_ROOT" || forms="directory immutable"
  for form in $forms; do
    make_lease_modeling_pool_case "pool-root-pending-close-$form" ''
    case_dir=$POOL_CASE
    slot=$POOL_SLOT
    record=$case_dir/state/task-x1.backlog-close
    if [ "$form" = directory ]; then
      mkdir "$record"
    else
      printf 'id=task-x1\ndata=%s\nspawn_gen=teardown-test-task-x1\ncleanup_incomplete=0\n' "$case_dir/data" > "$record"
      chflags uchg "$record"
    fi
    rc=0
    FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    [ "$form" = directory ] || chflags nouchg "$record"
    expect_code 1 "$rc" "pool-root-$form: the teardown must refuse: $(cat "$case_dir/stderr")"
    assert_grep 'previous pending backlog close for task-x1 could not be cleared' "$case_dir/stderr" "pool-root-$form: the refusal did not name the previous pending-close record"
    ! grep -q '^lease [^-]' "$case_dir/treehouse.log" 2>/dev/null || fail "pool-root-$form: the refused close took a lease"
    jq -e '.worktrees[0].leased == false' "$case_dir/pool/treehouse-state.json" >/dev/null \
      || fail "pool-root-$form: the refused close left the slot leased"
    assert_absent "$case_dir/state/task-x1.teardown-return-pending" "pool-root-$form: the refused close wrote a return-pending marker"
    assert_present "$case_dir/state/task-x1.meta" "pool-root-$form: the refused close removed the task record"
    assert_present "$slot/.git" "pool-root-$form: the refused close removed the slot copy"
    rm -rf "${record:?}"
    rc=0
    FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
      run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
    expect_code 0 "$rc" "pool-root-$form: the retry after the record is fixed must close: $(cat "$case_dir/stderr2")"
    assert_absent "$case_dir/state/task-x1.meta" "pool-root-$form: the retry kept the task record"
  done
  pass "a pool-slot-root close with an unremovable previous pending-close record ($forms) refuses before any lease or marker write, and the fixed retry closes"
}

# nested_slot_landed_tracked_file <case-dir>: the slot root gains a tracked
# tracked.txt in a commit that is on origin's main, so the slot stays landed.
nested_slot_landed_tracked_file() {  # <case-dir>
  local case_dir=$1
  printf 'tracked\n' > "$NESTED_SLOT/tracked.txt"
  git -C "$NESTED_SLOT" add tracked.txt
  git -C "$NESTED_SLOT" -c user.email=t@t -c user.name=t commit -qm "tracked file"
  git -C "$NESTED_SLOT" push -q origin HEAD:main
  git -C "$case_dir/project" fetch -q origin
}

# nested_self_clearing_lock_treehouse <case-dir> <dirty|clean>: a Treehouse
# stand-in whose first return of any path fails with Git's index.lock signature
# while the lock clears on its own; when dirty it first appends new bytes to a
# tracked file of the slot root, as a process finishing in the slot would. A
# later return records whether those bytes are still there in late-at-return,
# then resets the slot with Git, as the provider's forced return does, and logs
# the return. The slot root must hold a landed tracked.txt
# (nested_slot_landed_tracked_file).
nested_self_clearing_lock_treehouse() {  # <case-dir> <dirty|clean>
  local case_dir=$1 mode=$2
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = return ] || exit 0
wt=\${@: -1}
count=\$(cat "$case_dir/return-attempts" 2>/dev/null || echo 0)
count=\$((count + 1))
printf '%s\n' "\$count" > "$case_dir/return-attempts"
if [ "\$count" = 1 ]; then
  if [ "$mode" = dirty ] && [ "\$wt" = "$NESTED_SLOT" ]; then
    printf 'late unlanded bytes\n' >> "$NESTED_SLOT/tracked.txt"
  fi
  echo "fatal: Unable to create '\$wt/.git/index.lock': File exists." >&2
  exit 128
fi
if [ "\$wt" = "$NESTED_SLOT" ]; then
  if grep -qs 'late unlanded bytes' "$NESTED_SLOT/tracked.txt"; then echo present; else echo absent; fi > "$case_dir/late-at-return"
  git -C "$NESTED_SLOT" reset -q --hard
fi
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# A return that fails on an index lock that then clears on its own is retried,
# but a lock means a process was writing in the slot: work that appeared while it
# held the lock must be proved before the slot is returned. Dirty: new bytes in a
# tracked file of the slot root refuse the return, so the provider never resets
# them, and the record and claim stay. Clean: the retry returns the slot once.
test_nested_self_clearing_lock_retry_reproves_the_slot() {
  local shape mode case_dir rc label tracked
  for shape in plain enclosing; do
    for mode in dirty clean; do
      label="nested-self-clearing-lock-$mode-$shape"
      nested_fixture "$label" "$shape" mine landed
      case_dir=$NESTED_CASE
      nested_slot_landed_tracked_file "$case_dir"
      tracked=tracked.txt
      nested_self_clearing_lock_treehouse "$case_dir" "$mode"
      rc=0
      FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 nested_run "$case_dir" || rc=$?
      if [ "$mode" = dirty ]; then
        expect_code 1 "$rc" "$label: the retry must refuse the slot's new unproved work: $(tail -3 "$case_dir/stderr")"
        ! grep -qxF "return --force $NESTED_SLOT" "$case_dir/treehouse.log" 2>/dev/null \
          || fail "$label: the slot was returned with new unproved work"
        grep -qF 'late unlanded bytes' "$NESTED_SLOT/$tracked" || fail "$label: the slot's new work was lost"
        assert_present "$case_dir/state/task-x1.meta" "$label: the task record was retired"
        assert_present "$case_dir/pool/1/.fm-slot-owner" "$label: the slot claim was dropped"
      else
        expect_code 0 "$rc" "$label: a clean self-clearing lock must let the return finish: $(tail -3 "$case_dir/stderr")"
        assert_nested_closed "$case_dir" "$label"
      fi
    done
  done
  pass "a self-clearing index-lock retry re-proves the slot: new unproved work refuses the return and is kept, a clean slot is returned once, for a plain and a prior-shape record"
}

# The busy-state retirement refuses a record whose busy generation is stale
# (bin/fm-busy-event.sh retire), and that is decidable at entry: the refusal
# must come before the endpoint close and every removal. Matching generations
# close.
test_nested_stale_busy_generation_refuses_at_entry() {
  local shape gen case_dir rc label
  for shape in plain enclosing; do
    for gen in stale matching; do
      label="nested-busy-gen-$gen-$shape"
      nested_fixture "$label" "$shape" mine landed
      case_dir=$NESTED_CASE
      printf 'busy_gen=old-1\n' >> "$case_dir/state/task-x1.meta"
      if [ "$gen" = stale ]; then printf 'new-2\n' > "$case_dir/state/task-x1.busy-gen"; else printf 'old-1\n' > "$case_dir/state/task-x1.busy-gen"; fi
      nested_snapshot "$case_dir" "$case_dir/snapshot.before"
      rc=0
      nested_run "$case_dir" || rc=$?
      if [ "$gen" = stale ]; then
        assert_nested_refused_untouched "$case_dir" "$rc" "$label" "stale busy-state gen for task-x1"
        assert_absent "$case_dir/endpoint.log" "$label: the refusal closed the endpoint"
      else
        expect_code 0 "$rc" "$label: matching busy generations must close: $(tail -3 "$case_dir/stderr")"
        assert_nested_closed "$case_dir" "$label"
      fi
    done
  done
  pass "a stale busy generation refuses a plain and a prior-shape nested close before the endpoint close and any removal; matching generations close"
}

# The shared Supabase stack is identified from the project's
# supabase/config.toml before Docker cleanup; a project_id that cannot be read
# is decidable at entry and must refuse before any lease, marker or record
# change. A valid project_id closes.
test_nested_invalid_supabase_config_refuses_at_entry() {
  local shape config case_dir rc label
  for shape in plain enclosing; do
    for config in invalid valid; do
      label="nested-supabase-$config-$shape"
      nested_fixture "$label" "$shape" mine landed
      case_dir=$NESTED_CASE
      held_plain_get_slot "$case_dir" "$NESTED_SLOT"
      nested_place_leftovers "$case_dir"
      mkdir -p "$case_dir/project/supabase"
      if [ "$config" = invalid ]; then
        printf 'project_id = ""\n' > "$case_dir/project/supabase/config.toml"
      else
        printf 'project_id = "vernant"\n' > "$case_dir/project/supabase/config.toml"
      fi
      nested_snapshot "$case_dir" "$case_dir/snapshot.before"
      rc=0
      nested_run "$case_dir" || rc=$?
      if [ "$config" = invalid ]; then
        assert_nested_refused_untouched "$case_dir" "$rc" "$label" "cannot identify the shared Supabase stack for task-x1"
        assert_absent "$case_dir/lease.log" "$label: the refused close took a lease"
      else
        expect_code 0 "$rc" "$label: a valid Supabase project_id must close: $(tail -3 "$case_dir/stderr")"
        assert_nested_closed "$case_dir" "$label"
      fi
    done
  done
  pass "an unreadable Supabase project_id refuses a plain and a prior-shape nested close before any lease, marker or record change; a valid one closes"
}

# The return-pending record is written at the reservation; a path it cannot be
# written to (a directory there) is decidable at entry and must refuse before the
# lease and before any file is moved into that directory. Once it is removed the
# same teardown closes.
test_nested_unwritable_return_pending_path_refuses_at_entry() {
  local shape case_dir rc label
  for shape in plain enclosing; do
    label="nested-return-pending-directory-$shape"
    nested_fixture "$label" "$shape" mine landed
    case_dir=$NESTED_CASE
    held_plain_get_slot "$case_dir" "$NESTED_SLOT"
    mkdir "$case_dir/state/task-x1.teardown-return-pending"
    nested_snapshot "$case_dir" "$case_dir/snapshot.before"
    rc=0
    nested_run "$case_dir" || rc=$?
    assert_nested_refused_untouched "$case_dir" "$rc" "$label" "return-pending record"
    assert_absent "$case_dir/lease.log" "$label: the refused close took a lease"
    rmdir "$case_dir/state/task-x1.teardown-return-pending"
    rc=0
    nested_run "$case_dir" || rc=$?
    expect_code 0 "$rc" "$label: the retry after the directory is removed must close: $(tail -3 "$case_dir/stderr")"
    assert_nested_closed "$case_dir" "$label"
  done
  pass "a return-pending path that is a directory refuses a plain and a prior-shape nested close before any lease or write, and the retry closes"
}

# The removability check of the previous pending-close record writes and removes
# nothing: a record whose delete is denied by an access-control entry refuses
# with the state directory unchanged, whether or not a file already sits at a
# name such a check could use; once the entry is removed the close finishes.
test_nested_delete_denied_pending_close_refuses_without_writing() {
  local shape occupant case_dir rc label record
  if [ "$(uname -s)" != Darwin ] || [ "$(id -u)" = 0 ]; then
    pass "a delete-denied pending-close record refuses without writing (skipped: needs macOS access-control entries and a non-root user)"
    return 0
  fi
  for shape in plain enclosing; do
    for occupant in absent present; do
      label="nested-pending-close-acl-$occupant-$shape"
      nested_fixture "$label" "$shape" mine landed
      case_dir=$NESTED_CASE
      held_plain_get_slot "$case_dir" "$NESTED_SLOT"
      nested_place_leftovers "$case_dir"
      record=$case_dir/state/task-x1.backlog-close
      [ "$occupant" = absent ] || printf 'sentinel bytes\n' > "$case_dir/state/.task-x1.backlog-close.removal-probe"
      chmod +a "$(id -un) deny delete" "$record"
      nested_snapshot "$case_dir" "$case_dir/snapshot.before"
      rc=0
      nested_run "$case_dir" || rc=$?
      chmod -N "$record"
      assert_nested_refused_untouched "$case_dir" "$rc" "$label" "pending-close record could not be removed at $record"
      assert_absent "$case_dir/lease.log" "$label: the refused close took a lease"
      rm -f "$case_dir/state/.task-x1.backlog-close.removal-probe"
      rc=0
      nested_run "$case_dir" || rc=$?
      expect_code 0 "$rc" "$label: the retry after the entry is removed must close: $(tail -3 "$case_dir/stderr")"
      assert_nested_closed "$case_dir" "$label"
    done
  done
  pass "a delete-denied pending-close record refuses a plain and a prior-shape nested close with the state unchanged, and the retry closes"
}

# A forced drop that refuses at entry must not create or replace the captain's
# drop record: with the previous pending-close record unremovable, data/<id>/
# captain-drop.md stays absent, or keeps its earlier bytes. An authorized drop
# that closes still retains the words (test_gate_409_recorded_case_tears_down).
test_nested_forced_entry_refusal_keeps_the_drop_record() {
  local shape prior case_dir rc label record
  if ! pending_close_immutable_supported "$TMP_ROOT"; then
    pass "a forced entry refusal keeps the drop record (skipped: this host cannot make an unremovable file with chflags uchg)"
    return 0
  fi
  for shape in plain enclosing; do
    for prior in absent present; do
      label="nested-forced-refusal-drop-record-$prior-$shape"
      nested_fixture "$label" "$shape" mine landed
      case_dir=$NESTED_CASE
      nested_place_leftovers "$case_dir"
      if [ "$prior" = present ]; then
        mkdir -p "$case_dir/data/task-x1"
        printf 'earlier words\n' > "$case_dir/data/task-x1/captain-drop.md"
      fi
      record=$case_dir/state/task-x1.backlog-close
      chflags uchg "$record"
      nested_snapshot "$case_dir" "$case_dir/snapshot.before"
      rc=0
      nested_run "$case_dir" --force || rc=$?
      chflags nouchg "$record"
      assert_nested_refused_untouched "$case_dir" "$rc" "$label" "pending-close record could not be removed at $record"
      if [ "$prior" = present ]; then
        assert_equals 'earlier words' "$(cat "$case_dir/data/task-x1/captain-drop.md")" "$label: the refusal replaced the drop record"
      else
        assert_absent "$case_dir/data/task-x1/captain-drop.md" "$label: the refusal created a drop record"
      fi
    done
  done
  pass "a forced plain or prior-shape nested close that refuses at entry neither creates nor replaces the captain's drop record"
}

# The removability check needs no hard links: where linking the record fails
# (a filesystem without hard links, or a Linux protected_hardlinks refusal), a
# record rm -f can remove still lets the close finish.
test_nested_pending_close_check_needs_no_hard_link() {
  local shape case_dir rc label
  for shape in plain enclosing; do
    label="nested-pending-close-no-hard-link-$shape"
    nested_fixture "$label" "$shape" mine landed
    case_dir=$NESTED_CASE
    nested_place_leftovers "$case_dir"
    cat > "$case_dir/fakebin/ln" <<'SH'
#!/usr/bin/env bash
case " $* " in *" -s "*) exec /bin/ln "$@" ;; esac
echo "ln: hard links are not supported here" >&2
exit 1
SH
    chmod +x "$case_dir/fakebin/ln"
    rc=0
    nested_run "$case_dir" || rc=$?
    expect_code 0 "$rc" "$label: a removable record must not refuse where hard links fail: $(tail -3 "$case_dir/stderr")"
    assert_nested_closed "$case_dir" "$label"
  done
  pass "a removable pending-close record lets a plain and a prior-shape nested close finish where hard links fail"
}

# The entry preflight covers the records later steps remove or replace: each of
# these fixed conditions refuses before any lease, endpoint close, removal or
# drop-record write, for both record shapes, and once only that condition is
# repaired the same teardown closes. busy-state-directory and
# merge-notified-directory and turn-ended-directory put a directory where
# cleanup removes a file;
# immutable-meta and immutable-return-pending make that record undeletable;
# forced runs the immutable return-pending case with the drop words, whose
# record must stay absent.
nested_preflight_case() {  # <plain|enclosing> <cause>
  local shape=$1 cause=$2 case_dir rc=0 label="nested-preflight-$2-$1" path fragment force=
  nested_fixture "$label" "$shape" mine landed
  case_dir=$NESTED_CASE
  held_plain_get_slot "$case_dir" "$NESTED_SLOT"
  nested_place_leftovers "$case_dir"
  case "$cause" in
    busy-state-directory)
      printf 'busy_gen=g1\n' >> "$case_dir/state/task-x1.meta"
      printf 'g1\n' > "$case_dir/state/task-x1.busy-gen"
      path=$case_dir/state/task-x1.busy-state; mkdir "$path"; fragment="busy-state record at $path is a directory"
      ;;
    merge-notified-directory)
      path=$case_dir/state/task-x1.pr-poll-merge-notified; mkdir "$path"; fragment="merge-notified record at $path is not a regular file"
      ;;
    turn-ended-directory)
      path=$case_dir/state/task-x1.turn-ended; mkdir "$path"; fragment="runtime record at $path is a directory"
      ;;
    immutable-meta)
      path=$case_dir/state/task-x1.meta; fragment="record could not be removed"
      ;;
    immutable-return-pending|forced)
      path=$case_dir/state/task-x1.teardown-return-pending; fragment="return-pending record path $path cannot take"
      ;;
  esac
  [ "$cause" != forced ] || force=--force
  case "$cause" in immutable-*|forced) chflags uchg "$path" ;; esac
  nested_snapshot "$case_dir" "$case_dir/snapshot.before"
  nested_run "$case_dir" $force || rc=$?
  case "$cause" in immutable-*|forced) chflags nouchg "$path" ;; esac
  assert_nested_refused_untouched "$case_dir" "$rc" "$label" "$fragment"
  assert_absent "$case_dir/lease.log" "$label: the refused close took a lease"
  assert_absent "$case_dir/endpoint.log" "$label: the refused close closed the endpoint"
  assert_absent "$case_dir/data/task-x1/captain-drop.md" "$label: the refused close wrote the drop record"
  case "$cause" in
    busy-state-directory|merge-notified-directory|turn-ended-directory) rmdir "$path" ;;
  esac
  rc=0
  nested_run "$case_dir" $force || rc=$?
  expect_code 0 "$rc" "$label: the retry after the condition is repaired must close: $(tail -3 "$case_dir/stderr")"
  assert_nested_closed "$case_dir" "$label"
}

test_nested_entry_preflight_refuses_before_any_mutation() {
  local shape cause causes="busy-state-directory merge-notified-directory turn-ended-directory"
  pending_close_immutable_supported "$TMP_ROOT" && causes="$causes immutable-meta immutable-return-pending forced"
  for shape in plain enclosing; do
    for cause in $causes; do
      nested_preflight_case "$shape" "$cause"
    done
  done
  pass "the entry preflight refuses a plain and a prior-shape nested close before any mutation ($causes), and each repaired retry closes"
}

# A tracked hook file in a clean, landed slot is not slot work: when a return
# fails on an index lock that clears on its own, the retry's reproof must not
# count teardown's own handling of that hook, so the close finishes and returns
# the slot once. A late change to the tracked hook made while the lock was held
# is new work and refuses the return, keeping the change.
test_nested_lock_retry_ignores_its_own_tracked_hook() {
  local shape mode case_dir rc label hook=.opencode/plugins/fm-turn-end.js
  for shape in plain enclosing; do
    for mode in clean late-hook-change; do
      label="nested-lock-retry-hook-$mode-$shape"
      nested_fixture "$label" "$shape" mine landed
      case_dir=$NESTED_CASE
      mkdir -p "$NESTED_SLOT/${hook%/*}"
      printf 'tracked hook\n' > "$NESTED_SLOT/$hook"
      git -C "$NESTED_SLOT" add "$hook"
      git -C "$NESTED_SLOT" -c user.email=t@t -c user.name=t commit -qm "tracked hook"
      git -C "$NESTED_SLOT" push -q origin HEAD:main
      git -C "$case_dir/project" fetch -q origin
      cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = return ] || exit 0
wt=\${@: -1}
count=\$(cat "$case_dir/return-attempts" 2>/dev/null || echo 0)
count=\$((count + 1))
printf '%s\n' "\$count" > "$case_dir/return-attempts"
if [ "\$count" = 1 ]; then
  [ "$mode" != late-hook-change ] || [ "\$wt" != "$NESTED_SLOT" ] || printf 'late hook change\n' >> "$NESTED_SLOT/$hook"
  echo "fatal: Unable to create '\$wt/.git/index.lock': File exists." >&2
  exit 128
fi
[ "\$wt" != "$NESTED_SLOT" ] || git -C "$NESTED_SLOT" reset -q --hard
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
      chmod +x "$case_dir/fakebin/treehouse"
      rc=0
      FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 nested_run "$case_dir" || rc=$?
      if [ "$mode" = clean ]; then
        expect_code 0 "$rc" "$label: a clean slot with a tracked hook must close on the retry: $(tail -3 "$case_dir/stderr")"
        assert_nested_closed "$case_dir" "$label"
      else
        expect_code 1 "$rc" "$label: a late change to the tracked hook must refuse the return: $(tail -3 "$case_dir/stderr")"
        ! grep -qxF "return --force $NESTED_SLOT" "$case_dir/treehouse.log" 2>/dev/null || fail "$label: the slot was returned"
        grep -qF 'late hook change' "$NESTED_SLOT/$hook" || fail "$label: the late hook change was lost"
        assert_present "$case_dir/state/task-x1.meta" "$label: the task record was retired"
      fi
    done
  done
  pass "a lock retry closes a clean slot with a tracked hook and refuses a late change to it, for a plain and a prior-shape record"
}

# The return-pending record is written by renaming over its path, which
# replaces a link, not the link's target. A link to a regular file inside the
# state directory is therefore accepted and the target keeps its bytes; a
# dangling link, a link to a directory and a link to a regular file outside the
# state directory refuse before any mutation, and the target is unchanged.
test_nested_return_pending_link_shapes() {
  local shape form case_dir rc label marker target
  for shape in plain enclosing; do
    for form in inside dangling directory outside; do
      label="nested-return-pending-link-$form-$shape"
      nested_fixture "$label" "$shape" mine landed
      case_dir=$NESTED_CASE
      held_plain_get_slot "$case_dir" "$NESTED_SLOT"
      marker=$case_dir/state/task-x1.teardown-return-pending
      case "$form" in
        inside) target=$case_dir/state/return-pending-sentinel; printf 'sentinel\n' > "$target" ;;
        dangling) target=$case_dir/state/no-such-record ;;
        directory) target=$case_dir/state/return-pending-dir; mkdir "$target" ;;
        outside) target=$case_dir/outside-sentinel; printf 'sentinel\n' > "$target" ;;
      esac
      ln -s "$target" "$marker"
      nested_snapshot "$case_dir" "$case_dir/snapshot.before"
      rc=0
      nested_run "$case_dir" || rc=$?
      if [ "$form" = inside ]; then
        expect_code 0 "$rc" "$label: a link to a regular file in the state directory must close: $(tail -3 "$case_dir/stderr")"
        assert_nested_closed "$case_dir" "$label"
        assert_equals sentinel "$(cat "$target")" "$label: the link target changed"
      else
        assert_nested_refused_untouched "$case_dir" "$rc" "$label" "return-pending record path $marker cannot take"
        assert_absent "$case_dir/lease.log" "$label: the refused close took a lease"
        [ -L "$marker" ] || fail "$label: the refusal replaced the link"
        [ "$form" != outside ] || assert_equals sentinel "$(cat "$target")" "$label: the outside target changed"
        rm -f "$marker"
        rc=0
        nested_run "$case_dir" || rc=$?
        expect_code 0 "$rc" "$label: the retry after the link is removed must close: $(tail -3 "$case_dir/stderr")"
        assert_nested_closed "$case_dir" "$label"
      fi
    done
  done
  pass "a return-pending link to a regular file in the state directory closes with its target unchanged; dangling, directory and outside links refuse before any mutation, and each retry without the link closes"
}

# A forced drop whose slot lease fails at the reservation refuses with the
# captain's drop record still absent: the words are written only after the
# preflight and the reservation, just before the first discard. Once the lease
# works, the same forced teardown closes and retains the words.
test_nested_forced_drop_record_follows_the_reservation() {
  local shape case_dir rc label
  for shape in plain enclosing; do
    label="nested-forced-drop-after-reservation-$shape"
    nested_fixture "$label" "$shape" mine landed
    case_dir=$NESTED_CASE
    held_plain_get_slot "$case_dir" "$NESTED_SLOT"
    : > "$case_dir/lease-fails"
    rc=0
    nested_run "$case_dir" --force || rc=$?
    expect_code 1 "$rc" "$label: a failed lease must refuse: $(tail -3 "$case_dir/stderr")"
    assert_absent "$case_dir/data/task-x1/captain-drop.md" "$label: the refused close wrote the drop record"
    assert_present "$NESTED_COPY/.git" "$label: the refused close removed the nested copy"
    assert_present "$case_dir/state/task-x1.meta" "$label: the refused close retired the task record"
    rm -f "$case_dir/lease-fails"
    rc=0
    nested_run "$case_dir" --force || rc=$?
    expect_code 0 "$rc" "$label: the retry with a working lease must close: $(tail -3 "$case_dir/stderr")"
    assert_nested_closed "$case_dir" "$label"
    cmp -s "$FM_TEST_DROP_WORDS" "$case_dir/data/task-x1/captain-drop.md" || fail "$label: the closing run did not retain the captain's words"
  done
  pass "a forced plain or prior-shape nested close whose lease fails leaves no drop record, and the working retry retains the words and closes"
}

# A record whose worktree= is an alias (a link outside the slot to the nested
# copy) must recover exactly like one that names the copy's own path. The first
# teardown removes the copy and then stops at the slot's late work; with that
# work committed but not landed, a re-run proves the slot again and refuses,
# keeping the record, the claim and the return-pending record and returning
# nothing - with or without a recorded merged PR, which proves the copy but not
# the slot; once the work lands, a re-run returns the slot and retires both.
test_nested_alias_worktree_recovers_like_its_physical_path() {
  local case_dir rc lock pr label alias
  for pr in none merged; do
    label="nested-alias-rerun-$pr"
    nested_fixture "$label" plain mine landed
    case_dir=$NESTED_CASE
    alias=$case_dir/alias-copy
    ln -s "$NESTED_COPY" "$alias"
    sed -i.bak "s#^worktree=.*#worktree=$alias#" "$case_dir/state/task-x1.meta"
    rm -f "$case_dir/state/task-x1.meta.bak"
    if [ "$pr" = merged ]; then
      printf '%s\n' 'pr=https://github.com/example/repo/pull/7' "pr_head=$(git -C "$NESTED_COPY" rev-parse HEAD)" >> "$case_dir/state/task-x1.meta"
      add_gh_pr_merged_for_head "$case_dir" "$(git -C "$NESTED_COPY" rev-parse HEAD)"
    fi
    stale_lock_late_work_treehouse "$case_dir"
    lock=$(git_index_lock_path "$NESTED_SLOT")
    : > "$lock"
    touch -t 200001010000 "$lock"
    rc=0
    FM_HOME="$case_dir/home" FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$label: the first teardown must stop at the slot's late work: $(cat "$case_dir/stderr")"
    assert_absent "$NESTED_COPY" "$label: the first teardown had not yet removed the nested copy"
    assert_present "$case_dir/state/task-x1.teardown-return-pending" "$label: the first teardown left no return-pending record"

    git -C "$NESTED_SLOT" add late.txt
    git -C "$NESTED_SLOT" commit -qm "late slot work"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
    expect_code 1 "$rc" "$label: a re-run must prove the slot again: $(cat "$case_dir/stderr2")"
    assert_grep "claimed pool slot $NESTED_SLOT" "$case_dir/stderr2" "$label: the re-run refusal did not name the slot"
    assert_present "$case_dir/state/task-x1.meta" "$label: the re-run retired the record with the slot unproved"
    assert_present "$case_dir/state/task-x1.teardown-return-pending" "$label: the re-run retired the return-pending record"
    assert_present "$case_dir/pool/1/.fm-slot-owner" "$label: the re-run dropped the slot claim"
    assert_absent "$case_dir/treehouse.log" "$label: the re-run returned the unproved slot"

    git -C "$NESTED_SLOT" push -q origin HEAD:main
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout3" 2> "$case_dir/stderr3" || rc=$?
    expect_code 0 "$rc" "$label: a re-run with the slot's work landed must finish: $(cat "$case_dir/stderr3")"
    assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" "$label: the landed slot was not returned"
    assert_absent "$case_dir/pool/1/.fm-slot-owner" "$label: the slot claim survived the task"
    assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
    assert_absent "$case_dir/state/task-x1.teardown-return-pending" "$label: the return-pending record survived"
  done
  pass "a record naming the nested copy through an alias recovers like its physical path, with and without a recorded merged PR"
}

# The shared status manifest is rewritten when the task's status is retired,
# after the endpoint close; a manifest that is a directory is decidable at entry
# and refuses before any lease, removal, marker write or endpoint close, for
# both record shapes; once it is removed the same teardown closes.
test_nested_status_manifest_directory_refuses_at_entry() {
  local shape case_dir rc label manifest
  for shape in plain enclosing; do
    label="nested-status-manifest-directory-$shape"
    nested_fixture "$label" "$shape" mine landed
    case_dir=$NESTED_CASE
    held_plain_get_slot "$case_dir" "$NESTED_SLOT"
    nested_place_leftovers "$case_dir"
    manifest=$case_dir/state/.status-presentation-cursor
    mkdir "$manifest"
    nested_snapshot "$case_dir" "$case_dir/snapshot.before"
    rc=0
    nested_run "$case_dir" || rc=$?
    assert_nested_refused_untouched "$case_dir" "$rc" "$label" "shared status manifest $manifest cannot be retired"
    assert_absent "$case_dir/lease.log" "$label: the refused close took a lease"
    assert_absent "$case_dir/endpoint.log" "$label: the refused close closed the endpoint"
    rmdir "$manifest"
    rc=0
    nested_run "$case_dir" || rc=$?
    expect_code 0 "$rc" "$label: the retry after the directory is removed must close: $(tail -3 "$case_dir/stderr")"
    assert_nested_closed "$case_dir" "$label"
  done
  pass "a shared status manifest that is a directory refuses a plain and a prior-shape nested close before any mutation, and the retry closes"
}

# The private run directory must share a filesystem with the pool only when
# this task's claim is handed to a peer. With the pool on another filesystem, a
# prior-shape task whose peer still works in the slot removes its own copy when
# the claim names the peer, and refuses at entry, changing nothing, when the
# claim names this task and would be handed over.
# A clean, landed, unlocked nested copy in the task's own slot has no writer
# that renames into the task's data folder, so a data folder on another
# filesystem does not stop its close, for the plain and the prior record shapes.
test_cross_device_data_does_not_stop_a_clean_nested_close() {
  local shape case_dir rc label
  for shape in plain enclosing; do
    label="xdev-clean-nested-$shape"
    nested_fixture "$label" "$shape" mine landed
    case_dir=$NESTED_CASE
    teardown_test_fake_other_device "$case_dir/fakebin" "$case_dir/data"
    rc=0
    nested_run "$case_dir" || rc=$?
    expect_code 0 "$rc" "$label: a clean nested close with no data writer must complete: $(tail -3 "$case_dir/stderr")"
    assert_nested_closed "$case_dir" "$label"
  done
  pass "a data folder on another filesystem does not stop a clean nested close that writes nothing there"
}

test_cross_device_pool_is_checked_only_for_a_claim_handoff() {
  local claim case_dir rc label peer
  for claim in peer mine; do
    label="xdev-pool-claim-$claim"
    nested_fixture "$label" enclosing mine landed
    case_dir=$NESTED_CASE
    peer="$NESTED_SLOT/.claude/worktrees/peer"
    git -C "$case_dir/project" worktree add -q -b fm/peer "$peer" main
    fm_write_meta "$case_dir/state/peer.meta" \
      "window=firstmate:fm-peer" "endpoint_task_id=peer" \
      "worktree=$peer" "branch=fm/peer" "project=$case_dir/project" \
      "kind=ship" "spawn_gen=peer-gen" "prior_worktree=$NESTED_SLOT"
    [ "$claim" = mine ] || printf 'task=peer\nhome=%s\n' "$case_dir/home" > "$case_dir/pool/1/.fm-slot-owner"
    teardown_test_fake_other_device "$case_dir/fakebin" "$(cd "$case_dir/pool" && pwd -P)"
    nested_snapshot "$case_dir" "$case_dir/before"
    rc=0
    nested_run "$case_dir" || rc=$?
    if [ "$claim" = peer ]; then
      expect_code 0 "$rc" "$label: a claim naming the peer needs no rename into the pool: $(tail -3 "$case_dir/stderr")"
      assert_absent "$NESTED_COPY" "$label: the task's own copy survived"
      assert_absent "$case_dir/state/task-x1.meta" "$label: the task record survived"
      assert_present "$peer/.git" "$label: the peer's copy was removed"
      grep -Fxq "task=peer" "$case_dir/pool/1/.fm-slot-owner" || fail "$label: the peer's claim changed"
    else
      expect_code 1 "$rc" "$label: a claim handoff across filesystems must refuse"
      assert_grep "are not on one filesystem" "$case_dir/stderr" "$label: the refusal did not name the filesystem split"
      nested_snapshot "$case_dir" "$case_dir/after"
      cmp -s "$case_dir/before" "$case_dir/after" \
        || fail "$label: the refusal changed the world: $(diff "$case_dir/before" "$case_dir/after" | head -10)"
      [ -z "$(find "$case_dir/state" -maxdepth 1 -name '.teardown-run.*')" ] || fail "$label: the refusal left its private run directory"
    fi
  done
  pass "with the pool on another filesystem, a teardown routes when the claim names the peer and refuses at entry when it must hand its own claim over"
}

# With no busy generation recorded or armed, retire_busy_state removes nothing,
# so a directory at the busy-state path does not stop a prior-shape ship or a
# scout: both close, as on the base.
test_inactive_busy_state_path_does_not_refuse() {
  local kind case_dir rc label
  for kind in ship scout; do
    label="inactive-busy-state-$kind"
    nested_fixture "$label" enclosing mine landed
    case_dir=$NESTED_CASE
    if [ "$kind" = scout ]; then
      sed -i.bak 's/^kind=ship$/kind=scout/' "$case_dir/state/task-x1.meta"
      rm -f "$case_dir/state/task-x1.meta.bak"
      prepare_scout_teardown "$case_dir"
    fi
    mkdir "$case_dir/state/task-x1.busy-state"
    rc=0
    nested_run "$case_dir" || rc=$?
    expect_code 0 "$rc" "$label: an inactive busy-state path must not refuse: $(tail -3 "$case_dir/stderr")"
    assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
  done
  pass "a busy-state path with no generation does not stop a prior-shape ship or a scout"
}

# A return-pending record from an earlier run that names a pool slot the task
# still claims is never retired with the task record while that slot stays
# claimed: here the record's copy is gone and its worktree= no longer leads to
# the slot, and a recorded merged PR proves the copy, so nothing in this run
# would return the slot. The teardown refuses and keeps the record, the
# return-pending record and the claim, whether that record is a regular file or
# a symbolic link to one, which does not prove the slot settled. Plain record
# only; it checks those records and the claim, not a full snapshot.
test_owed_return_pending_slot_is_never_retired() {
  local case_dir rc label head form
  for form in regular link; do
    label="owed-return-pending-slot-$form"
    nested_fixture "$label" plain mine landed
    case_dir=$NESTED_CASE
    head=$(git -C "$NESTED_COPY" rev-parse HEAD)
    git -C "$case_dir/project" worktree remove --force "$NESTED_COPY"
    sed -i.bak "s#^worktree=.*#worktree=$case_dir/elsewhere/gone-copy#" "$case_dir/state/task-x1.meta"
    rm -f "$case_dir/state/task-x1.meta.bak"
    printf '%s\n' 'pr=https://github.com/example/repo/pull/7' "pr_head=$head" >> "$case_dir/state/task-x1.meta"
    add_gh_pr_merged_for_head "$case_dir" "$head"
    if [ "$form" = regular ]; then
      printf 'spawn_gen=teardown-test-task-x1\nslot=%s\n' "$NESTED_SLOT" > "$case_dir/state/task-x1.teardown-return-pending"
    else
      printf 'spawn_gen=teardown-test-task-x1\nslot=%s\n' "$NESTED_SLOT" > "$case_dir/state/return-pending-target"
      ln -s return-pending-target "$case_dir/state/task-x1.teardown-return-pending"
    fi
    rc=0
    nested_run "$case_dir" || rc=$?
    expect_code 1 "$rc" "$label: a slot still owed its return must refuse: $(tail -3 "$case_dir/stderr")"
    assert_grep "names pool slot $NESTED_SLOT, which task task-x1 still claims" "$case_dir/stderr" "$label: the refusal did not name the owed slot"
    [ "$form" = regular ] || assert_grep "is a symbolic link, which does not prove the slot settled" "$case_dir/stderr" "$label: the refusal did not name the linked record"
    assert_present "$case_dir/state/task-x1.meta" "$label: the task record was retired"
    { [ -e "$case_dir/state/task-x1.teardown-return-pending" ] || [ -L "$case_dir/state/task-x1.teardown-return-pending" ]; } \
      || fail "$label: the return-pending record was retired"
    assert_present "$case_dir/pool/1/.fm-slot-owner" "$label: the slot claim was dropped"
    assert_absent "$case_dir/treehouse.log" "$label: the slot was returned"
  done
  pass "a return-pending record, regular or a link, naming a slot the task still claims is kept with the task record when no route returns that slot"
}


# The plain shape gets the prior shape's disposition for every claim state and
# fixture: the same exit class, the same removals, the same number of slot
# returns and the same markers.
test_plain_nested_disposition_equals_the_prior_shape() {
  local spec name claim variant mode shape case_dir rc obs_enclosing obs_plain mismatches=
  for spec in a:other:landed:normal b:none:landed:normal c:mine:slot-unlanded:normal \
      d:mine:copy-dirty:normal e:mine:landed:force f:other:copy-unlanded:normal; do
    IFS=: read -r name claim variant mode <<< "$spec"
    for shape in enclosing plain; do
      nested_fixture "nested-pair-$name-$shape" "$shape" "$claim" "$variant"
      case_dir=$NESTED_CASE
      rc=0
      if [ "$mode" = force ]; then nested_run "$case_dir" --force || rc=$?; else nested_run "$case_dir" || rc=$?; fi
      if [ "$shape" = plain ]; then obs_plain=$(nested_observe "$case_dir" "$rc"); else obs_enclosing=$(nested_observe "$case_dir" "$rc"); fi
    done
    [ "$obs_enclosing" = "$obs_plain" ] || mismatches="$mismatches $name"
  done
  [ -z "$mismatches" ] || fail "the plain shape differs from the prior shape in fixture(s):$mismatches"
  pass "a plain nested record gets the prior shape's result for every claim state and fixture"
}

# A scout's teardown is outside the plain nested route: the same plain nested
# path, claim and clean landed copies leave a scout on the route it has without
# this change - ordinary copy cleanup, which retires the record, keeps the claim
# and returns no pool slot, only the nested copy itself.
test_scout_with_a_plain_nested_copy_keeps_its_own_route() {
  local case_dir rc=0 observed
  nested_fixture nested-scout plain mine landed
  case_dir=$NESTED_CASE
  sed -i.bak 's/^kind=ship$/kind=scout/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  grep -q '^kind=scout$' "$case_dir/state/task-x1.meta" || fail "nested-scout: the record is not a scout"
  prepare_scout_teardown "$case_dir"
  nested_run "$case_dir" || rc=$?
  observed=$(nested_observe "$case_dir" "$rc")
  case "$observed" in
    "exit=0 copy=kept claim=kept record=removed "*" returns=1 "*) ;;
    *) fail "nested-scout: a scout with a plain nested copy must keep the route it had: $observed" ;;
  esac
  ! grep -qxF "return --force $NESTED_SLOT" "$case_dir/treehouse.log" || fail "nested-scout: the scout returned the pool slot"
  grep -qxF "return --force $NESTED_COPY" "$case_dir/treehouse.log" || fail "nested-scout: the scout did not take ordinary copy cleanup"
  pass "a scout with a plain nested copy in its claimed slot keeps its own route: ordinary copy cleanup, claim kept, no slot returned"
}

# The recorded gate-409 case: a Herdr-backed ship whose current copy is nested
# in a slot it claims, with no prior_worktree= line, and the backlog-close and
# teardown-return-pending files (empty slot=) an earlier failed forced teardown
# left. With the slot root and copy landed, the forced teardown completes and
# clears both files; with the slot root's HEAD neither landed nor held, it
# refuses naming the slot and HEAD and changes nothing, those files included.
gate_409_case() {  # <landed|slot-unlanded>
  nested_fixture "gate-409-$1" plain mine "$1" .claude/worktrees/task-x1-v2
  configure_flat_herdr_teardown_case "$NESTED_CASE"
  : > "$NESTED_CASE/herdr.log"
  nested_place_leftovers "$NESTED_CASE"
  assert_present "$NESTED_CASE/state/task-x1.backlog-close" "gate-409-$1: the leftover backlog-close file was not placed"
  assert_present "$NESTED_CASE/state/task-x1.teardown-return-pending" "gate-409-$1: the leftover return-pending file was not placed"
  nested_snapshot "$NESTED_CASE" "$NESTED_CASE/snapshot.before"
}

test_gate_409_recorded_case_tears_down() {
  local case_dir rc=0
  gate_409_case landed
  case_dir=$NESTED_CASE
  nested_run "$case_dir" --force || rc=$?
  expect_code 0 "$rc" "gate-409-landed: the recorded case must tear down: $(tail -3 "$case_dir/stderr")"
  assert_nested_closed "$case_dir" gate-409-landed
  assert_present "$case_dir/herdr-closed" "gate-409-landed: the pane was not closed"
  pass "the recorded gate-409 case tears down, returns the slot and clears both leftover files"
}

test_gate_409_recorded_case_refuses_untouched_when_the_slot_is_unlanded() {
  local case_dir rc=0 slot_head
  gate_409_case slot-unlanded
  case_dir=$NESTED_CASE
  slot_head=$(git -C "$NESTED_SLOT" rev-parse HEAD)
  nested_run "$case_dir" --force || rc=$?
  assert_nested_refused_untouched "$case_dir" "$rc" gate-409-slot-unlanded \
    "claimed pool slot $NESTED_SLOT, whose HEAD $slot_head"
  assert_present "$case_dir/state/task-x1.backlog-close" "gate-409-slot-unlanded: the leftover backlog-close file was removed"
  assert_present "$case_dir/state/task-x1.teardown-return-pending" "gate-409-slot-unlanded: the leftover return-pending file was removed"
  assert_absent "$case_dir/herdr-closed" "gate-409-slot-unlanded: the pane was closed before the refusal"
  pass "the recorded gate-409 case refuses naming the slot root and its HEAD, with every file left as it was"
}

# A removed nested copy whose branch ref is gone too leaves no ref to measure.
# The forge's word on the recorded PR then settles it, as it does for any
# missing worktree: a merged recorded PR finishes with a plain re-run, returns
# the enclosing slot and records the ship as landed, never as dropped. With no
# recorded PR, or one the forge does not report merged, it still refuses and
# changes nothing.
test_nested_rerun_gone_copy_and_branch_uses_recorded_merged_pr() {
  local case_dir rc shape label
  for shape in merged no-pr not-merged; do
    label="nested-gone-branch-pr-$shape"
    make_nested_slot_case "$label" enclosing .claude/worktrees/x
    case_dir=$NESTED_CASE
    seed_backlog_in_flight "$case_dir"
    printf 'gone ship work\n' > "$NESTED_COPY/ship.txt"
    git -C "$NESTED_COPY" add ship.txt
    git -C "$NESTED_COPY" -c user.email=t@t -c user.name=t commit -qm "gone ship work"
    git -C "$case_dir/project" worktree remove --force "$NESTED_COPY"
    git -C "$case_dir/project" branch -D fm/task-x1-v2 >/dev/null
    assert_absent "$NESTED_COPY" "$label: setup did not remove the nested copy"
    if git -C "$case_dir/project" rev-parse --verify --quiet refs/heads/fm/task-x1-v2 >/dev/null; then
      fail "$label: setup did not delete the branch"
    fi
    case "$shape" in
      merged)
        append_pr_meta_url "$case_dir"
        add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/project" rev-parse HEAD)"
        ;;
      not-merged) append_pr_meta_url "$case_dir" ;;
    esac
    cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$shape" = merged ]; then
      expect_code 0 "$rc" "$label: a merged recorded PR must finish with a plain re-run: $(cat "$case_dir/stderr")"
      assert_no_grep "get the captain's own words" "$case_dir/stderr" "$label: the re-run asked for captain words for landed work"
      assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" "$label: the slot was not returned"
      assert_absent "$case_dir/pool/1/.fm-slot-owner" "$label: the slot claim survived the task"
      assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
      assert_absent "$case_dir/data/task-x1/captain-drop.md" "$label: landed work was recorded as a captain drop"
      grep -F "[x] task-x1" "$case_dir/data/backlog.md" >/dev/null || fail "$label: the backlog row was not closed"
      assert_no_grep "dropped" "$case_dir/data/backlog.md" "$label: landed work was recorded as dropped"
      assert_grep "pull/7" "$case_dir/data/backlog.md" "$label: the row does not record the merged PR"
    else
      expect_code 1 "$rc" "$label: a removed copy with no merged PR must still refuse: $(cat "$case_dir/stderr")"
      assert_grep "is already removed and its branch is not landed" "$case_dir/stderr" "$label: the refusal did not name the reason"
      cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" || fail "$label: the refusal changed the task record"
      assert_present "$case_dir/pool/1/.fm-slot-owner" "$label: the refusal dropped the slot claim"
      assert_absent "$case_dir/treehouse.log" "$label: the refusal returned the slot"
    fi
  done
  pass "a removed nested copy whose branch is gone is settled by its recorded PR: merged finishes as landed, otherwise it refuses"
}

# The landed-work test of a nested copy an earlier teardown already removed
# reads its branch ref from the project. An unlanded branch is refused and
# changes nothing, so the project's own HEAD is never mistaken for the copy's;
# the same branch passes once its content landed through a squash commit with a
# different SHA, with a plain re-run and no recorded PR.
test_nested_rerun_gone_copy_needs_its_branch_landed() {
  local case_dir rc label=nested-gone-branch
  make_nested_slot_case "$label" enclosing .claude/worktrees/x
  case_dir=$NESTED_CASE
  printf 'gone ship work\n' > "$NESTED_COPY/ship.txt"
  git -C "$NESTED_COPY" add ship.txt
  git -C "$NESTED_COPY" -c user.email=t@t -c user.name=t commit -qm "gone ship work"
  git -C "$case_dir/project" worktree remove --force "$NESTED_COPY"
  assert_absent "$NESTED_COPY" "$label: setup did not remove the nested copy"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$label: an unlanded branch of a removed copy must refuse: $(cat "$case_dir/stderr")"
  assert_grep "is already removed and its branch is not landed" "$case_dir/stderr" "$label: the refusal did not name the reason"
  assert_present "$case_dir/state/task-x1.meta" "$label: the refusal deleted the task record"
  assert_present "$case_dir/pool/1/.fm-slot-owner" "$label: the refusal dropped the slot claim"
  assert_absent "$case_dir/treehouse.log" "$label: the refusal returned the slot"

  land_on_origin_main "$case_dir" ship.txt "gone ship work"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 0 "$rc" "$label: a branch whose content landed must finish with a plain re-run: $(cat "$case_dir/stderr2")"
  assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" "$label: the slot was not returned"
  assert_absent "$case_dir/pool/1/.fm-slot-owner" "$label: the slot claim survived the task"
  assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
  pass "a removed nested copy is judged by its own branch ref: unlanded refuses, content landed by squash passes"
}

# The run record proves the nested current copy, not the slot around it. A
# slot holding a later commit of its own is measured at its own HEAD: it is
# refused until that commit is anchored or landed, and returned once it is.
test_nested_slot_is_not_proven_by_the_current_copys_pipeline_input() {
  local case_dir rc slot_head label=nested-slot-pipeline-input
  nested_pipeline_input_case "$label"
  case_dir=$NESTED_CASE
  printf 'late slot work\n' > "$NESTED_SLOT/late.txt"
  git -C "$NESTED_SLOT" add late.txt
  git -C "$NESTED_SLOT" -c user.email=t@t -c user.name=t commit -qm "late slot work"
  slot_head=$(git -C "$NESTED_SLOT" rev-parse HEAD)
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$label: the slot's own unanchored commit must stop the return: $(cat "$case_dir/stderr")"
  assert_grep "claimed pool slot $NESTED_SLOT" "$case_dir/stderr" "$label: the refusal did not name the slot"
  assert_grep "neither landed nor held" "$case_dir/stderr" "$label: the refusal did not name the reason"
  assert_no_grep "the ship deliverable is not landed" "$case_dir/stderr" "$label: the current copy's own run record did not prove it"
  assert_absent "$case_dir/treehouse.log" "$label: the unproved slot was returned"
  assert_present "$NESTED_COPY" "$label: the refusal removed the nested copy"
  [ "$(git -C "$NESTED_SLOT" rev-parse HEAD)" = "$slot_head" ] || fail "$label: the slot lost its commit"
  assert_present "$case_dir/state/task-x1.meta" "$label: the task record was removed"

  git -C "$case_dir/project" update-ref \
    "refs/fm/anchor/task-x1-$(git -C "$NESTED_SLOT" rev-parse --short HEAD)" "$slot_head"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 0 "$rc" "$label: an anchored slot around a copy its run record proves must tear down: $(cat "$case_dir/stderr2")"
  assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" "$label: the anchored slot was not returned"
  assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
  pass "the enclosing slot is measured at its own HEAD, not proven by the nested copy's pipeline-input record"
}

# A nested copy an earlier teardown already removed is judged by its branch ref
# under every landed-work proof, the run record included: a plain re-run
# finishes without --force or captain words.
test_nested_rerun_gone_copy_is_proven_by_its_pipeline_input() {
  local case_dir rc label=nested-gone-pipeline-input
  nested_pipeline_input_case "$label"
  case_dir=$NESTED_CASE
  git -C "$case_dir/project" worktree remove --force "$NESTED_COPY"
  assert_absent "$NESTED_COPY" "$label: setup did not remove the nested copy"
  rc=0
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "$label: a removed copy whose branch was the merged run's input must finish with a plain re-run: $(cat "$case_dir/stderr")"
  assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" "$label: the slot was not returned"
  assert_absent "$case_dir/pool/1/.fm-slot-owner" "$label: the slot claim survived the task"
  assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
  pass "a removed nested copy whose branch was the merged run's input is proven by the run record"
}

# Endpoint closure refuses before the reserved slot or nested copy is removed.
# A plain retry finishes once the endpoint closes, returns the slot exactly
# once and records the landed ship as landed rather than an authorized drop.
test_nested_rerun_after_endpoint_refusal_records_landed() {
  local case_dir rc mode label returns
  for mode in local-only no-mistakes; do
    label="nested-after-endpoint-refusal-$mode"
    make_nested_slot_case "$label" enclosing .claude/worktrees/x "$mode"
    case_dir=$NESTED_CASE
    seed_backlog_in_flight "$case_dir"
    stuck_endpoint_tmux "$case_dir"
    printf 'nested ship work\n' > "$NESTED_COPY/ship.txt"
    git -C "$NESTED_COPY" add ship.txt
    git -C "$NESTED_COPY" -c user.email=t@t -c user.name=t commit -qm "nested ship work"
    if [ "$mode" = local-only ]; then
      git -C "$case_dir/project" merge -q --ff-only fm/task-x1-v2
    else
      land_on_origin_main "$case_dir" ship.txt "nested ship work"
    fi
    : > "$case_dir/endpoint-stuck"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$label: the first teardown must stop at the endpoint close: $(cat "$case_dir/stderr")"
    assert_absent "$case_dir/treehouse.log" "$label: the slot was returned while its endpoint could still hold it"
    assert_present "$case_dir/pool/1/.fm-slot-owner" "$label: the reserved slot lost its claim"
    assert_present "$NESTED_COPY" "$label: the nested copy was removed before its endpoint closed"
    jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
      || fail "$label: the refused endpoint close left its slot allocatable"
    assert_present "$case_dir/state/task-x1.meta" "$label: the failed teardown deleted the record"

    rm -f "$case_dir/endpoint-stuck"
    rc=0
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
    expect_code 0 "$rc" "$label: a plain re-run must finish: $(cat "$case_dir/stderr2")"
    assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
    assert_absent "$NESTED_COPY" "$label: the retry left the nested copy in place"
    assert_absent "$case_dir/pool/1/.fm-slot-owner" "$label: the returned slot is still claimed"
    assert_absent "$case_dir/data/task-x1/captain-drop.md" "$label: landed work was recorded as a captain drop"
    grep -F "[x] task-x1" "$case_dir/data/backlog.md" >/dev/null || fail "$label: the backlog row was not closed"
    assert_no_grep "dropped" "$case_dir/data/backlog.md" "$label: landed work was recorded as dropped"
    returns=$(grep -c "^return --force $NESTED_SLOT\$" "$case_dir/treehouse.log" || true)
    assert_equals 1 "$returns" "$label: the retry must return the reserved slot exactly once"
  done
  pass "an endpoint-refused retry keeps the reservation until closure and records the nested ship landed"
}

# The stale-lock proof covers the enclosing slot only. Nested copies teardown
# itself already removed, here two of them, are not proved again, so the stale
# lock's cleanup returns the slot instead of refusing over a copy that is gone.
test_nested_post_lock_reprove_skips_removed_nested_priors() {
  local case_dir rc lock label=nested-post-lock-priors nested_y
  make_nested_slot_case "$label" enclosing .claude/worktrees/x
  case_dir=$NESTED_CASE
  nested_y="$NESTED_SLOT/.claude/worktrees/y"
  git -C "$case_dir/project" worktree add -q -b fm/task-x1-y "$nested_y" main
  printf 'prior_worktree=%s\n' "$nested_y" >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = return ] || exit 0
wt=\${@: -1}
lock=\$(git -C "\$wt" rev-parse --path-format=absolute --git-path index.lock 2>/dev/null || true)
if [ -n "\$lock" ] && [ -e "\$lock" ]; then
  echo "fatal: Unable to create '\$lock': File exists." >&2
  exit 128
fi
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  add_lsof_no_holder "$case_dir"
  lock=$(git_index_lock_path "$NESTED_SLOT")
  : > "$lock"
  touch -t 200001010000 "$lock"
  rc=0
  FM_HOME="$case_dir/home" FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "$label: the slot must be returned after the stale lock is cleared: $(cat "$case_dir/stderr")"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" "$label: the stale lock was not cleaned up"
  assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" "$label: the slot was not returned"
  assert_absent "$NESTED_COPY" "$label: the nested copy survived"
  assert_absent "$nested_y" "$label: the second nested copy survived"
  assert_absent "$case_dir/pool/1/.fm-slot-owner" "$label: the slot claim survived the task"
  assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
  pass "the post-lock proof does not refuse over nested copies teardown itself already removed"
}


teardown_test_cases=(
test_reassigned_dirty_slot_retires_only_finished_task
test_reassigned_slot_unlanded_task_refuses
test_reservation_window_reassignment_retires_records_only
test_reservation_window_reassignment_reproves_own_landing
test_enclosing_reservation_window_reassignment_leaves_claimant_slot
test_slot_claim_and_copy_ownership_table
test_reassociated_copies_are_left_in_place
test_reassociated_unlanded_copy_still_refuses
test_released_slot_record_keeps_current_copy
test_slot_named_as_another_prior_copy_refuses
test_own_prior_copies_block_only_an_unproven_pool_return
test_reverse_nested_prior_outside_claude_tears_down
test_nested_slot_stale_lock_cleanup_reproves_the_slot
test_nested_slot_reproof_refusal_is_rerunnable
test_plain_nested_copy_in_own_slot_is_removed_and_slot_returned
test_plain_nested_copy_in_own_slot_is_removed_with_force_and_drop_file
test_nested_entry_refusals_change_nothing
test_nested_pending_close_directory_refuses_at_entry_plain
test_nested_pending_close_directory_refuses_at_entry_enclosing
test_nested_pending_close_dangling_link_refuses_at_entry_plain
test_nested_pending_close_dangling_link_refuses_at_entry_enclosing
test_nested_pending_close_immutable_refuses_at_entry_plain_marker_absent
test_nested_pending_close_immutable_refuses_at_entry_plain_marker_present
test_nested_pending_close_immutable_refuses_at_entry_enclosing_marker_absent
test_nested_pending_close_immutable_refuses_at_entry_enclosing_marker_present
test_nested_read_only_pending_close_still_closes
test_pool_slot_root_unremovable_pending_close_refuses_before_lease
test_nested_self_clearing_lock_retry_reproves_the_slot
test_nested_stale_busy_generation_refuses_at_entry
test_nested_invalid_supabase_config_refuses_at_entry
test_nested_unwritable_return_pending_path_refuses_at_entry
test_nested_delete_denied_pending_close_refuses_without_writing
test_nested_forced_entry_refusal_keeps_the_drop_record
test_nested_pending_close_check_needs_no_hard_link
test_nested_entry_preflight_refuses_before_any_mutation
test_nested_lock_retry_ignores_its_own_tracked_hook
test_nested_return_pending_link_shapes
test_nested_forced_drop_record_follows_the_reservation
test_nested_alias_worktree_recovers_like_its_physical_path
test_nested_status_manifest_directory_refuses_at_entry
test_inactive_busy_state_path_does_not_refuse
test_cross_device_pool_is_checked_only_for_a_claim_handoff
test_cross_device_data_does_not_stop_a_clean_nested_close
test_owed_return_pending_slot_is_never_retired
test_plain_nested_disposition_equals_the_prior_shape
test_scout_with_a_plain_nested_copy_keeps_its_own_route
test_gate_409_recorded_case_tears_down
test_gate_409_recorded_case_refuses_untouched_when_the_slot_is_unlanded
test_nested_rerun_local_only_ship_is_recorded_landed
test_nested_rerun_gone_copy_needs_its_branch_landed
test_nested_rerun_gone_copy_and_branch_uses_recorded_merged_pr
test_nested_slot_is_not_proven_by_the_current_copys_pipeline_input
test_nested_rerun_gone_copy_is_proven_by_its_pipeline_input
test_nested_rerun_after_endpoint_refusal_records_landed
test_nested_post_lock_reprove_skips_removed_nested_priors
test_tasktmp_preserves_current_and_prior_reassociated_copies
test_tasktmp_checks_all_other_copy_fields_in_both_directions
test_secondmate_home_preserves_other_tasks_prior_copy
)

# Restore errexit before the first case of this slice to match the original combined run.
errexit_restored=false
fm_test_before_case() {
  if [ "$errexit_restored" = false ] && [ "$1" = test_reassigned_dirty_slot_retires_only_finished_task ]; then
    set -e
    errexit_restored=true
  fi
}
fm_test_run_cases "${teardown_test_cases[@]}" -- "$@"
