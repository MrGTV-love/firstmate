#!/usr/bin/env bash
# The real-Treehouse case of the Herdr spawn path behind bin/fm-control.sh relaunch: a Herdr pass-over abort (the spawn
# passed over a copy it cannot take, then gave up) is never reported clean. Copy A is a real pool slot whose state shows
# another holder's lease, made by the installed treehouse binary; Herdr is the stub of tests/fm-control-relaunch-helpers.sh.
# The case needs only `get --lease` (and jq), as it did before it moved here; without them the first output line is the
# runner's gate skip and the script exits 0. The other Herdr relaunch cases live in tests/fm-control-relaunch-backends.test.sh.
# Shared fixtures: tests/fm-control-relaunch-helpers.sh.

# shellcheck source=tests/fm-control-relaunch-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch-helpers.sh"
fm_test_require_real_treehouse get-lease

# A Herdr spawn that passes over a copy and then aborts must never report the abort as clean: Herdr pass-over settlement and
# the Herdr projection branch are untested, so fm-spawn reads no Herdr foreground and the outcome is always unobservable.
# The stub's pane enters copy A, a real pool slot whose state shows another holder's lease, on every `treehouse get`, so the
# second get makes no progress and the no-progress limit (reached by tests/skip-clock.sh) ends the spawn.
test_a_herdr_pass_over_abort_is_never_reported_clean() {
  local dir out rc real a_copy state holder log
  real=$(command -v treehouse 2>/dev/null || true)
  dir=$(new_case herdr-passover hp1)
  make_herdr_stub "$dir"
  fm_fake_exit0 "$dir/fakebin" treehouse
  fm_git_worktree "$dir/proj" "$dir/wt" task-hp1
  a_copy=$(cd "$dir/proj" && TREEHOUSE_ROOT="$dir/th-root" "$real" get --lease --lease-holder other-holder 2>/dev/null </dev/null | tail -n 1)
  a_copy=$(CDPATH='' cd -- "$a_copy" 2>/dev/null && pwd -P) || fail "herdr pass-over: the real treehouse made no pool slot"
  state="$(dirname "$(dirname "$a_copy")")/treehouse-state.json"
  cp "$state" "$dir/state.before"
  fm_test_spawn_brief "$dir/home" hp1
  mkdir -p "$dir/home/projects"
  printf '%s' "$a_copy" > "$dir/fake/herdr-treehouse-worktree"
  printf '%s' '%9' > "$dir/fake/herdr-pane"
  # The stub's `pane process-info` then names a foreground process for the pane, so a Herdr foreground read, were there
  # one, would see a pane resting in copy A with no get and could call the abort clean.
  : > "$dir/fake/herdr-live-%9"
  out=$(FM_TEST_TICK_SECONDS=60 BASH_ENV="$ROOT/tests/skip-clock.sh" \
    run_spawn "$dir" hp1 "$dir/proj" claude --backend herdr --mode no-mistakes --yolo off); rc=$?
  [ "$rc" -ne 0 ] || fail "herdr pass-over: the spawn launched although its only copy was passed over"$'\n'"$out"
  assert_contains "$out" "skipped: copy $a_copy already carries another holder's lease" "herdr pass-over: copy A was not passed over"
  assert_contains "$out" "aborting acquisition" "herdr pass-over: the spawn did not end with its acquisition refusal"
  assert_contains "$out" "is not settled" "herdr pass-over: the abort was not reported as not settled"
  assert_contains "$out" "this abort is not clean" "herdr pass-over: the abort was not called unclean"
  assert_not_contains "$out" "notice: acquisition pane" "herdr pass-over: a Herdr abort was reported as settled"
  grep -q $'\tunobservable\t' "$dir/home/data/hp1/acquisition-pane.tsv" 2>/dev/null \
    || fail "herdr pass-over: the pane was not recorded as unobservable: $(cat "$dir/home/data/hp1/acquisition-pane.tsv" 2>&1)"
  log=$(cat "$dir/fake/herdr-log")
  assert_contains "$log" "pane send-keys %9 ctrl+c" "herdr pass-over: the pane was not interrupted"
  assert_not_contains "$log" "close" "herdr pass-over: the spawn closed a pane, tab or workspace after the pass-over"
  cmp -s "$state" "$dir/state.before" || fail "herdr pass-over: the pool state changed"
  holder=$(jq -r --arg p "$a_copy" '[.worktrees[] | select(.path == $p) | .lease_holder] | join(",")' "$state")
  [ "$holder" = other-holder ] || fail "herdr pass-over: copy A lost the other holder's lease ($holder)"
  pass "a herdr abort after a pass-over interrupts the pane, records it as unobservable and is never reported as clean"
}

control_relaunch_test_cases=(
  test_a_herdr_pass_over_abort_is_never_reported_clean
)

control_relaunch_run "$@"
