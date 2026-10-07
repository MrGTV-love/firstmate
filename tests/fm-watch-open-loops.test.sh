#!/usr/bin/env bash
# Watcher integration for the open-work ledger: the detached helper runs from the poll loop,
# a newly overdue row wakes firstmate with a durable row, an unchanged set stays quiet, a ledger
# the helper stopped publishing is its own wake.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-open-loops-tests)

# The shared poll-count seam: each completed watcher poll is recorded, so a test can wait
# for whole cycles instead of guessing durations.
unset _FM_TEST_POLL_OWNER _FM_TEST_POLL_COUNT
sleep() {
  local completed
  if [ "${FUNCNAME[1]:-}" = event_wait_or_sleep ] \
    && [ "$BASH_SUBSHELL" -eq 0 ] \
    && [ "${BASHPID:-$$}" = "${WATCHER_PID:-}" ]; then
    if [ "${_FM_TEST_POLL_OWNER:-}" != "$WATCHER_PID" ]; then
      _FM_TEST_POLL_OWNER=$WATCHER_PID
      _FM_TEST_POLL_COUNT=0
    fi
    _FM_TEST_POLL_COUNT=$((_FM_TEST_POLL_COUNT + 1))
    completed="$FM_STATE_OVERRIDE/.test-poll-completed-$WATCHER_PID"
    if ! printf '%s\n' "$_FM_TEST_POLL_COUNT" > "$completed.tmp" \
      || ! mv -f "$completed.tmp" "$completed"; then
      exit 1
    fi
  fi
  command sleep "$@"
}
export -f sleep


wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} completed first now i=0
  completed="$state/.test-poll-completed-$pid"
  first=$(cat "$completed" 2>/dev/null || true)
  case "$first" in
    ''|*[!0-9]*) first=0 ;;
  esac
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(cat "$completed" 2>/dev/null || true)
    case "$now" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$now" -ge "$((first + 2))" ]; then
          kill -0 "$pid" 2>/dev/null
          return $?
        fi
        ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}


# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

# Set <file>'s mtime to exactly <epoch> seconds, for aging a busy-turn marker by
# a precise amount (touch -t takes a local-time stamp, not an epoch, on both
# platforms, so convert via BSD `date -r` or GNU `date -d @`).
set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}


# The watcher is the only poll loop here, so its wait is the only sleep to shorten.
reap() {
  local rc
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100
  rc=$?
  [ "$rc" -ne 124 ] || fail "watcher pid $1 did not exit within 10s of TERM"
}

ack_stopped_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation"
}

# Start a watcher with every other cadence switched off, so only the ledger path can fire.
watch_ledger() {  # <state> <fakebin> <out> [extra env...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 env "$@" "$WATCH" > "$out" &
}

publish_ledger() {  # <state> <overdue-id>...
  local state=$1 rows='' id
  shift
  for id in "$@"; do
    rows="${rows:+$rows,}{\"id\":\"$id\",\"category\":\"missing_worker\",\"subject\":\"$id\",\"owner\":\"firstmate\",\"next_action\":\"recover\",\"age_seconds\":9999,\"limit_seconds\":600,\"overdue\":true}"
  done
  printf '{"schema":"fm-open-loops.v1","generated_epoch":%s,"complete":true,"rows":[%s]}\n' "$(date +%s)" "$rows" > "$state/open-loops.json"
}

# A stand-in reconciler: records that it ran and publishes one overdue row, like the real helper.
install_helper() {  # <fakebin>
  cat > "$1/fake-open-loops" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = --heartbeat ] || exit 2
: >> "$FM_STATE_OVERRIDE/.helper-ran"
printf '{"schema":"fm-open-loops.v1","generated_epoch":%s,"complete":false,"rows":[{"id":"degraded","category":"coverage","subject":"ledger degraded","owner":"firstmate","next_action":"restore","age_seconds":null,"limit_seconds":0,"overdue":true}]}\n' "$(date +%s)" > "$FM_STATE_OVERRIDE/open-loops.json"
SH
  chmod +x "$1/fake-open-loops"
}

test_overdue_row_wakes_with_a_durable_row() {
  local dir state fakebin out pid
  dir=$(make_case ledger-wake); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  publish_ledger "$state" lost-launcher
  watch_ledger "$state" "$fakebin" "$out" FM_OPEN_LOOPS_INTERVAL=999999
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "watcher did not exit for an overdue ledger row"; }
  grep -q 'check: open-loop-ledger (1 overdue' "$out" || fail "wake reason missing the overdue count: $(cat "$out")"
  grep -q 'open-loop-ledger' "$state/.wake-queue" || fail "overdue ledger wake was not durably queued"
  [ -s "$state/.open-loops-surfaced" ] || fail "surfacing marker was not recorded"
  pass "an overdue ledger row wakes firstmate and leaves a durable queue row"
}

test_unchanged_overdue_set_stays_quiet_then_new_row_wakes() {
  local dir state fakebin out pid
  dir=$(make_case ledger-quiet); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  publish_ledger "$state" lost-launcher
  watch_ledger "$state" "$fakebin" "$out" FM_OPEN_LOOPS_INTERVAL=999999
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "first overdue ledger did not wake"; }
  ack_stopped_cycle "$state" || fail "could not acknowledge the first wake"
  # The same set, republished, is already known: absorbed without an exit or a queue row.
  publish_ledger "$state" lost-launcher
  watch_ledger "$state" "$fakebin" "$out" FM_OPEN_LOOPS_INTERVAL=999999
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "an unchanged overdue set woke again"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "an unchanged overdue set was queued again"; }
  # A newly overdue row changes the set, so it wakes at once.
  publish_ledger "$state" lost-launcher forgotten-guard
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a newly overdue row did not wake"; }
  grep -q '2 overdue' "$state/.wake-queue" || fail "new overdue row was not queued: $(cat "$state/.wake-queue")"
  pass "an unchanged overdue set stays quiet and a new overdue row wakes again"
}

test_ledger_without_overdue_rows_is_silent() {
  local dir state fakebin out pid
  dir=$(make_case ledger-clean); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  publish_ledger "$state"
  watch_ledger "$state" "$fakebin" "$out" FM_OPEN_LOOPS_INTERVAL=999999
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher exited for a ledger with no overdue rows"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "a clean ledger queued a wake"; }
  reap "$pid"
  pass "a ledger with no overdue rows is silent"
}

test_detached_helper_runs_and_a_blind_ledger_wakes() {
  local dir state fakebin out pid
  dir=$(make_case ledger-helper); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  install_helper "$fakebin"
  watch_ledger "$state" "$fakebin" "$out" FM_OPEN_LOOPS_INTERVAL=1 FM_OPEN_LOOPS_BIN="$fakebin/fake-open-loops"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a degraded ledger published by the helper did not wake"; }
  [ -e "$state/.helper-ran" ] || fail "the watcher never ran the detached reconciler"
  grep -q 'open-loop-ledger' "$state/.wake-queue" || fail "degraded ledger wake was not durably queued"
  pass "the watcher runs the reconciler detached and a partly blind ledger still wakes"
}

test_unpublished_ledger_is_its_own_wake() {
  local dir state fakebin out pid
  dir=$(make_case ledger-stale); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  publish_ledger "$state"
  set_mtime "$(( $(date +%s) - 600 ))" "$state/open-loops.json"
  # The helper path fails without publishing, so the old ledger stays old.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/failing-open-loops"
  chmod +x "$fakebin/failing-open-loops"
  watch_ledger "$state" "$fakebin" "$out" FM_OPEN_LOOPS_INTERVAL=10 FM_OPEN_LOOPS_BIN="$fakebin/failing-open-loops"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a ledger nobody refreshes did not wake"; }
  grep -q 'check: open-loop-ledger-stale' "$out" || fail "stale wake reason missing: $(cat "$out")"
  grep -q 'open-loop-ledger-stale' "$state/.wake-queue" || fail "stale ledger wake was not durably queued"
  pass "a ledger the reconciler stopped publishing is its own wake"
}

test_overdue_row_wakes_with_a_durable_row
test_unchanged_overdue_set_stays_quiet_then_new_row_wakes
test_ledger_without_overdue_rows_is_silent
test_detached_helper_runs_and_a_blind_ledger_wakes
test_unpublished_ledger_is_its_own_wake
