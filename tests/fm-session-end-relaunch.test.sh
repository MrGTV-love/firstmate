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
[ -z "${FM_FAKE_TMUX_LOG:-}" ] || printf '%s\n' "${1:-}" >> "$FM_FAKE_TMUX_LOG"
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
[ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is not set" >&2; exit 1; }
printf '%s\n' "$*" >> "${FM_SESSION_END_CONTROL_LOG:?}"
[ -z "${FM_SESSION_END_CONTROL_ENV_LOG:-}" ] \
  || printf 'FM_HOME=%s\nFM_STATE_OVERRIDE=%s\nFM_CONTROL_LAUNCH_WAIT=%s\n' \
    "$FM_HOME" "${FM_STATE_OVERRIDE:-}" "${FM_CONTROL_LAUNCH_WAIT:-}" > "$FM_SESSION_END_CONTROL_ENV_LOG"
if [ -n "${FM_SESSION_END_BEACON_REF:-}" ]; then
  date +%s > "$FM_SESSION_END_BEACON_REF.start"
  if [ "${FM_STATE_OVERRIDE:-}/.last-watcher-beat" -nt "$FM_SESSION_END_BEACON_REF" ]; then
    printf 'fresh\n' > "$FM_SESSION_END_BEACON_REF.seen"
  else
    printf 'stale\n' > "$FM_SESSION_END_BEACON_REF.seen"
  fi
fi
[ -z "${FM_SESSION_END_CONTROL_SLEEP:-}" ] || sleep "$FM_SESSION_END_CONTROL_SLEEP"
[ -z "${FM_SESSION_END_CONTROL_OUT:-}" ] || printf '%s\n' "$FM_SESSION_END_CONTROL_OUT"
exit "${FM_SESSION_END_CONTROL_RC:-0}"
SH
  chmod +x "$bin/fm-control.sh"
  printf '%s\n' "$bin/fm-control.sh"
}

# <dir> <id>. One ship in <dir>/state, session-end recorded, worktree present.
add_lane() {
  local dir=$1 id=$2 state wt gen
  state="$dir/state"
  wt="$dir/wt-$id"
  mkdir -p "$state" "$wt" "$dir/data"
  printf 'window=firstmate:fm-lane\nkind=ship\nharness=claude\nbackend=tmux\nworktree=%s\n' "$wt" > "$state/$id.meta"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" --state idle --source claude-hook --event launch-brief >/dev/null
  gen=$(cat "$state/$id.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" --source claude-hook --event session-end >/dev/null
}

# <name> -> dir. One ship named lane.
make_lane() {
  local dir="$TMP_ROOT/$1"
  add_lane "$dir" lane
  printf '%s\n' "$dir"
}

scan_lane() {  # <dir> [<watcher-grace-secs>]
  local dir=$1 fakebin recorder
  fakebin=$(make_tmux "$dir")
  recorder=$(make_recorder "$dir")
  : > "$dir/control.log"
  : > "$dir/tmux.log"
  PATH="$fakebin:$PATH" \
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WAKE_QUEUE="$dir/state/.wake-queue" \
    FM_TEST_SEAM=1 FM_SESSION_END_CONTROL="$recorder" \
    FM_SESSION_END_CONTROL_LOG="$dir/control.log" \
    FM_FAKE_TMUX_CAPTURE="${FM_FAKE_TMUX_CAPTURE:-}" \
    FM_FAKE_TMUX_CURRENT_COMMAND="${FM_FAKE_TMUX_CURRENT_COMMAND:-zsh}" \
    FM_FAKE_WINDOW_GONE="${FM_FAKE_WINDOW_GONE:-0}" \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" \
    fm_session_end_relaunch_scan "$dir/state" "${2:-}"
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
  [ ! -s "$dir/tmux.log" ] || fail "an already-handled lane still probed its endpoint: $(cat "$dir/tmux.log")"
  pass "a dead session-end lane is relaunched once and then left alone"
}

# The watcher assigns FM_HOME and STATE without exporting them, and the
# default home has nothing else that exports FM_HOME.
test_relaunch_hands_control_the_watcher_home() {
  local dir fakebin recorder wait
  dir=$(make_lane unexported-home)
  fakebin=$(make_tmux "$dir")
  recorder=$(make_recorder "$dir")
  : > "$dir/control.log"
  (
    export -n FM_HOME
    unset FM_STATE_OVERRIDE FM_WAKE_QUEUE
    # shellcheck disable=SC2030 # The unexported assignment is meant to stay local to this subshell.
    FM_HOME="$dir"
    export PATH="$fakebin:$PATH" FM_TEST_SEAM=1 FM_SESSION_END_CONTROL="$recorder" \
      FM_SESSION_END_CONTROL_LOG="$dir/control.log" \
      FM_SESSION_END_CONTROL_ENV_LOG="$dir/control-env.log" \
      FM_CONTROL_LAUNCH_WAIT=600
    fm_session_end_relaunch_scan "$dir/state" || exit 1
    printf '%s\n' "$FM_SESSION_END_WAKE" > "$dir/wake"
    printf '%s\n' "$FM_SESSION_END_TIMEOUT" > "$dir/bound"
  ) || fail "scan failed with an unexported FM_HOME"
  [ "$(cat "$dir/wake")" = "check: lane auto-relaunched after session-end" ] \
    || fail "an unexported FM_HOME did not relaunch: $(cat "$dir/wake")"
  grep -Fx "FM_HOME=$dir" "$dir/control-env.log" >/dev/null \
    || fail "control did not get the watcher's home: $(cat "$dir/control-env.log")"
  grep -Fx "FM_STATE_OVERRIDE=$dir/state" "$dir/control-env.log" >/dev/null \
    || fail "control did not get the scanned state dir: $(cat "$dir/control-env.log")"
  wait=$(sed -n 's/^FM_CONTROL_LAUNCH_WAIT=//p' "$dir/control-env.log")
  case "$wait" in
    ''|*[!0-9]*) fail "control did not get a launch wait: $(cat "$dir/control-env.log")" ;;
  esac
  [ "$wait" -lt "$(cat "$dir/bound")" ] \
    || fail "control's launch wait ${wait}s is not inside the $(cat "$dir/bound")s bound"
  pass "the relaunch hands control the watcher's home, state, and a launch wait inside its bound"
}

test_missing_endpoint_is_not_relaunched() {
  local dir
  dir=$(make_lane missing-endpoint)
  FM_FAKE_WINDOW_GONE=1 scan_lane "$dir" || fail "scan failed on a missing endpoint"
  unset FM_FAKE_WINDOW_GONE
  [ ! -s "$dir/control.log" ] || fail "a missing endpoint was relaunched: $(cat "$dir/control.log")"
  [ -z "$FM_SESSION_END_WAKE" ] || fail "a missing endpoint woke: $FM_SESSION_END_WAKE"
  [ ! -e "$dir/state/.session-end-relaunch-lane" ] \
    || fail "a missing endpoint ledgered an attempt: $(cat "$dir/state/.session-end-relaunch-lane")"
  pass "a missing endpoint with session-end is not relaunched"
}

# The watcher touches its beacon once per cycle, and the relaunch blocks
# inside that cycle, so the bound must leave the beacon short of the grace.
test_relaunch_bound_stays_inside_the_watcher_grace() {
  local dir grace start elapsed called
  for grace in '' 300 900; do
    dir=$(make_lane "bound-${grace:-default}")
    FM_POLL=15 scan_lane "$dir" "$grace" || fail "scan failed with grace '${grace:-default}'"
    [ -n "$grace" ] || grace=300
    [ $((grace - FM_SESSION_END_TIMEOUT)) -ge 60 ] \
      || fail "the ${FM_SESSION_END_TIMEOUT}s bound leaves less than 60s of the ${grace}s watcher grace"
    [ "$FM_SESSION_END_LAUNCH_WAIT" -lt "$FM_SESSION_END_TIMEOUT" ] \
      || fail "the ${FM_SESSION_END_LAUNCH_WAIT}s launch wait is not inside the ${FM_SESSION_END_TIMEOUT}s bound"
  done

  dir=$(make_lane bound-kill)
  touch -t 200001010000 "$dir/state/.last-watcher-beat"
  touch -t 200101010000 "$dir/beacon-ref"
  start=$SECONDS
  FM_SESSION_END_CONTROL_SLEEP=60 FM_SESSION_END_BEACON_REF="$dir/beacon-ref" \
    scan_lane "$dir" 66 || fail "scan failed with a short watcher grace"
  elapsed=$((SECONDS - start))
  [ "$elapsed" -lt 60 ] || fail "a relaunch that outlived the bound blocked the scan for ${elapsed}s"
  called=$(( $(date +%s) - $(cat "$dir/beacon-ref.start") ))
  [ "$called" -le $((66 - 60 + 5)) ] \
    || fail "the relaunch call blocked for ${called}s, past the 66s grace less its 60s margin"
  [ "$(cat "$dir/beacon-ref.seen" 2>/dev/null)" = fresh ] \
    || fail "the watcher beacon was not touched before the blocking relaunch call"
  grep -F 'check: lane auto-relaunch failed after session-end' <<<"$FM_SESSION_END_WAKE" >/dev/null \
    || fail "a relaunch cut off by the bound did not wake as failed: ${FM_SESSION_END_WAKE:-<empty>}"

  dir=$(make_lane bound-too-short)
  scan_lane "$dir" 61 || fail "scan failed with a grace too short for the margin"
  [ ! -s "$dir/control.log" ] \
    || fail "a grace with no room for the margin still relaunched: $(cat "$dir/control.log")"
  pass "the relaunch bound stays at least 60s inside the watcher grace and refreshes the beacon first"
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
  printf '%s\tattempt\n%s\tattempt\n%s\tattempt\n' $((now - 1900)) $((now - 4000)) $((now - 8000)) \
    > "$state/.session-end-relaunch-lane"
  scan_lane "$dir" || fail "daily-cap scan failed"
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
  pass "deliberate exit, pause, hold, done, and a live agent are skipped"
}

test_stale_exit_in_scrollback_still_relaunches() {
  local dir gen
  dir=$(make_lane stale-exit)
  gen=$(cat "$dir/state/lane.busy-gen")
  printf 'gen=%s-previous\n' "$gen" > "$dir/state/lane.control-exit"
  printf '❯ /exit\nResume this session with:\n$ claude --debug\nResume this session with:\n' > "$dir/pane"
  FM_FAKE_TMUX_CAPTURE="$dir/pane" scan_lane "$dir" || fail "stale-exit scan failed"
  unset FM_FAKE_TMUX_CAPTURE
  [ "$FM_SESSION_END_WAKE" = "check: lane auto-relaunched after session-end" ] \
    || fail "an old /exit in the pane suppressed the relaunch: ${FM_SESSION_END_WAKE:-<empty>}"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "an old /exit in the pane did not relaunch exactly once: $(cat "$dir/control.log")"
  pass "an old /exit in the pane and an older exit marker do not suppress a later session-end relaunch"
}

test_one_relaunch_per_scan() {
  local dir="$TMP_ROOT/two-lanes" first
  add_lane "$dir" lane-a
  add_lane "$dir" lane-b
  scan_lane "$dir" || fail "two-lane scan failed"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "one scan relaunched more than one lane: $(cat "$dir/control.log")"
  first=$(cut -d' ' -f1 "$dir/control.log")
  scan_lane "$dir" || fail "second two-lane scan failed"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] \
    || fail "the second scan did not relaunch exactly one lane: $(cat "$dir/control.log")"
  [ "$(cut -d' ' -f1 "$dir/control.log")" != "$first" ] \
    || fail "the second scan relaunched $first again instead of the other lane"
  pass "one scan runs at most one relaunch and the next scan takes the next lane"
}

test_unreadable_hold_answer_is_skipped() {
  local dir
  dir=$(make_lane hold-unreadable)
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  mkdir -p "$dir/fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$dir/fakebin/tasks-axi"
  chmod +x "$dir/fakebin/tasks-axi"
  scan_lane "$dir" || fail "unreadable-hold scan failed"
  [ -s "$dir/control.log" ] && fail "a lane whose captain hold could not be read was relaunched: $(cat "$dir/control.log")"
  [ -z "$FM_SESSION_END_WAKE" ] || fail "an unreadable hold answer woke: $FM_SESSION_END_WAKE"
  pass "a lane whose captain hold cannot be read is not relaunched"
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
    "$ROOT/bin/fm-captain-hold.sh" hold lane --reason 'awaiting the captain' \
      --boundary owner-rule-change --if-no 'Keep the existing owner rule' >/dev/null 2>&1 \
    || { pass "backlog hold skip skipped (hold could not be recorded)"; return 0; }
  printf 'working: still open\n' > "$dir/state/lane.status"
  scan_lane "$dir" || fail "held-metadata scan failed"
  [ -s "$dir/control.log" ] && fail "a backlog captain hold was relaunched: $(cat "$dir/control.log")"
  pass "a backlog captain hold is not relaunched"
}

test_claude_debug_is_off_unless_asked() {
  local case_dir home proj wt fakebin id=debug-off out launch status sm form probe env_log arg debug_count
  local -a argv
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
  probe="$case_dir/claude-probe"
  env_log="$case_dir/claude.env"
  mkdir -p "$probe"
  fm_fake_claude_recording "$probe"
  (unset CLAUDE_CODE_DIAGNOSTICS_FILE
    fm_eval_launch "$launch" "$wt" "$probe" HOME="$home" \
      FM_FAKE_CLAUDE_ENV_LOG="$env_log"
  ) || fail "the default Claude launch failed to execute"
  argv=()
  while IFS= read -r -d '' arg; do argv+=("$arg"); done < "$env_log.args"
  for arg in "${argv[@]}"; do
    [ "$arg" != --debug ] || fail "claude debug was on without --claude-debug"
  done
  assert_no_grep 'CLAUDE_CODE_DIAGNOSTICS_FILE=' "$env_log" \
    "claude diagnostics were on without --claude-debug"

  # The relaunch needs the recorded window listed with a bare shell in it.
  mkdir -p "$case_dir/stopped"
  cat > "$case_dir/stopped/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'#{pane_current_command}'*) printf 'zsh\\n'; exit 0 ;;
esac
exec '$fakebin/tmux' "\$@"
SH
  chmod +x "$case_dir/stopped/tmux"
  fakebin="$case_dir/stopped:$fakebin"
  : > "$case_dir/launch.log"
  status=0
  FM_FAKE_DUPLICATE_WINDOW="fm-$id" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" --relaunch --claude-debug > "$case_dir/relaunch.out" || status=$?
  expect_code 0 "$status" "a --relaunch --claude-debug spawn should succeed: $(cat "$case_dir/relaunch.out")"
  launch=$(cat "$case_dir/launch.log")
  (unset CLAUDE_CODE_DIAGNOSTICS_FILE
    fm_eval_launch "$launch" "$wt" "$probe" HOME="$home" \
      FM_FAKE_CLAUDE_ENV_LOG="$env_log"
  ) || fail "the debug Claude relaunch failed to execute"
  argv=()
  while IFS= read -r -d '' arg; do argv+=("$arg"); done < "$env_log.args"
  debug_count=0
  for arg in "${argv[@]}"; do
    if [ "$arg" = --debug ]; then debug_count=$((debug_count + 1)); fi
  done
  [ "$debug_count" -eq 1 ] || fail "claude debug was not enabled exactly once when asked"
  assert_grep "CLAUDE_CODE_DIAGNOSTICS_FILE=$(cd "$home/state" && pwd -P)/$id.claude-diagnostics.jsonl" "$env_log" \
    "the claude launch did not name the diagnostics file that records the stop signal"

  cp "$home/state/$id.meta" "$case_dir/meta.before"
  status=0
  FM_FAKE_DUPLICATE_WINDOW="fm-$id" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" --relaunch --harness pi --claude-debug \
    > "$case_dir/relaunch-pi.out" || status=$?
  expect_code 1 "$status" "a non-claude --claude-debug relaunch must be refused"
  assert_contains "$(cat "$case_dir/relaunch-pi.out")" '--claude-debug applies only to a claude launch' \
    "the harness refusal did not name the flag"
  cmp -s "$case_dir/meta.before" "$home/state/$id.meta" \
    || fail "a refused --claude-debug relaunch changed the task record"

  id=debug-fresh
  fm_test_spawn_brief "$home" "$id"
  sm="$case_dir/mate-home"
  mkdir -p "$sm"
  for form in ship scout secondmate batch; do
    status=0
    case "$form" in
      ship) fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --claude-debug ;;
      scout) fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --scout --claude-debug ;;
      secondmate) fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$sm" --secondmate --claude-debug ;;
      batch) fm_test_run_spawn "$home" "$wt" "$fakebin" "$id=$proj" "$id-b=$proj" --mode no-mistakes --yolo off --claude-debug ;;
    esac > "$case_dir/fresh-$form.out" || status=$?
    expect_code 1 "$status" "a fresh $form spawn with --claude-debug must be refused: $(cat "$case_dir/fresh-$form.out")"
    assert_contains "$(cat "$case_dir/fresh-$form.out")" '--claude-debug applies to --relaunch only' \
      "the fresh $form refusal did not name the flag"
    [ ! -e "$home/state/$id.meta" ] && [ ! -e "$home/state/$id-b.meta" ] \
      || fail "a refused fresh $form --claude-debug spawn published a task record"
  done
  pass "claude debug is off by default, on for a claude relaunch, and refused for another harness or a fresh spawn"
}

# A scan in a freshly started process, as the real watcher exits after a wake and a successor runs the next scan:
# state kept only in the first process cannot make these cases pass.
scan_lane_fresh() {  # <dir>
  local dir=$1 fakebin recorder
  fakebin=$(make_tmux "$dir")
  recorder=$(make_recorder "$dir")
  : > "$dir/control.log"
  # shellcheck disable=SC2016 # The single-quoted program expands in the freshly started shell.
  env FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_WAKE_QUEUE="$dir/state/.wake-queue" \
    FM_TEST_SEAM=1 FM_SESSION_END_CONTROL="$recorder" FM_SESSION_END_CONTROL_LOG="$dir/control.log" \
    FM_SESSION_END_CONTROL_RC="${FM_SESSION_END_CONTROL_RC:-0}" FM_SESSION_END_CONTROL_OUT="${FM_SESSION_END_CONTROL_OUT:-}" \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" \
    bash -c 'export PATH="$3:$PATH"; . "$1/bin/fm-session-end-relaunch-lib.sh"; fm_session_end_relaunch_scan "$2/state"; printf "%s" "$FM_SESSION_END_WAKE" > "$2/wake"' _ "$ROOT" "$dir" "$fakebin"
  FM_SESSION_END_WAKE=$(cat "$dir/wake")
}

# Age every ledger row past the 30-minute cap, as if the next scan came much later.
age_ledger() {  # <dir>
  local dir=$1 ledger
  ledger="$dir/state/.session-end-relaunch-lane"
  awk -F '\t' -v OFS='\t' '{ $1 = $1 - 4000; print }' "$ledger" > "$ledger.aged" && mv "$ledger.aged" "$ledger"
}

# Main 115: an unchanged refusal is reported once and not retried every 30 minutes; a changed cause permits one attempt.
test_unchanged_refusal_is_reported_once_and_not_retried() {
  local dir state refusal='error: slot adoption refused: manifest_exists: the manifest is not adoptable'
  dir=$(make_lane refusal-memory)
  state="$dir/state"
  FM_SESSION_END_CONTROL_RC=1 FM_SESSION_END_CONTROL_OUT="$refusal" scan_lane_fresh "$dir" || fail "the first scan failed"
  case "$FM_SESSION_END_WAKE" in
    *'auto-relaunch failed after session-end'*'refused: manifest_exists'*'not retried by the scan'*) ;;
    *) fail "the first refusal was not reported by name once: ${FM_SESSION_END_WAKE:-<empty>}" ;;
  esac
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] || fail 'the first scan did not attempt exactly once'
  [ -f "$state/.session-end-refusal-lane" ] || fail 'the refusal left no durable record for a successor scanner'
  local rows
  rows=$(wc -l < "$state/.wake-queue" | tr -d ' ')
  for _ in 1 2 3; do
    age_ledger "$dir"
    FM_SESSION_END_CONTROL_RC=1 FM_SESSION_END_CONTROL_OUT="$refusal" scan_lane_fresh "$dir" || fail "a later scan failed"
    [ ! -s "$dir/control.log" ] || fail "an unchanged refusal was retried: $(cat "$dir/control.log")"
    [ -z "$FM_SESSION_END_WAKE" ] || fail "an unchanged refusal woke again: $FM_SESSION_END_WAKE"
    [ "$(wc -l < "$state/.wake-queue" | tr -d ' ')" = "$rows" ] || fail 'an unchanged refusal wrote another wake row'
  done
  # the cause changes: the recorded manifest pointer changes, so one new attempt is permitted
  printf 'slot_manifest=/elsewhere/manifest.json\n' >> "$state/lane.meta"
  age_ledger "$dir"
  FM_SESSION_END_CONTROL_RC=1 FM_SESSION_END_CONTROL_OUT="$refusal" scan_lane_fresh "$dir" || fail "the scan after a changed cause failed"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] || fail "a changed cause did not permit exactly one attempt: $(cat "$dir/control.log")"
  pass "an unchanged slot refusal is reported once and not retried by successor scanners; a changed cause permits one attempt"
}

# An outcome that is not a refusal keeps today's caps and retries.
test_a_non_refusal_failure_keeps_its_retry() {
  local dir
  dir=$(make_lane non-refusal)
  FM_SESSION_END_CONTROL_RC=1 FM_SESSION_END_CONTROL_OUT='error: the replacement agent could not be launched on claude' scan_lane_fresh "$dir" \
    || fail "the first scan failed"
  [ ! -e "$dir/state/.session-end-refusal-lane" ] || fail 'a launch failure was remembered as a refusal'
  age_ledger "$dir"
  FM_SESSION_END_CONTROL_RC=1 FM_SESSION_END_CONTROL_OUT='error: the replacement agent could not be launched on claude' scan_lane_fresh "$dir" \
    || fail "the later scan failed"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] || fail 'a launch failure was not retried after the cap window'
  pass "a failure that is not a refusal keeps today's retry"
}

# D9: a successful automatic relaunch that starts with out-of-scope work, and a refusal that names it, deliver the complete report.
test_drift_report_reaches_the_observer() {
  local dir report
  report=$(printf '%s\n' 'relaunch drift report for lane: 2 out-of-scope path(s) changed by this task'"'"'s own work; the recorded scope is unchanged' \
    '  drift: proven docs/b.txt' '  drift: uncertain,ignored cache dir' '  a relaunch is not a new scope declaration')
  dir=$(make_lane drift-success)
  FM_SESSION_END_CONTROL_RC=0 FM_SESSION_END_CONTROL_OUT="$report" scan_lane_fresh "$dir" || fail "the scan failed"
  case "$FM_SESSION_END_WAKE" in
    *'auto-relaunched after session-end'*'docs/b.txt'*'uncertain,ignored cache dir'*) ;;
    *) fail "the wake did not carry the complete drift report: ${FM_SESSION_END_WAKE:-<empty>}" ;;
  esac
  grep -F 'drift: proven docs/b.txt' "$dir/state/lane.relaunch-drift" >/dev/null || fail 'the durable report is missing'
  dir=$(make_lane drift-refusal)
  FM_SESSION_END_CONTROL_RC=1 FM_SESSION_END_CONTROL_OUT="$(printf '%s\n' "$report" 'error: slot provisioning refused: dirty_worktree; preserve and reconcile')" \
    scan_lane_fresh "$dir" || fail "the refusal scan failed"
  case "$FM_SESSION_END_WAKE" in
    *'dirty_worktree'*'docs/b.txt'*) ;;
    *) fail "the dirty refusal did not carry the complete drift report: ${FM_SESSION_END_WAKE:-<empty>}" ;;
  esac
  pass "the complete drift report reaches the observer on a relaunch and on a dirty refusal"
}

# The control print and the spawn print both reach the captured output: the wake and the durable file hold the first report once.
test_two_printed_reports_are_listed_once() {
  local dir report out file n
  report=$(printf '%s\n' 'relaunch drift report for lane: 2 out-of-scope path(s) changed by this task'"'"'s own work; the recorded scope is unchanged' \
    '  drift: proven docs/b.txt' '  drift: uncertain,ignored cache dir' '  limitation: shallow history' '  a relaunch is not a new scope declaration')
  out=$(printf '%s\n' "$report" 'spawn: launching the agent' "$report" 'spawn: the agent started')
  dir=$(make_lane drift-twice)
  FM_SESSION_END_CONTROL_RC=0 FM_SESSION_END_CONTROL_OUT="$out" scan_lane_fresh "$dir" || fail "the scan failed"
  case "$FM_SESSION_END_WAKE" in *'drift report: 2 out-of-scope path(s)'*) ;; *) fail "the wake has no count of 2: $FM_SESSION_END_WAKE" ;; esac
  for n in 'docs/b.txt' 'uncertain,ignored cache dir' 'shallow history'; do
    [ "$(printf '%s' "$FM_SESSION_END_WAKE" | grep -o -F "$n" | wc -l | tr -d ' ')" = 1 ] || fail "the wake does not list $n once: $FM_SESSION_END_WAKE"
  done
  file="$dir/state/lane.relaunch-drift"
  [ "$(grep -c '^relaunch drift report for ' "$file")" = 1 ] || fail "the durable file holds more than one report: $(cat "$file")"
  [ "$(grep -c '^  drift: ' "$file")" = 2 ] || fail "the durable file does not list the 2 counted paths: $(cat "$file")"
  for n in '  drift: proven docs/b.txt' '  drift: uncertain,ignored cache dir' '  limitation: shallow history'; do
    [ "$(grep -c -x -F "$n" "$file")" = 1 ] || fail "the durable file does not list '$n' once: $(cat "$file")"
  done
  ! grep -F 'spawn:' "$file" >/dev/null || fail "the durable file holds unrelated spawn output: $(cat "$file")"
  pass "two printed reports are listed once, with a count that matches the paths, in the wake and in the durable file"
}

# The could-not-be-produced report is one line: the durable file holds that header and nothing after it.
test_could_not_be_produced_report_is_one_line() {
  local dir header out
  header='relaunch drift report for lane: could not be produced (python3 failed); this is a limitation of the report, not a statement that the task stayed in scope'
  out=$(printf '%s\n' "$header" 'control: stopping the agent' 'spawn: launching the agent' \
    'relaunch drift report for lane: 1 out-of-scope path(s) changed by this task'"'"'s own work; the recorded scope is unchanged' \
    '  drift: proven docs/b.txt' '  a relaunch is not a new scope declaration')
  dir=$(make_lane drift-could-not)
  FM_SESSION_END_CONTROL_RC=0 FM_SESSION_END_CONTROL_OUT="$out" scan_lane_fresh "$dir" || fail "the scan failed"
  [ "$(cat "$dir/state/lane.relaunch-drift")" = "$header" ] || fail "the durable file holds more than the one header line: $(cat "$dir/state/lane.relaunch-drift")"
  pass "a could-not-be-produced report is kept as its one header line in the durable file"
}

# A fresh session-end generation for the lane, as a later worker death produces.
new_generation() {  # <dir>
  local dir=$1 gen
  "$ROOT/bin/fm-busy-event.sh" arm "$dir/state" lane --state idle --source claude-hook --event launch-brief >/dev/null
  gen=$(cat "$dir/state/lane.busy-gen")
  "$ROOT/bin/fm-busy-event.sh" apply "$dir/state" lane idle --gen "$gen" --source claude-hook --event session-end >/dev/null
}

# F5: the memory is keyed on the obstruction, not on the busy generation or the raw HEAD.
test_unchanged_refusal_survives_a_new_generation_and_an_unrelated_commit() {
  local dir state wt refusal='error: slot provisioning refused: scope_mismatch: docs/out.txt changed outside the recorded scope'
  dir=$(make_lane refusal-effective-inputs)
  state="$dir/state"
  wt="$dir/wt-lane"
  git init -q -b main "$wt"
  mkdir -p "$wt/src" "$wt/docs"
  printf 'a\n' > "$wt/src/a.txt"
  printf 'd\n' > "$wt/docs/d.txt"
  git -C "$wt" add -A
  git -C "$wt" -c user.name=T -c user.email=t@example.invalid commit -qm base
  git -C "$wt" update-ref refs/remotes/origin/main HEAD
  printf 'slot_owned_path=src\nbranch=main\n' >> "$state/lane.meta"
  printf 'out\n' > "$wt/docs/out.txt"
  git -C "$wt" add -A
  git -C "$wt" -c user.name=T -c user.email=t@example.invalid commit -qm 'own change outside the scope'
  FM_SESSION_END_CONTROL_RC=1 FM_SESSION_END_CONTROL_OUT="$refusal" scan_lane_fresh "$dir" || fail "the first scan failed"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] || fail 'the first scan did not attempt once'
  # only the busy generation advances: no attempt, no wake
  new_generation "$dir"
  age_ledger "$dir"
  FM_SESSION_END_CONTROL_RC=1 FM_SESSION_END_CONTROL_OUT="$refusal" scan_lane_fresh "$dir" || fail "the scan after a new generation failed"
  [ ! -s "$dir/control.log" ] || fail "a new busy generation retried an unchanged refusal: $(cat "$dir/control.log")"
  [ -z "$FM_SESSION_END_WAKE" ] || fail "a new busy generation woke again: $FM_SESSION_END_WAKE"
  # only an unrelated commit wholly inside the recorded scope: the same obstruction, so no attempt
  printf 'b\n' > "$wt/src/b.txt"
  git -C "$wt" add -A
  git -C "$wt" -c user.name=T -c user.email=t@example.invalid commit -qm 'in-scope work'
  age_ledger "$dir"
  FM_SESSION_END_CONTROL_RC=1 FM_SESSION_END_CONTROL_OUT="$refusal" scan_lane_fresh "$dir" || fail "the scan after an in-scope commit failed"
  [ ! -s "$dir/control.log" ] || fail "an unrelated in-scope commit retried an unchanged refusal: $(cat "$dir/control.log")"
  # the obstruction really changes (a different out-of-scope path set): exactly one attempt
  git -C "$wt" rm -q docs/out.txt
  git -C "$wt" -c user.name=T -c user.email=t@example.invalid commit -qm 'revert the out-of-scope change'
  age_ledger "$dir"
  FM_SESSION_END_CONTROL_RC=1 FM_SESSION_END_CONTROL_OUT="$refusal" scan_lane_fresh "$dir" || fail "the scan after the obstruction changed failed"
  [ "$(wc -l < "$dir/control.log" | tr -d ' ')" = 1 ] || fail "a cleared obstruction did not permit one attempt: $(cat "$dir/control.log")"
  pass "an unchanged slot refusal is not retried after a new generation or an unrelated commit; a real change to the obstruction permits one attempt"
}

# F6: a long drift report keeps its stable durable reference through the wake's 4096-character fallback cap.
test_long_drift_report_keeps_its_durable_reference_at_the_fallback() {
  local dir report i capped
  # shellcheck source=bin/fm-push-transition-lib.sh
  . "$ROOT/bin/fm-push-transition-lib.sh"
  dir=$(make_lane long-drift)
  report='relaunch drift report for lane: 100 out-of-scope path(s) changed by this task'"'"'s own work; the recorded scope is unchanged'
  for i in $(seq 1 100); do report=$report$'\n'"  drift: proven docs/generated/very/long/directory/name/for/path-number-$i.txt"; done
  FM_SESSION_END_CONTROL_RC=0 FM_SESSION_END_CONTROL_OUT="$report" scan_lane_fresh "$dir" || fail "the scan failed"
  [ "${#FM_SESSION_END_WAKE}" -gt 4096 ] || fail 'the fixture reason is not over the fallback cap'
  capped=$(watch_delivery_clean_reason "$FM_SESSION_END_WAKE")
  [ "${#capped}" = 4096 ] || fail "the fallback did not cap the reason: ${#capped}"
  case "$capped" in *"$dir/state/lane.relaunch-drift"*) ;; *) fail 'the durable report path was lost at the fallback cap' ;; esac
  [ "$(grep -c 'drift: proven' "$dir/state/lane.relaunch-drift")" = 100 ] || fail 'the durable report is not complete'
  grep -F 'path-number-100.txt' "$dir/state/lane.relaunch-drift" >/dev/null || fail 'the last path is missing from the durable report'
  # a short report stays whole in the reason
  dir=$(make_lane short-drift)
  FM_SESSION_END_CONTROL_RC=0 FM_SESSION_END_CONTROL_OUT=$'relaunch drift report for lane: 1 out-of-scope path(s) changed by this task\'s own work\n  drift: proven docs/b.txt' scan_lane_fresh "$dir" || fail "the short scan failed"
  case "$FM_SESSION_END_WAKE" in *'docs/b.txt'*"$dir/state/lane.relaunch-drift"*|*"$dir/state/lane.relaunch-drift"*'docs/b.txt'*) ;; *) fail "the short report is not whole in the reason: $FM_SESSION_END_WAKE" ;; esac
  pass "a long drift report keeps its durable reference through the fallback cap; a short one stays whole"
}

test_session_end_relaunches_a_dead_lane_once
test_unchanged_refusal_is_reported_once_and_not_retried
test_unchanged_refusal_survives_a_new_generation_and_an_unrelated_commit
test_long_drift_report_keeps_its_durable_reference_at_the_fallback
test_a_non_refusal_failure_keeps_its_retry
test_drift_report_reaches_the_observer
test_two_printed_reports_are_listed_once
test_could_not_be_produced_report_is_one_line
test_relaunch_hands_control_the_watcher_home
test_missing_endpoint_is_not_relaunched
test_relaunch_bound_stays_inside_the_watcher_grace
test_cap_holds_and_wakes_once
test_deliberate_exit_and_waits_are_skipped
test_stale_exit_in_scrollback_still_relaunches
test_one_relaunch_per_scan
test_unreadable_hold_answer_is_skipped
test_backlog_hold_is_skipped
test_claude_debug_is_off_unless_asked
