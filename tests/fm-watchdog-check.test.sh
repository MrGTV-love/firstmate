#!/usr/bin/env bash
# Behavior tests for bin/fm-watchdog-check.sh and bin/fm-watchdog-install.sh.
#
# Each case builds a temp FM_HOME, runs the real check script against it, and
# asserts the verdict, the recovery actions it took, and the alarm it raised.
# The session is a sleep whose argv[0] is claude, so fm_harness_pid_alive sees a
# real harness-shaped process. Recovery steps are recorded by stubs wired
# through the documented test seams; no real watcher, launchd, or notification
# is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watchdog-check)
SESSION_PIDS=()
cleanup_sessions() {
  local pid
  for pid in ${SESSION_PIDS[@]+"${SESSION_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
}
trap cleanup_sessions EXIT

start_session() {  # prints the pid of a live harness-shaped process
  bash -c 'exec -a claude /bin/sleep 600' >/dev/null 2>&1 &
  SESSION_PIDS+=("$!")
  printf '%s\n' "$!"
}

dead_pid() {
  local pid
  /bin/sleep 0 &
  pid=$!
  wait "$pid" 2>/dev/null
  printf '%s\n' "$pid"
}

# make_home <name> [session=live|dead]: a home that needs supervision.
make_home() {
  local name=$1 session=${2:-live} home pid
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/state" "$home/config"
  fm_write_meta "$home/state/task.meta" "window=firstmate:fm-task" "kind=ship"
  if [ "$session" = live ]; then
    pid=$(start_session)
  else
    pid=$(dead_pid)
  fi
  printf '%s\n' "$pid" > "$home/state/.lock"
  : > "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

stale_beat() { touch -t 201901010000 "$1/state/.last-watcher-beat"; }

write_ledger() {  # <home> <outcome> <owner-pid>
  printf 'epoch=7 owner_pid=%s outcome=%s updated_at=1\n' "$3" "$2" > "$1/state/.claude-autoarm-epoch"
}

# Recorder and recovery stubs live beside the home.
write_stubs() {  # <home> <resume-body>
  local home=$1 body=$2 dir
  dir=$(dirname "$home")
  cat > "$dir/arm.sh" <<STUB
#!/bin/sh
echo "\$@" >> "$dir/arm.calls"
STUB
  chmod +x "$dir/arm.sh"
  cat > "$dir/alarm.sh" <<STUB
#!/bin/sh
echo "\$*" >> "$dir/alarm.calls"
STUB
  chmod +x "$dir/alarm.sh"
  printf '%s\n' "$body" > "$home/config/watchdog-resume"
}

run_check() {  # <home> [extra env assignments...]; sets OUT and CODE
  local home=$1 dir
  shift
  dir=$(dirname "$home")
  OUT=$(env FM_HOME="$home" FM_WATCHDOG_ARM="$dir/arm.sh" FM_WATCHDOG_VERIFY_SECS=1 \
    FM_WATCHDOG_STEP_SECS=20 FM_WEDGE_ALARM_EXEC="$dir/alarm.sh" \
    FM_WEDGE_ALARM_CHANNEL='command:true' "$@" "$ROOT/bin/fm-watchdog-check.sh" 2>&1)
  CODE=$?
}

# A resume command that restores health, recording its reason. With a session
# pid it also takes the session lock, as a relaunched session would.
healing_resume() {  # <home> [session-pid]
  local dir
  dir=$(dirname "$1")
  # shellcheck disable=SC2016 # The resume command expands FM_WATCHDOG_REASON itself.
  printf 'echo "$FM_WATCHDOG_REASON" >> "%s/resume.calls"; touch "%s/state/.last-watcher-beat"; [ -z "%s" ] || echo "%s" > "%s/state/.lock"' \
    "$dir" "$1" "${2:-}" "${2:-}" "$1"
}

test_fresh_state_does_nothing() {
  local home dir
  home=$(make_home fresh)
  dir=$(dirname "$home")
  write_ledger "$home" rewake "$(dead_pid)"
  write_stubs "$home" "$(healing_resume "$home")"
  run_check "$home"
  expect_code 0 "$CODE" "fresh state exit"
  assert_contains "$OUT" "watchdog: healthy" "fresh state verdict"
  assert_absent "$dir/resume.calls" "fresh state must not resume the session"
  assert_absent "$dir/arm.calls" "fresh state must not touch the watcher"
  assert_absent "$home/state/.watchdog-episode" "fresh state leaves no episode"
  pass "fresh state reads healthy and acts on nothing"
}

test_idle_home_does_nothing() {
  local home dir
  home=$(make_home idle)
  dir=$(dirname "$home")
  rm -f "$home/state/task.meta"
  stale_beat "$home"
  write_stubs "$home" "$(healing_resume "$home")"
  run_check "$home"
  expect_code 0 "$CODE" "idle exit"
  assert_contains "$OUT" "watchdog: idle" "idle verdict"
  assert_absent "$dir/resume.calls" "an idle home needs no recovery"
  pass "a home with no work reads idle even with a stale beacon"
}

test_missing_home_is_idle() {
  OUT=$(env FM_HOME="$TMP_ROOT/nowhere" "$ROOT/bin/fm-watchdog-check.sh" 2>&1)
  expect_code 0 "$?" "missing home exit"
  assert_contains "$OUT" "watchdog: idle" "missing home verdict"
  assert_absent "$TMP_ROOT/nowhere" "a missing home must not be created"
  pass "a missing home reads idle and is not created"
}

test_stale_watcher_recovers() {
  local home dir
  home=$(make_home stale)
  dir=$(dirname "$home")
  stale_beat "$home"
  write_ledger "$home" rewake "$(dead_pid)"
  write_stubs "$home" "$(healing_resume "$home")"
  run_check "$home"
  expect_code 0 "$CODE" "stale watcher exit"
  assert_contains "$OUT" "watchdog: recovered from stale-watcher" "stale watcher verdict"
  assert_equals "stale-watcher" "$(cat "$dir/resume.calls")" "resume command receives the reason"
  assert_absent "$home/state/.watchdog-episode" "a recovery clears the episode"
  assert_absent "$dir/alarm.calls" "a recovery raises no alarm"
  pass "a stale watcher with a live session is resumed and recovers"
}

test_stale_watcher_with_live_pid_is_stopped_first() {
  local home dir holder
  home=$(make_home hung)
  dir=$(dirname "$home")
  stale_beat "$home"
  write_ledger "$home" rewake "$(dead_pid)"
  holder=$(start_session)
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$holder" > "$home/state/.watch.lock/pid"
  write_stubs "$home" "$(healing_resume "$home")"
  run_check "$home"
  expect_code 0 "$CODE" "hung watcher exit"
  assert_equals "--stop" "$(cat "$dir/arm.calls")" "the home-scoped stop is the only watcher action"
  kill -0 "$holder" 2>/dev/null || fail "the check must not signal the watcher pid itself"
  pass "a hung watcher is stopped through the arm's home-scoped --stop only"
}

test_dead_arm_owner_is_named() {
  local home dir
  home=$(make_home deadarm)
  dir=$(dirname "$home")
  stale_beat "$home"
  write_ledger "$home" arming "$(dead_pid)"
  write_stubs "$home" "$(healing_resume "$home")"
  run_check "$home"
  expect_code 0 "$CODE" "dead arm owner exit"
  assert_contains "$OUT" "watchdog: recovered from dead-arm-owner" "dead arm owner verdict"
  assert_equals "dead-arm-owner" "$(cat "$dir/resume.calls")" "resume reason names the dead arm owner"
  pass "an arming ledger with a dead owner reads dead-arm-owner and recovers"
}

test_live_arm_owner_is_not_dead_arm() {
  local home dir owner
  home=$(make_home livearm)
  dir=$(dirname "$home")
  stale_beat "$home"
  owner=$(start_session)
  write_ledger "$home" arming "$owner"
  write_stubs "$home" "$(healing_resume "$home")"
  run_check "$home"
  assert_equals "stale-watcher" "$(cat "$dir/resume.calls")" "a live arm owner is only a stale watcher"
  pass "an arming ledger with a live owner is not called a dead arm owner"
}

test_missing_session_relaunches() {
  local home dir
  home=$(make_home gone dead)
  dir=$(dirname "$home")
  write_ledger "$home" rewake "$(dead_pid)"
  write_stubs "$home" "$(healing_resume "$home" "$(start_session)")"
  run_check "$home"
  expect_code 0 "$CODE" "missing session exit"
  assert_contains "$OUT" "watchdog: recovered from session-missing" "missing session verdict"
  assert_equals "session-missing" "$(cat "$dir/resume.calls")" "resume reason names the missing session"
  pass "a dead session lock is resumed through the configured command"
}

test_absent_lock_is_missing_session() {
  local home dir
  home=$(make_home nolock)
  dir=$(dirname "$home")
  rm -f "$home/state/.lock"
  write_stubs "$home" "$(healing_resume "$home" "$(start_session)")"
  run_check "$home"
  assert_equals "session-missing" "$(cat "$dir/resume.calls")" "an absent lock is a missing session"
  pass "an absent session lock reads session-missing"
}

test_failed_recovery_alarms_after_threshold() {
  local home dir
  home=$(make_home fail dead)
  dir=$(dirname "$home")
  write_ledger "$home" rewake "$(dead_pid)"
  write_stubs "$home" 'true'
  run_check "$home" FM_TEST_SEAM=1 FM_WATCHDOG_NOW=1000
  expect_code 1 "$CODE" "first failed recovery exit"
  assert_contains "$OUT" "recovery failed (attempt 1)" "first failure report"
  assert_absent "$dir/alarm.calls" "one failure stays below the alarm threshold"
  run_check "$home" FM_TEST_SEAM=1 FM_WATCHDOG_NOW=1100
  expect_code 0 "$CODE" "inside the retry interval"
  assert_contains "$OUT" "waiting out the retry interval" "retry interval wait"
  assert_absent "$dir/alarm.calls" "waiting raises no alarm"
  run_check "$home" FM_TEST_SEAM=1 FM_WATCHDOG_NOW=1300
  expect_code 1 "$CODE" "second failed recovery exit"
  assert_contains "$OUT" "recovery failed (attempt 2)" "second failure report"
  assert_present "$dir/alarm.calls" "the second failure raises the alarm"
  assert_contains "$(cat "$dir/alarm.calls")" "session-missing" "the alarm names the verdict"
  run_check "$home" FM_TEST_SEAM=1 FM_WATCHDOG_NOW=1600
  assert_equals "1" "$(wc -l < "$dir/alarm.calls" | tr -d ' ')" "the alarm is rate limited"
  run_check "$home" FM_TEST_SEAM=1 FM_WATCHDOG_NOW=5000
  assert_equals "2" "$(wc -l < "$dir/alarm.calls" | tr -d ' ')" "the alarm repeats after its interval"
  pass "a failing recovery alarms after the threshold and then rate limits"
}

test_missing_resume_command_fails_and_logs() {
  local home dir
  home=$(make_home noresume dead)
  dir=$(dirname "$home")
  write_stubs "$home" 'true'
  rm -f "$home/config/watchdog-resume"
  run_check "$home"
  expect_code 1 "$CODE" "no resume command exit"
  assert_grep "no config/watchdog-resume" "$home/state/.watchdog.log" "the log names the missing command"
  pass "an absent resume command is a recorded failed recovery"
}

test_recovery_after_failures_clears_episode() {
  local home dir
  home=$(make_home heal dead)
  dir=$(dirname "$home")
  write_ledger "$home" rewake "$(dead_pid)"
  write_stubs "$home" 'true'
  run_check "$home" FM_TEST_SEAM=1 FM_WATCHDOG_NOW=1000
  assert_present "$home/state/.watchdog-episode" "a failure opens an episode"
  write_stubs "$home" "$(healing_resume "$home" "$(start_session)")"
  run_check "$home" FM_TEST_SEAM=1 FM_WATCHDOG_NOW=1300
  expect_code 0 "$CODE" "healthy after failure exit"
  assert_absent "$home/state/.watchdog-episode" "health clears the episode"
  pass "a healthy verdict after failures clears the episode"
}

test_installer_renders_and_registers() {
  local dir calls plist
  dir="$TMP_ROOT/installer"
  mkdir -p "$dir/agents" "$dir/home/state"
  cat > "$dir/launchctl.sh" <<STUB
#!/bin/sh
echo "\$@" >> "$dir/launchctl.calls"
case "\$1" in print) exit 1 ;; esac
exit 0
STUB
  chmod +x "$dir/launchctl.sh"
  OUT=$(env FM_HOME="$dir/home" FM_TEST_SEAM=1 FM_WATCHDOG_AGENT_DIR="$dir/agents" \
    FM_WATCHDOG_LAUNCHCTL="$dir/launchctl.sh" "$ROOT/bin/fm-watchdog-install.sh" install --interval 60 2>&1)
  expect_code 0 "$?" "install exit"
  plist=$(ls "$dir/agents"/com.firstmate.watchdog.*.plist)
  assert_grep "<string>$dir/home</string>" "$plist" "plist names the home"
  assert_grep "<integer>60</integer>" "$plist" "plist carries the interval"
  assert_grep "$ROOT/bin/fm-watchdog-check.sh" "$plist" "plist runs the check script"
  ! grep -E '@[A-Z_]+@' "$plist" >/dev/null || fail "plist has an unfilled token"
  calls=$(cat "$dir/launchctl.calls")
  assert_contains "$calls" "bootstrap gui/" "install bootstraps into the user domain"
  OUT=$(env FM_HOME="$dir/home" FM_TEST_SEAM=1 FM_WATCHDOG_AGENT_DIR="$dir/agents" \
    FM_WATCHDOG_LAUNCHCTL="$dir/launchctl.sh" "$ROOT/bin/fm-watchdog-install.sh" install --interval 5 2>&1)
  expect_code 1 "$?" "too-short interval exit"
  pass "install renders the plist for the home and bootstraps it"
}

test_installer_uninstall_removes_plist() {
  local dir
  dir="$TMP_ROOT/installer"
  cat > "$dir/launchctl-loaded.sh" <<STUB
#!/bin/sh
echo "\$@" >> "$dir/launchctl-loaded.calls"
case "\$1" in
  print) [ -e "$dir/booted-out" ] && exit 1; exit 0 ;;
  bootout) : > "$dir/booted-out"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$dir/launchctl-loaded.sh"
  OUT=$(env FM_HOME="$dir/home" FM_TEST_SEAM=1 FM_WATCHDOG_AGENT_DIR="$dir/agents" \
    FM_WATCHDOG_LAUNCHCTL="$dir/launchctl-loaded.sh" "$ROOT/bin/fm-watchdog-install.sh" uninstall 2>&1)
  expect_code 0 "$?" "uninstall exit"
  assert_contains "$(cat "$dir/launchctl-loaded.calls")" "bootout gui/" "uninstall boots the agent out"
  [ -z "$(ls "$dir/agents" 2>/dev/null)" ] || fail "uninstall must delete the plist"
  pass "uninstall boots the agent out and deletes its plist"
}

test_fresh_state_does_nothing
test_idle_home_does_nothing
test_missing_home_is_idle
test_stale_watcher_recovers
test_stale_watcher_with_live_pid_is_stopped_first
test_dead_arm_owner_is_named
test_live_arm_owner_is_not_dead_arm
test_missing_session_relaunches
test_absent_lock_is_missing_session
test_failed_recovery_alarms_after_threshold
test_missing_resume_command_fails_and_logs
test_recovery_after_failures_clears_episode
test_installer_renders_and_registers
test_installer_uninstall_removes_plist
