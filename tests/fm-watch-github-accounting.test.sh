#!/usr/bin/env bash
# Watcher integration for the standing GitHub accounting owner
# (bin/fm-github-accounting.py): a primary home's poll loop starts an absent owner
# through its own idempotent start, leaves a running one alone, recovers a crash at
# the next cycle, and reports a failed start once instead of looping on it. The
# owner's own behavior is covered by tests/fm-github-accounting.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
OWNER="$ROOT/bin/fm-github-accounting.py"
TMP_ROOT=$(fm_test_tmproot fm-watch-github-accounting-tests)
count_watch_polls

# Start a watcher with every other cadence switched off, so only the owner's start
# can fire. The fake gh-axi keeps a real owner away from the account.
start_watcher() {  # <dir> [extra env...]
  local dir=$1
  shift
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/bin/sh
printf 'api_response:\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\n'
SH
  chmod +x "$dir/fakebin/gh-axi"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
    FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 \
    FM_GITHUB_ACCOUNTING=1 \
    env "$@" "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" &
}

stop_owned_watcher() {  # <pid> [hung-start-pid]
  [ -z "${2:-}" ] || kill "$2" 2>/dev/null || true
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100 || true
}

owner() {  # <dir> <command>
  PATH="$1/fakebin:$PATH" FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$OWNER" "$2"
}

owner_field() {  # <dir> <field>
  owner "$1" status | python3 -c 'import json, sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$2"
}

# Read the owner's published metadata without taking its lock, so a probe cannot
# collide with an owner that is claiming the lock at that moment.
published_run_id() {  # <dir>
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["run_id"])' \
    "$1/state/github-accounting/owner.lock" 2>/dev/null
}

owner_runs() {  # <dir> <run-id-to-differ-from>
  local id
  id=$(published_run_id "$1") && [ -n "$id" ] && [ "$id" != "${2:-}" ]
}

# A stand-in owner that records each call: its subcommand, the home and state it
# was given, and its own pid. A behavior may exec into a sleeper to stay alive.
install_fake_owner() {  # <dir> <behavior>
  cat > "$1/fakebin/fake-owner" <<SH
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "\${1:-}" "\${FM_HOME:-}" "\${FM_STATE_OVERRIDE:-}" "\$\$" >> "\$FM_STATE_OVERRIDE/.owner-calls"
$2
SH
  chmod +x "$1/fakebin/fake-owner"
}

owner_calls() {  # <state>
  if [ -f "$1/.owner-calls" ]; then wc -l < "$1/.owner-calls" | tr -d ' '; else printf 0; fi
}
owner_called_at_least() { [ "$(owner_calls "$1")" -ge "$2" ]; }

polled_at_least() {  # <state> <watcher-pid> <cycles>
  local count=0 file
  file=$(watch_polls_file "$1" "$2")
  [ ! -e "$file" ] || count=$(cat "$file" 2>/dev/null) || count=0
  [ "${count:-0}" -ge "$3" ]
}

wake_rows() {  # <state>
  if [ -f "$1/.wake-queue" ]; then grep -c 'github-accounting-start-failed' "$1/.wake-queue"; else printf 0; fi
}

test_cycle_starts_absent_owner_leaves_running_one_and_recovers_a_crash() {
  local dir state pid first owner_pid base
  dir=$(make_case absent-running-crash); state="$dir/state"
  start_watcher "$dir"
  pid=$!
  fm_test_wait_until --while-alive "$pid" --cycles 5 "$(watch_polls_file "$state" "$pid")" -- owner_runs "$dir" "" \
    || { stop_owned_watcher "$pid"; fail "the watcher never started an absent owner"; }
  first=$(owner_field "$dir" run_id)
  owner_pid=$(owner_field "$dir" pid)
  base=$(cat "$(watch_polls_file "$state" "$pid")" 2>/dev/null || printf 0)
  fm_test_wait_until --while-alive "$pid" --cycles 8 "$(watch_polls_file "$state" "$pid")" -- polled_at_least "$state" "$pid" "$((base + 3))" \
    || { stop_owned_watcher "$pid"; owner "$dir" stop >/dev/null; fail "the watcher stopped polling"; }
  [ "$(owner_field "$dir" run_id)" = "$first" ] \
    || { stop_owned_watcher "$pid"; owner "$dir" stop >/dev/null; fail "a running owner must be left alone"; }
  [ ! -s "$state/.wake-queue" ] \
    || { stop_owned_watcher "$pid"; owner "$dir" stop >/dev/null; fail "a healthy owner must not wake firstmate: $(cat "$state/.wake-queue")"; }
  kill -9 "$owner_pid"
  fm_test_wait_until --while-alive "$pid" --cycles 5 "$(watch_polls_file "$state" "$pid")" -- owner_runs "$dir" "$first" \
    || { stop_owned_watcher "$pid"; owner "$dir" stop >/dev/null; fail "a crashed owner did not recover at the next cycle"; }
  stop_owned_watcher "$pid"
  [ "$(owner_field "$dir" state)" = running ] \
    || { owner "$dir" stop >/dev/null; fail "the detached owner must outlive its watcher"; }
  owner "$dir" stop >/dev/null || fail "the owner did not stop"
  pass "a cycle starts an absent owner, leaves a running one alone, and recovers a crash"
}

test_failed_start_is_reported_once_not_looped() {
  local dir state pid base
  dir=$(make_case failed-start); state="$dir/state"
  install_fake_owner "$dir" 'exit 1'
  start_watcher "$dir" FM_GITHUB_ACCOUNTING_BIN="$dir/fakebin/fake-owner"
  pid=$!
  wait_for_exit "$pid" 100 || { stop_owned_watcher "$pid"; fail "a failed start must close the cycle with a wake"; }
  grep -q '^check: github-accounting owner failed to start: exit=1;' "$dir/watch.out" \
    || fail "the wake must name the failed start: $(cat "$dir/watch.out")"
  [ "$(wake_rows "$state")" = 1 ] || fail "the wake must be durably queued once"
  [ "$(owner_calls "$state")" = 1 ] || fail "the owner must be asked once"
  case "$(head -n 1 "$state/.owner-calls")" in
    "start|$dir|$state|"*) ;;
    *) fail "the owner is started with 'start' for this home: $(head -n 1 "$state/.owner-calls")" ;;
  esac

  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "the failed-start wake must drain: $(cat "$dir/drain.err")"
  grep -q 'github-accounting owner failed to start' "$dir/drain.out" || fail "the drain must present the failed start"
  ack_drain_err "$state" "$dir/drain.err" >/dev/null || fail "the failed-start wake must acknowledge"
  [ "$(wake_rows "$state")" = 0 ] || fail "the acknowledged wake must leave the queue"

  clear_watcher_cycle "$state"
  start_watcher "$dir" FM_GITHUB_ACCOUNTING_BIN="$dir/fakebin/fake-owner"
  pid=$!
  fm_test_wait_until --while-alive "$pid" --cycles 8 "$(watch_polls_file "$state" "$pid")" -- polled_at_least "$state" "$pid" 3 \
    || { stop_owned_watcher "$pid"; fail "the next watcher stopped polling: $(cat "$dir/watch.out")"; }
  [ "$(owner_calls "$state")" = 1 ] || { stop_owned_watcher "$pid"; fail "a failed start must not be retried each cycle"; }
  [ "$(wake_rows "$state")" = 0 ] || { stop_owned_watcher "$pid"; fail "a failed start must not wake again"; }

  touch -t 200001010000 "$state/.github-accounting-start-failed"
  fm_test_wait_until --while-alive "$pid" --cycles 5 "$(watch_polls_file "$state" "$pid")" -- owner_called_at_least "$state" 2 \
    || { stop_owned_watcher "$pid"; fail "the retry interval must allow another attempt"; }
  base=$(cat "$(watch_polls_file "$state" "$pid")" 2>/dev/null || printf 0)
  fm_test_wait_until --while-alive "$pid" --cycles 8 "$(watch_polls_file "$state" "$pid")" -- polled_at_least "$state" "$pid" "$((base + 3))" \
    || { stop_owned_watcher "$pid"; fail "a repeat failure must not close the cycle: $(cat "$dir/watch.out")"; }
  [ "$(owner_calls "$state")" = 2 ] || { stop_owned_watcher "$pid"; fail "a repeat failure must restart the retry interval"; }
  [ "$(wake_rows "$state")" = 0 ] || { stop_owned_watcher "$pid"; fail "a repeat failure of one episode must stay silent"; }

  install_fake_owner "$dir" 'exit 0'
  touch -t 200001010000 "$state/.github-accounting-start-failed"
  fm_test_wait_until --while-alive "$pid" --cycles 5 "$(watch_polls_file "$state" "$pid")" -- test ! -e "$state/.github-accounting-start-failed" \
    || { stop_owned_watcher "$pid"; fail "a successful start must end the failure episode"; }
  stop_owned_watcher "$pid"
  pass "a failed start wakes once, retries only on the long interval, and clears on success"
}

test_real_failed_start_leaves_its_reason_in_the_owner_log() {
  local dir state pid
  dir=$(make_case real-failure); state="$dir/state"
  mkdir -p "$state/github-accounting"
  python3 -c 'import sqlite3, sys; db = sqlite3.connect(sys.argv[1]); db.execute("CREATE TABLE unrelated(value)"); db.commit()' \
    "$state/github-accounting/observations.sqlite"
  start_watcher "$dir"
  pid=$!
  wait_for_exit "$pid" 100 || { stop_owned_watcher "$pid"; owner "$dir" stop >/dev/null; fail "a real failed start must close the cycle with a wake"; }
  grep -q "owner stderr: $state/github-accounting/owner.log" "$dir/watch.out" \
    || fail "the wake must name the owner's log: $(cat "$dir/watch.out")"
  grep -q 'operation unavailable' "$state/github-accounting/owner.log" \
    || fail "the detached owner's stderr must reach its log"
  [ "$(owner_field "$dir" state)" = stopped ] || fail "the refused owner must not stay running"
  pass "a real failed start is reported and its stderr reaches the bounded log"
}

test_only_a_primary_home_with_the_switch_on_starts_the_owner() {
  local dir state pid label
  for label in secondmate lab disabled; do
    dir=$(make_case "not-started-$label"); state="$dir/state"
    install_fake_owner "$dir" 'exit 0'
    case "$label" in
      secondmate) printf 'mate\n' > "$dir/.fm-secondmate-home"
        start_watcher "$dir" FM_GITHUB_ACCOUNTING_BIN="$dir/fakebin/fake-owner" ;;
      lab) printf 'fm-lab-home v1\n' > "$dir/.fm-lab-home"
        start_watcher "$dir" FM_GITHUB_ACCOUNTING_BIN="$dir/fakebin/fake-owner" ;;
      disabled)
        start_watcher "$dir" FM_GITHUB_ACCOUNTING_BIN="$dir/fakebin/fake-owner" FM_GITHUB_ACCOUNTING=0 ;;
    esac
    pid=$!
    fm_test_wait_until --while-alive "$pid" --cycles 8 "$(watch_polls_file "$state" "$pid")" -- polled_at_least "$state" "$pid" 3 \
      || { stop_owned_watcher "$pid"; fail "the $label watcher stopped polling"; }
    [ "$(owner_calls "$state")" = 0 ] || { stop_owned_watcher "$pid"; fail "a $label home must not start the owner"; }
    stop_owned_watcher "$pid"
  done
  pass "a secondmate home, a lab home, and FM_GITHUB_ACCOUNTING=0 never start the owner"
}

test_hung_start_is_never_doubled() {
  local dir state pid hung base
  dir=$(make_case hung-start); state="$dir/state"
  install_fake_owner "$dir" 'exec sleep 30'
  start_watcher "$dir" FM_GITHUB_ACCOUNTING_BIN="$dir/fakebin/fake-owner"
  pid=$!
  fm_test_wait_until --while-alive "$pid" --cycles 5 "$(watch_polls_file "$state" "$pid")" -- owner_called_at_least "$state" 1 \
    || { stop_owned_watcher "$pid"; fail "the hung-start case never asked the owner"; }
  hung=$(head -n 1 "$state/.owner-calls" | cut -d'|' -f4)
  base=$(cat "$(watch_polls_file "$state" "$pid")" 2>/dev/null || printf 0)
  fm_test_wait_until --while-alive "$pid" --cycles 8 "$(watch_polls_file "$state" "$pid")" -- polled_at_least "$state" "$pid" "$((base + 3))" \
    || { stop_owned_watcher "$pid" "$hung"; fail "a hung start must not stop the poll"; }
  [ "$(owner_calls "$state")" = 1 ] || { stop_owned_watcher "$pid" "$hung"; fail "a start still running must not be doubled"; }
  stop_owned_watcher "$pid" "$hung"
  pass "a start still running is never doubled, and the poll keeps running"
}

test_cycle_starts_absent_owner_leaves_running_one_and_recovers_a_crash
test_failed_start_is_reported_once_not_looped
test_real_failed_start_leaves_its_reason_in_the_owner_log
test_only_a_primary_home_with_the_switch_on_starts_the_owner
test_hung_start_is_never_doubled
