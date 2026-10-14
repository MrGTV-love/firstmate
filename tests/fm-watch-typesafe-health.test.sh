#!/usr/bin/env bash
# Watcher integration for the TypeSafe account-health probe
# (bin/fm-typesafe-health.sh): the poll loop starts the probe detached at
# FM_TYPESAFE_HEALTH_INTERVAL for this home, the first probe waits a full
# interval, 0 turns it off, and a probe that fails or hangs never stops the poll
# or wakes firstmate on its own. The helper's own behavior is covered by
# tests/fm-typesafe-health.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-typesafe-health-tests)

# Start a watcher with every other cadence switched off, so only the probe can fire.
start_watcher() {  # <state> <fakebin> <out> [extra env...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
    FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_IDLE_REAP_INTERVAL=0 \
    env "$@" "$WATCH" > "$out" 2> "$out.err" &
}

stop_owned_watcher() {  # <pid> [hung-probe-pid]
  [ -z "${2:-}" ] || kill "$2" 2>/dev/null || true
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100 || true
}

# A stand-in probe that records each call: its subcommand, the home and state it
# was given, and its own pid (a behavior may exec into a sleeper to stay alive).
install_probe() {  # <fakebin> <behavior>
  cat > "$1/fake-probe" <<SH
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "\${1:-}" "\${FM_HOME:-}" "\${FM_STATE_OVERRIDE:-}" "\$\$" >> "\$FM_STATE_OVERRIDE/.probe-calls"
$2
SH
  chmod +x "$1/fake-probe"
}

probe_calls() {  # <state>
  if [ -f "$1/.probe-calls" ]; then wc -l < "$1/.probe-calls" | tr -d ' '; else printf 0; fi
}
probe_called() { [ -f "$1/.probe-calls" ]; }
probe_repeated() { [ "$(probe_calls "$1")" -ge 2 ]; }

test_probe_runs_detached_on_its_interval_with_the_home() {
  local dir state fakebin out pid
  dir=$(make_case typesafe-health-runs); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_probe "$fakebin" 'exit 0'
  start_watcher "$state" "$fakebin" "$out" FM_TYPESAFE_HEALTH_INTERVAL=1 FM_TYPESAFE_HEALTH_BIN="$fakebin/fake-probe" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until 30 probe_called "$state" || { stop_owned_watcher "$pid"; fail "the watcher never started the probe"; }
  fm_test_wait_until 30 probe_repeated "$state" || { stop_owned_watcher "$pid"; fail "the probe did not repeat on its interval"; }
  case "$(head -n 1 "$state/.probe-calls")" in
    "probe|$dir|$state|"*) ;;
    *) stop_owned_watcher "$pid"; fail "the probe is started as 'probe' with this home: $(head -n 1 "$state/.probe-calls")" ;;
  esac
  is_live_non_zombie "$pid" || fail "a finished probe must not stop the watcher"
  [ ! -s "$state/.wake-queue" ] || { stop_owned_watcher "$pid"; fail "a routine probe must not wake firstmate: $(cat "$state/.wake-queue")"; }
  stop_owned_watcher "$pid"
  pass "the poll loop starts the probe detached, on its interval, for this home, without a wake"
}

test_first_probe_waits_a_full_interval() {
  local dir state fakebin out pid
  dir=$(make_case typesafe-health-first); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_probe "$fakebin" 'exit 0'
  start_watcher "$state" "$fakebin" "$out" FM_TYPESAFE_HEALTH_INTERVAL=3600 FM_TYPESAFE_HEALTH_BIN="$fakebin/fake-probe" FM_HOME="$dir"
  pid=$!
  sleep 4
  is_live_non_zombie "$pid" || fail "the watcher stopped early"
  if probe_called "$state"; then
    stop_owned_watcher "$pid"
    fail "a fresh watcher must not start a probe before one interval has passed"
  fi
  fm_test_wait_until 30 test -e "$state/.typesafe-health-next" \
    || { stop_owned_watcher "$pid"; fail "the first deadline is recorded so a restart keeps it"; }
  stop_owned_watcher "$pid"
  pass "a fresh watcher leaves session start alone: the first probe waits one full interval"
}

test_zero_interval_disables_the_probe() {
  local dir state fakebin out pid
  dir=$(make_case typesafe-health-off); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_probe "$fakebin" 'exit 0'
  start_watcher "$state" "$fakebin" "$out" FM_TYPESAFE_HEALTH_INTERVAL=0 FM_TYPESAFE_HEALTH_BIN="$fakebin/fake-probe" FM_HOME="$dir"
  pid=$!
  sleep 4
  is_live_non_zombie "$pid" || fail "the watcher stopped early"
  if probe_called "$state"; then
    stop_owned_watcher "$pid"
    fail "FM_TYPESAFE_HEALTH_INTERVAL=0 must turn the probe off"
  fi
  stop_owned_watcher "$pid"
  pass "FM_TYPESAFE_HEALTH_INTERVAL=0 turns the probe off"
}

test_failing_probe_never_stops_the_poll() {
  local dir state fakebin out pid
  dir=$(make_case typesafe-health-fail); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_probe "$fakebin" 'echo "boom" >&2; exit 1'
  start_watcher "$state" "$fakebin" "$out" FM_TYPESAFE_HEALTH_INTERVAL=1 FM_TYPESAFE_HEALTH_BIN="$fakebin/fake-probe" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until 30 probe_repeated "$state" || { stop_owned_watcher "$pid"; fail "a failing probe must be retried on the next interval"; }
  is_live_non_zombie "$pid" || fail "a failing probe must not stop the watcher"
  [ ! -s "$state/.wake-queue" ] || { stop_owned_watcher "$pid"; fail "a failing probe must not wake firstmate by itself"; }
  stop_owned_watcher "$pid"
  pass "a failing probe is retried quietly and never stops the poll"
}

test_hung_probe_is_never_doubled() {
  local dir state fakebin out pid hung
  dir=$(make_case typesafe-health-hung); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_probe "$fakebin" 'exec sleep 30'
  start_watcher "$state" "$fakebin" "$out" FM_TYPESAFE_HEALTH_INTERVAL=1 FM_TYPESAFE_HEALTH_BIN="$fakebin/fake-probe" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until 30 probe_called "$state" || { stop_owned_watcher "$pid"; fail "the hung-probe case never started a probe"; }
  sleep 4
  hung=$(head -n 1 "$state/.probe-calls" | cut -d'|' -f4)
  if [ "$(probe_calls "$state")" != 1 ]; then
    stop_owned_watcher "$pid" "$hung"
    fail "a probe still running must not be started a second time"
  fi
  is_live_non_zombie "$pid" || fail "a hung probe must not stop the watcher"
  stop_owned_watcher "$pid" "$hung"
  pass "a probe still running is never started twice, and the poll keeps running"
}

test_probe_runs_detached_on_its_interval_with_the_home
test_first_probe_waits_a_full_interval
test_zero_interval_disables_the_probe
test_failing_probe_never_stops_the_poll
test_hung_probe_is_never_doubled
