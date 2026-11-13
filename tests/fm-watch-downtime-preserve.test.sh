#!/usr/bin/env bash
# tests/fm-watch-downtime-preserve.test.sh - real watcher downtime still announces exactly once.
#
# The loop fix (docs/watcher-continuity.md "Take-over and the prelude") removes the empty
# `check: rearm-resurface` that followed a take-over of a watcher that lost nothing. It must not
# suppress the announcement of a real downtime. Every case here runs the real arm and watcher in a
# scratch home, seeds the recovery marker with an explicit token and the queue with an explicit
# state, stops the watcher one way, starts a fresh arm and counts `check: rearm-resurface` in its
# output. A seed of pending:downtime announces once; an announced:downtime seed with an empty queue
# was already announced, so it stays quiet. These cases pass on the base, with only the loop fix, with
# only the stamps fix, and on the head.
# shellcheck disable=SC2016 # fixture scripts expand in their own shells
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-downtime-preserve)
# Each watcher announces its completed poll sleeps, so a wait can count polls instead of seconds.
count_watch_polls
ARM_PIDS=
trap 'for p in $ARM_PIDS; do kill -TERM "$p" 2>/dev/null || true; done; fm_test_cleanup' EXIT

ARM=
arm_env() {  # <home>: the environment every arm and watcher of a case shares
  printf 'PATH=%s FM_HOME=%s FM_STATE_OVERRIDE=%s FM_POLL=6 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=30 FM_SECONDMATE_LIVENESS_SECS=1' \
    "$1/fakebin:$PATH" "$1" "$1/state"
}

start_arm() {  # <home> <out> [arm args...]; sets ARM
  local home=$1 out=$2
  shift 2
  # shellcheck disable=SC2046 # arm_env prints VAR=value words
  env $(arm_env "$home") "$WATCH_ARM" "$@" > "$out" 2>&1 &
  ARM=$!
  ARM_PIDS="$ARM_PIDS $ARM"
}

wait_started() {  # <out>
  local i=0
  while [ "$i" -lt 300 ]; do
    grep -q '^watcher: started pid=\|^watcher: attached pid=' "$1" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Count the recovery announcements a fresh arm prints. The watcher announces in the prelude, before
# its first terminal poll sleep begins, and announces each poll sleep it enters (tests/wake-helpers.sh
# count_watch_polls), so a watcher that has entered one poll sleep with no announcement has none to
# give; an announcement ends the wait at once. Both waits are poll counts, not a clock.
announcements_of_a_fresh_arm() {  # <home> <out>
  start_arm "$1" "$2"
  wait_started "$2" || fail "the fresh arm never started: $(cat "$2")"
  announcements_in "$1" "$2"
}
announcements_in() {  # <home> <out>: count what the arm that wrote <out> prints
  local home=$1 out=$2 i=0 w polls
  w=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  while [ "$i" -lt 900 ]; do
    grep -q '^check: rearm-resurface' "$out" && break
    polls=$(cat "$(watch_polls_file "$home/state" "$w")" 2>/dev/null || echo 0)
    [ "$polls" -lt 1 ] || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -c '^check: rearm-resurface' "$out" || true
}

seed_marker() {  # <home> <token>
  printf '%s\n' "$2" > "$1/state/.watcher-down"
}

# <name> <stop-kind> <seed-token> <queue: empty|undelivered> <expected announcements>
preserve_case() {
  local name=$1 kind=$2 seed=$3 queue=$4 want=$5 home out owner w got real_touch i
  home=$(make_case "preserve-$name")
  out="$home/owner.out"
  real_touch=$(command -v touch)
  printf '#!/usr/bin/env bash\nif [ "$*" = "%s/state/.secondmate-liveness-tick" ] && [ -e "%s/fail-tick" ]; then exit 1; fi\nexec "%s" "$@"\n' \
    "$home" "$home" "$real_touch" > "$home/fakebin/touch"
  chmod +x "$home/fakebin/touch"
  start_arm "$home" "$out" --restart
  owner=$ARM
  wait_started "$out" || fail "$name: the owner arm never started: $(cat "$out")"
  w=$(cat "$home/state/.watch.lock/pid")
  # POLL is long, so the watcher is asleep from here until its next pass: nothing consumes the seed
  # before the stop below.
  i=0
  while [ "$i" -lt 300 ] && [ ! -s "$(watch_polls_file "$home/state" "$w")" ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$(watch_polls_file "$home/state" "$w")" ] || fail "$name: the watcher never entered a poll sleep"
  if [ "$queue" = undelivered ]; then
    append_wake "$home/state" signal preserve "signal: fixture work queued and not yet delivered"
  fi
  seed_marker "$home" "$seed"
  case "$kind" in
    kill9)
      kill -KILL "$w"
      wait_for_exit "$owner" 100 >/dev/null 2>&1 || true
      rm -rf "$home/state/.watch.lock"
      ;;
    term)
      # An operator's kill -TERM under an arm attached to the same watcher.
      start_arm "$home" "$home/attached.out"
      wait_for_file_text "$home/attached.out" "watcher: attached pid=$w" 2>/dev/null || sleep 1
      kill -TERM "$w"
      wait_for_exit "$owner" 150 >/dev/null 2>&1 || true
      ;;
    arm-stop)
      # shellcheck disable=SC2046 # arm_env prints VAR=value words
      env $(arm_env "$home") "$WATCH_ARM" --stop > "$home/stop.out" 2>&1
      wait_for_exit "$owner" 150 >/dev/null 2>&1 || true
      ;;
    error-exit)
      start_arm "$home" "$home/attached.out"
      sleep 1
      : > "$home/fail-tick"
      wait_for_exit "$owner" 200 >/dev/null 2>&1 || true
      rm -f "$home/fail-tick"
      ;;
    take-over)
      # shellcheck disable=SC2046 # arm_env prints VAR=value words
      env $(arm_env "$home") "$WATCH_ARM" --take-over "$owner" > "$home/takeover.out" 2>&1 &
      ARM_PIDS="$ARM_PIDS $!"
      wait_started "$home/takeover.out" || fail "$name: the take-over arm never started: $(cat "$home/takeover.out")"
      # The take-over arm already owns a fresh cycle; its own announcement is the one counted.
      got=$(announcements_in "$home" "$home/takeover.out")
      [ "$got" = "$want" ] || fail "$name: $got announcement(s) after a take-over of $seed, expected $want: $(cat "$home/takeover.out")"
      pass "downtime: a take-over of a watcher whose token was $seed announces $want time(s)"
      return 0
      ;;
  esac
  ! is_live_non_zombie "$w" || fail "$name: the watcher survived its $kind stop"
  got=$(announcements_of_a_fresh_arm "$home" "$home/fresh.out")
  [ "$got" = "$want" ] || fail "$name: $got announcement(s) after $kind with $seed (queue $queue), expected $want"$'\n'"marker: $(cat "$home/state/.watcher-down" 2>/dev/null)"$'\n'"$(cat "$home/fresh.out")"
  pass "downtime: $kind of a watcher whose token was $seed (queue $queue) announces $want time(s)"
}

test_kill9_with_pending_downtime() { preserve_case kill9-pending kill9 pending:downtime:seedgen empty 1; }
test_kill9_with_announced_downtime() { preserve_case kill9-announced kill9 announced:downtime:seedgen empty 0; }
test_operator_term_with_pending_downtime() { preserve_case term-pending term pending:downtime:seedgen empty 1; }
test_operator_term_with_announced_downtime() { preserve_case term-announced term announced:downtime:seedgen empty 0; }
test_arm_stop_with_pending_downtime() { preserve_case stop-pending arm-stop pending:downtime:seedgen empty 1; }
test_arm_stop_with_announced_downtime() { preserve_case stop-announced arm-stop announced:downtime:seedgen empty 0; }
test_watcher_error_exit_with_pending_downtime() { preserve_case error-pending error-exit pending:downtime:seedgen empty 1; }
test_watcher_error_exit_with_announced_downtime() { preserve_case error-announced error-exit announced:downtime:seedgen empty 0; }
test_close_with_an_undelivered_wake_announces_once() { preserve_case undelivered kill9 announced:downtime:seedgen undelivered 1; }
test_take_over_of_a_watcher_whose_downtime_was_never_announced() { preserve_case takeover-unannounced take-over pending:downtime:seedgen empty 1; }

fm_test_only
fm_test_run_cases \
  test_kill9_with_pending_downtime \
  test_kill9_with_announced_downtime \
  test_operator_term_with_pending_downtime \
  test_operator_term_with_announced_downtime \
  test_arm_stop_with_pending_downtime \
  test_arm_stop_with_announced_downtime \
  test_watcher_error_exit_with_pending_downtime \
  test_watcher_error_exit_with_announced_downtime \
  test_close_with_an_undelivered_wake_announces_once \
  test_take_over_of_a_watcher_whose_downtime_was_never_announced \
  --
