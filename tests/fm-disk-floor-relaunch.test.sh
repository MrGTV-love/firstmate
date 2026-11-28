#!/usr/bin/env bash
# The free-disk floor never refuses recovery: a relaunch of an existing worker
# allocates nothing new, so it runs on a nearly full disk and never reads the
# disk meter (bin/fm-disk-floor-lib.sh owns the contract; bin/fm-spawn.sh runs
# the check only for a fresh spawn). Both relaunch routes are real processes
# against the control-relaunch fixtures: bin/fm-control.sh relaunch and
# bin/fm-spawn.sh --relaunch. The fake df (tests/assets/fake-bin/df) reports 1 GiB
# free and records every call it answers.
# Shared fixtures: tests/fm-control-relaunch-helpers.sh.

# shellcheck source=tests/fm-control-relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-helpers.sh"

full_disk() { # <case-dir>
  : > "$1/df.log"
  export FM_FAKE_DF_AVAIL_KB=1048576 FM_FAKE_DF_LOG="$1/df.log"
}

test_control_relaunch_is_admitted_below_the_floor() {
  local dir out rc
  dir=$(new_case floor-control rl1)
  add_ship_task "$dir" rl1 claude
  full_disk "$dir"
  out=$(run_control "$dir" rl1 relaunch --note "disk is nearly full"); rc=$?
  unset FM_FAKE_DF_AVAIL_KB FM_FAKE_DF_LOG
  expect_code 0 "$rc" "a control relaunch at 1 GiB free was refused"$'\n'"$out"
  assert_contains "$out" "relaunched rl1 harness=claude" "the relaunch did not complete"
  assert_not_contains "$out" "disk free floor" "a relaunch printed a floor message"
  [ ! -s "$dir/df.log" ] || fail "a relaunch read the disk meter: $(cat "$dir/df.log")"
  assert_grep "Firstmate operational input waiting: read" "$dir/fake/literal" "the replacement agent was not launched"
  pass "fm-control relaunch is admitted at 1 GiB free and never reads the disk meter"
}

test_direct_spawn_relaunch_is_admitted_below_the_floor() {
  local dir out rc
  dir=$(new_case floor-spawn rl2)
  add_ship_task "$dir" rl2 claude
  printf 'zsh' > "$dir/fake/command"
  full_disk "$dir"
  out=$(run_spawn "$dir" rl2 --relaunch --harness claude); rc=$?
  unset FM_FAKE_DF_AVAIL_KB FM_FAKE_DF_LOG
  expect_code 0 "$rc" "a direct fm-spawn --relaunch at 1 GiB free was refused"$'\n'"$out"
  assert_not_contains "$out" "disk free floor" "a direct relaunch printed a floor message"
  [ ! -s "$dir/df.log" ] || fail "a direct relaunch read the disk meter: $(cat "$dir/df.log")"
  assert_grep "Firstmate operational input waiting: read" "$dir/fake/literal" "the replacement agent was not launched"
  pass "fm-spawn --relaunch is admitted at 1 GiB free and never reads the disk meter"
}

control_relaunch_test_cases=(
test_control_relaunch_is_admitted_below_the_floor
test_direct_spawn_relaunch_is_admitted_below_the_floor
)

control_relaunch_run "$@"
