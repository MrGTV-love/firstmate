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

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (plist and heartbeat fixtures)"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-watchdog-check)

start_session() {  # prints the pid of a live harness-shaped process
  local pid pidfile
  pidfile=$(mktemp "$TMP_ROOT/session.XXXXXX") || return 1
  fm_test_track_process "$pidfile" claude || return 1
  bash -c 'exec -a claude /bin/sleep 600' >/dev/null 2>&1 &
  pid=$!
  fm_test_record_process "$pidfile" "$pid" || {
    kill "$pid" 2>/dev/null || true
    return 1
  }
  printf '%s\n' "$pid"
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

test_bound_rewake_has_finite_grace() {
  local home dir pid
  home=$(make_home boundrewake)
  dir=$(dirname "$home")
  pid=$(cat "$home/state/.lock")
  printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=watchdog-test\n' \
    "$pid" > "$home/state/.claude-autoarm-epoch"
  printf 'acked:handling:watchdog-test\n' > "$home/state/.watcher-down"
  write_stubs "$home" 'true'
  python3 - "$home/state/.last-watcher-beat" <<'PY'
import os, sys, time
stamp = time.time() - 1000
os.utime(sys.argv[1], (stamp, stamp))
PY
  run_check "$home"
  expect_code 0 "$CODE" "bound rewake at 1000 seconds exit"
  assert_equals "watchdog: healthy" "$OUT" "bound rewake gets longer handling grace"
  assert_absent "$dir/resume.calls" "a legitimate long turn is not resumed"
  assert_absent "$home/state/.watchdog-episode" "a legitimate long turn leaves no episode"
  python3 - "$home/state/.last-watcher-beat" <<'PY'
import os, sys, time
stamp = time.time() - 3700
os.utime(sys.argv[1], (stamp, stamp))
PY
  run_check "$home" FM_WATCHDOG_NOW=1000
  expect_code 1 "$CODE" "bound rewake at 3700 seconds exit"
  assert_contains "$OUT" "watchdog: stale-watcher - recovery failed" "bound rewake expires"
  assert_present "$home/state/.watchdog-episode" "an expired turn remains a failed episode"
  run_check "$home" FM_WATCHDOG_NOW=1300 FM_WATCHDOG_STALE_SECS=7200
  expect_code 1 "$CODE" "bound rewake at 3700 seconds with extended stale threshold exit"
  assert_contains "$OUT" "watchdog: stale-watcher - recovery failed (attempt 2)" "ordinary freshness cannot bypass the handling cap or clear the episode"
  assert_present "$home/state/.watchdog-episode" "extended stale threshold preserves the failed episode"
  write_stubs "$home" "$(healing_resume "$home")"
  run_check "$home" FM_WATCHDOG_NOW=1600 FM_WATCHDOG_STALE_SECS=7200
  expect_code 0 "$CODE" "expired bound rewake recovery exit"
  assert_equals "stale-watcher" "$(cat "$dir/resume.calls")" "expired turn resumes as stale"
  assert_absent "$home/state/.watchdog-episode" "a fresh beacon clears the expired episode"
  pass "a bound rewake is healthy at 1000 seconds and stale at 3700 seconds"
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

test_reused_watchdog_pid_is_reclaimed() {
  local home dir holder layout evidence lock owner mutex_owner
  holder=$(start_session)
  for layout in directory symlink; do
    for evidence in mismatched missing; do
      home=$(make_home "reused-$layout-$evidence")
      dir=$(dirname "$home")
      stale_beat "$home"
      write_ledger "$home" rewake "$(dead_pid)"
      write_stubs "$home" "$(healing_resume "$home")"
      lock="$home/state/.watchdog.lock"
      if [ "$layout" = symlink ]; then
        owner="$lock.owner.fixture"
        mkdir "$owner"
        ln -s "$owner" "$lock"
      else
        owner=$lock
        mkdir "$lock"
      fi
      printf '%s\n' "$holder" > "$lock/pid"
      if [ "$evidence" = mismatched ]; then
        printf 'previous-boot %s\n' "$(fm_test_pid_identity "$holder")" > "$lock/pid-identity"
      fi
      mutex_owner="$lock.steal.owner.fixture"
      mkdir "$mutex_owner"
      ln -s "$mutex_owner" "$lock.steal"
      printf '%s\n' "$holder" > "$lock.steal/pid"
      fm_test_pid_identity "$holder" > "$lock.steal/pid-identity"
      run_check "$home"
      expect_code 0 "$CODE" "live reclaim mutex contention exit"
      assert_equals "watchdog: another check is running" "$OUT" "matching reclaim owner excludes a check"
      assert_absent "$dir/resume.calls" "a live reclaim mutex prevents concurrent recovery"
      printf 'previous-boot\n' > "$lock.steal/pid-identity"
      run_check "$home"
      expect_code 0 "$CODE" "reused watchdog pid recovery exit"
      assert_equals "watchdog: recovered from stale-watcher" "$OUT" "reused pid cannot suppress supervision"
      assert_equals "stale-watcher" "$(cat "$dir/resume.calls")" "reclaimed watchdog runs recovery"
      kill -0 "$holder" 2>/dev/null || fail "reclaim must not signal the reused pid"
      assert_absent "$lock" "reclaimed watchdog releases its lock"
      assert_absent "$owner" "reclaim removes the stale owner"
      assert_absent "$lock.steal" "reclaim releases its mutex"
      assert_absent "$mutex_owner" "reclaim removes the stale mutex owner"
    done
  done
  pass "reused and unbound watchdog pids are reclaimed for both lock layouts"
}

test_reused_reaper_pid_is_reclaimed() {
  local home dir holder lock owner tomb
  home=$(make_home reused-reaper)
  dir=$(dirname "$home")
  holder=$(start_session)
  stale_beat "$home"
  write_ledger "$home" rewake "$(dead_pid)"
  write_stubs "$home" "$(healing_resume "$home")"
  lock="$home/state/.watchdog.lock"
  mkdir "$lock"
  printf '%s\n' "$holder" > "$lock/pid"
  owner="$lock.steal.owner.fixture"
  tomb="$owner.reaped.$holder"
  mkdir "$tomb"
  ln -s "$owner" "$lock.steal"
  fm_test_pid_identity "$holder" > "$tomb/reaper-$holder-identity"
  run_check "$home"
  assert_equals "watchdog: another check is running" "$OUT" "a matching elected reaper excludes a check"
  assert_absent "$dir/resume.calls" "a live elected reaper prevents concurrent recovery"
  printf 'previous-boot\n' > "$tomb/reaper-$holder-identity"
  run_check "$home"
  expect_code 0 "$CODE" "reused reaper pid recovery exit"
  assert_equals "watchdog: recovered from stale-watcher" "$OUT" "a reused elected reaper cannot suppress supervision"
  assert_absent "$tomb" "reclaim removes the interrupted reaper's tombstone"
  assert_absent "$lock.steal" "reclaim releases the interrupted mutex"
  kill -0 "$holder" 2>/dev/null || fail "reclaim must not signal the reused reaper pid"
  pass "a reused elected reaper pid cannot block watchdog recovery"
}

test_live_watchdog_identity_preserves_singleton() {
  local home dir pid pidfile i
  home=$(make_home watchdog-singleton)
  dir=$(dirname "$home")
  stale_beat "$home"
  write_ledger "$home" rewake "$(dead_pid)"
  write_stubs "$home" "touch '$dir/entered'; while [ ! -e '$dir/release' ]; do sleep 0.1; done; touch '$home/state/.last-watcher-beat'"
  pidfile="$dir/watchdog.pid"
  fm_test_track_process "$pidfile" fm-watchdog-check.sh || fail "register watchdog fixture"
  env FM_HOME="$home" FM_WATCHDOG_VERIFY_SECS=1 FM_WATCHDOG_STEP_SECS=20 \
    "$ROOT/bin/fm-watchdog-check.sh" > "$dir/check.out" 2>&1 &
  pid=$!
  fm_test_record_process "$pidfile" "$pid" || fail "record watchdog fixture"
  i=0
  while [ ! -e "$dir/entered" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  assert_present "$dir/entered" "first watchdog enters recovery"
  assert_equals "$pid" "$(cat "$home/state/.watchdog.lock/pid")" "singleton records its actual pid"
  assert_equals "$(fm_test_pid_identity "$pid")" "$(cat "$home/state/.watchdog.lock/pid-identity")" "singleton binds the process start identity"
  run_check "$home"
  expect_code 0 "$CODE" "contending watchdog exit"
  assert_equals "watchdog: another check is running" "$OUT" "matching identity preserves singleton"
  assert_present "$home/state/.watchdog.lock" "contender cannot release the owner's lock"
  : > "$dir/release"
  wait "$pid"
  expect_code 0 "$?" "original watchdog recovery exit"
  assert_equals "watchdog: recovered from stale-watcher" "$(cat "$dir/check.out")" "original watchdog completes recovery"
  assert_absent "$home/state/.watchdog.lock" "owner releases its identity-bound lock"
  run_check "$home"
  assert_equals "watchdog: healthy" "$OUT" "next scheduled check can acquire after release"
  pass "a live identity-bound watchdog excludes contenders and releases normally"
}

assert_watchdog_plist_contract() {
  python3 - "$@" <<'PY' || fail "generated watchdog plist violates its launchd contract"
import plistlib, sys
plist, home, root, label, interval, path = sys.argv[1:]
with open(plist, "rb") as stream:
    model = plistlib.load(stream)
expected = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", root + "/bin/fm-watchdog-check.sh"],
    "EnvironmentVariables": {"FM_HOME": home, "PATH": path},
    "WorkingDirectory": home,
    "RunAtLoad": True,
    "StartInterval": int(interval),
    "ProcessType": "Background",
    "StandardOutPath": home + "/state/.watchdog.launchd.log",
    "StandardErrorPath": home + "/state/.watchdog.launchd.log",
}
def check(actual, expected, key):
    assert type(actual) is type(expected), (key, type(actual), type(expected))
    if isinstance(expected, dict):
        for name, value in expected.items():
            check(actual[name], value, key + "." + name)
    elif isinstance(expected, list):
        assert len(actual) == len(expected), (key, actual, expected)
        for index, value in enumerate(expected):
            check(actual[index], value, key + "[" + str(index) + "]")
    else:
        assert actual == expected, (key, actual, expected)
check(model, expected, "plist")
PY
}

test_installer_renders_and_registers() {
  local dir calls plist home label
  dir="$TMP_ROOT/installer"
  home="$dir/home & <main>"
  label="com.firstmate.watchdog.$(printf '%s' "$home" | cksum | cut -d' ' -f1)"
  mkdir -p "$dir/agents" "$home/state"
  cat > "$dir/launchctl.sh" <<STUB
#!/bin/sh
echo "\$@" >> "$dir/launchctl.calls"
case "\$1" in print) exit 1 ;; esac
exit 0
STUB
  chmod +x "$dir/launchctl.sh"
  OUT=$(env FM_HOME="$home" FM_TEST_SEAM=1 FM_WATCHDOG_AGENT_DIR="$dir/agents" \
    FM_WATCHDOG_LAUNCHCTL="$dir/launchctl.sh" "$ROOT/bin/fm-watchdog-install.sh" install --interval 60 2>&1)
  expect_code 0 "$?" "install exit"
  plist="$dir/agents/$label.plist"
  assert_watchdog_plist_contract "$plist" "$home" "$ROOT" "$label" 60 "$PATH"
  calls=$(cat "$dir/launchctl.calls")
  assert_contains "$calls" "bootstrap gui/" "install bootstraps into the user domain"
  OUT=$(env FM_HOME="$home" FM_TEST_SEAM=1 FM_WATCHDOG_AGENT_DIR="$dir/agents" \
    FM_WATCHDOG_LAUNCHCTL="$dir/launchctl.sh" "$ROOT/bin/fm-watchdog-install.sh" install --interval 5 2>&1)
  expect_code 1 "$?" "too-short interval exit"
  pass "install renders the plist for the home and bootstraps it"
}

test_installer_resolves_relative_paths() {
  local dir home root label plist
  dir="$TMP_ROOT/relative-installer"
  home="$dir/homes/main"
  root="$dir/checkout"
  label="com.firstmate.watchdog.$(printf '%s' "$home" | cksum | cut -d' ' -f1)"
  plist="$dir/agents/$label.plist"
  mkdir -p "$home/state" "$dir/agents"
  ln -s "$ROOT" "$root"
  cat > "$dir/launchctl.sh" <<'STUB'
#!/bin/sh
case "$1" in print) exit 1 ;; esac
exit 0
STUB
  chmod +x "$dir/launchctl.sh"
  OUT=$(cd "$dir" && env FM_HOME=homes/main FM_ROOT_OVERRIDE=checkout \
    FM_WATCHDOG_AGENT_DIR="$dir/agents" FM_WATCHDOG_LAUNCHCTL="$dir/launchctl.sh" \
    "$ROOT/bin/fm-watchdog-install.sh" install --interval 60 2>&1)
  expect_code 0 "$?" "relative install exit"
  assert_watchdog_plist_contract "$plist" "$home" "$root" "$label" 60 "$PATH"
  OUT=$(env FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_WATCHDOG_AGENT_DIR="$dir/agents" FM_WATCHDOG_LAUNCHCTL="$dir/launchctl.sh" \
    "$ROOT/bin/fm-watchdog-install.sh" status 2>&1)
  expect_code 0 "$?" "absolute status exit"
  assert_equals "$label plist=present launchd=not-loaded" "$OUT" "relative and absolute homes share agent identity"
  OUT=$(cd "$dir" && env FM_HOME=homes/main FM_ROOT_OVERRIDE=checkout \
    FM_WATCHDOG_AGENT_DIR="$dir/agents" FM_WATCHDOG_LAUNCHCTL="$dir/launchctl.sh" \
    "$ROOT/bin/fm-watchdog-install.sh" uninstall 2>&1)
  expect_code 0 "$?" "relative uninstall exit"
  assert_absent "$plist" "relative uninstall removes the same agent"
  pass "installer resolves relative roots before rendering and identity generation"
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
  OUT=$(env FM_HOME="$dir/home & <main>" FM_TEST_SEAM=1 FM_WATCHDOG_AGENT_DIR="$dir/agents" \
    FM_WATCHDOG_LAUNCHCTL="$dir/launchctl-loaded.sh" "$ROOT/bin/fm-watchdog-install.sh" uninstall 2>&1)
  expect_code 0 "$?" "uninstall exit"
  assert_contains "$(cat "$dir/launchctl-loaded.calls")" "bootout gui/" "uninstall boots the agent out"
  [ -z "$(ls "$dir/agents" 2>/dev/null)" ] || fail "uninstall must delete the plist"
  pass "uninstall boots the agent out and deletes its plist"
}

test_fresh_state_does_nothing
test_idle_home_does_nothing
test_missing_home_is_idle
test_bound_rewake_has_finite_grace
test_stale_watcher_recovers
test_stale_watcher_with_live_pid_is_stopped_first
test_dead_arm_owner_is_named
test_live_arm_owner_is_not_dead_arm
test_missing_session_relaunches
test_absent_lock_is_missing_session
test_failed_recovery_alarms_after_threshold
test_missing_resume_command_fails_and_logs
test_recovery_after_failures_clears_episode
test_reused_watchdog_pid_is_reclaimed
test_reused_reaper_pid_is_reclaimed
test_live_watchdog_identity_preserves_singleton
test_installer_renders_and_registers
test_installer_resolves_relative_paths
test_installer_uninstall_removes_plist
