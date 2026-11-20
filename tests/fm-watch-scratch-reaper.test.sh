#!/usr/bin/env bash
# Watcher integration for the scratch reaper (bin/fm-scratch-reaper.sh): the poll loop starts
# `--scheduled` detached at FM_SCRATCH_REAPER_TICK for this home, 0 turns the offer off, a run
# that fails or hangs never stops the poll or wakes firstmate, and a suite that arms
# FM_TEST_SEAM never starts the real script (it deletes directories). The reaper's own
# behavior, window and alarm are covered by tests/fm-scratch-reaper.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-scratch-reaper-tests)
count_watch_polls

# Start a watcher with every other cadence switched off, so only the reaper offer can fire.
start_watcher() {  # <state> <fakebin> <out> [extra env...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
    FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 \
    env "$@" "$WATCH" > "$out" 2> "$out.err" &
}

stop_owned_watcher() {  # <pid> [hung-run-pid]
  [ -z "${2:-}" ] || kill "$2" 2>/dev/null || true
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100 || true
}

# A stand-in reaper that records each call: its arguments, the home, state and config it was
# given, and its own pid (a behavior may exec into a sleeper to stay alive).
install_reaper() {  # <fakebin> <behavior>
  cat > "$1/fake-reaper" <<SH
#!/usr/bin/env bash
printf '%s|%s|%s|%s|%s\n' "\${1:-}" "\${FM_HOME:-}" "\${FM_STATE_OVERRIDE:-}" "\${FM_CONFIG_OVERRIDE:-}" "\$\$" >> "\$FM_STATE_OVERRIDE/.reaper-calls"
$2
SH
  chmod +x "$1/fake-reaper"
}

reaper_calls() {  # <state>
  if [ -f "$1/.reaper-calls" ]; then wc -l < "$1/.reaper-calls" | tr -d ' '; else printf 0; fi
}
reaper_called() { [ -f "$1/.reaper-calls" ]; }
reaper_repeated() { [ "$(reaper_calls "$1")" -ge 2 ]; }

test_run_starts_detached_on_its_tick_with_the_home() {
  local dir state fakebin out pid
  dir=$(make_case scratch-reaper-runs); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_reaper "$fakebin" 'exit 0'
  start_watcher "$state" "$fakebin" "$out" FM_SCRATCH_REAPER_TICK=1 FM_SCRATCH_REAPER_BIN="$fakebin/fake-reaper" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until --while-alive "$pid" --cycles 5 "$(watch_polls_file "$state" "$pid")" -- reaper_called "$state" || { stop_owned_watcher "$pid"; fail "the watcher never started the reaper"; }
  fm_test_wait_until --while-alive "$pid" --cycles 5 "$(watch_polls_file "$state" "$pid")" -- reaper_repeated "$state" || { stop_owned_watcher "$pid"; fail "the reaper was not offered again on the next tick"; }
  case "$(head -n 1 "$state/.reaper-calls")" in
    "--scheduled|$dir|$state|$dir/config|"*) ;;
    *) stop_owned_watcher "$pid"; fail "the run is started as --scheduled with this home, state and config: $(head -n 1 "$state/.reaper-calls")" ;;
  esac
  is_live_non_zombie "$pid" || fail "a finished run must not stop the watcher"
  [ ! -s "$state/.wake-queue" ] || { stop_owned_watcher "$pid"; fail "a routine run must not wake firstmate: $(cat "$state/.wake-queue")"; }
  stop_owned_watcher "$pid"
  pass "the poll loop starts the reaper detached with --scheduled, on its tick, for this home, without a wake"
}

test_zero_tick_disables_the_offer() {
  local dir state fakebin out pid
  dir=$(make_case scratch-reaper-off); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_reaper "$fakebin" 'exit 0'
  start_watcher "$state" "$fakebin" "$out" FM_SCRATCH_REAPER_TICK=0 FM_SCRATCH_REAPER_BIN="$fakebin/fake-reaper" FM_HOME="$dir"
  pid=$!
  sleep 4
  is_live_non_zombie "$pid" || fail "the watcher stopped early"
  if reaper_called "$state"; then
    stop_owned_watcher "$pid"
    fail "FM_SCRATCH_REAPER_TICK=0 must turn the offer off"
  fi
  stop_owned_watcher "$pid"
  pass "FM_SCRATCH_REAPER_TICK=0 turns the offer off"
}

test_failing_run_never_stops_the_poll() {
  local dir state fakebin out pid
  dir=$(make_case scratch-reaper-fail); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_reaper "$fakebin" 'echo "boom" >&2; exit 3'
  start_watcher "$state" "$fakebin" "$out" FM_SCRATCH_REAPER_TICK=1 FM_SCRATCH_REAPER_BIN="$fakebin/fake-reaper" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until --while-alive "$pid" --cycles 5 "$(watch_polls_file "$state" "$pid")" -- reaper_repeated "$state" || { stop_owned_watcher "$pid"; fail "a failing run must be offered again on the next tick"; }
  is_live_non_zombie "$pid" || fail "a failing run must not stop the watcher"
  [ ! -s "$state/.wake-queue" ] || { stop_owned_watcher "$pid"; fail "a failing run must not wake firstmate through the watcher"; }
  stop_owned_watcher "$pid"
  pass "a failing run is offered again quietly and never stops the poll"
}

test_hung_run_is_never_doubled() {
  local dir state fakebin out pid hung
  dir=$(make_case scratch-reaper-hung); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_reaper "$fakebin" 'exec sleep 30'
  start_watcher "$state" "$fakebin" "$out" FM_SCRATCH_REAPER_TICK=1 FM_SCRATCH_REAPER_BIN="$fakebin/fake-reaper" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until --while-alive "$pid" --cycles 5 "$(watch_polls_file "$state" "$pid")" -- reaper_called "$state" || { stop_owned_watcher "$pid"; fail "the hung-run case never started a run"; }
  sleep 4
  hung=$(head -n 1 "$state/.reaper-calls" | cut -d'|' -f5)
  if [ "$(reaper_calls "$state")" != 1 ]; then
    stop_owned_watcher "$pid" "$hung"
    fail "a run still going must not be started a second time"
  fi
  is_live_non_zombie "$pid" || fail "a hung run must not stop the watcher"
  stop_owned_watcher "$pid" "$hung"
  pass "a run still going is never started twice, and the poll keeps running"
}

# A suite arms FM_TEST_SEAM through tests/lib.sh. With no stand-in named, the watcher must not
# start the real script, because its defaults point at the real /private/tmp. A failing lsof
# shim and a private HOME are a second line of defense: if the real script did start, it would
# keep everything and leave a log in this case's state folder, which the test then finds.
test_real_script_never_starts_under_the_test_seam() {
  local dir state fakebin out pid
  dir=$(make_case scratch-reaper-seam); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf '#!/bin/sh\n: > "%s/lsof-called"\nexit 1\n' "$dir" > "$fakebin/lsof"; chmod +x "$fakebin/lsof"
  start_watcher "$state" "$fakebin" "$out" FM_SCRATCH_REAPER_TICK=1 FM_HOME="$dir" HOME="$dir"
  pid=$!
  sleep 5
  is_live_non_zombie "$pid" || fail "the watcher stopped early"
  stop_owned_watcher "$pid"
  if [ -e "$dir/lsof-called" ] || [ -e "$state/scratch-reaper.log" ] || [ -e "$state/.scratch-reaper-next" ]; then
    fail "the watcher started the real reaper under the test seam"
  fi
  pass "under FM_TEST_SEAM the watcher never starts the real reaper"
}

test_run_starts_detached_on_its_tick_with_the_home
test_zero_tick_disables_the_offer
test_failing_run_never_stops_the_poll
test_hung_run_is_never_doubled
test_real_script_never_starts_under_the_test_seam
