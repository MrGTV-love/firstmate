#!/usr/bin/env bash
# Watcher integration for the finished-session sweep (bin/fm-idle-session-reap.sh):
# the poll loop starts the sweep detached at FM_IDLE_REAP_INTERVAL, the first sweep
# waits a full interval, 0 turns it off, and a sweep that fails or hangs never
# stops the poll or wakes firstmate. The Lavish listener sweep
# (bin/fm-procevent-lavish.sh sweep --auto, FM_LAVISH_AUTO_RETIRE_INTERVAL) is the
# same detached single-flight shape and is covered by the same cases. The watcher's
# poll interval by home role (fm_watch_poll_seconds in bin/fm-wake-lib.sh) is
# covered at the end.
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

# A stand-in sweep that records each call: its arguments, the home and state it was
# given, and its own pid (a behavior may exec into a sleeper to stay alive).
install_sweep() {  # <fakebin> <behavior>
  cat > "$1/fake-sweep" <<SH
#!/usr/bin/env bash
printf '%s|%s|%s|%s\n' "\$*" "\${FM_HOME:-}" "\${FM_STATE_OVERRIDE:-}" "\$\$" >> "\$FM_STATE_OVERRIDE/.sweep-calls"
$2
SH
  chmod +x "$1/fake-sweep"
}

# Runs the real sweep for the first call only and does nothing afterwards, so a
# watcher that keeps polling cannot publish a second report over the first.
install_run_once() {  # <fakebin> <real-sweep>
  cat > "$1/reap-once" <<SH
#!/usr/bin/env bash
mkdir "$1/reap-once.started" 2>/dev/null || exit 0
exec "$2" "\$@"
SH
  chmod +x "$1/reap-once"
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

test_stock_lab_watcher_reaps_through_real_teardown() (
  local dir home state fakebin out pid name now old
  for name in "${!FM_@}"; do
    case "$name" in *_OVERRIDE) unset "$name" ;; esac
  done
  dir=$(make_case idle-reap-lab); fakebin="$dir/fakebin"; out="$dir/watch.out"
  mkdir -p "$dir/code-root"
  ln -s "$ROOT/bin" "$dir/code-root/bin"
  fm_git_worktree "$dir/project" "$dir/wt" fm/lab-worker || fail "could not create the scout worktree"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/axi"
  chmod +x "$fakebin/treehouse" "$fakebin/axi"
  home="$dir/home"
  mkdir -p "$home"
  # shellcheck source=bin/fm-gate-refuse-lib.sh
  . "$ROOT/bin/fm-gate-refuse-lib.sh"
  fm_gate_lab_mark "$home" || fail "could not mark the empty lab fixture"
  state="$home/state"
  mkdir -p "$state" "$home/data/lab-worker" "$home/config" "$home/projects"
  fm_test_track_watcher_state "$state"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  fm_write_meta "$state/lab-worker.meta" "window=firstmate:fm-lab-worker" \
    "kind=scout" "harness=claude" "backend=tmux" "spawn_gen=spawn-lab-worker" \
    "worktree=$dir/wt" "project=$dir/project"
  now=$(date +%s); old=$((now - 7200))
  printf 'done [at=%s]: report written\n' "$old" > "$state/lab-worker.status"
  printf 'g1.1.1\n' > "$state/lab-worker.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$now" > "$state/lab-worker.busy-state"
  printf '# Report\nCompleted findings.\n' > "$home/data/lab-worker/report.md"
  fm_touch_epoch "$old" "$home/data/lab-worker/report.md"
  FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" complete lab-worker --none >/dev/null \
    || fail "could not complete the scout's captain-call inventory"
  prime_status_seen "$state" "$state/lab-worker.status"
  # The real sweep runs once. Reaping removes lab-worker.meta, and the watcher keeps polling
  # until its own stale wake retires it, so a later real sweep finds no task and
  # replaces the report with a header-only one, which is correct but not what this test reads.
  install_run_once "$fakebin" "$dir/code-root/bin/fm-idle-session-reap.sh"
  start_watcher "$state" "$fakebin" "$out" -u FM_STATE_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
    NO_MISTAKES_GATE=1 FM_HOME="$home" FM_IDLE_REAP_INTERVAL=1 FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_IDLE_REAP_BIN="$fakebin/reap-once" \
    FM_IDLE_REAP_TEARDOWN_BIN="$dir/code-root/bin/fm-teardown.sh" FM_TEARDOWN_GUARD_DONE=1
  pid=$!
  fm_test_wait_until 100 grep -q $'reaped\tlab-worker\t' "$state/idle-sessions.report" \
    || { stop_owned_watcher "$pid"; fail "the lab watcher did not report the reaped task: $(cat "$state/idle-sessions.report" 2>/dev/null) $(cat "$out.err")"; }
  stop_owned_watcher "$pid"
  assert_grep $'reaped\tlab-worker\t' "$state/idle-sessions.report" \
    "real teardown must admit the eligible task under lab authority: $(cat "$state/idle-sessions.report")"
  assert_absent "$state/lab-worker.meta" "real teardown removes the finished task record"
  assert_absent "$state/.idle-reap/lab-worker.refused" "lab authorization must not become a standing refusal"
  assert_present "$home/data/lab-worker/report.md" "the scout's durable work remains"
  pass "the stock-layout lab watcher reaches real teardown admission and cleans up an eligible scout"
)

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

# --- the Lavish listener sweep ----------------------------------------------------
# The same detached single-flight shape; the retirement rules are covered by
# tests/fm-captain-hold-sweep.test.sh.
test_lavish_sweep_runs_detached_on_its_interval_in_auto_mode() {
  local dir state fakebin out pid
  dir=$(make_case lavish-auto-runs); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_sweep "$fakebin" 'exit 0'
  start_watcher "$state" "$fakebin" "$out" FM_IDLE_REAP_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=1 FM_LAVISH_AUTO_RETIRE_BIN="$fakebin/fake-sweep" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until 30 sweep_called "$state" || { stop_owned_watcher "$pid"; fail "the watcher never started the Lavish sweep"; }
  fm_test_wait_until 30 sweep_repeated "$state" || { stop_owned_watcher "$pid"; fail "the Lavish sweep did not repeat on its interval"; }
  case "$(head -n 1 "$state/.sweep-calls")" in
    "sweep --auto|$dir|$state|"*) ;;
    *) stop_owned_watcher "$pid"; fail "the Lavish sweep is started as 'sweep --auto' with this home: $(head -n 1 "$state/.sweep-calls")" ;;
  esac
  is_live_non_zombie "$pid" || fail "a finished Lavish sweep must not stop the watcher"
  [ ! -s "$state/.wake-queue" ] || { stop_owned_watcher "$pid"; fail "a routine Lavish sweep must not wake firstmate: $(cat "$state/.wake-queue")"; }
  stop_owned_watcher "$pid"
  pass "the poll loop starts the automatic Lavish sweep detached, on its interval, for this home, without a wake"
}

test_lavish_sweep_first_run_waits_and_zero_turns_it_off() {
  local dir state fakebin out pid
  dir=$(make_case lavish-auto-first); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_sweep "$fakebin" 'exit 0'
  start_watcher "$state" "$fakebin" "$out" FM_IDLE_REAP_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=3600 FM_LAVISH_AUTO_RETIRE_BIN="$fakebin/fake-sweep" FM_HOME="$dir"
  pid=$!
  sleep 4
  is_live_non_zombie "$pid" || fail "the watcher stopped early"
  if sweep_called "$state"; then
    stop_owned_watcher "$pid"
    fail "a fresh watcher must not run the Lavish sweep before one interval has passed"
  fi
  fm_test_wait_until 30 test -e "$state/.lavish-auto-retire-next" \
    || { stop_owned_watcher "$pid"; fail "the first Lavish sweep deadline is recorded so a restart keeps it"; }
  stop_owned_watcher "$pid"
  dir=$(make_case lavish-auto-off); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_sweep "$fakebin" 'exit 0'
  start_watcher "$state" "$fakebin" "$out" FM_IDLE_REAP_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_BIN="$fakebin/fake-sweep" FM_HOME="$dir"
  pid=$!
  sleep 4
  is_live_non_zombie "$pid" || fail "the watcher stopped early"
  if sweep_called "$state"; then
    stop_owned_watcher "$pid"
    fail "FM_LAVISH_AUTO_RETIRE_INTERVAL=0 must turn the Lavish sweep off"
  fi
  stop_owned_watcher "$pid"
  pass "the first Lavish sweep waits one full interval, and FM_LAVISH_AUTO_RETIRE_INTERVAL=0 turns it off"
}

test_lavish_sweep_failing_or_hung_never_stops_the_poll() {
  local dir state fakebin out pid hung
  dir=$(make_case lavish-auto-fail); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_sweep "$fakebin" 'echo "boom" >&2; exit 1'
  start_watcher "$state" "$fakebin" "$out" FM_IDLE_REAP_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=1 FM_LAVISH_AUTO_RETIRE_BIN="$fakebin/fake-sweep" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until 30 sweep_repeated "$state" || { stop_owned_watcher "$pid"; fail "a failing Lavish sweep must be retried on the next interval"; }
  is_live_non_zombie "$pid" || fail "a failing Lavish sweep must not stop the watcher"
  [ ! -s "$state/.wake-queue" ] || { stop_owned_watcher "$pid"; fail "a failing Lavish sweep must not wake firstmate by itself"; }
  stop_owned_watcher "$pid"
  dir=$(make_case lavish-auto-hung); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_sweep "$fakebin" 'exec sleep 30'
  start_watcher "$state" "$fakebin" "$out" FM_IDLE_REAP_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=1 FM_LAVISH_AUTO_RETIRE_BIN="$fakebin/fake-sweep" FM_HOME="$dir"
  pid=$!
  fm_test_wait_until 30 sweep_called "$state" || { stop_owned_watcher "$pid"; fail "the hung Lavish sweep case never started a sweep"; }
  sleep 4
  hung=$(head -n 1 "$state/.sweep-calls" | cut -d'|' -f4)
  if [ "$(sweep_calls "$state")" != 1 ]; then
    stop_owned_watcher "$pid" "$hung"
    fail "a Lavish sweep still running must not be started a second time"
  fi
  is_live_non_zombie "$pid" || fail "a hung Lavish sweep must not stop the watcher"
  stop_owned_watcher "$pid" "$hung"
  pass "a failing Lavish sweep is retried quietly and a hung one is never doubled, and the poll keeps running"
}

# --- the poll interval by home role -----------------------------------------------
# A secondmate home polls every 30 seconds, every other home every 15, config/watch-poll
# overrides a home, and FM_POLL still wins. The cadences are observed through a recording
# `sleep` so the effective interval is read from the running watcher, not from its source.

# A genuine secondmate home carries the identity marker (bin/fm-primary-scope-lib.sh).
poll_mark_secondmate() {  # <home>
  printf 'sm-test\n' > "$1/.fm-secondmate-home"
}

# The interval the library picks for that home.
poll_resolve() {  # <home> [config-dir]
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_watch_poll_seconds "${@:2}"' _ "$ROOT" "$@"
}

# A `sleep` that logs the interval it was asked for, then sleeps for real.
poll_install_recording_sleep() {  # <fakebin> <log>
  cat > "$1/sleep" <<SH
#!/bin/sh
printf '%s\n' "\$1" >> '$2'
exec /bin/sleep "\$@"
SH
  chmod +x "$1/sleep"
}

# A watcher with every other cadence off and no FM_POLL, so only the resolved interval matters.
poll_start_watcher() {  # <home> <state> <fakebin> <out> [extra env...]
  local home=$1 state=$2 fakebin=$3 out=$4
  shift 4
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
    FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_IDLE_REAP_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 \
    env "$@" "$WATCH" > "$out" 2> "$out.err" &
}

poll_logged() { grep -qx "$2" "$1" 2>/dev/null; }

test_poll_resolution_by_home_role() {
  local dir sm
  dir=$(make_case poll-primary); sm=$(make_case poll-secondmate)
  poll_mark_secondmate "$sm"
  [ "$(poll_resolve "$dir")" = 15 ] || fail "a primary home must poll every 15 seconds, got $(poll_resolve "$dir")"
  [ "$(poll_resolve "$sm")" = 30 ] || fail "a secondmate home must poll every 30 seconds, got $(poll_resolve "$sm")"
  ln -s "$sm/.fm-secondmate-home" "$dir/.fm-secondmate-home"
  [ "$(poll_resolve "$dir")" = 15 ] || fail "a symlinked marker is not a genuine secondmate marker"
  pass "primary homes poll every 15 seconds and secondmate homes every 30"
}

test_wake_lib_sources_without_the_primary_scope_lib() {
  local dir lib out
  dir=$(make_case poll-lib-alone); lib="$dir/lib/bin"
  mkdir -p "$lib"
  cp "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-path-lib.sh" "$ROOT/bin/fm-secondmate-parent-lib.sh" "$lib/"
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" bash -c 'set -eu; . "$1/fm-wake-lib.sh"; printf sourced' _ "$lib" 2>&1) \
    || fail "fm-wake-lib.sh must source under set -eu without fm-primary-scope-lib.sh: $out"
  [ "$out" = sourced ] || fail "sourcing fm-wake-lib.sh alone printed unexpected output: $out"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$lib/"
  poll_mark_secondmate "$dir"
  out=$(FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir" bash -c 'set -eu; . "$1/fm-wake-lib.sh"; fm_watch_poll_seconds' _ "$lib" 2>&1) \
    || fail "fm_watch_poll_seconds failed with the primary-scope library beside the wake library: $out"
  [ "$out" = 30 ] || fail "fm_watch_poll_seconds must resolve a secondmate home to 30 once the library is beside it, got: $out"
  pass "fm-wake-lib.sh sources alone under set -eu and loads the primary-scope library only to resolve the poll"
}

test_poll_config_override() {
  local dir sm value
  dir=$(make_case poll-config-primary); sm=$(make_case poll-config-secondmate)
  poll_mark_secondmate "$sm"
  mkdir -p "$dir/config" "$sm/config"
  printf '45\n' > "$dir/config/watch-poll"
  printf '  8 \n' > "$sm/config/watch-poll"
  [ "$(poll_resolve "$dir")" = 45 ] || fail "config/watch-poll must override a primary home, got $(poll_resolve "$dir")"
  [ "$(poll_resolve "$sm")" = 8 ] || fail "config/watch-poll must override a secondmate home, got $(poll_resolve "$sm")"
  printf '09' > "$dir/config/watch-poll"
  [ "$(poll_resolve "$dir")" = 9 ] || fail "a zero-padded value must read as decimal, got $(poll_resolve "$dir")"
  printf '240\n' > "$dir/config/watch-poll"
  [ "$(poll_resolve "$dir")" = 240 ] || fail "the 240 ceiling itself must be accepted"
  [ "$(poll_resolve "$dir" "$dir/elsewhere")" = 15 ] || fail "an explicit config dir without the file must fall back to the role default"
  for value in 0 241 -5 abc 1.5 ''; do
    printf '%s\n' "$value" > "$sm/config/watch-poll"
    [ "$(poll_resolve "$sm")" = 30 ] || fail "invalid config/watch-poll '$value' must be ignored for the role default, got $(poll_resolve "$sm")"
  done
  rm -f "$sm/config/watch-poll"
  printf '77\n' > "$dir/real-poll"
  ln -s "$dir/real-poll" "$sm/config/watch-poll"
  [ "$(poll_resolve "$sm")" = 30 ] || fail "a symlinked config/watch-poll must be ignored"
  pass "config/watch-poll overrides a home within 1..240 and bad values fall back to the role default"
}

test_poll_watcher_uses_the_resolved_interval() {
  local dir state fakebin out log pid
  dir=$(make_case poll-watcher-secondmate); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; log="$dir/sleeps"
  poll_mark_secondmate "$dir"
  poll_install_recording_sleep "$fakebin" "$log"
  poll_start_watcher "$dir" "$state" "$fakebin" "$out"
  pid=$!
  fm_test_wait_until 60 poll_logged "$log" 30 || { stop_owned_watcher "$pid"; fail "a secondmate-home watcher must sleep 30 seconds between cycles: $(tr '\n' ' ' < "$log" 2>/dev/null)"; }
  stop_owned_watcher "$pid"
  poll_logged "$log" 15 && fail "a secondmate-home watcher must not use the 15-second interval"
  dir=$(make_case poll-watcher-primary); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; log="$dir/sleeps"
  poll_install_recording_sleep "$fakebin" "$log"
  poll_start_watcher "$dir" "$state" "$fakebin" "$out"
  pid=$!
  fm_test_wait_until 60 poll_logged "$log" 15 || { stop_owned_watcher "$pid"; fail "a primary-home watcher must sleep 15 seconds between cycles: $(tr '\n' ' ' < "$log" 2>/dev/null)"; }
  stop_owned_watcher "$pid"
  poll_logged "$log" 30 && fail "a primary-home watcher must not use the 30-second interval"
  dir=$(make_case poll-watcher-config); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; log="$dir/sleeps"
  poll_mark_secondmate "$dir"; mkdir -p "$dir/config"; printf '41\n' > "$dir/config/watch-poll"
  poll_install_recording_sleep "$fakebin" "$log"
  poll_start_watcher "$dir" "$state" "$fakebin" "$out"
  pid=$!
  fm_test_wait_until 60 poll_logged "$log" 41 || { stop_owned_watcher "$pid"; fail "config/watch-poll must set the watcher interval: $(tr '\n' ' ' < "$log" 2>/dev/null)"; }
  stop_owned_watcher "$pid"
  dir=$(make_case poll-watcher-env); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; log="$dir/sleeps"
  poll_mark_secondmate "$dir"; mkdir -p "$dir/config"; printf '41\n' > "$dir/config/watch-poll"
  poll_install_recording_sleep "$fakebin" "$log"
  poll_start_watcher "$dir" "$state" "$fakebin" "$out" FM_POLL=7
  pid=$!
  fm_test_wait_until 60 poll_logged "$log" 7 || { stop_owned_watcher "$pid"; fail "FM_POLL must beat config/watch-poll: $(tr '\n' ' ' < "$log" 2>/dev/null)"; }
  stop_owned_watcher "$pid"
  poll_logged "$log" 41 && fail "config/watch-poll must not be used while FM_POLL is set"
  pass "a running watcher sleeps the resolved interval: role default, config override, FM_POLL first"
}

# A longer interval only delays the look; it must not lose the event. The home polls every
# 4 seconds (a secondmate home whose config/watch-poll overrides its 30-second default), the
# status is written once the watcher is asleep in its first wait, so the earliest it can be
# noticed is the end of that wait, and it must be noticed by the next look.
test_poll_status_change_noticed_within_one_longer_interval() {
  local dir state fakebin out log pid status_file written noticed waited
  dir=$(make_case poll-notice); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; log="$dir/sleeps"
  status_file="$state/task.status"
  poll_mark_secondmate "$dir"
  mkdir -p "$dir/config"; printf '4\n' > "$dir/config/watch-poll"
  poll_install_recording_sleep "$fakebin" "$log"
  poll_start_watcher "$dir" "$state" "$fakebin" "$out"
  pid=$!
  fm_test_wait_until 60 poll_logged "$log" 4 || { stop_owned_watcher "$pid"; fail "the watcher never reached its first interval wait"; }
  printf 'blocked: needs a decision\n' > "$status_file"
  written=$(date +%s)
  waited=0
  while [ "$waited" -lt 400 ] && is_live_non_zombie "$pid"; do
    sleep 0.1
    waited=$((waited + 1))
  done
  noticed=$(date +%s)
  if is_live_non_zombie "$pid"; then
    stop_owned_watcher "$pid"
    fail "a status change was not noticed within 40 seconds in a 4-second home"
  fi
  wait "$pid" 2>/dev/null || true
  grep -F "signal: $status_file" "$out" >/dev/null || fail "the watcher exited without reporting the status change: $(cat "$out" "$out.err")"
  [ $((noticed - written)) -ge 1 ] || fail "the change was noticed after $((noticed - written))s, before the longer interval could have ended"
  pass "a status change is noticed within one longer interval ($((noticed - written))s after the write, 4s interval)"
}

test_sweep_runs_detached_on_its_interval_with_the_home
test_stock_lab_watcher_reaps_through_real_teardown || exit $?
test_first_sweep_waits_a_full_interval
test_zero_interval_disables_the_sweep
test_failing_sweep_never_stops_the_poll
test_hung_sweep_is_never_doubled
test_successive_watchers_preserve_the_cleanup_deadline
test_lavish_sweep_runs_detached_on_its_interval_in_auto_mode
test_lavish_sweep_first_run_waits_and_zero_turns_it_off
test_lavish_sweep_failing_or_hung_never_stops_the_poll
test_poll_resolution_by_home_role
test_wake_lib_sources_without_the_primary_scope_lib
test_poll_config_override
test_poll_watcher_uses_the_resolved_interval
test_poll_status_change_noticed_within_one_longer_interval
