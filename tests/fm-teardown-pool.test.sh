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
# current copy was already removed. A re-run must still find the slot through
# the task's own prior copy, prove it again, and return it only once its work
# is landed or anchored, never retire the record and leave the slot claimed but
# unproved. --force does not waive that proof.
test_nested_slot_reproof_refusal_is_rerunnable() {
  local case_dir rc lock label=nested-reproof-rerun
  make_nested_slot_case "$label" enclosing .claude/worktrees/x
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
  pass "a plain re-run after the post-lock refusal proves the enclosing slot again and returns it once its work lands"
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

# The re-run matrix: a refusal at each phase of the nested slot return, then a
# plain re-run (no --force, no captain words) that finishes. Whatever the phase,
# the task record is never deleted while the enclosing slot is unproved and
# still claimed, and the nested copy is removed only once its phase is reached.
#   prove      the slot has uncommitted work before anything starts
#   retire     a launch agent rooted in the slot will not unload
#   pre-remove a dying process leaves work in the slot after the first proof
#   pre-copy   the same, but in the nested copy itself
#   return     the nested copy is gone and treehouse refuses the return
test_nested_rerun_matrix_refusal_at_each_phase() {
  local case_dir rc phase label pid
  for phase in prove retire pre-remove pre-copy return; do
    label="nested-matrix-$phase"
    make_nested_slot_case "$label" enclosing .claude/worktrees/x
    case_dir=$NESTED_CASE
    pid=
    case "$phase" in
      prove) printf 'slot scratch\n' > "$NESTED_SLOT/scratch.txt" ;;
      retire|pre-remove|pre-copy)
        add_fake_launchctl "$case_dir"
        mkdir -p "$NESTED_SLOT/.claude/nm/h"
        teardown_fixture_start "$NESTED_SLOT/.claude/nm/h" KILL sleep 300
        pid=$TEARDOWN_FIXTURE_PID
        sleep 0.3
        add_nm_launch_agent "$case_dir" "7a11e0${phase//-/}" "$NESTED_SLOT/.claude/nm/h" "$pid"
        ;;
      return)
        fail_switch_treehouse "$case_dir"
        : > "$case_dir/fail-return"
        ;;
    esac
    rc=0
    case "$phase" in
      retire)
        FM_HOME="$case_dir/home" FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" FAKE_LAUNCHCTL_BOOTOUT_FAILS=1 \
          run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        ;;
      pre-remove)
        FM_HOME="$case_dir/home" FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
          FAKE_LAUNCHCTL_BOOTOUT_WRITES="$NESTED_SLOT/late.txt" \
          run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        ;;
      pre-copy)
        FM_HOME="$case_dir/home" FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
          FAKE_LAUNCHCTL_BOOTOUT_WRITES="$NESTED_COPY/late.txt" \
          run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        ;;
      *)
        FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        ;;
    esac
    expect_code 1 "$rc" "$label: the first teardown must refuse: $(cat "$case_dir/stderr")"
    assert_present "$case_dir/state/task-x1.meta" "$label: the refusal deleted the task record"
    assert_present "$case_dir/pool/1/.fm-slot-owner" "$label: the refusal dropped the slot claim"
    case "$phase" in
      prove|retire|pre-remove|pre-copy)
        assert_present "$NESTED_COPY" "$label: the nested copy was removed before its phase"
        [ ! -e "$case_dir/treehouse.log" ] || fail "$label: the slot was returned"
        ;;
      return)
        assert_absent "$NESTED_COPY" "$label: the nested copy was not removed before the return failed"
        [ ! -e "$case_dir/treehouse.log" ] || fail "$label: the failed return was logged as done"
        ;;
    esac
    case "$phase" in
      prove)
        assert_grep "claimed pool slot $NESTED_SLOT" "$case_dir/stderr" "$label: the refusal did not name the slot"
        git -C "$NESTED_SLOT" add scratch.txt
        git -C "$NESTED_SLOT" -c user.email=t@t -c user.name=t commit -qm "slot scratch"
        git -C "$NESTED_SLOT" push -q origin HEAD:main
        ;;
      retire) assert_grep "still loaded" "$case_dir/stderr" "$label: the refusal did not name the unloaded agent" ;;
      pre-remove)
        assert_grep "claimed pool slot $NESTED_SLOT" "$case_dir/stderr" "$label: the refusal did not name the slot"
        assert_present "$NESTED_SLOT/late.txt" "$label: the refusal removed the slot's late work"
        git -C "$NESTED_SLOT" add late.txt
        git -C "$NESTED_SLOT" -c user.email=t@t -c user.name=t commit -qm "late slot work"
        git -C "$NESTED_SLOT" push -q origin HEAD:main
        ;;
      pre-copy)
        assert_grep "worktree $NESTED_COPY has uncommitted changes" "$case_dir/stderr" \
          "$label: the refusal did not name the nested copy's work"
        assert_present "$NESTED_COPY/late.txt" "$label: the refusal changed the nested copy"
        rm -f "$NESTED_COPY/late.txt"
        ;;
      return) rm -f "$case_dir/fail-return" ;;
    esac
    rc=0
    FM_HOME="$case_dir/home" FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
      run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
    [ -z "$pid" ] || teardown_fixture_stop "$pid"
    expect_code 0 "$rc" "$label: a plain re-run must finish: $(cat "$case_dir/stderr2")"
    assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" "$label: the re-run did not return the slot"
    assert_absent "$case_dir/pool/1/.fm-slot-owner" "$label: the slot claim survived the task"
    assert_absent "$case_dir/state/task-x1.meta" "$label: the task record was not removed"
    assert_absent "$NESTED_COPY" "$label: the nested copy survived the task"
  done
  pass "a refusal at the slot proof, the retire step, either proof before removal or the return is safe to re-run with a plain teardown"
}

# Returning the enclosing slot sweeps more than the nested current copy, so the
# safety steps run on every copy swept: a run parked on the slot's own branch is
# aborted and a task-private launch agent rooted in the slot is retired before
# the return, not left holding a fleet slot or pointing into a reset copy.
test_nested_slot_return_concludes_runs_and_agents_on_the_slot() {
  local case_dir rc pid label agent_root slot_head
  make_nested_slot_case nested-slot-safety enclosing .claude/worktrees/x
  case_dir=$NESTED_CASE
  add_fake_launchctl "$case_dir"
  agent_root="$NESTED_SLOT/.claude/nm/h"
  mkdir -p "$agent_root"
  teardown_fixture_start "$agent_root" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "nested-slot-safety: setup daemon did not start"
  label="$NM_AGENT_PREFIX.5107aa11"
  add_nm_launch_agent "$case_dir" 5107aa11 "$agent_root" "$pid"
  slot_head=$(git -C "$NESTED_SLOT" rev-parse HEAD)
  rc=0
  FM_HOME="$case_dir/home" FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$slot_head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if kill -0 "$pid" 2>/dev/null; then
    teardown_fixture_stop "$pid"
    fail "nested-slot-safety: the launch agent rooted in the returned slot survived teardown"
  fi
  expect_code 0 "$rc" "nested-slot-safety: teardown must finish: $(cat "$case_dir/stderr")"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "nested-slot-safety: the run parked on the returned slot's branch was not aborted"
  assert_grep "bootout gui/$(id -u)/$label" "$case_dir/launchctl-calls" \
    "nested-slot-safety: the launch agent rooted in the returned slot was not booted out"
  assert_present "$case_dir/data/task-x1/launchagent-backup/$label.plist" \
    "nested-slot-safety: the launch agent plist was not archived"
  assert_absent "$NESTED_COPY" "nested-slot-safety: the nested copy was not removed"
  assert_grep "return --force $NESTED_SLOT" "$case_dir/treehouse.log" "nested-slot-safety: the slot was not returned"
  pass "returning the enclosing slot aborts its parked run and retires its launch agent before the return"
}

test_shared_nested_copy_concludes_only_its_own_runtime() {
  local ownership case_dir head rc own_pid worker_pid root_pid label root_label own_survived root_survived daemon_survived late
  for ownership in duplicate own foreign late; do
    make_nested_slot_case "shared-nested-runtime-$ownership" enclosing .claude/worktrees/x
    case_dir=$NESTED_CASE
    printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"parked"}]}\n' "$NESTED_SLOT" > "$case_dir/pool/treehouse-state.json"
    fm_write_meta "$case_dir/state/parked.meta" "worktree=$NESTED_SLOT" "kind=ship"
    cp "$case_dir/state/parked.meta" "$case_dir/parked.before"
    add_fake_launchctl "$case_dir"
    mkdir -p "$NESTED_COPY/.claude/nm/h" "$NESTED_SLOT/.claude/nm/h"
    teardown_fixture_start "$NESTED_COPY/.claude/nm/h" KILL perl -e 'sleep'
    own_pid=$TEARDOWN_FIXTURE_PID
    teardown_fixture_start "$NESTED_COPY" KILL perl -e 'sleep'
    worker_pid=$TEARDOWN_FIXTURE_PID
    teardown_fixture_start "$NESTED_SLOT/.claude/nm/h" KILL perl -e 'sleep'
    root_pid=$TEARDOWN_FIXTURE_PID
    label="$NM_AGENT_PREFIX.5a11c001"
    root_label="$NM_AGENT_PREFIX.5a11c002"
    add_nm_launch_agent "$case_dir" 5a11c001 "$NESTED_COPY/.claude/nm/h" "$own_pid"
    add_nm_launch_agent "$case_dir" 5a11c002 "$NESTED_SLOT/.claude/nm/h" "$root_pid"
    if [ "$ownership" = duplicate ]; then
      fm_write_meta "$case_dir/state/other-nested.meta" "worktree=$NESTED_COPY" "kind=ship"
      cp "$case_dir/state/other-nested.meta" "$case_dir/other.before"
      cp "$case_dir/state/task-x1.meta" "$case_dir/own.before"
    fi
    late=
    if [ "$ownership" = late ]; then
      late="$NESTED_COPY/late.txt"
      cp "$case_dir/state/task-x1.meta" "$case_dir/own.before"
    fi
    head=$(git -C "$NESTED_COPY" rev-parse HEAD)
    rc=0
    FM_HOME="$case_dir/home" FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
      FM_FAKE_AXI_STATUS="$(parked_axi_status_toon "$([ "$ownership" = foreign ] && printf fm/foreign || printf fm/task-x1-v2)" "$head")" \
      FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" FAKE_LAUNCHCTL_BOOTOUT_WRITES="$late" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    own_survived=0
    root_survived=0
    daemon_survived=0
    kill -0 "$worker_pid" 2>/dev/null && own_survived=1
    kill -0 "$root_pid" 2>/dev/null && root_survived=1
    kill -0 "$own_pid" 2>/dev/null && daemon_survived=1
    teardown_fixture_stop "$worker_pid"
    teardown_fixture_stop "$own_pid"
    teardown_fixture_stop "$root_pid"
    if [ "$ownership" = duplicate ]; then
      expect_code 1 "$rc" "duplicate nested custody must refuse before any runtime cleanup: $(cat "$case_dir/stderr")"
      assert_grep 'other-nested' "$case_dir/stderr" 'the refusal must name the other nested owner'
      [ "$own_survived$root_survived$daemon_survived" = 111 ] || fail 'duplicate-copy refusal signalled a live process'
      assert_absent "$case_dir/nm-abort.log" 'duplicate-copy refusal aborted the parked run'
      assert_absent "$case_dir/state/task-x1.teardown-processes" 'duplicate-copy refusal recorded signal targets'
      assert_present "$case_dir/launchagents/$label.plist" 'duplicate-copy refusal removed the own launch agent'
      assert_present "$case_dir/launchagents/$root_label.plist" 'duplicate-copy refusal removed the root launch agent'
      assert_no_grep 'bootout' "$case_dir/launchctl-calls" 'duplicate-copy refusal unloaded a launch agent'
      cmp -s "$case_dir/own.before" "$case_dir/state/task-x1.meta" || fail 'duplicate-copy refusal changed its own record'
      cmp -s "$case_dir/other.before" "$case_dir/state/other-nested.meta" || fail 'duplicate-copy refusal changed the other nested record'
      cmp -s "$case_dir/parked.before" "$case_dir/state/parked.meta" || fail 'duplicate-copy refusal changed the parked root record'
      assert_present "$NESTED_COPY" 'duplicate-copy refusal removed the nested copy'
      assert_absent "$case_dir/treehouse.log" 'duplicate-copy refusal returned the slot'
      continue
    fi
    if [ "$ownership" = late ]; then
      expect_code 1 "$rc" "late work in the own nested copy must keep its custody: $(cat "$case_dir/stderr")"
      assert_grep "worktree $NESTED_COPY has uncommitted changes" "$case_dir/stderr" 'the refusal did not name the late work'
      assert_present "$NESTED_COPY/late.txt" 'the refusal lost the late work'
      cmp -s "$case_dir/own.before" "$case_dir/state/task-x1.meta" || fail 'late-work refusal retired or changed its own record'
      assert_grep 'task=task-x1' "$case_dir/pool/1/.fm-slot-owner" 'late-work refusal released the shared-slot claim'
      cmp -s "$case_dir/parked.before" "$case_dir/state/parked.meta" || fail 'late-work refusal changed the parked root record'
      [ "$root_survived" = 1 ] || fail "late-work refusal killed the parked root's daemon"
      assert_absent "$case_dir/treehouse.log" 'late-work refusal returned the slot'
      continue
    fi
    expect_code 0 "$rc" "$ownership: shared nested cleanup must succeed: $(cat "$case_dir/stderr")"
    [ "$own_survived" = 0 ] || fail "$ownership: the retiring task's own process survived"
    [ "$root_survived" = 1 ] || fail "$ownership: the parked root's daemon was killed"
    if [ "$ownership" = own ]; then
      assert_grep 'abort --run 01RUN' "$case_dir/nm-abort.log" 'the task-owned parked run was not concluded'
    else
      assert_absent "$case_dir/nm-abort.log" 'a foreign parked run was aborted'
    fi
    assert_grep "bootout gui/$(id -u)/$label" "$case_dir/launchctl-calls" 'the own nested launch agent was not retired'
    assert_present "$case_dir/data/task-x1/launchagent-backup/$label.plist" 'the own launch agent was not archived'
    assert_present "$case_dir/launchagents/$root_label.plist" 'the parked root launch agent was removed'
    assert_no_grep "bootout gui/$(id -u)/$root_label" "$case_dir/launchctl-calls" 'the parked root launch agent was unloaded'
    assert_present "$NESTED_COPY" 'shared cleanup removed the own nested copy'
    assert_absent "$case_dir/treehouse.log" 'shared cleanup returned the slot'
    assert_absent "$case_dir/state/task-x1.meta" 'the finished task record survived'
    cmp -s "$case_dir/parked.before" "$case_dir/state/parked.meta" || fail 'shared cleanup changed the parked record'
  done
  pass 'shared nested cleanup concludes an owned run, retires its launch agent and reaps its process, preserving the parked root, foreign runs and late work'
}

test_other_record_copy_overlap_is_component_aware() {
  local case_dir field direction rc recorded proceeds
  for field in worktree home prior_worktree; do
    for direction in ancestor descendant sibling exact; do
      case_dir=$(make_case "other-overlap-$field-$direction")
      mkdir -p "$case_dir/home/state" "$case_dir/wt/nested" "$case_dir/wt-sibling"
      write_meta "$case_dir" no-mistakes ship
      land_shippable_commit "$case_dir"
      ln -s "$case_dir/wt" "$case_dir/copy"
      cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
      case "$direction" in
        ancestor) recorded=$case_dir ;;
        descendant) recorded=$case_dir/copy/nested ;;
        sibling) recorded=$case_dir/wt-sibling ;;
        exact) recorded=$case_dir/wt ;;
      esac
      # Another task's current worktree= is refused only on an exact path match,
      # as on origin/main; home= and prior_worktree= keep the component-aware
      # overlap, so a copy nested inside or around the target still refuses.
      proceeds=0
      case "$direction" in
        sibling) proceeds=1 ;;
        ancestor|descendant) [ "$field" != worktree ] || proceeds=1 ;;
      esac
      fm_write_meta "$case_dir/state/other.meta" "$field=$recorded" "kind=ship"
      cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
      rc=0
      FM_HOME="$case_dir/home" FM_TEST_TREEHOUSE_LOG="$case_dir/treehouse.log" \
        run_teardown "$case_dir" --force --drop-file "$FM_TEST_DROP_WORDS" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      if [ "$proceeds" = 1 ]; then
        expect_code 0 "$rc" "other-overlap-$field-$direction: this custody must not block cleanup"
        assert_absent "$case_dir/state/task-x1.meta" "other-overlap-$field-$direction: task was not retired"
      else
        expect_code 1 "$rc" "other-overlap-$field-$direction: overlapping custody must refuse cleanup"
        assert_grep "is also task other's recorded $field" "$case_dir/stderr" \
          "other-overlap-$field-$direction: refusal did not identify the conflicting field"
        cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" \
          || fail "other-overlap-$field-$direction: refusal changed metadata"
        assert_absent "$case_dir/treehouse.log" "other-overlap-$field-$direction: cleanup returned a copy"
      fi
      assert_present "$case_dir/state/other.meta" "other-overlap-$field-$direction: other record changed"
    done
  done
  pass "other home and prior custody overlap refuses in both directions, another task's worktree only on an exact match, and siblings never"
}

test_forced_descendant_preserved_copy_refuses_before_cleanup() {
  local case_dir home prior where rc
  for where in child home; do
    case_dir=$(make_case "descendant-prior-$where")
    write_meta "$case_dir" local-only secondmate
    configure_secondmate_with_tmux_children "$case_dir"
    home=$case_dir/secondmate-home
    if [ "$where" = child ]; then
      prior=$case_dir/child-b-wt/prior
    else
      prior=$home/preserved-copy
    fi
    mkdir -p "$prior"
    printf 'preserved child work\n' > "$prior/scratch.txt"
    printf 'prior_worktree=%s\n' "$prior" >> "$home/state/child-b.meta"
    cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
    cp "$home/state/child-b.meta" "$case_dir/child.before"
    cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
    rc=0
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "descendant-prior-$where: cascade must preserve child prior custody"
    assert_grep "preserved prior_worktree" "$case_dir/stderr" \
      "descendant-prior-$where: refusal did not identify preserved custody"
    cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" \
      || fail "descendant-prior-$where: parent metadata changed"
    cmp -s "$case_dir/child.before" "$home/state/child-b.meta" \
      || fail "descendant-prior-$where: child metadata changed"
    assert_present "$home/state/child-a.meta" "descendant-prior-$where: earlier child was retired"
    assert_absent "$case_dir/treehouse.log" "descendant-prior-$where: earlier child copy was returned"
    assert_grep "preserved child work" "$prior/scratch.txt" "descendant-prior-$where: prior work changed"
  done
  pass "forced descendant admission preserves prior copies inside child worktrees and retiring homes before any cascade cleanup"
}

test_forced_nested_secondmate_admits_only_locked_current_copies() {
  local shape case_dir home child_home wt sibling_wt rc field owner_home owner_meta slot_head
  for shape in admitted prior external-worktree external-home external-prior_worktree unavailable reassigned-root reassigned-peer reassigned-inside; do
    case_dir=$(make_case "nested-home-admission-$shape")
    home="$case_dir/secondmate-home"
    child_home="$case_dir/disjoint-child-home"
    wt="$child_home/pool/1/project"
    case "$shape" in
      reassigned-root|reassigned-peer) wt="$case_dir/external-pool/1/project" ;;
    esac
    mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" \
      "$child_home/state" "$child_home/data" "$child_home/config" "$child_home/projects"
    mkdir -p "$case_dir/home/state" "$case_dir/home/data" "$case_dir/test-root"
    ln -s "$ROOT/bin" "$case_dir/test-root/bin"
    printf 'task-x1\n' > "$home/.fm-secondmate-home"
    printf 'nested-sm\n' > "$child_home/.fm-secondmate-home"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$case_dir/home" > "$home/.fm-secondmate-parent"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$home" > "$child_home/.fm-secondmate-parent"
    printf '# Secondmates\n- task-x1 - parent fixture (home: %s; scope: fixture; projects: alpha; added 2026-10-08)\n' \
      "$home" > "$case_dir/home/data/secondmates.md"
    printf '# Secondmates\n- nested-sm - child fixture (home: %s; scope: fixture; projects: alpha; added 2026-10-08)\n' \
      "$child_home" > "$home/data/secondmates.md"
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$home" "project=$case_dir/project" "kind=secondmate" "mode=local-only"
    printf 'home=%s\n' "$home" >> "$case_dir/state/task-x1.meta"
    fm_write_meta "$home/state/nested-sm.meta" \
      "window=firstmate:fm-nested-sm" "endpoint_task_id=nested-sm" \
      "worktree=$child_home" "home=$child_home" "project=$case_dir/project" \
      "kind=secondmate" "mode=local-only"
    mkdir -p "${wt%/*}"
    git -C "$case_dir/project" worktree add -q -b fm/grandchild "$wt" main
    printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"grandchild"}]}\n' \
      "$wt" > "${wt%/*/*}/treehouse-state.json"
    printf 'task=grandchild\nhome=%s\n' "$child_home" > "${wt%/*}/.fm-slot-owner"
    fm_write_meta "$child_home/state/grandchild.meta" \
      "window=firstmate:fm-grandchild" "endpoint_task_id=grandchild" \
      "worktree=$wt" "project=$case_dir/project" "kind=ship" "mode=local-only"
    sibling_wt="$case_dir/sibling-wt"
    git -C "$case_dir/project" worktree add -q -b fm/z-sibling "$sibling_wt" main
    fm_write_meta "$home/state/z-sibling.meta" \
      "window=firstmate:fm-z-sibling" "endpoint_task_id=z-sibling" \
      "worktree=$sibling_wt" "project=$case_dir/project" "kind=ship" "mode=local-only"
    case "$shape" in
      prior) printf 'prior_worktree=%s\n' "$wt" >> "$child_home/state/grandchild.meta" ;;
      unavailable)
        printf -- '- unavailable - unrelated fixture (home: %s; scope: fixture; projects: alpha; added 2026-10-08)\n' \
          "$case_dir/missing-home" >> "$case_dir/home/data/secondmates.md"
        ;;
      external-*)
        field=${shape#external-}
        fm_write_meta "$case_dir/home/state/external.meta" "$field=$wt" "kind=ship"
        ;;
      reassigned-*)
        owner_home="$case_dir/home"
        if [ "$shape" = reassigned-peer ]; then
          owner_home="$case_dir/peer-home"
          mkdir -p "$owner_home/state" "$owner_home/data"
          printf -- '- peer-sm - peer fixture (home: %s; scope: fixture; projects: alpha; added 2026-10-08)\n' \
            "$owner_home" >> "$case_dir/home/data/secondmates.md"
        fi
        owner_meta="$owner_home/state/external.meta"
        fm_write_meta "$owner_meta" "worktree=$wt" "project=$case_dir/project" "kind=ship"
        printf 'task=external\nhome=%s\n' "$owner_home" > "${wt%/*}/.fm-slot-owner"
        cp "$owner_meta" "$case_dir/owner-meta.before"
        cp "${wt%/*}/.fm-slot-owner" "$case_dir/slot-owner.before"
        slot_head=$(git -C "$wt" rev-parse HEAD)
        mkdir -p "$wt/.claude"
        printf 'claimant hook bytes\n' > "$wt/.claude/settings.local.json"
        printf 'claimant uncommitted work\n' > "$wt/scratch.txt"
        ;;
    esac
    printf 'retained bytes\n' > "$child_home/retained.txt"
    cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  kill-*)
    printf '%s\n' "\$*" >> "$case_dir/kill.log"
    if [ "\${3:-}" = '=firstmate:=fm-z-sibling' ]; then
      cp "$home/data/secondmates.md" "$case_dir/registry-after-child.md"
    fi
    ;;
esac
exit 0
SH
    cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
    rc=0
    FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/test-root" \
      FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
      FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
      "$TEARDOWN" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$shape" = admitted ] || [ "$shape" = reassigned-root ] || [ "$shape" = reassigned-peer ]; then
      expect_code 0 "$rc" "locked nested home cleanup should complete: $(cat "$case_dir/stderr")"
      assert_absent "$home" "nested cleanup retained its parent home"
      assert_absent "$child_home" "nested cleanup retained its disjoint child home"
      assert_absent "$case_dir/state/task-x1.meta" "nested cleanup retained the parent record"
      assert_grep "kill-window -t =firstmate:=fm-grandchild" "$case_dir/kill.log" "nested cleanup did not close the admitted task: $(cat "$case_dir/kill.log")"
      if [ "$shape" = admitted ]; then
        assert_grep "$wt" "$case_dir/treehouse.log" "nested cleanup did not return the admitted pool copy"
      else
        assert_no_grep "$wt" "$case_dir/treehouse.log" "nested cleanup returned the reassigned pool copy"
        cmp -s "$case_dir/slot-owner.before" "${wt%/*}/.fm-slot-owner" || fail "nested cleanup changed the claimant's slot owner"
        cmp -s "$case_dir/owner-meta.before" "$owner_meta" || fail "nested cleanup changed the claimant's record"
        [ "$slot_head" = "$(git -C "$wt" rev-parse HEAD)" ] || fail "nested cleanup changed the claimant's HEAD"
        assert_grep 'claimant uncommitted work' "$wt/scratch.txt" "nested cleanup changed the claimant's work"
        assert_grep 'claimant hook bytes' "$wt/.claude/settings.local.json" "nested cleanup removed the claimant's hooks"
      fi
      assert_grep "kill-window -t =firstmate:=fm-z-sibling" "$case_dir/kill.log" "nested cleanup stopped before the later sibling"
      assert_grep "$sibling_wt" "$case_dir/treehouse.log" "nested cleanup did not return the later sibling copy"
      assert_present "$case_dir/registry-after-child.md" "later sibling did not observe the owning registry"
      assert_no_grep '- nested-sm ' "$case_dir/registry-after-child.md" "removed child retained its owning registration"
      assert_no_grep '- task-x1 ' "$case_dir/home/data/secondmates.md" "removed parent retained its owning registration"
      cp "$case_dir/kill.log" "$case_dir/kill.before-retry"
      cp "$case_dir/treehouse.log" "$case_dir/treehouse.before-retry"
      rc=0
      FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$case_dir/test-root" \
        FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
        FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
        "$TEARDOWN" task-x1 --force > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
      expect_code 1 "$rc" "retry must report the already-retired task rather than stale custody"
      assert_grep 'task record is not a regular file' "$case_dir/retry.stderr" "retry encountered incomplete retirement"
      cmp -s "$case_dir/kill.before-retry" "$case_dir/kill.log" || fail "retry closed another endpoint"
      cmp -s "$case_dir/treehouse.before-retry" "$case_dir/treehouse.log" || fail "retry returned another copy"
    else
      expect_code 1 "$rc" "preserved nested custody must refuse: $shape"
      if [ "$shape" = unavailable ]; then
        assert_grep 'registered local Firstmate home is unavailable' "$case_dir/stderr" "cleanup skipped an unrelated unavailable home"
      else
        assert_grep 'custody overlaps' "$case_dir/stderr" "nested refusal missed preserved custody"
      fi
      assert_grep 'retained bytes' "$child_home/retained.txt" "nested refusal removed preserved home bytes"
      assert_present "$home/state/nested-sm.meta" "nested refusal removed the child record"
      assert_present "$child_home/state/grandchild.meta" "nested refusal removed the grandchild record"
      assert_absent "$case_dir/kill.log" "nested refusal closed an endpoint"
      assert_absent "$case_dir/treehouse.log" "nested refusal returned a copy"
    fi
  done
  pass "recursive retirement admits locked copies, preserves reassigned external slots, and refuses overlapping home custody"
}

test_forced_descendant_reassociated_copy_preserves_checkout_and_storage() {
  local shape case_dir home project storage current prior current_head prior_head current_branch prior_branch common rc hook
  for shape in prior-storage current-storage home-storage prior-storage-in-sibling current-inside-home outside; do
    case_dir=$(make_case "descendant-reassociated-$shape")
    write_meta "$case_dir" local-only secondmate
    configure_secondmate_with_tmux_children "$case_dir"
    home=$case_dir/secondmate-home
    project=$case_dir/project
    current=$case_dir/child-b-wt
    prior=$case_dir/prior-A
    storage=$home/P
    [ "$shape" != prior-storage-in-sibling ] || storage=$case_dir/child-a-wt/P
    if [ "$shape" = prior-storage ] || [ "$shape" = current-storage ] || [ "$shape" = home-storage ] || [ "$shape" = prior-storage-in-sibling ]; then
      git clone -q "$case_dir/origin.git" "$storage"
    fi
    if [ "$shape" = prior-storage ] || [ "$shape" = prior-storage-in-sibling ]; then
      git -C "$storage" worktree add -q -b fm/prior-A "$prior" main
    else
      git -C "$project" worktree add -q -b fm/prior-A "$prior" main
    fi
    if [ "$shape" = current-storage ]; then
      project=$storage
      current=$case_dir/current-B
      git -C "$project" worktree add -q -b fm/current-B "$current" main
    elif [ "$shape" = current-inside-home ]; then
      current=$home/current-B
      git -C "$project" worktree move "$case_dir/child-b-wt" "$current"
    fi
    fm_write_meta "$home/state/child-b.meta" \
      "window=firstmate:fm-child-b" "endpoint_task_id=child-b" \
      "worktree=$current" "project=$project" "kind=ship" "mode=local-only" \
      "prior_worktree=$prior"
    if [ "$shape" = home-storage ]; then
      git -C "$storage" worktree add -q -b fm/copy-home "$case_dir/copy-home" main
      printf 'home=%s\n' "$case_dir/copy-home" >> "$home/state/child-b.meta"
    fi
    mkdir -p "$current/.claude" "$current/.opencode/plugins" "$case_dir/hooks.before"
    for hook in .claude/settings.local.json .opencode/plugins/fm-turn-end.js \
      .opencode/plugins/fm-busy-state.js .fm-grok-turnend .fm-kimi-turnend; do
      printf 'preserved B hook %s\n' "$hook" > "$current/$hook"
      cp "$current/$hook" "$case_dir/hooks.before/${hook##*/}"
    done
    printf 'unlanded B bytes\n' > "$current/scratch.txt"
    printf 'unlanded A bytes\n' > "$prior/scratch.txt"
    current_head=$(git -C "$current" rev-parse HEAD)
    prior_head=$(git -C "$prior" rev-parse HEAD)
    current_branch=$(git -C "$current" symbolic-ref HEAD)
    prior_branch=$(git -C "$prior" symbolic-ref HEAD)
    git -C "$prior" update-ref refs/fm/reassociation/preserved-A "$prior_head"
    git -C "$current" status --porcelain --untracked-files=all > "$case_dir/current-status.before"
    git -C "$prior" status --porcelain --untracked-files=all > "$case_dir/prior-status.before"
    cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
    cp "$home/state/child-b.meta" "$case_dir/child.before"
    cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in kill-*) printf '%s\n' "\$*" >> "$case_dir/kill.log" ;; esac
exit 0
SH
    cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
    rc=0
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$shape" = outside ]; then
      expect_code 0 "$rc" "disjoint reassociated child retirement must succeed: $(cat "$case_dir/stderr")"
      assert_absent "$home" "reassociated retirement retained the safe home"
      assert_absent "$case_dir/state/task-x1.meta" "reassociated retirement retained the parent record"
      assert_grep 'kill-window -t =firstmate:=fm-child-b' "$case_dir/kill.log" "reassociated child endpoint was not retired"
      assert_grep "$case_dir/child-a-wt" "$case_dir/treehouse.log" "ordinary sibling copy was not returned"
      assert_no_grep "$current" "$case_dir/treehouse.log" "reassociated current was returned"
      assert_no_grep "$prior" "$case_dir/treehouse.log" "reassociated prior was returned"
    else
      expect_code 1 "$rc" "forced home cleanup must refuse preserved $shape custody"
      assert_grep 'custody overlaps' "$case_dir/stderr" "reassociated refusal omitted custody"
      if [ "$shape" != current-inside-home ]; then
        common=$(cd "$storage/.git" && pwd -P)
        assert_grep "Git common-dir storage $common" "$case_dir/stderr" "refusal did not protect shared Git storage"
      else
        assert_grep 'recorded worktree' "$case_dir/stderr" "retiring record's preserved current was skipped"
      fi
      cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" || fail "storage refusal changed parent metadata"
      cmp -s "$case_dir/child.before" "$home/state/child-b.meta" || fail "storage refusal changed child metadata"
      assert_present "$home/state/child-a.meta" "storage refusal retired an earlier child"
      assert_absent "$case_dir/kill.log" "storage refusal closed an endpoint"
      assert_absent "$case_dir/treehouse.log" "storage refusal returned a copy"
    fi
    [ "$current_head" = "$(git -C "$current" rev-parse HEAD)" ] || fail "retirement changed B HEAD"
    [ "$prior_head" = "$(git -C "$prior" rev-parse HEAD)" ] || fail "retirement changed A HEAD"
    [ "$current_branch" = "$(git -C "$current" symbolic-ref HEAD)" ] || fail "retirement detached B branch"
    [ "$prior_branch" = "$(git -C "$prior" symbolic-ref HEAD)" ] || fail "retirement detached A branch"
    [ "$prior_head" = "$(git -C "$prior" rev-parse refs/fm/reassociation/preserved-A)" ] || fail "retirement deleted the prior anchor"
    git -C "$current" status --porcelain --untracked-files=all > "$case_dir/current-status.after"
    git -C "$prior" status --porcelain --untracked-files=all > "$case_dir/prior-status.after"
    cmp -s "$case_dir/current-status.before" "$case_dir/current-status.after" || fail "retirement changed B status"
    cmp -s "$case_dir/prior-status.before" "$case_dir/prior-status.after" || fail "retirement changed A status"
    for hook in .claude/settings.local.json .opencode/plugins/fm-turn-end.js \
      .opencode/plugins/fm-busy-state.js .fm-grok-turnend .fm-kimi-turnend; do
      cmp -s "$case_dir/hooks.before/${hook##*/}" "$current/$hook" || fail "retirement changed B hook $hook"
    done
    assert_grep 'unlanded B bytes' "$current/scratch.txt" "retirement lost B work"
    assert_grep 'unlanded A bytes' "$prior/scratch.txt" "retirement lost A work"
  done
  pass "forced retirement preserves reassociated non-pool copies and refuses their checkout or shared-storage destruction before mutation"
}

test_cleanup_roots_preserve_foreign_copy_git_storage() {
  local root field location case_dir target copy state common rc
  for root in home worktree tasktmp; do
    for field in worktree home prior_worktree; do
      for location in local peer; do
        case_dir=$(make_case "foreign-storage-$root-$field-$location")
        mkdir -p "$case_dir/home/state" "$case_dir/home/data"
        if [ "$root" = home ]; then
          write_meta "$case_dir" local-only secondmate
          target=$case_dir/secondmate-home
          mkdir -p "$target/state" "$target/data" "$target/config" "$target/projects"
          printf 'task-x1\n' > "$target/.fm-secondmate-home"
          printf 'home=%s\n' "$target" >> "$case_dir/state/task-x1.meta"
        else
          write_meta "$case_dir" local-only ship
          if [ "$root" = tasktmp ]; then
            target=$case_dir/tasktmp
            mkdir -p "$target"
            printf 'tasktmp=%s\n' "$target" >> "$case_dir/state/task-x1.meta"
          else
            target=$case_dir/wt
          fi
        fi
        git clone -q "$case_dir/origin.git" "$target/P"
        copy=$case_dir/foreign-copy
        git -C "$target/P" worktree add -q -b fm/foreign "$copy" main
        printf 'foreign work bytes\n' > "$copy/scratch.txt"
        ln -s "$copy" "$case_dir/foreign-alias"
        state=$case_dir/home/state
        if [ "$location" = peer ]; then
          state=$case_dir/peer/state
          mkdir -p "$state"
          printf '# Secondmates\n- peer - peer fixture (home: %s; scope: fixture; projects: none; added 2026-10-08)\n' \
            "$case_dir/peer" > "$case_dir/home/data/secondmates.md"
        fi
        fm_write_meta "$state/foreign.meta" "$field=$case_dir/foreign-alias" "kind=ship"
        cp "$state/foreign.meta" "$case_dir/foreign.before"
        cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
        common=$(cd "$target/P/.git" && pwd -P)
        cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\${1:-}" in kill-*) printf '%s\n' "\$*" >> "$case_dir/kill.log" ;; esac
exit 0
SH
        cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
        rc=0
        FM_HOME="$case_dir/home" run_teardown "$case_dir" --force --drop-file "$FM_TEST_DROP_WORDS" \
          > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        expect_code 1 "$rc" "$root cleanup must preserve $location foreign $field Git storage"
        assert_grep "Git common-dir storage $common" "$case_dir/stderr" "foreign refusal missed shared Git storage: $(cat "$case_dir/stderr")"
        assert_grep "task foreign's recorded $field" "$case_dir/stderr" "foreign refusal missed the preserving field"
        cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" || fail "foreign storage refusal changed retiring metadata"
        cmp -s "$case_dir/foreign.before" "$state/foreign.meta" || fail "foreign storage refusal changed foreign metadata"
        assert_grep 'foreign work bytes' "$copy/scratch.txt" "foreign storage refusal lost copy bytes"
        git -C "$copy" rev-parse --verify HEAD >/dev/null || fail "foreign storage refusal destroyed Git storage"
        assert_absent "$case_dir/kill.log" "foreign storage refusal closed an endpoint"
        assert_absent "$case_dir/treehouse.log" "foreign storage refusal returned a copy"
      done
    done
  done
  pass "home, worktree, and tasktmp roots preserve Git storage of every foreign copy field in local and peer homes"
}

test_tasktmp_preserves_reassociated_copy_git_storage() {
  local shape case_dir tmp current prior project common force rc
  for shape in current prior; do
    case_dir=$(make_case "tasktmp-reassociated-storage-$shape")
    mkdir -p "$case_dir/home/state" "$case_dir/tasktmp"
    tmp=$case_dir/tasktmp
    git clone -q "$case_dir/origin.git" "$tmp/P"
    current=$case_dir/wt
    prior=$case_dir/prior-A
    project=$case_dir/project
    if [ "$shape" = current ]; then
      current=$case_dir/current-B
      project=$tmp/P
      git -C "$project" worktree add -q -b fm/current-B "$current" main
      git -C "$case_dir/project" worktree add -q -b fm/prior-A "$prior" main
    else
      git -C "$tmp/P" worktree add -q -b fm/prior-A "$prior" main
    fi
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$current" "project=$project" "kind=ship" "mode=local-only" \
      "spawn_gen=teardown-test-task-x1" "tasktmp=$tmp" "prior_worktree=$prior"
    cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
    common=$(cd "$tmp/P/.git" && pwd -P)
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
    chmod +x "$case_dir/fakebin/lsof"
    for force in normal force; do
      rc=0
      if [ "$force" = force ]; then
        FM_HOME="$case_dir/home" run_teardown "$case_dir" --force --drop-file "$FM_TEST_DROP_WORDS" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      else
        FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      fi
      expect_code 1 "$rc" "tasktmp must preserve reassociated $shape Git storage under $force cleanup"
      assert_grep "Git common-dir storage $common" "$case_dir/stderr" "tasktmp refusal missed shared Git storage"
      cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" || fail "tasktmp storage refusal changed metadata"
      git -C "$current" rev-parse --verify HEAD >/dev/null || fail "tasktmp storage refusal destroyed B"
      git -C "$prior" rev-parse --verify HEAD >/dev/null || fail "tasktmp storage refusal destroyed A"
      assert_absent "$case_dir/kill.log" "tasktmp storage refusal closed an endpoint"
      assert_absent "$case_dir/reap.log" "tasktmp storage refusal reached process reaping"
    done
  done
  pass "tasktmp protects external reassociated current and prior copies' Git storage before endpoint or copy mutation"
}

test_subordinate_slot_cleanup_preserves_ancestor_custody() {
  local shape case_dir home parent slot owner rc
  for shape in admitted prior unvalidated shared-storage; do
    case_dir=$(make_case "subordinate-cleanup-$shape")
    home=$case_dir
    parent="$TMP_ROOT/subordinate-parent-$shape"
    mkdir -p "$home/data" "$home/config" "$parent/state" "$parent/data"
    printf 'mate\n' > "$home/.fm-secondmate-home"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"
    printf -- '- mate - mate (home: %s; scope: fixture; projects: P; added 2026-10-08)\n' "$home" > "$parent/data/secondmates.md"
    owner="$parent/state/mate.meta"
    fm_write_meta "$owner" "kind=secondmate" "home=$home" "worktree=$home"
    land_shippable_commit "$case_dir"
    slot="$home/pool/1/project"
    if [ "$shape" = shared-storage ]; then
      git init -q "$home"
      slot="$home/.git/pool/1/project"
    fi
    mkdir -p "${slot%/*}"
    git -C "$case_dir/project" worktree move "$case_dir/wt" "$slot"
    printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"task-x1"}]}\n' \
      "$slot" > "${slot%/*/*}/treehouse-state.json"
    fm_write_meta "$case_dir/state/task-x1.meta" \
      "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
      "worktree=$slot" "project=$case_dir/project" "kind=ship" "mode=no-mistakes" \
      "spawn_gen=teardown-test-task-x1"
    case "$shape" in
      prior) printf 'prior_worktree=%s\n' "$slot" >> "$owner" ;;
      # The registered mate record stays, so the parent binding resolves and
      # the unregistered impostor naming the same home is what must refuse.
      unvalidated) cp "$owner" "$parent/state/impostor.meta"; owner="$parent/state/impostor.meta" ;;
    esac
    cp "$owner" "$case_dir/owner.before"
    cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
    cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
    rc=0
    FM_HOME="$home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if [ "$shape" = admitted ]; then
      expect_code 0 "$rc" "validated ancestor should allow ordinary child slot cleanup: $(cat "$case_dir/stderr")"
      assert_absent "$case_dir/state/task-x1.meta" "subordinate teardown did not retire the child"
      assert_grep "return --force $slot" "$case_dir/treehouse.log" "subordinate teardown did not return its slot"
    else
      expect_code 1 "$rc" "protected ancestor custody should refuse $shape cleanup"
      case "$shape" in
        prior) assert_grep "task mate's recorded prior_worktree" "$case_dir/stderr" "cleanup skipped ancestor prior custody" ;;
        unvalidated) assert_grep "task impostor's recorded worktree" "$case_dir/stderr" "cleanup exempted an unvalidated record" ;;
        shared-storage) assert_grep "Git common-dir storage $home/.git" "$case_dir/stderr" "cleanup skipped ancestor Git storage" ;;
      esac
      cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" || fail "custody refusal retired the child"
      assert_absent "$case_dir/treehouse.log" "custody refusal returned a slot"
      assert_present "$slot" "custody refusal removed the slot"
    fi
    cmp -s "$case_dir/owner.before" "$owner" || fail "child cleanup changed the owning ancestor"
  done
  pass "ordinary subordinate cleanup admits validated ancestors but preserves their priors and Git storage"
}

# A provider return still sweeps nested copies when its pool inventory is absent.
# Introduce a copy at each return boundary, not during earlier custody scans.
test_non_pool_returns_recheck_registered_copies() {
  local phase case_dir nested lock rc
  for phase in initial retry stale; do
    case_dir=$(make_case "non-pool-registered-$phase")
    write_meta "$case_dir" no-mistakes ship
    nested="$case_dir/wt/.claude/worktrees/parked"
    lock=$(git_index_lock_path "$case_dir/wt")
    if [ "$phase" = initial ]; then
      git -C "$case_dir/project" worktree add -q --detach "$nested" main
    fi
    cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
if [ ! -e "$case_dir/attempted" ]; then
  touch "$case_dir/attempted"
  if [ "$phase" = retry ]; then
    git -C "$case_dir/project" worktree add -q --detach "$nested" main || exit 2
  elif [ "$phase" = stale ]; then
    touch "$lock"
    touch -t 200001010000 "$lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
    if [ "$phase" = stale ]; then
      cat > "$case_dir/fakebin/rm" <<SH
#!/usr/bin/env bash
/bin/rm "\$@" || exit
for arg in "\$@"; do
  if [ "\$arg" = "$lock" ]; then
    git -C "$case_dir/project" worktree add -q --detach "$nested" main || exit 2
  fi
done
SH
      chmod +x "$case_dir/fakebin/rm"
      add_lsof_no_holder "$case_dir"
    fi
    rc=0
    FM_TREEHOUSE_RETURN_LOCK_RETRIES=$([ "$phase" = stale ] && printf 0 || printf 1) \
    FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
      run_teardown "$case_dir" --force --drop-file "$FM_TEST_DROP_WORDS" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$phase: an unproven registered copy must stop the return: $(cat "$case_dir/stderr")"
    assert_grep "contains registered copy $nested" "$case_dir/stderr" "$phase: missing custody refusal"
    assert_present "$nested/.git" "$phase: parked copy was lost"
    assert_present "$case_dir/state/task-x1.meta" "$phase: task record was retired"
    if [ "$phase" = initial ]; then
      assert_absent "$case_dir/treehouse.log" 'initial: provider was called despite the parked copy'
      assert_grep 'FM_HOME=/path/to/owning-home bin/fm-control.sh <owning-task> reassociate' \
        "$case_dir/stderr" 'recovery command omitted the owning home'
    else
      assert_equals 1 "$(wc -l < "$case_dir/treehouse.log" | tr -d ' ')" "$phase: provider retried despite the parked copy"
    fi
    if [ "$phase" = stale ]; then
      assert_grep 'removed provably-stale git lock' "$case_dir/stderr" 'stale cleanup boundary was not reached'
    fi
  done
  pass 'every forced return checks registered copies without pool inventory, and recovery names the owning home'
}

# A provider may lose its target between attempts; refusal must explain why.
test_return_missing_slot_reports_canonicalization_refusal() {
  local case_dir rc=0
  case_dir=$(make_case return-missing-slot)
  write_meta "$case_dir" no-mistakes ship
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
mv "$case_dir/wt" "$case_dir/retained-copy" || exit 2
echo "fatal: Unable to create 'index.lock': File exists." >&2
exit 128
SH
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
    run_teardown "$case_dir" --force --drop-file "$FM_TEST_DROP_WORDS" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "missing slot must stop the retry: $(cat "$case_dir/stderr")"
  assert_grep "REFUSED: cannot canonicalize pool slot $case_dir/wt" "$case_dir/stderr" 'missing slot refusal did not identify the path'
  assert_equals 1 "$(wc -l < "$case_dir/treehouse.log" | tr -d ' ')" 'provider retried an unresolvable slot'
  assert_present "$case_dir/state/task-x1.meta" 'missing-slot refusal retired the task record'
  assert_present "$case_dir/retained-copy/.git" 'missing-slot refusal lost the retained copy'
  pass 'an uncanonicalizable return target reports an explicit refusal and preserves its record'
}

# A custody refusal at a child's return is final; no fallback may delete the copy.
test_child_return_custody_refusal_keeps_non_pool_worktree() {
  local case_dir home nested rc=0
  case_dir=$(make_case child-return-custody)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_tmux_children "$case_dir"
  home="$case_dir/secondmate-home"
  nested="$case_dir/child-a-wt/.claude/worktrees/parked"
  git -C "$case_dir/project" worktree add -q --detach "$nested" main
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"
  run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 5 "$rc" "child custody refusal must stop teardown: $(cat "$case_dir/stderr")"
  assert_grep "contains registered copy $nested" "$case_dir/stderr" 'child custody refusal was not reported'
  assert_present "$nested/.git" 'child custody refusal lost the parked copy'
  assert_present "$case_dir/child-a-wt/.git" 'child custody refusal removed the child worktree'
  assert_present "$home/state/child-a.meta" 'child custody refusal retired the child record'
  assert_present "$case_dir/state/task-x1.meta" 'child custody refusal retired the parent record'
  assert_absent "$case_dir/treehouse.log" 'provider was called despite the parked copy'
  pass 'a custody refusal at a non-pool child return keeps the child worktree and its parked copy'
}

test_unverified_pool_reservation_preserves_processes() {
  local case_dir pid rc=0
  make_nested_slot_case unverified-pool-reservation enclosing .claude/worktrees/x
  case_dir=$NESTED_CASE
  printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$NESTED_SLOT" \
    > "$case_dir/pool/treehouse-state.json"
  # This provider has the lease command and acknowledges it but never changes
  # state. A successful command is not evidence that this slot became
  # nonallocatable.
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = lease ] && [ "\${2:-}" = --help ]; then
  printf 'Usage:\n  treehouse lease <name> [flags]\n\nFlags:\n      --lease-holder string   Optional label recorded as the lease holder\n'
  exit 0
fi
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  teardown_fixture_start "$NESTED_COPY" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  FM_HOME="$case_dir/home" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if ! kill -0 "$pid" 2>/dev/null; then
    fail 'an unverified reservation killed the worker before protecting its slot'
  fi
  teardown_fixture_stop "$pid"
  expect_code 1 "$rc" "unverified reservation must stop cleanup: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.meta" 'unverified reservation removed task identity'
  assert_present "$case_dir/pool/1/.fm-slot-owner" 'unverified reservation dropped slot ownership'
  assert_present "$NESTED_COPY" 'unverified reservation removed its nested copy'
  assert_no_grep '^return ' "$case_dir/treehouse.log" 'unverified reservation returned the pool slot'
  pass 'a lease command without durable state proof cannot reap processes or return the slot, even with authorized discard'
}

test_pool_return_rechecks_work_after_waiting_for_project_custody() {
  local shape case_dir slot lock actor holder ticket queued i rc head
  for shape in dirty committed; do
    case_dir=$(make_case "pool-late-work-$shape")
    slot="$case_dir/pool/1/project"
    mkdir -p "${slot%/*}" "$case_dir/primary-home/state"
    git -C "$case_dir/project" worktree add -q -b fm/late-root "$slot" main
    printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"task-x1"}]}\n' \
      "$slot" > "$case_dir/pool/treehouse-state.json"
    printf 'task=task-x1\nhome=%s\n' "$case_dir/primary-home" > "${slot%/*}/.fm-slot-owner"
    fm_write_meta "$case_dir/state/task-x1.meta" \
      'window=firstmate:fm-task-x1' 'endpoint_task_id=task-x1' \
      "worktree=$slot" "project=$case_dir/project" 'kind=ship' 'mode=local-only' \
      'spawn_gen=teardown-test-task-x1' 'branch=fm/late-root'
    printf 'manual\n' > "$case_dir/config/backlog-backend"
    cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    [ -f "$FM_LATE_CASE/closed" ] || printf '%s\n' fm-task-x1
    exit 0
    ;;
  kill-window)
    : > "$FM_LATE_CASE/closing"
    i=0
    while [ ! -f "$FM_LATE_CASE/project-held" ]; do
      i=$((i + 1)); [ "$i" -lt 2000 ] || exit 1
      sleep 0.05
    done
    : > "$FM_LATE_CASE/closed"
    ;;
esac
SH
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_LATE_CASE/treehouse.log"
SH
    chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"
    lock=$(FM_HOME="$case_dir/primary-home" FM_STATE_OVERRIDE="$case_dir/state" \
      bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' \
      _ "$ROOT" "$case_dir/project")
    FM_HOME="$case_dir/primary-home" FM_LATE_CASE="$case_dir" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" &
    actor=$!
    i=0
    while [ ! -f "$case_dir/closing" ]; do
      i=$((i + 1)); [ "$i" -lt 1000 ] || fail "$shape: teardown did not reach endpoint closure: $(cat "$case_dir/stderr" "$case_dir/stdout")"
      sleep 0.05
    done
    FM_HOME="$case_dir/primary-home" FM_STATE_OVERRIDE="$case_dir/state" \
      bash -c '
        . "$1/bin/fm-wake-lib.sh"
        fm_lock_try_acquire "$2" || exit 1
        trap '\''fm_lock_release "$2"'\'' EXIT
        : > "$3/project-held"
        while [ ! -f "$3/release" ]; do sleep 0.05; done
      ' _ "$ROOT" "$lock" "$case_dir" &
    holder=$!
    i=0
    while :; do
      queued=0
      for ticket in "$lock.queue"/ticket-*; do
        [ ! -L "$ticket" ] || queued=1
      done
      [ "$queued" = 0 ] || break
      i=$((i + 1)); [ "$i" -lt 1000 ] || {
        : > "$case_dir/release"; wait "$holder" || true; wait "$actor" || true
        fail "$shape: teardown never queued for final project custody: $(cat "$case_dir/stderr")"
      }
      sleep 0.05
    done
    printf 'work produced while return waits\n' > "$slot/late.txt"
    if [ "$shape" = committed ]; then
      git -C "$slot" add late.txt
      git -C "$slot" -c user.email=t@t -c user.name=t commit -qm 'late unlanded work'
    fi
    head=$(git -C "$slot" rev-parse HEAD)
    : > "$case_dir/release"
    wait "$holder" || fail "$shape: project holder could not release"
    rc=0; wait "$actor" || rc=$?
    [ "$rc" -ne 0 ] || fail "$shape: teardown returned a slot whose work changed while project custody was queued"
    assert_present "$case_dir/state/task-x1.meta" "$shape: refused return erased its record"
    assert_present "${slot%/*}/.fm-slot-owner" "$shape: refused return dropped its claim"
    assert_absent "$case_dir/treehouse.log" "$shape: late work reached a destructive provider call"
    assert_equals "$head" "$(git -C "$slot" rev-parse HEAD)" "$shape: late HEAD was changed"
    assert_grep 'work produced while return waits' "$slot/late.txt" "$shape: late bytes were changed"
    jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
      || fail "$shape: refused return released its durable reservation"
  done
  pass 'ordinary pool return preserves dirt and new commits produced while final project custody is queued'
}

# A "not ready yet" refusal must leave Treehouse state exactly as it found it.
# The reservation is taken only after every non-destructive check has passed,
# so a later reassociation never strands a state-only lease on the old slot.
test_refusal_before_cleanup_takes_no_pool_reservation() {
  local case_dir slot rc=0
  make_lease_modeling_pool_case pool-refusal-no-reservation ''
  case_dir=$POOL_CASE
  slot=$POOL_SLOT
  printf 'unfinished\n' > "$slot/unfinished.txt"
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown accepted a slot with uncommitted work"
  assert_present "$case_dir/state/task-x1.meta" 'the refusal removed the task record'
  assert_present "$slot/unfinished.txt" 'the refusal changed the slot contents'
  jq -e '.worktrees[0].leased == false and (.worktrees[0] | has("lease_holder") | not)' \
    "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail "a refusal before cleanup left a durable lease: $(cat "$case_dir/pool/treehouse-state.json")"

  rm -f "$slot/unfinished.txt"
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 0 "$rc" "the clean retry must finish: $(cat "$case_dir/stderr2")"
  assert_absent "$case_dir/state/task-x1.meta" 'the clean retry kept the task record'
  jq -e '.worktrees[0].leased == false' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the completed teardown left its slot leased'
  pass 'a refusal before cleanup leaves the pool slot unreserved, and the clean retry still returns it'
}

# Treehouse state that can be neither proved held nor leased never blocks
# cleanup: teardown names the state, keeps project custody from the
# reservation point through the return, and finishes as before.
test_unprovable_pool_state_keeps_project_custody_through_return() {
  local shape state logged case_dir slot rc returns recovered
  recovered="recovered: state file was corrupt or truncated; verify before reuse"
  for shape in recovered conflicting unreadable; do
    logged=$shape
    case "$shape" in
      recovered) state='{"worktrees":[{"name":"1","path":"@SLOT@","leased":true,"lease_holder":"'"$recovered"'"}]}' ;;
      conflicting) state='{"worktrees":[{"name":"1","path":"@SLOT@","leased":false},{"name":"1","path":"@SLOT@","leased":true,"lease_holder":"task-x1"}]}' ;;
      unreadable) state='{"worktrees": ['; logged=unknown ;;
    esac
    make_lease_modeling_pool_case "pool-legacy-$shape" "$state"
    case_dir=$POOL_CASE
    slot=$POOL_SLOT
    cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    [ -f "$FM_POOL_CASE/closed" ] || printf '%s\n' fm-task-x1
    ;;
  kill-window)
    if FM_STATE_OVERRIDE="$FM_POOL_CASE/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 1; fm_lock_release "$2"' \
        _ "$FM_POOL_ROOT" "$FM_POOL_LOCK" 2>/dev/null; then
      printf 'free\n' > "$FM_POOL_CASE/lock-at-close"
    else
      printf 'held\n' > "$FM_POOL_CASE/lock-at-close"
    fi
    : > "$FM_POOL_CASE/closed"
    ;;
esac
exit 0
SH
    chmod +x "$case_dir/fakebin/tmux"
    rc=0
    FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" FM_POOL_ROOT="$ROOT" FM_POOL_LOCK="$POOL_LOCK" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "$shape: an unprovable slot state must not refuse cleanup: $(cat "$case_dir/stderr")"
    assert_grep "'$logged'" "$case_dir/stderr" "$shape: teardown did not log the slot's Treehouse state"
    [ "$(cat "$case_dir/lock-at-close" 2>/dev/null)" = held ] \
      || fail "$shape: project custody was released while the unreserved slot's endpoint was closing"
    assert_absent "$case_dir/state/task-x1.meta" "$shape: teardown kept the task record"
    assert_absent "${slot%/*}/.fm-slot-owner" "$shape: teardown kept the slot claim"
    returns=$(grep -c "^return --force $slot\$" "$case_dir/treehouse.log" || true)
    assert_equals 1 "$returns" "$shape: the slot must be returned exactly once"
    assert_no_grep '^lease ' "$case_dir/treehouse.log" "$shape: teardown tried to lease a slot it could not prove unleased"
    [ ! -e "$POOL_LOCK" ] || fail "$shape: teardown left the project lock held"
  done
  pass 'recovered, conflicting and unreadable slot states fall back to whole-cleanup project custody and return the slot'
}

# Whether teardown may narrow project custody follows the installed Treehouse:
# one with the lease command reserves the unleased slot and closes the endpoint
# outside the lock, while one that predates it cannot reserve anything, so the
# endpoint closes and the slot is returned under whole-cleanup project custody
# with no lease attempted, and the cleanup still finishes instead of refusing.
test_teardown_follows_the_installed_treehouse_lease_support() {
  local shape case_dir slot rc returns leases no_lease want_custody
  for shape in capable leaseless; do
    make_lease_modeling_pool_case "pool-lease-support-$shape" ''
    case_dir=$POOL_CASE
    slot=$POOL_SLOT
    cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows)
    [ -f "$FM_POOL_CASE/closed" ] || printf '%s\n' fm-task-x1
    ;;
  kill-window)
    if FM_STATE_OVERRIDE="$FM_POOL_CASE/state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 1; fm_lock_release "$2"' \
        _ "$FM_POOL_ROOT" "$FM_POOL_LOCK" 2>/dev/null; then
      printf 'free\n' > "$FM_POOL_CASE/lock-at-close"
    else
      printf 'held\n' > "$FM_POOL_CASE/lock-at-close"
    fi
    : > "$FM_POOL_CASE/closed"
    ;;
esac
exit 0
SH
    chmod +x "$case_dir/fakebin/tmux"
    no_lease=
    want_custody=free
    if [ "$shape" = leaseless ]; then
      no_lease=1
      want_custody=held
    fi
    rc=0
    FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" FM_POOL_ROOT="$ROOT" FM_POOL_LOCK="$POOL_LOCK" \
      FM_POOL_NO_LEASE="$no_lease" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "$shape: teardown must finish: $(cat "$case_dir/stderr")"
    assert_equals "$want_custody" "$(cat "$case_dir/lock-at-close" 2>/dev/null)" \
      "$shape: the project lock was in the wrong state while the endpoint closed"
    assert_absent "$case_dir/state/task-x1.meta" "$shape: teardown kept the task record"
    assert_absent "${slot%/*}/.fm-slot-owner" "$shape: teardown kept the slot claim"
    returns=$(grep -c "^return --force $slot\$" "$case_dir/treehouse.log" || true)
    assert_equals 1 "$returns" "$shape: the slot must be returned exactly once"
    leases=$(grep -c '^lease ' "$case_dir/treehouse.log" || true)
    if [ "$shape" = leaseless ]; then
      assert_equals 0 "$leases" "$shape: teardown tried a lease command the installed Treehouse lacks"
      assert_grep 'no lease command' "$case_dir/stderr" "$shape: teardown did not say why it kept project custody"
    else
      assert_equals 1 "$leases" "$shape: the slot must be reserved exactly once"
      assert_equals 1 "$(grep -c '^lease 1 --lease-holder task-x1$' "$case_dir/treehouse.log" || true)" \
        "$shape: the slot was reserved for the wrong holder"
    fi
    [ ! -e "$POOL_LOCK" ] || fail "$shape: teardown left the project lock held"
  done
  pass 'an unleased pool slot is reserved only when the installed Treehouse has a lease command, else project custody covers the return'
}

# The idle reaper's teardown never waits before it has closed anything, but
# once the endpoint is gone the task no longer classifies as reap-ready. Its
# return stage therefore waits in the project queue and completes, instead of
# exiting busy and leaving a closed task holding its slot with no retry.
test_idle_reap_return_waits_for_project_custody_after_closure() {
  local case_dir slot holder actor i queued ticket rc returns
  make_idle_reap_pool_case pool-idle-reap-return
  case_dir=$POOL_CASE
  slot=$POOL_SLOT
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" FM_IDLE_REAP_ADMISSION=1 \
    FM_PROJECT_LOCK_POLL_SECS=0.05 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" &
  actor=$!
  i=0
  while [ ! -f "$case_dir/closing" ]; do
    i=$((i + 1)); [ "$i" -lt 1000 ] || { kill "$actor" 2>/dev/null || true; fail "automatic teardown did not reach endpoint closure: $(cat "$case_dir/stderr")"; }
    sleep 0.05
  done
  hold_project_lock_until_release "$case_dir" "$POOL_LOCK" &
  holder=$!
  i=0
  while :; do
    queued=0
    for ticket in "$POOL_LOCK.queue"/ticket-*; do
      [ ! -L "$ticket" ] || queued=1
    done
    [ "$queued" = 0 ] || break
    if ! kill -0 "$actor" 2>/dev/null; then
      : > "$case_dir/release"; wait "$holder" || true
      rc=0; wait "$actor" || rc=$?
      fail "automatic teardown exited ($rc) instead of queueing for its return: $(cat "$case_dir/stderr")"
    fi
    i=$((i + 1)); [ "$i" -lt 1000 ] || {
      : > "$case_dir/release"; wait "$holder" || true; wait "$actor" || true
      fail "automatic teardown never queued for its return: $(cat "$case_dir/stderr")"
    }
    sleep 0.05
  done
  jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the closed task lost its reservation while its return queued'
  : > "$case_dir/release"
  wait "$holder" || fail 'the project holder could not release'
  rc=0; wait "$actor" || rc=$?
  expect_code 0 "$rc" "the queued automatic return must finish: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" 'the automatic teardown kept the closed task record'
  returns=$(grep -c "^return --force $slot\$" "$case_dir/treehouse.log" || true)
  assert_equals 1 "$returns" 'the automatic teardown must return the slot exactly once'
  jq -e '.worktrees[0].leased == false' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the automatic teardown left its returned slot leased'
  pass 'an automatic teardown that has closed its endpoint waits for project custody and returns its slot'
}

# A closed task whose return still cannot obtain project custody within the
# stall bound is neither stranded nor parked behind a refusal memo: its
# durable return-pending record lets the very next sweep select it again
# without a live busy state, and that sweep finishes the return.
test_idle_reap_retries_a_closed_task_whose_return_stalled() {
  local case_dir slot holder actor contender reaper i rc out returns
  make_idle_reap_pool_case pool-idle-reap-stalled-return
  case_dir=$POOL_CASE
  slot=$POOL_SLOT
  rm -f "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir" scout
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" FM_IDLE_REAP_ADMISSION=1 \
    FM_PROJECT_LOCK_POLL_SECS=0.05 FM_PROJECT_LOCK_SERVICE_SECS=2 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" &
  actor=$!
  i=0
  while [ ! -f "$case_dir/closing" ]; do
    i=$((i + 1)); [ "$i" -lt 1000 ] || { kill "$actor" 2>/dev/null || true; fail "automatic teardown did not reach endpoint closure: $(cat "$case_dir/stderr")"; }
    sleep 0.05
  done
  hold_project_lock_until_release "$case_dir" "$POOL_LOCK" &
  holder=$!
  rc=0; wait "$actor" || rc=$?
  if [ "$rc" != 75 ]; then
    : > "$case_dir/release"; wait "$holder" || true
    fail "a stalled return must exit busy for the next sweep, got $rc: $(cat "$case_dir/stderr")"
  fi
  assert_present "$case_dir/closed" 'the fixture did not close the endpoint before the return stalled'
  assert_present "$case_dir/state/task-x1.meta" 'the stalled return erased the task record'
  assert_present "${slot%/*}/.fm-slot-owner" 'the stalled return dropped the slot claim'
  [ "$(grep -c '^return ' "$case_dir/treehouse.log" || true)" = 0 ] || fail 'the stalled return still returned the slot'
  jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the stalled return left the closed slot allocatable'
  assert_present "$case_dir/state/task-x1.backlog-close" 'the stalled return lost its pending backlog close'
  out=$(PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/primary-home" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || fail "session start failed beside a pending return: $out"
  assert_present "$case_dir/state/task-x1.meta" 'session start retired the record whose slot return is pending'
  assert_present "$case_dir/state/task-x1.backlog-close" 'session start consumed the close the teardown retry owes'
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "session start closed the backlog row before the slot return: $(backlog_row_state "$case_dir")"
  out=$(FM_HOME="$case_dir/primary-home" FM_ROOT_OVERRIDE="$case_dir/code-root" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    NM_HOME="$case_dir/nm" FM_POOL_CASE="$case_dir" PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-idle-session-reap.sh" scan) || fail "the reaper could not scan the closed task: $out"
  [ "$(printf '%s\n' "$out" | awk -F'\t' '$2 == "task-x1" { print $1 }')" = reap ] \
    || fail "the next sweep could not select the closed task again: $out"

  # The retry meets a still-held lock with a live waiter already queued. A
  # nonwaiting admission would refuse behind that waiter on every sweep; the
  # retry must queue behind it and finish once the queue drains.
  FM_PROJECT_LOCK_POLL_SECS=0.05 FM_HOME="$case_dir/primary-home" FM_STATE_OVERRIDE="$case_dir/state" \
    bash -c '
      . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-project-lock-lib.sh"
      fm_project_lock_acquire "$2" contender || exit 1
      fm_project_lock_release "$2"
    ' _ "$ROOT" "$POOL_LOCK" > "$case_dir/contender.out" 2>&1 &
  contender=$!
  i=0
  while [ "$(queued_tickets "$POOL_LOCK")" -lt 1 ]; do
    i=$((i + 1)); [ "$i" -lt 1000 ] || fail "the contender never queued: $(cat "$case_dir/contender.out")"
    sleep 0.05
  done
  FM_HOME="$case_dir/primary-home" FM_ROOT_OVERRIDE="$case_dir/code-root" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    NM_HOME="$case_dir/nm" FM_POOL_CASE="$case_dir" PATH="$case_dir/fakebin:$PATH" FM_PROJECT_LOCK_POLL_SECS=0.05 \
    "$ROOT/bin/fm-idle-session-reap.sh" reap > "$case_dir/reap.out" 2>&1 &
  reaper=$!
  i=0
  while [ "$(queued_tickets "$POOL_LOCK")" -lt 2 ]; do
    if ! kill -0 "$reaper" 2>/dev/null; then
      : > "$case_dir/release"; wait "$holder" || true; wait "$contender" || true
      fail "the retry did not queue behind the live waiter: $(cat "$case_dir/reap.out")"
    fi
    i=$((i + 1)); [ "$i" -lt 2000 ] || {
      : > "$case_dir/release"; wait "$holder" || true; wait "$contender" || true; wait "$reaper" || true
      fail "the retry never queued: $(cat "$case_dir/reap.out")"
    }
    sleep 0.05
  done
  : > "$case_dir/release"
  wait "$holder" || fail 'the project holder could not release'
  wait "$contender" || fail "the queued contender was not admitted: $(cat "$case_dir/contender.out")"
  wait "$reaper" || fail "the retry sweep failed: $(cat "$case_dir/reap.out")"
  out=$(cat "$case_dir/reap.out")
  [ "$(printf '%s\n' "$out" | awk -F'\t' '$2 == "task-x1" { print $1 }')" = reaped ] \
    || fail "the retry sweep did not finish the closed task: $out"
  assert_absent "$case_dir/state/task-x1.meta" 'the retry kept the closed task record'
  assert_absent "$case_dir/state/task-x1.teardown-return-pending" 'the retry kept the return-pending record'
  returns=$(grep -c "^return --force $slot\$" "$case_dir/treehouse.log" || true)
  assert_equals 1 "$returns" 'the retry must return the slot exactly once'
  jq -e '.worktrees[0].leased == false' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the retry left the returned slot leased'
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "the retry did not close the backlog row: $(backlog_row_state "$case_dir")"
  pass 'a closed task whose return stalled survives session start and the next sweep finishes it behind a queued waiter'
}

# An endpoint that refuses to close after the slot was reserved and the
# pending backlog close was published leaves a closed-or-closing task holding
# a durable lease. Session start must not replay that close and retire the
# only record naming the slot; the plain retry returns the slot and closes it.
test_endpoint_refusal_after_reservation_survives_session_start() {
  local case_dir slot rc out returns
  make_lease_modeling_pool_case pool-endpoint-refusal-replay ''
  case_dir=$POOL_CASE
  slot=$POOL_SLOT
  rm -f "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"
  stuck_endpoint_tmux "$case_dir"
  : > "$case_dir/endpoint-stuck"
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "the endpoint refusal must stop teardown: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.backlog-close" 'the refusal came before the pending close was published'
  jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the refusal came before the slot was reserved'
  out=$(PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/primary-home" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || fail "session start failed beside a refused endpoint: $out"
  assert_present "$case_dir/state/task-x1.meta" 'session start retired the only record naming the leased slot'
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "session start closed the row while the slot was still leased: $(backlog_row_state "$case_dir")"
  assert_present "${slot%/*}/.fm-slot-owner" 'session start dropped the slot claim'
  jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'session start released the reserved slot'

  rm -f "$case_dir/endpoint-stuck"
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 0 "$rc" "the plain retry must finish: $(cat "$case_dir/stderr2")"
  assert_absent "$case_dir/state/task-x1.meta" 'the retry kept the task record'
  assert_absent "$case_dir/state/task-x1.teardown-return-pending" 'the retry kept the return-pending record'
  returns=$(grep -c "^return --force $slot\$" "$case_dir/treehouse.log" || true)
  assert_equals 1 "$returns" 'the retry must return the slot exactly once'
  jq -e '.worktrees[0].leased == false' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the retry left the slot leased'
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "the retry did not close the backlog row: $(backlog_row_state "$case_dir")"
  pass 'an endpoint refusal after reservation keeps its record through session start and the retry returns the slot'
}

# A project-lock error at the waited return stage is not contention: it keeps
# exit 1, which the idle reaper records as a refusal, instead of the busy exit
# a stall uses for a silent retry.
test_waited_return_lock_error_is_not_reported_as_contention() {
  local case_dir rc
  make_idle_reap_pool_case pool-return-lock-error
  case_dir=$POOL_CASE
  : > "$case_dir/project-held"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) [ -f "$FM_POOL_CASE/closed" ] || printf '%s\n' fm-task-x1 ;;
  kill-window)
    mkdir -p "$FM_POOL_LOCK.queue" && printf 'corrupt\n' > "$FM_POOL_LOCK.queue/sequence"
    : > "$FM_POOL_CASE/closed"
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" FM_POOL_LOCK="$POOL_LOCK" FM_IDLE_REAP_ADMISSION=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "a lock error at the waited return must keep its error exit: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/closed" 'the lock error was injected before the endpoint closed'
  assert_present "$case_dir/state/task-x1.meta" 'the lock error erased the task record'
  jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the lock error released the reserved slot'
  pass 'a waited return that meets a project-lock error exits 1, not the contention exit'
}

# A legacy record (no spawn_gen) is stamped only after its slot is reserved.
# The return-pending record must follow that stamp, so an endpoint that refuses
# to close after the stamp still leaves bootstrap unable to replay the close,
# and a plain retry returns the slot once. A stamp rolled back by a failed
# close publication must leave the record matching the unstamped task again.
test_legacy_pool_teardown_keeps_its_return_pending_record_across_the_stamp() {
  local case_dir slot rc out returns
  make_lease_modeling_pool_case pool-legacy-return-pending ''
  case_dir=$POOL_CASE
  slot=$POOL_SLOT
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=firstmate:fm-task-x1' 'endpoint_task_id=task-x1' \
    "worktree=$slot" "project=$case_dir/project" 'kind=ship' 'mode=local-only' \
    'harness=codex' 'branch=fm/pool-root'
  rm -f "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) [ ! -f "$FM_POOL_CASE/kill-attempted" ] || printf '%s\n' fm-task-x1 ;;
  kill-window) : > "$FM_POOL_CASE/kill-attempted"; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "the endpoint refusal must stop the legacy teardown: $(cat "$case_dir/stderr")"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] || fail 'the legacy record was not stamped before the endpoint refusal'
  assert_present "$case_dir/state/task-x1.backlog-close" 'the refusal came before the pending close was published'
  jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the refusal came before the slot was reserved'
  out=$(PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/primary-home" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || fail "session start failed beside a refused legacy endpoint: $out"
  assert_present "$case_dir/state/task-x1.meta" 'session start retired the only record naming the leased slot'
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "session start closed the row while the slot was still leased: $(backlog_row_state "$case_dir")"
  assert_present "${slot%/*}/.fm-slot-owner" 'session start dropped the slot claim'
  jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'session start released the reserved slot'

  rm -f "$case_dir/kill-attempted"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" --legacy-record > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 0 "$rc" "the legacy retry must finish: $(cat "$case_dir/stderr2")"
  assert_absent "$case_dir/state/task-x1.meta" 'the retry kept the task record'
  assert_absent "$case_dir/state/task-x1.teardown-return-pending" 'the retry kept the return-pending record'
  returns=$(grep -c "^return --force $slot\$" "$case_dir/treehouse.log" || true)
  assert_equals 1 "$returns" 'the retry must return the slot exactly once'
  jq -e '.worktrees[0].leased == false' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the retry left the slot leased'
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "the retry did not close the backlog row: $(backlog_row_state "$case_dir")"
  pass 'an interrupted legacy pool teardown keeps its record through session start and its retry returns the slot once'
}

# The stamp's rollback after a failed close publication leaves the record
# unstamped; the return-pending record written at reservation must then match
# that rolled-back record again, not the stamp that no longer exists.
test_legacy_stamp_rollback_rebinds_the_return_pending_record() {
  local case_dir rc
  make_lease_modeling_pool_case pool-legacy-rollback-pending ''
  case_dir=$POOL_CASE
  fm_write_meta "$case_dir/state/task-x1.meta" \
    'window=firstmate:fm-task-x1' 'endpoint_task_id=task-x1' \
    "worktree=$POOL_SLOT" "project=$case_dir/project" 'kind=ship' 'mode=local-only' \
    'harness=codex' 'branch=fm/pool-root'
  rm -f "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"
  add_failing_close_publication_mv "$case_dir"
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "an unrecordable close must fail the legacy teardown: $(cat "$case_dir/stderr")"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] || fail 'the failed close publication left the legacy stamp in place'
  assert_present "$case_dir/state/task-x1.teardown-return-pending" 'the reserved slot lost its return-pending record'
  jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the failed close publication released the reserved slot'
  FM_HOME="$case_dir/primary-home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_teardown_return_pending "$2" task-x1' \
    _ "$ROOT" "$case_dir/state" \
    || fail 'the rolled-back record no longer matches its return-pending record'
  pass 'a rolled-back legacy stamp leaves its return-pending record bound to the unstamped record'
}

test_return_pending_write_failure_refuses_and_the_retry_finishes() {
  local case_dir slot rc out
  make_lease_modeling_pool_case pool-pending-write-failure ''
  case_dir=$POOL_CASE
  slot=$POOL_SLOT
  rm -f "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"
  recording_endpoint_tmux "$case_dir"
  add_failing_return_pending_mv "$case_dir"
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" \
    "pending-write: an unrecordable return-pending record must stop teardown: $(cat "$case_dir/stderr")"
  assert_unrecorded_return_refusal_state "$case_dir" "$slot" pending-write
  rm -f "$case_dir/fakebin/mv"
  out=$(PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/primary-home" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "pending-write: session start failed beside the refused record: $out"
  assert_unrecorded_return_refusal_state "$case_dir" "$slot" pending-write
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 0 "$rc" "pending-write: the retry must finish: $(cat "$case_dir/stderr2")"
  assert_unrecorded_return_retry_finished "$case_dir" "$slot" pending-write
  pass 'a failed return-pending record write refuses before any destruction and the retry returns the slot once'
}

test_return_pending_occupied_marker_path_refuses_and_the_retry_finishes() {
  local case_dir slot rc out
  make_lease_modeling_pool_case pool-pending-occupied-path ''
  case_dir=$POOL_CASE
  slot=$POOL_SLOT
  rm -f "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"
  recording_endpoint_tmux "$case_dir"
  mkdir "$case_dir/state/task-x1.teardown-return-pending"
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" \
    "pending-path: an unrecordable return-pending record must stop teardown: $(cat "$case_dir/stderr")"
  assert_unrecorded_return_refusal_state "$case_dir" "$slot" pending-path
  rm -rf "$case_dir/state/task-x1.teardown-return-pending"
  out=$(PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/primary-home" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "pending-path: session start failed beside the refused record: $out"
  assert_unrecorded_return_refusal_state "$case_dir" "$slot" pending-path
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 0 "$rc" "pending-path: the retry must finish: $(cat "$case_dir/stderr2")"
  assert_unrecorded_return_retry_finished "$case_dir" "$slot" pending-path
  pass 'a stale directory at the return-pending path refuses before any destruction and the retry returns the slot once'
}

test_return_pending_unreadable_generation_refuses_and_the_retry_finishes() {
  local case_dir slot rc out
  make_lease_modeling_pool_case pool-pending-unreadable-gen ''
  case_dir=$POOL_CASE
  slot=$POOL_SLOT
  rm -f "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"
  recording_endpoint_tmux "$case_dir"
  add_unreadable_return_pending_gen "$case_dir"
  : > "$case_dir/inject-unreadable-gen"
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" \
    "pending-gen: an unreadable record generation must stop teardown: $(cat "$case_dir/stderr")"
  rm -f "$case_dir/inject-unreadable-gen"
  chmod 644 "$case_dir/state/task-x1.meta"
  assert_unrecorded_return_refusal_state "$case_dir" "$slot" pending-gen
  out=$(PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/primary-home" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "pending-gen: session start failed beside the refused record: $out"
  assert_unrecorded_return_refusal_state "$case_dir" "$slot" pending-gen
  rc=0
  FM_HOME="$case_dir/primary-home" FM_POOL_CASE="$case_dir" \
    run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 0 "$rc" "pending-gen: the retry must finish: $(cat "$case_dir/stderr2")"
  assert_unrecorded_return_retry_finished "$case_dir" "$slot" pending-gen
  pass 'an unreadable return-pending generation refuses before any destruction and the retry returns the slot once'
}

# Task A shares a pool slot with live task B: B holds the durable lease and A's
# claim still sits beside the slot. A's endpoint refuses to close after the
# pending backlog close is published. Session start must not replay that close
# and retire A's record while A's claim still names the slot, because B's own
# teardown would then read the slot as reassigned and never return it. A's plain
# retry releases only its claim; B keeps its lease and later finishes normally.
test_shared_slot_claim_release_survives_endpoint_refusal_and_bootstrap() {
  local case_dir slot delivered rc out returns mode gen; local -a flags
  for mode in plain legacy; do
  flags=()
  gen="spawn_gen=finished"
  if [ "$mode" = legacy ]; then flags=(--legacy-record); gen="harness=codex"; fi
  case_dir=$(make_case "shared-claim-refusal-$mode")
  wt_commit_file "$case_dir" delivered.txt 'merged task work' 'delivered task'
  delivered=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin HEAD:main
  add_gh_pr_merged_for_head "$case_dir" "$delivered"
  mkdir -p "$case_dir/pool/1" "$case_dir/primary-home/state"
  slot="$case_dir/pool/1/project"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$slot"
  slot=$(cd "$slot" && pwd -P)
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"live-task"}]}\n' "$slot" \
    > "$case_dir/pool/treehouse-state.json"
  printf 'task=task-x1\nhome=%s\n' "$case_dir/primary-home" > "${slot%/*}/.fm-slot-owner"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" \
    "worktree=$slot" "project=$case_dir/project" "kind=ship" \
    "mode=no-mistakes" "branch=fm/task-x1" "$gen" \
    "pr=https://github.com/example/repo/pull/7" "pr_head=$delivered"
  fm_write_meta "$case_dir/state/live-task.meta" \
    "window=firstmate:fm-live-task" "endpoint_task_id=live-task" \
    "worktree=$slot" "project=$case_dir/project" "kind=ship" "mode=no-mistakes" \
    "branch=fm/task-x1" "spawn_gen=live" \
    "pr=https://github.com/example/repo/pull/7" "pr_head=$delivered"
  rm -f "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"
  tasks-axi add live-task "sharing task" --kind ship --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start live-task --file "$case_dir/data/backlog.md" >/dev/null
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ -e "$case_dir/endpoint-stuck" ]; then
  case "\${1:-}" in
    kill-window) : > "$case_dir/kill-attempted"; exit 1 ;;
    list-windows) [ ! -e "$case_dir/kill-attempted" ] || printf '%s\n' fm-task-x1; exit 0 ;;
  esac
fi
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"
  cp "$case_dir/pool/treehouse-state.json" "$case_dir/lease.before"
  cp "$case_dir/state/live-task.meta" "$case_dir/live-meta.before"
  : > "$case_dir/endpoint-stuck"

  rc=0
  FM_HOME="$case_dir/primary-home" run_teardown "$case_dir" "${flags[@]+"${flags[@]}"}" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "the endpoint refusal must stop the shared-slot teardown: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.backlog-close" 'the refusal came before the pending close was published'
  assert_present "$case_dir/state/task-x1.teardown-return-pending" 'the shared claim awaiting release has no return-pending record'

  out=$(PATH="$case_dir/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/primary-home" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) || fail "session start failed beside a refused shared endpoint: $out"
  assert_present "$case_dir/state/task-x1.meta" 'session start retired the record whose claim still names the shared slot'
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "session start closed the row before the claim was released: $(backlog_row_state "$case_dir")"
  assert_grep 'task=task-x1' "${slot%/*}/.fm-slot-owner" 'session start changed the slot claim'
  cmp -s "$case_dir/lease.before" "$case_dir/pool/treehouse-state.json" || fail 'session start changed the sharer lease'

  rm -f "$case_dir/endpoint-stuck" "$case_dir/kill-attempted"
  rc=0
  FM_HOME="$case_dir/primary-home" run_teardown "$case_dir" "${flags[@]+"${flags[@]}"}" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
  expect_code 0 "$rc" "the plain retry must finish: $(cat "$case_dir/stderr2")"
  assert_absent "$case_dir/state/task-x1.meta" 'the retry kept the task record'
  assert_absent "$case_dir/state/task-x1.teardown-return-pending" 'the retry kept the return-pending record'
  assert_absent "${slot%/*}/.fm-slot-owner" "the retry left the finished task's claim beside the shared slot"
  assert_no_grep '^return ' "$case_dir/treehouse.log" 'the retry returned a slot another task still holds'
  cmp -s "$case_dir/lease.before" "$case_dir/pool/treehouse-state.json" || fail 'the retry changed the sharer lease'
  cmp -s "$case_dir/live-meta.before" "$case_dir/state/live-task.meta" || fail 'the retry changed the sharer record'
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "the retry did not close the backlog row: $(backlog_row_state "$case_dir")"

  rc=0
  FM_HOME="$case_dir/primary-home" FM_ROOT_OVERRIDE="$case_dir/code-root" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" FM_CONFIG_OVERRIDE="$case_dir/config" \
    NM_HOME="$case_dir/nm" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" live-task > "$case_dir/b.stdout" 2> "$case_dir/b.stderr" || rc=$?
  expect_code 0 "$rc" "the sharer's own teardown must finish once the claim is released: $(cat "$case_dir/b.stderr")"
  assert_absent "$case_dir/state/live-task.meta" 'the sharer kept its record'
  returns=$(grep -c "^return --force $slot\$" "$case_dir/treehouse.log" || true)
  assert_equals 1 "$returns" 'the sharer must return the slot exactly once'
  done
  pass 'a shared-slot claim release survives an endpoint refusal and session start, and the sharer then finishes normally'
}

# The deferred pool return of a child shares that rule after its project wait.
test_child_pool_return_custody_refusal_keeps_slot() {
  local case_dir home slot nested lock rc=0
  case_dir=$(make_case child-pool-return-custody)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_tmux_children "$case_dir"
  home="$case_dir/secondmate-home"
  slot="$case_dir/pool/1/project"
  mkdir -p "${slot%/*}" "$case_dir/primary-home/state"
  git -C "$case_dir/project" worktree add -q -b fm/child-pool "$slot" main
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"child-a"}]}\n' \
    "$slot" > "$case_dir/pool/treehouse-state.json"
  printf 'task=child-a\nhome=%s\n' "$home" > "${slot%/*}/.fm-slot-owner"
  fm_write_meta "$home/state/child-a.meta" \
    'window=firstmate:fm-child-a' 'endpoint_task_id=child-a' \
    "worktree=$slot" "project=$case_dir/project" 'kind=ship' 'mode=local-only'
  nested="$slot/.claude/worktrees/parked"
  lock=$(git_index_lock_path "$slot")
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
if [ ! -e "$case_dir/attempted" ]; then
  touch "$case_dir/attempted"
  git -C "$case_dir/project" worktree add -q --detach "$nested" main || exit 2
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"
  FM_HOME="$case_dir/primary-home" FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 5 "$rc" "child pool custody refusal must stop teardown: $(cat "$case_dir/stderr")"
  assert_grep "contains registered copy $nested" "$case_dir/stderr" 'child pool custody refusal was not reported'
  assert_present "$nested/.git" 'child pool custody refusal lost the parked copy'
  assert_present "$slot/.git" 'child pool custody refusal removed the child slot'
  assert_present "${slot%/*}/.fm-slot-owner" 'child pool custody refusal dropped the slot claim'
  assert_present "$home/state/child-a.meta" 'child pool custody refusal retired the child record'
  assert_present "$case_dir/state/task-x1.meta" 'child pool custody refusal retired the parent record'
  pass 'a custody refusal at a deferred child pool return keeps the slot, its claim and its parked copy'
}

teardown_test_cases=(
test_shared_slot_claim_release_survives_endpoint_refusal_and_bootstrap
test_legacy_pool_teardown_keeps_its_return_pending_record_across_the_stamp
test_legacy_stamp_rollback_rebinds_the_return_pending_record
test_return_pending_write_failure_refuses_and_the_retry_finishes
test_return_pending_occupied_marker_path_refuses_and_the_retry_finishes
test_return_pending_unreadable_generation_refuses_and_the_retry_finishes
test_endpoint_refusal_after_reservation_survives_session_start
test_waited_return_lock_error_is_not_reported_as_contention
test_idle_reap_retries_a_closed_task_whose_return_stalled
test_refusal_before_cleanup_takes_no_pool_reservation
test_unprovable_pool_state_keeps_project_custody_through_return
test_teardown_follows_the_installed_treehouse_lease_support
test_idle_reap_return_waits_for_project_custody_after_closure
test_pool_return_rechecks_work_after_waiting_for_project_custody
test_unverified_pool_reservation_preserves_processes
test_non_pool_returns_recheck_registered_copies
test_return_missing_slot_reports_canonicalization_refusal
test_child_return_custody_refusal_keeps_non_pool_worktree
test_child_pool_return_custody_refusal_keeps_slot
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
test_nested_slot_return_concludes_runs_and_agents_on_the_slot
test_shared_nested_copy_concludes_only_its_own_runtime
test_nested_slot_stale_lock_cleanup_reproves_the_slot
test_nested_slot_reproof_refusal_is_rerunnable
test_nested_rerun_local_only_ship_is_recorded_landed
test_nested_rerun_matrix_refusal_at_each_phase
test_nested_rerun_gone_copy_needs_its_branch_landed
test_nested_rerun_gone_copy_and_branch_uses_recorded_merged_pr
test_nested_slot_is_not_proven_by_the_current_copys_pipeline_input
test_nested_rerun_gone_copy_is_proven_by_its_pipeline_input
test_nested_rerun_after_endpoint_refusal_records_landed
test_nested_post_lock_reprove_skips_removed_nested_priors
test_other_record_copy_overlap_is_component_aware
test_forced_descendant_preserved_copy_refuses_before_cleanup
test_tasktmp_preserves_current_and_prior_reassociated_copies
test_tasktmp_checks_all_other_copy_fields_in_both_directions
test_secondmate_home_preserves_other_tasks_prior_copy
test_forced_nested_secondmate_admits_only_locked_current_copies
test_forced_descendant_reassociated_copy_preserves_checkout_and_storage
test_cleanup_roots_preserve_foreign_copy_git_storage
test_tasktmp_preserves_reassociated_copy_git_storage
test_subordinate_slot_cleanup_preserves_ancestor_custody
)

# Validate the complete selection before running any behavioral case.
for requested_case in "$@"; do
  registered_case=false
  for test_case in "${teardown_test_cases[@]}"; do
    if [ "$requested_case" = "$test_case" ]; then
      registered_case=true
      break
    fi
  done
  if [ "$registered_case" = false ]; then
    printf 'Unknown test case: %s\n' "$requested_case" >&2
    printf 'Usage: bash tests/fm-teardown-pool.test.sh [test_function_name ...]\n' >&2
    exit 2
  fi
done

for test_case in "${teardown_test_cases[@]}"; do
  if [ "$#" -eq 0 ]; then
    "$test_case"
    continue
  fi
  for requested_case in "$@"; do
    if [ "$requested_case" = "$test_case" ]; then
      "$test_case"
      break
    fi
  done
done
