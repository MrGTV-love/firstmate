#!/usr/bin/env bash
# Session-end auto-relaunch and the opt-in Claude debug flag.
#
# The decision runs through bin/fm-session-end-relaunch-lib.sh against a fake
# endpoint. The debug flag runs through the real fm-spawn launch command.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-end-relaunch)
mkdir -p "$TMP_ROOT"
export FM_HOME="$TMP_ROOT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-session-end-relaunch-lib.sh"

make_tmux() {  # <dir>
  local fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
cmd=${FM_FAKE_TMUX_CURRENT_COMMAND:-zsh}
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) printf '%s\n' "$cmd"; exit 0 ;;
        *cursor_y*) printf '0\n'; exit 0 ;;
      esac
    done
    exit 0 ;;
  list-windows)
    if [ "${FM_FAKE_WINDOW_GONE:-0}" = 1 ]; then
      printf 'main\n'
    else
      printf 'main\nfm-lane\n'
    fi
    exit 0 ;;
  capture-pane)
    [ -z "${FM_FAKE_TMUX_CAPTURE:-}" ] || cat "$FM_FAKE_TMUX_CAPTURE"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_recorder() {  # <dir>
  local bin="$1/recorder"
  mkdir -p "$bin"
  cat > "$bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_SESSION_END_CONTROL_LOG:?}"
exit "${FM_SESSION_END_CONTROL_RC:-0}"
SH
  chmod +x "$bin/fm-control.sh"
  printf '%s\n' "$bin/fm-control.sh"
}

# <name> -> dir. One ship, session-end recorded, worktree present.
make_lane() {
  local name=$1 dir state wt gen
  dir="$TMP_ROOT/$name"
  state="$dir/state"
  wt="$dir/wt"
  mkdir -p "$state" "$wt" "$dir/data"
  printf 'window=firstmate:fm-lane\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\n' "$wt" > "$state/lane.meta"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" lane --state idle --source claude-hook --event launch-brief >/dev/null
  gen=$(cat "$state/lane.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" lane idle --gen "$gen" --source claude-hook --event session-end >/dev/null
  printf '%s\n' "$dir"
}

scan_lane() {  # <dir>
  local dir=$1 fakebin recorder
  fakebin=$(make_tmux "$dir")
  recorder=$(make_recorder "$dir")
  : > "$dir/control.log"
  PATH="$fakebin:$PATH" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WAKE_QUEUE="$dir/state/.wake-queue" \
    FM_TEST_SEAM=1 FM_SESSION_END_CONTROL="$recorder" \
    FM_SESSION_END_CONTROL_LOG="$dir/control.log" \
    FM_FAKE_TMUX_CAPTURE="${FM_FAKE_TMUX_CAPTURE:-}" \
    FM_FAKE_TMUX_CURRENT_COMMAND="${FM_FAKE_TMUX_CURRENT_COMMAND:-zsh}" \
    FM_FAKE_WINDOW_GONE="${FM_FAKE_WINDOW_GONE:-0}" \
    fm_session_end_relaunch_scan "$dir/state"
}

test_typed_exit_matches_a_submitted_line_only() {
  fm_session_end_typed_exit $'idle\n❯ /exit\nResume this session with:' /exit \
    || fail "a submitted /exit line was not recognized"
  fm_session_end_typed_exit 'the brief mentions /exit in prose' /exit \
    && fail "a prose mention of /exit was treated as a typed exit"
  fm_session_end_typed_exit $'❯ /quit' /exit \
    && fail "a different submitted command was treated as /exit"
  pass "typed exit matches only a submitted exit command"
}

test_session_end_relaunches_a_dead_lane_once() {
  local dir state
  dir=$(make_lane relaunch-once)
  state="$dir/state"
  scan_lane "$dir" || fail "scan failed on an eligible dead lane"
  [ "$FM_SESSION_END_WAKE" = "check: lane auto-relaunched after session-end" ] \
    || fail "eligible session-end did not wake a relaunch: ${FM_SESSION_END_WAKE:-<empty>}"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "relaunch was not invoked exactly once: $(cat "$dir/control.log")"
  grep -F 'lane relaunch --note' "$dir/control.log" >/dev/null \
    || fail "relaunch was not the control verb: $(cat "$dir/control.log")"
  grep -F 'left as the previous worker left them' "$dir/control.log" >/dev/null \
    || fail "the relaunch note did not say the local copy was preserved: $(cat "$dir/control.log")"
  [ "$(awk -F '\t' '$2 == "attempt"' "$state/.session-end-relaunch-lane" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the attempt was not ledgered"
  scan_lane "$dir" || fail "second scan failed"
  [ -z "$FM_SESSION_END_WAKE" ] || fail "a second scan woke again: $FM_SESSION_END_WAKE"
  [ ! -s "$dir/control.log" ] || fail "a second scan relaunched again: $(cat "$dir/control.log")"
  pass "a dead session-end lane is relaunched once and then left alone"
}

test_missing_endpoint_relaunches() {
  local dir
  dir=$(make_lane missing-endpoint)
  FM_FAKE_WINDOW_GONE=1 scan_lane "$dir" || fail "scan failed on a missing endpoint"
  unset FM_FAKE_WINDOW_GONE
  [ "$FM_SESSION_END_WAKE" = "check: lane auto-relaunched after session-end" ] \
    || fail "a missing endpoint was not relaunched: ${FM_SESSION_END_WAKE:-<empty>}"
  pass "a missing endpoint with session-end is relaunched"
}

test_cap_holds_and_wakes_once() {
  local dir state now
  dir=$(make_lane cap-min)
  state="$dir/state"
  now=$(date +%s)
  printf '%s\tattempt\n' "$now" > "$state/.session-end-relaunch-lane"
  scan_lane "$dir" || fail "capped scan failed"
  [ -s "$dir/control.log" ] && fail "a capped lane was relaunched: $(cat "$dir/control.log")"
  grep -F 'auto-relaunch paused after 1 attempt in 1800s' <<<"$FM_SESSION_END_WAKE" >/dev/null \
    || fail "the 30-minute cap did not wake: ${FM_SESSION_END_WAKE:-<empty>}"
  scan_lane "$dir" || fail "second capped scan failed"
  [ -z "$FM_SESSION_END_WAKE" ] || fail "the cap woke again for the same session-end: $FM_SESSION_END_WAKE"
  pass "the 30-minute cap holds and wakes once"

  dir=$(make_lane cap-day)
  state="$dir/state"
  now=$(date +%s)
  printf '%s\tattempt\n%s\tattempt\n%s\tattempt\n' $((now - 10)) $((now - 20)) $((now - 30)) \
    > "$state/.session-end-relaunch-lane"
  FM_SESSION_END_RELAUNCH_MIN_SECS=1 scan_lane "$dir" || fail "daily-cap scan failed"
  unset FM_SESSION_END_RELAUNCH_MIN_SECS
  [ -s "$dir/control.log" ] && fail "a daily-capped lane was relaunched: $(cat "$dir/control.log")"
  grep -F 'auto-relaunch paused after 3 attempts in 86400s' <<<"$FM_SESSION_END_WAKE" >/dev/null \
    || fail "the daily cap did not wake: ${FM_SESSION_END_WAKE:-<empty>}"
  pass "the daily cap holds and wakes once"
}

test_deliberate_exit_and_waits_are_skipped() {
  local dir gen
  dir=$(make_lane deliberate)
  gen=$(cat "$dir/state/lane.busy-gen")
  printf 'gen=%s\n' "$gen" > "$dir/state/lane.control-exit"
  scan_lane "$dir" || fail "deliberate-exit scan failed"
  [ -z "$FM_SESSION_END_WAKE" ] || fail "a deliberate exit was relaunched: $FM_SESSION_END_WAKE"
  [ -s "$dir/control.log" ] && fail "a deliberate exit invoked control"

  dir=$(make_lane typed-exit)
  printf '❯ /exit\n' > "$dir/pane"
  FM_FAKE_TMUX_CAPTURE="$dir/pane" scan_lane "$dir" || fail "typed-exit scan failed"
  unset FM_FAKE_TMUX_CAPTURE
  [ -s "$dir/control.log" ] && fail "a typed /exit was relaunched: $(cat "$dir/control.log")"

  dir=$(make_lane paused)
  printf 'paused: waiting on the upstream release\n' > "$dir/state/lane.status"
  scan_lane "$dir" || fail "paused scan failed"
  [ -s "$dir/control.log" ] && fail "a paused task was relaunched"

  dir=$(make_lane held)
  printf 'captain-held: waiting on the merge\n' > "$dir/state/lane.status"
  scan_lane "$dir" || fail "held scan failed"
  [ -s "$dir/control.log" ] && fail "a captain-held task was relaunched"

  dir=$(make_lane done-lane)
  printf 'done: the work is finished\n' > "$dir/state/lane.status"
  scan_lane "$dir" || fail "done scan failed"
  [ -s "$dir/control.log" ] && fail "a finished task was relaunched"

  dir=$(make_lane alive)
  FM_FAKE_TMUX_CURRENT_COMMAND=claude scan_lane "$dir" || fail "alive scan failed"
  unset FM_FAKE_TMUX_CURRENT_COMMAND
  [ -s "$dir/control.log" ] && fail "a live agent was relaunched"
  pass "deliberate exit, typed exit, pause, hold, done, and a live agent are skipped"
}

test_backlog_hold_is_skipped() {
  local dir
  command -v tasks-axi >/dev/null 2>&1 || { pass "backlog hold skip skipped (tasks-axi absent)"; return 0; }
  dir=$(make_lane backlog-hold)
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  (cd "$dir" && tasks-axi add lane 'open lane' --file data/backlog.md) >/dev/null 2>&1 \
    || { pass "backlog hold skip skipped (could not add a backlog row)"; return 0; }
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_CONFIG_OVERRIDE="$dir/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold lane --reason 'awaiting the captain' >/dev/null 2>&1 \
    || { pass "backlog hold skip skipped (hold could not be recorded)"; return 0; }
  printf 'working: still open\n' > "$dir/state/lane.status"
  scan_lane "$dir" || fail "held-metadata scan failed"
  [ -s "$dir/control.log" ] && fail "a backlog captain hold was relaunched: $(cat "$dir/control.log")"
  pass "a backlog captain hold is not relaunched"
}

test_claude_debug_is_off_unless_asked() {
  local case_dir home proj wt fakebin id=debug-off out launch status
  case_dir="$TMP_ROOT/debug-off"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" claude)
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-debug-off"
  fm_test_spawn_brief "$home" "$id"
  status=0
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off > "$case_dir/spawn.out" || status=$?
  out=$(cat "$case_dir/spawn.out")
  expect_code 0 "$status" "a default claude spawn should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_not_contains "$launch" '--debug' "claude debug was on without --claude-debug: $launch"
  id=debug-on
  fm_test_spawn_brief "$home" "$id"
  : > "$case_dir/launch.log"
  status=0
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --claude-debug > "$case_dir/spawn-on.out" || status=$?
  expect_code 0 "$status" "a --claude-debug spawn should succeed: $(cat "$case_dir/spawn-on.out")"
  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" '--debug ' "claude debug was not enabled when asked: $launch"

  id=debug-pi
  fm_test_spawn_brief "$home" "$id"
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off \
    --harness pi --claude-debug > "$case_dir/spawn-pi.out"
  expect_code 1 $? "a non-claude --claude-debug spawn must be refused"
  assert_contains "$(cat "$case_dir/spawn-pi.out")" '--claude-debug applies only to a claude launch' \
    "the refusal did not name the flag"
  pass "claude debug is off by default, on when asked, and refused for another harness"
}

test_typed_exit_matches_a_submitted_line_only
test_session_end_relaunches_a_dead_lane_once
test_missing_endpoint_relaunches
test_cap_holds_and_wakes_once
test_deliberate_exit_and_waits_are_skipped
test_backlog_hold_is_skipped
test_claude_debug_is_off_unless_asked
