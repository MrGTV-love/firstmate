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

install_test_clock() {
  local real_date
  real_date=$(command -v date)
  cat > "$1/date" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 1 ] && [ "\${1:-}" = +%s ] && [ -n "\${FM_TEST_DATE_NOW:-}" ]; then
  printf '%s\n' "\$FM_TEST_DATE_NOW"
else
  exec "$real_date" "\$@"
fi
SH
  chmod +x "$1/date"
  cat > "$1/clock-env.sh" <<'SH'
if [ -n "${FM_TEST_PREVIOUS_BASH_ENV:-}" ] \
  && [ "$FM_TEST_PREVIOUS_BASH_ENV" != "${BASH_ENV:-}" ]; then
  . "$FM_TEST_PREVIOUS_BASH_ENV"
fi
if [ "${BASH_VERSINFO[0]}" -gt 4 ] \
  || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
  printf() {
    if [ -n "${FM_TEST_DATE_NOW:-}" ] && [ "${1:-}" = -v ] \
      && [ "${3:-}" = '%(%s)T' ] && [ "${4:-}" = -1 ]; then
      builtin printf -v "$2" '%s' "$FM_TEST_DATE_NOW"
    else
      builtin printf "$@"
    fi
  }
fi
sleep() {
  local completed
  if [ "${FUNCNAME[1]:-}" = event_wait_or_sleep ] \
    && [ "$BASH_SUBSHELL" -eq 0 ] \
    && [ "${BASHPID:-$$}" = "${WATCHER_PID:-}" ]; then
    _FM_TEST_POLL_COUNT=$((${_FM_TEST_POLL_COUNT:-0} + 1))
    completed="$FM_STATE_OVERRIDE/.test-poll-completed-$WATCHER_PID"
    printf '%s\n' "$_FM_TEST_POLL_COUNT" > "$completed.tmp" \
      && mv -f "$completed.tmp" "$completed" || exit 1
  fi
  command sleep "$@"
}
SH
}

start_clocked_watcher() {
  local state=$1 fakebin=$2 out=$3 now=$4 interval=$5
  start_watcher "$state" "$fakebin" "$out" FM_HOME="${state%/state}" \
    FM_IDLE_REAP_INTERVAL="$interval" FM_IDLE_REAP_BIN="$fakebin/fake-sweep" \
    FM_TEST_DATE_NOW="$now" FM_WATCH_HANDLING_SUCCESSOR=1 \
    BASH_ENV="$fakebin/clock-env.sh" FM_TEST_PREVIOUS_BASH_ENV="${BASH_ENV:-}"
}

polls_completed() {
  local state=$1 pid=$2 target=$3 count
  is_live_non_zombie "$pid" || return 1
  count=$(cat "$state/.test-poll-completed-$pid" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  [ "$count" -ge "$target" ]
}

wait_clocked_polls() {
  local state=$1 pid=$2 count
  count=$(cat "$state/.test-poll-completed-$pid" 2>/dev/null || true)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  fm_test_wait_until 100 polls_completed "$state" "$pid" "$((count + 2))" \
    || { stop_owned_watcher "$pid"; fail "the clocked watcher did not complete two polls"; }
}

sweep_count_is() { [ "$(sweep_calls "$1")" -eq "$2" ]; }

sweep_finished() {
  local call sweep=
  [ -f "$1/.sweep-calls" ] || return 1
  while IFS= read -r call; do sweep=${call##*|}; done < "$1/.sweep-calls"
  [ -n "$sweep" ] && ! is_live_non_zombie "$sweep"
}

handoff_clocked_watcher() {
  local state=$1 pid=$2 step=$3
  printf 'done: idle reap handoff %s\n' "$step" >> "$state/handoff.status"
  wait_for_exit "$pid" 100 \
    || { stop_owned_watcher "$pid"; fail "an actionable signal did not retire the watcher"; }
}

test_successive_watchers_preserve_the_cleanup_deadline() {
  local dir state fakebin out pid base step offset expected interval
  dir=$(make_case idle-reap-handoffs); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_test_clock "$fakebin"
  install_sweep "$fakebin" 'exit 0'
  base=$(date +%s)
  for step in initial early before-first first after-first before-second disabled second; do
    interval=60
    case "$step" in
      initial) offset=0; expected=0 ;;
      early) offset=20; expected=0 ;;
      before-first) offset=59; expected=0 ;;
      first) offset=60; expected=1 ;;
      after-first) offset=80; expected=1 ;;
      disabled) offset=120; expected=1; interval=0 ;;
      before-second) offset=119; expected=1 ;;
      second) offset=120; expected=2 ;;
    esac
    start_clocked_watcher "$state" "$fakebin" "$out.$step" "$((base + offset))" "$interval"
    pid=$!
    wait_clocked_polls "$state" "$pid"
    if [ "$expected" -gt 0 ]; then
      fm_test_wait_until 30 sweep_count_is "$state" "$expected" \
        || { stop_owned_watcher "$pid"; fail "$step watcher did not retain the original sweep deadline"; }
      fm_test_wait_until 30 sweep_finished "$state" \
        || { stop_owned_watcher "$pid"; fail "$step sweep did not finish"; }
    fi
    sweep_count_is "$state" "$expected" \
      || { stop_owned_watcher "$pid"; fail "$step watcher swept before the retained deadline"; }
    wait_clocked_polls "$state" "$pid"
    sweep_count_is "$state" "$expected" \
      || { stop_owned_watcher "$pid"; fail "repeated $step ticks doubled the sweep"; }
    handoff_clocked_watcher "$state" "$pid" "$step"
  done
  pass "actionable watcher handoffs preserve the initial and subsequent sweep deadlines, including disabled and repeated ticks"
}

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
test_successive_watchers_preserve_the_cleanup_deadline
