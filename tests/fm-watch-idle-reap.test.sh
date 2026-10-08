#!/usr/bin/env bash
# Watcher integration for the finished-session sweep (bin/fm-idle-session-reap.sh):
# the poll loop starts the sweep detached at FM_IDLE_REAP_INTERVAL, the first sweep
# waits a full interval, 0 turns it off, and a sweep that fails or hangs never
# stops the poll or wakes firstmate.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-idle-reap-tests)

# Start a watcher with every other cadence switched off, so only the sweep can fire.
start_watcher() {  # <state> <fakebin> <out> [extra env...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
    FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    env "$@" "$WATCH" > "$out" 2> "$out.err" &
}

# Stops only the one watcher this test started, by the pid it owns.
stop_owned_watcher() {  # <pid> [hung-sweep-pid]
  [ -z "${2:-}" ] || kill "$2" 2>/dev/null || true
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100 || true
}

# A stand-in sweep that records each call: its subcommand, the home and state it was
# given, and its own pid (a behavior may exec into a sleeper to stay alive).
install_sweep() {  # <fakebin> <behavior>
  cat > "$1/fake-sweep" <<SH
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "\${1:-}" "\${FM_HOME:-}" "\${FM_STATE_OVERRIDE:-}" "\$\$" >> "\$FM_STATE_OVERRIDE/.sweep-calls"
$2
SH
  chmod +x "$1/fake-sweep"
}

sweep_calls() {  # <state>
  if [ -f "$1/.sweep-calls" ]; then
    wc -l < "$1/.sweep-calls" | tr -d ' '
  else
    printf 0
  fi
}

sweep_called() { [ -f "$1/.sweep-calls" ]; }

sweep_repeated() { [ "$(sweep_calls "$1")" -ge 2 ]; }

test_sweep_runs_detached_on_its_interval_with_the_home() {
  local dir state fakebin out pid
  dir=$(make_case idle-reap-runs); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_sweep "$fakebin" 'exit 0'
  start_watcher "$state" "$fakebin" "$out" FM_IDLE_REAP_INTERVAL=1 FM_IDLE_REAP_BIN="$fakebin/fake-sweep" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until 30 sweep_called "$state" || { stop_owned_watcher "$pid"; fail "the watcher never started the sweep"; }
  fm_test_wait_until 30 sweep_repeated "$state" || { stop_owned_watcher "$pid"; fail "the sweep did not repeat on its interval"; }
  case "$(head -n 1 "$state/.sweep-calls")" in
    "reap|$dir|$state|"*) ;;
    *) stop_owned_watcher "$pid"; fail "the sweep is started as 'reap' with this home: $(head -n 1 "$state/.sweep-calls")" ;;
  esac
  is_live_non_zombie "$pid" || fail "a finished sweep must not stop the watcher"
  [ ! -s "$state/.wake-queue" ] || { stop_owned_watcher "$pid"; fail "a routine sweep must not wake firstmate: $(cat "$state/.wake-queue")"; }
  stop_owned_watcher "$pid"
  pass "the poll loop starts the sweep detached, on its interval, for this home, without a wake"
}

test_first_sweep_waits_a_full_interval() {
  local dir state fakebin out pid
  dir=$(make_case idle-reap-first); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_sweep "$fakebin" 'exit 0'
  start_watcher "$state" "$fakebin" "$out" FM_IDLE_REAP_INTERVAL=3600 FM_IDLE_REAP_BIN="$fakebin/fake-sweep" FM_HOME="$dir"
  pid=$!
  sleep 4
  is_live_non_zombie "$pid" || fail "the watcher stopped early"
  if sweep_called "$state"; then
    stop_owned_watcher "$pid"
    fail "a fresh watcher must not start a sweep before one interval has passed"
  fi
  stop_owned_watcher "$pid"
  pass "a fresh watcher leaves session start alone: the first sweep waits one full interval"
}

test_zero_interval_disables_the_sweep() {
  local dir state fakebin out pid
  dir=$(make_case idle-reap-off); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_sweep "$fakebin" 'exit 0'
  start_watcher "$state" "$fakebin" "$out" FM_IDLE_REAP_INTERVAL=0 FM_IDLE_REAP_BIN="$fakebin/fake-sweep" FM_HOME="$dir"
  pid=$!
  sleep 4
  is_live_non_zombie "$pid" || fail "the watcher stopped early"
  if sweep_called "$state"; then
    stop_owned_watcher "$pid"
    fail "FM_IDLE_REAP_INTERVAL=0 must turn the sweep off"
  fi
  stop_owned_watcher "$pid"
  pass "FM_IDLE_REAP_INTERVAL=0 turns the sweep off"
}

test_failing_sweep_never_stops_the_poll() {
  local dir state fakebin out pid
  dir=$(make_case idle-reap-fail); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_sweep "$fakebin" 'echo "boom" >&2; exit 1'
  start_watcher "$state" "$fakebin" "$out" FM_IDLE_REAP_INTERVAL=1 FM_IDLE_REAP_BIN="$fakebin/fake-sweep" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until 30 sweep_repeated "$state" || { stop_owned_watcher "$pid"; fail "a failing sweep must be retried on the next interval"; }
  is_live_non_zombie "$pid" || fail "a failing sweep must not stop the watcher"
  [ ! -s "$state/.wake-queue" ] || { stop_owned_watcher "$pid"; fail "a failing sweep must not wake firstmate"; }
  stop_owned_watcher "$pid"
  pass "a failing sweep is retried quietly and never stops the poll"
}

test_hung_sweep_is_never_doubled() {
  local dir state fakebin out pid hung
  dir=$(make_case idle-reap-hung); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_sweep "$fakebin" 'exec sleep 30'
  start_watcher "$state" "$fakebin" "$out" FM_IDLE_REAP_INTERVAL=1 FM_IDLE_REAP_BIN="$fakebin/fake-sweep" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until 30 sweep_called "$state" || { stop_owned_watcher "$pid"; fail "the hung-sweep case never started a sweep"; }
  sleep 4
  hung=$(head -n 1 "$state/.sweep-calls" | cut -d'|' -f4)
  if [ "$(sweep_calls "$state")" != 1 ]; then
    stop_owned_watcher "$pid" "$hung"
    fail "a sweep still running must not be started a second time"
  fi
  is_live_non_zombie "$pid" || fail "a hung sweep must not stop the watcher"
  stop_owned_watcher "$pid" "$hung"
  pass "a sweep still running is never started twice, and the poll keeps running"
}

test_sweep_runs_detached_on_its_interval_with_the_home
test_first_sweep_waits_a_full_interval
test_zero_interval_disables_the_sweep
test_failing_sweep_never_stops_the_poll
test_hung_sweep_is_never_doubled
