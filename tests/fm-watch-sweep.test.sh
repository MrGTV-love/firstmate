#!/usr/bin/env bash
# tests/fm-watch-sweep.test.sh - the custom-check sweep (bin/fm-watch.sh prelude step 10) keeps one
# record per check, so a watcher that ends inside the sweep is followed by one that resumes
# after the last finished check, loses no check wake and repeats none.
#
# Real watchers run in a scratch state directory against five registered check scripts that
# log each run to $home/runs.log. A cut is a real signal to the watcher's pid at a chosen
# point: a check that blocks while a trigger file exists (the file is the in-flight oracle), or
# a named point the watcher holds at while FM_TEST_SEAM=1 and the hold file names it
# (bin/fm-watch.sh sweep_point). Cut kinds: TERM, SIGKILL (the only true mid-check cut, since
# the watcher defers TERM while it records an owned capture), and a wake-driven exit.
# shellcheck disable=SC2016 # fixture scripts expand in their own shells
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-sweep-tests)
WATCHER_PIDS=
trap 'for p in $WATCHER_PIDS; do kill -KILL "$p" 2>/dev/null || true; done; fm_test_cleanup' EXIT

IDS="c1 c2 c3 c4 c5"

make_sweep_home() {  # <name> [ids...]  -> prints the home
  local home ids id
  home=$(make_case "$1")
  shift
  ids=${*:-$IDS}
  : > "$home/runs.log"
  for id in $ids; do
    write_check "$home" "$id"
  done
  printf '%s\n' "$home"
}

write_check() {  # <home> <id> [register|reject]
  local home=$1 id=$2 hash
  cat > "$home/state/$id.check.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "$id" >> "\$FM_HOME/runs.log"
if [ -e "\$FM_HOME/block-$id" ]; then
  : > "\$FM_HOME/inflight-$id"
  i=0
  while [ -e "\$FM_HOME/block-$id" ] && [ "\$i" -lt 900 ]; do sleep 0.1; i=\$((i + 1)); done
  rm -f "\$FM_HOME/inflight-$id"
fi
if [ -e "\$FM_HOME/stall-$id" ]; then sleep 30; fi
[ ! -e "\$FM_HOME/out-$id" ] || cat "\$FM_HOME/out-$id"
exit 0
SH
  chmod 700 "$home/state/$id.check.sh"
  [ "${3:-register}" = reject ] && return 0
  hash=$(shasum -a 256 "$home/state/$id.check.sh" | awk '{print $1}')
  printf 'fm-custom-check-v1\n%s\n' "$hash" > "$home/state/$id.check-trust"
  chmod 600 "$home/state/$id.check-trust"
}

# Start a real watcher. Sets W (its pid); its stdout goes to $home/watch.<n>.out.
WATCH_N=0
start_watch() {  # <home> [VAR=value ...]
  local home=$1 i
  shift
  WATCH_N=$((WATCH_N + 1))
  # The seam variables are set for every watcher; they act only when the hold file exists.
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_HEARTBEAT=999999 FM_TEST_SEAM=1 FM_TEST_SWEEP_HOLD="$home/hold" FM_TEST_SWEEP_HELD="$home/held" \
    "${@:-FM_CHECK_INTERVAL=${SWEEP_INTERVAL:-999999}}" "$WATCH" > "$home/watch.$WATCH_N.out" 2>&1 &
  W=$!
  WATCHER_PIDS="$WATCHER_PIDS $W"
  i=0
  while [ "$i" -lt 100 ] && [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" != "$W" ]; do
    sleep 0.1
    i=$((i + 1))
  done
}

# A cut: a real signal to the watcher, then wait for it to be gone. A SIGKILLed watcher
# leaves its lock; the next one steals it.
cut_watch() {  # <pid> <TERM|KILL>
  kill "-$2" "$1" 2>/dev/null || true
  wait_for_exit "$1" 100 >/dev/null 2>&1 || true
  ! is_live_non_zombie "$1" || fail "the watcher $1 survived $2"
}

wait_for() {  # <polls of 0.1s> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# A watcher that raises a wake exits and its owner starts the next one; wait for a check's run count
# while keeping a watcher running, as supervision does.
until_runs() {  # <home> <id> <count> <env-args...>
  local home=$1 id=$2 want=$3 i=0
  shift 3
  while [ "$i" -lt 600 ]; do
    [ "$(runs_of "$home" "$id")" -lt "$want" ] || return 0
    is_live_non_zombie "$W" || start_watch "$home" "$@"
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

runs_of() { grep -c "^$2\$" "$1/runs.log" 2>/dev/null || true; }
sweep_closed() { [ ! -e "$1/state/.sweep-open" ] && [ ! -e "$1/state/.sweep-closing" ] && [ -e "$1/state/.last-check" ]; }
queue_rows() { grep -c "$2" "$1/state/.wake-queue" 2>/dev/null || true; }
printed() { cat "$1"/watch.*.out 2>/dev/null | grep -c "$2" || true; }

expect_runs() {  # <home> <label> id=count ...
  local home=$1 label=$2 pair id want got
  shift 2
  for pair in "$@"; do
    id=${pair%%=*}
    want=${pair#*=}
    got=$(runs_of "$home" "$id")
    [ "$got" = "$want" ] || fail "$label: check $id ran $got times, expected $want"$'\n'"runs: $(tr '\n' ' ' < "$home/runs.log")"
  done
}

# Block check $1 while the watcher is inside it, cut the watcher with $2, unblock, and let a fresh watcher
# finish. Checks before the cut one must not run again before the sweep closes.
cut_inside_third_check() {  # <name> <TERM|KILL>
  local home pid
  home=$(make_sweep_home "$1")
  : > "$home/block-c3"
  start_watch "$home" FM_CHECK_INTERVAL=1
  pid=$W
  wait_for 300 test -e "$home/inflight-c3" || fail "$1: the watcher never reached the third check"
  expect_runs "$home" "$1 before the cut" c1=1 c2=1 c3=1 c4=0 c5=0
  cut_watch "$pid" "$2"
  rm -f "$home/block-c3"
  start_watch "$home" FM_CHECK_INTERVAL=1
  wait_for 300 sweep_closed "$home" || fail "$1: the resumed sweep never closed"
  # c3 was cut mid-run and runs again; c1 and c2 finished and must not.
  expect_runs "$home" "$1 after the resume" c1=1 c2=1 c3=2 c4=1 c5=1
  cut_watch "$W" TERM
  pass "sweep: a $2 cut at the third of five checks resumes at the third (checks 1 and 2 are not run again)"
}
test_term_cut_at_the_third_of_five_checks() { cut_inside_third_check sweep-term TERM; }
test_sigkill_cut_at_the_third_of_five_checks() { cut_inside_third_check sweep-kill KILL; }

# A wake-driven exit. A signal wake raised during the sweep is held until the sweep ends (bin/fm-watch.sh
# signal_phase_flush), and a check wake ends the watcher only after the close, so the exit comes with
# the sweep closed: the next watcher within the interval runs no check, the wake is queued once and
# printed once.
test_wake_driven_exit_after_the_close_repeats_no_check_and_loses_no_wake() {
  local home pid
  home=$(make_sweep_home sweep-wake)
  printf 'state-of-c3\n' > "$home/out-c3"
  start_watch "$home" FM_CHECK_INTERVAL=4
  pid=$W
  wait_for_exit "$pid" 200 >/dev/null 2>&1
  grep -q '^check: .*c3.check.sh' "$home/watch.1.out" || fail "wake: the watcher did not exit on the check's wake: $(cat "$home/watch.1.out")"
  sweep_closed "$home" || fail "wake: the sweep was not closed when the watcher exited on its wake"
  [ "$(queue_rows "$home" 'c3.check.sh')" = 1 ] || fail "wake: the check wake was not queued exactly once: $(cat "$home/state/.wake-queue")"
  start_watch "$home" FM_CHECK_INTERVAL=4
  sleep 2
  expect_runs "$home" "wake exit" c1=1 c2=1 c3=1 c4=1 c5=1
  [ "$(printed "$home" 'c3.check.sh')" = 1 ] || fail "wake: the wake was printed other than once: $(cat "$home"/watch.*.out)"
  cut_watch "$W" TERM
  pass "sweep: a watcher that exits on a check wake leaves the sweep closed, runs no check again and loses no wake"
}

# S2b: cuts repeated every few seconds with a sweep longer than the interval. An open sweep resumes
# whatever the age of .last-check, so no finished check ever runs again.
test_repeated_cuts_with_a_sweep_longer_than_the_interval_still_close() {
  local home id
  home=$(make_sweep_home sweep-repeated)
  for id in $IDS; do : > "$home/block-$id"; done
  for id in $IDS; do
    # Each watcher reaches the next unfinished check, which blocks; the cut lands inside it.
    start_watch "$home" FM_CHECK_INTERVAL=2
    wait_for 300 test -e "$home/inflight-$id" || fail "repeated: no watcher reached $id"
    sleep 2.2
    cut_watch "$W" KILL
    rm -f "$home/block-$id"
  done
  start_watch "$home" FM_CHECK_INTERVAL=2
  wait_for 300 sweep_closed "$home" || fail "repeated: the sweep never closed after five cuts"
  # Each check was cut once mid-run (a true cut reruns it once) and finished once after: two runs, never three.
  expect_runs "$home" "repeated cuts" c1=2 c2=2 c3=2 c4=2 c5=2
  cut_watch "$W" TERM
  pass "sweep: five SIGKILL cuts over a sweep longer than the interval close it, no finished check rerun"
}

# S2c: a check stopped by the no-progress rule and a rejected one. The sweep still closes, the stopped
# check runs again in the next sweep, the rejected list names each rejected check once, and the
# stopped notice is queued once.
test_stopped_and_rejected_checks_close_the_sweep_and_run_again_next_sweep() {
  local home
  home=$(make_sweep_home sweep-nonfinishing c1 c2 c3 c4)
  write_check "$home" c5 reject
  write_check "$home" c6 reject
  : > "$home/stall-c2"
  start_watch "$home" FM_CHECK_INTERVAL=3 FM_CHECK_TIMEOUT=2
  wait_for 600 sweep_closed "$home" || fail "nonfinishing: the sweep never closed: $(cat "$home/watch.1.out")"
  expect_runs "$home" "nonfinishing sweep 1" c1=1 c2=1 c3=1 c4=1
  [ "$(queue_rows "$home" 'unauthenticated-state-checks')" = 1 ] || fail "nonfinishing: the aggregate rejected wake was not queued exactly once: $(cat "$home/state/.wake-queue")"
  grep -F "c5.check.sh" "$home/state/.wake-queue" | grep -qF "c6.check.sh" || fail "nonfinishing: the aggregate does not list both rejected checks: $(cat "$home/state/.wake-queue")"
  [ "$(grep -c 'check c2 stopped after' "$home/state/.wake-queue")" = 1 ] || fail "nonfinishing: the stopped notice was not queued exactly once: $(cat "$home/state/.wake-queue")"
  # The next sweep runs every check again.
  rm -f "$home/stall-c2"
  until_runs "$home" c4 2 FM_CHECK_INTERVAL=3 FM_CHECK_TIMEOUT=2 || fail "nonfinishing: the next sweep never ran"
  expect_runs "$home" "nonfinishing sweep 2" c1=2 c2=2 c3=2 c4=2
  cut_watch "$W" TERM
  pass "sweep: a stopped and a rejected check close the sweep and run again in the next one"
}

# Named cut points. The watcher holds at the point (a real SIGKILL then lands there); the hold is
# released and a fresh watcher resumes. Each case names which checks may have run and the
# wake counts that must hold afterwards.
cut_at_point() {  # <name> <point> <output-check|''>
  local home
  home=$(make_sweep_home "$1")
  [ -z "$3" ] || printf 'state-of-%s\n' "$3" > "$home/out-$3"
  printf '%s\n' "$2" > "$home/hold"
  rm -f "$home/held"
  start_watch "$home" FM_CHECK_INTERVAL=2
  wait_for 300 test -e "$home/held" || fail "$1: the watcher never reached $2"
  cut_watch "$W" KILL
  rm -f "$home/hold" "$home/held"
  echo "$home"
}

# A check with output, cut after its wake is queued and before its stamp: the resumed sweep reruns
# it, the queue still holds one row for it, and the resumed watcher prints the wake once.
test_cut_after_the_wake_and_before_the_stamp_queues_and_delivers_once() {
  local home
  home=$(cut_at_point sweep-before-stamp before-stamp:c2 c2)
  [ "$(queue_rows "$home" 'c2.check.sh')" = 1 ] || fail "before-stamp: the wake was not durable before the cut: $(cat "$home/state/.wake-queue")"
  start_watch "$home" FM_CHECK_INTERVAL=2
  wait_for 300 sweep_closed "$home" || fail "before-stamp: the resumed sweep never closed"
  expect_runs "$home" "before-stamp" c1=1 c2=2 c3=1 c4=1 c5=1
  [ "$(queue_rows "$home" 'c2.check.sh')" = 1 ] || fail "before-stamp: the rerun queued the wake twice: $(cat "$home/state/.wake-queue")"
  wait_for 100 grep -q '^check: .*c2.check.sh' "$home"/watch.*.out || fail "before-stamp: the resumed watcher did not print the wake"
  [ "$(printed "$home" 'c2.check.sh')" = 1 ] || fail "before-stamp: the wake was printed other than once: $(cat "$home"/watch.*.out)"
  cut_watch "$W" TERM
  pass "sweep: a cut between a check's queued wake and its stamp keeps one queue row and one delivery"
}

# The close record is down and the touch is not: the next watcher finishes the close and runs no check,
# whatever the age of .last-check.
test_cut_between_the_close_record_and_the_touch_runs_no_check() {
  local home
  home=$(cut_at_point sweep-close-record close-record '')
  expect_runs "$home" "close-record before resume" c1=1 c2=1 c3=1 c4=1 c5=1
  [ -e "$home/state/.sweep-closing" ] || fail "close-record: the close record was not written"
  start_watch "$home" FM_CHECK_INTERVAL=1
  wait_for 300 sweep_closed "$home" || fail "close-record: the resumed watcher did not finish the close"
  sleep 2
  expect_runs "$home" "close-record after resume" c1=1 c2=1 c3=1 c4=1 c5=1
  cut_watch "$W" TERM
  pass "sweep: a cut between the close record and the .last-check touch runs no check at the next start"
}

# After a close, a fresh watcher within the interval runs nothing and one past it runs every check.
test_after_a_close_the_cadence_is_unchanged() {
  local home
  home=$(make_sweep_home sweep-cadence)
  start_watch "$home" FM_CHECK_INTERVAL=4
  wait_for 300 sweep_closed "$home" || fail "cadence: the first sweep never closed"
  expect_runs "$home" "cadence first sweep" c1=1 c2=1 c3=1 c4=1 c5=1
  cut_watch "$W" TERM
  start_watch "$home" FM_CHECK_INTERVAL=4
  sleep 2
  expect_runs "$home" "cadence within the interval" c1=1 c2=1 c3=1 c4=1 c5=1
  until_runs "$home" c5 2 FM_CHECK_INTERVAL=4 || fail "cadence: a watcher past the interval did not run the checks"
  expect_runs "$home" "cadence past the interval" c1=2 c2=2 c3=2 c4=2 c5=2
  cut_watch "$W" TERM
  pass "sweep: within the interval after a close no check runs; past it every check runs"
}

# A touch of .last-check that is not a close (the retirement receipt's) neither closes nor invalidates
# an open sweep, and the open sweep resumes whatever the age of .last-check.
test_a_last_check_touch_between_cuts_leaves_the_open_sweep_open() {
  local home
  home=$(make_sweep_home sweep-touch)
  : > "$home/block-c3"
  start_watch "$home" FM_CHECK_INTERVAL=1
  wait_for 300 test -e "$home/inflight-c3" || fail "touch: no watcher reached c3"
  cut_watch "$W" KILL
  rm -f "$home/block-c3"
  touch "$home/state/.last-check"
  [ -e "$home/state/.sweep-open" ] || fail "touch: the touch closed the open sweep"
  start_watch "$home" FM_CHECK_INTERVAL=999999
  wait_for 300 sweep_closed "$home" || fail "touch: the open sweep did not resume although .last-check is young"
  expect_runs "$home" "touch" c1=1 c2=1 c3=2 c4=1 c5=1
  cut_watch "$W" TERM
  pass "sweep: a .last-check touch between cuts neither closes nor invalidates the open sweep"
}

# Records of other sweeps, removed checks, new checks and unreadable stamps.
test_stale_unreadable_and_removed_records_are_handled() {
  local home
  home=$(make_sweep_home sweep-records)
  : > "$home/block-c3"
  start_watch "$home" FM_CHECK_INTERVAL=1
  wait_for 300 test -e "$home/inflight-c3" || fail "records: no watcher reached c3"
  cut_watch "$W" KILL
  rm -f "$home/block-c3"
  printf 'garbage-not-a-sweep-id\n' > "$home/state/c1.check-stamp"
  rm -f "$home/state/c2.check.sh" "$home/state/c2.check-trust"
  write_check "$home" c6
  start_watch "$home" FM_CHECK_INTERVAL=1
  wait_for 300 sweep_closed "$home" || fail "records: the sweep never closed"
  expect_runs "$home" "records" c1=2 c2=1 c3=2 c4=1 c5=1 c6=1
  [ ! -e "$home/state/c2.check-stamp" ] || fail "records: the stamp of a removed check was kept"
  cut_watch "$W" TERM
  pass "sweep: an unreadable stamp reruns its check, a removed check's stamp goes, an added check runs"
}

# Production defaults and a home with no sweep record behave as the base.
test_a_home_with_no_sweep_record_runs_every_check_with_the_production_defaults() {
  local home
  home=$(make_sweep_home sweep-defaults)
  env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_HEARTBEAT=999999 "$WATCH" > "$home/watch.1.out" 2>&1 &
  W=$!
  WATCHER_PIDS="$WATCHER_PIDS $W"
  wait_for 300 sweep_closed "$home" || fail "defaults: the sweep never closed with FM_CHECK_INTERVAL and FM_CHECK_TIMEOUT unset"
  expect_runs "$home" "defaults" c1=1 c2=1 c3=1 c4=1 c5=1
  [ ! -e "$home/state/c1.check-stamp" ] || fail "defaults: a closed sweep left stamps behind"
  cut_watch "$W" TERM
  pass "sweep: with FM_CHECK_INTERVAL and FM_CHECK_TIMEOUT unset a home with no record runs every check once and leaves no record"
}

# contributions: its wake is queued before its stamp, and the delivered text equals the base's.
test_contributions_wake_is_durable_before_its_stamp_and_text_is_unchanged() {
  local home
  home=$(make_sweep_home sweep-contributions c1 contributions c3)
  printf 'contribution-wake: check: contributions 2 new upstream items\n' > "$home/out-contributions"
  printf 'hold\n' > /dev/null
  printf 'after-stamp:contributions\n' > "$home/hold"
  rm -f "$home/held"
  start_watch "$home" FM_CHECK_INTERVAL=2
  wait_for 300 test -e "$home/held" || fail "contributions: the watcher never reached the stamp"
  [ "$(queue_rows "$home" 'contributions')" = 1 ] || fail "contributions: its wake was not queued before its stamp: $(cat "$home/state/.wake-queue")"
  cut_watch "$W" KILL
  rm -f "$home/hold" "$home/held"
  start_watch "$home" FM_CHECK_INTERVAL=2
  wait_for 300 sweep_closed "$home" || fail "contributions: the resumed sweep never closed"
  expect_runs "$home" "contributions" c1=1 contributions=1 c3=1
  [ "$(queue_rows "$home" 'contributions')" = 1 ] || fail "contributions: its wake was queued more than once: $(cat "$home/state/.wake-queue")"
  wait_for 100 grep -qx 'check: contributions 2 new upstream items' "$home"/watch.*.out || fail "contributions: the delivered text differs from the base's: $(cat "$home"/watch.*.out)"
  cut_watch "$W" TERM
  pass "sweep: the contributions wake is durable before its stamp, queued once and delivered with the base's text"
}

# A cut right after a rejected check's attempt record, and one after the aggregate rejected wake is queued
# and before the close record: the resumed sweep reruns no finished check, rebuilds the aggregate from the
# attempt records, and the queue holds one aggregate row that lists every rejected check and is printed once.
cut_rejected_sweep() {  # <name> <point>
  local home
  home=$(make_sweep_home "$1" c1 c2 c3 c4)
  write_check "$home" c5 reject
  write_check "$home" c6 reject
  printf '%s\n' "$2" > "$home/hold"
  rm -f "$home/held"
  start_watch "$home" FM_CHECK_INTERVAL=2
  wait_for 300 test -e "$home/held" || fail "$1: the watcher never reached $2"
  cut_watch "$W" KILL
  rm -f "$home/hold" "$home/held"
  start_watch "$home" FM_CHECK_INTERVAL=2
  wait_for 300 sweep_closed "$home" || fail "$1: the resumed sweep never closed"
  expect_runs "$home" "$1" c1=1 c2=1 c3=1 c4=1
  [ "$(queue_rows "$home" 'unauthenticated-state-checks')" = 1 ] || fail "$1: the aggregate rejected wake was not queued exactly once: $(cat "$home/state/.wake-queue")"
  grep -F "c5.check.sh" "$home/state/.wake-queue" | grep -qF "c6.check.sh" || fail "$1: the aggregate does not list both rejected checks: $(cat "$home/state/.wake-queue")"
  wait_for 100 grep -q '^check: rejected unauthenticated state checks' "$home"/watch.*.out || fail "$1: the resumed watcher did not print the aggregate"
  [ "$(printed "$home" '^check: rejected unauthenticated state checks')" = 1 ] || fail "$1: the aggregate was printed other than once: $(cat "$home"/watch.*.out)"
  cut_watch "$W" TERM
}
test_cut_after_a_rejected_attempt_rebuilds_the_aggregate_once() {
  cut_rejected_sweep sweep-after-attempt after-attempt:c5
  pass "sweep: a cut after a rejected check's attempt resumes with one aggregate wake listing every rejected check"
}
test_cut_after_the_aggregate_wake_and_before_the_close_record_queues_it_once() {
  cut_rejected_sweep sweep-after-aggregate after-aggregate
  pass "sweep: a cut after the aggregate wake is queued and before the close record queues it once"
}

# A cut between a stopped check's queued notice and its episode file: the resumed sweep reruns the check, it
# stops again, and the queue still holds one notice for it.
test_cut_between_the_stopped_notice_and_its_episode_file_queues_one_notice() {
  local home
  home=$(make_sweep_home sweep-before-episode c1 c2 c3 c4)
  : > "$home/stall-c2"
  printf 'before-episode:c2\n' > "$home/hold"
  rm -f "$home/held"
  start_watch "$home" FM_CHECK_INTERVAL=3 FM_CHECK_TIMEOUT=2
  wait_for 600 test -e "$home/held" || fail "before-episode: the watcher never reached the point: $(cat "$home/watch.1.out")"
  [ "$(grep -c 'check c2 stopped after' "$home/state/.wake-queue")" = 1 ] || fail "before-episode: the notice was not queued before the episode file: $(cat "$home/state/.wake-queue")"
  [ ! -e "$home/state/c2.check-stopped" ] || fail "before-episode: the episode file existed before the notice point"
  cut_watch "$W" KILL
  rm -f "$home/hold" "$home/held"
  start_watch "$home" FM_CHECK_INTERVAL=3 FM_CHECK_TIMEOUT=2
  wait_for 600 sweep_closed "$home" || fail "before-episode: the resumed sweep never closed"
  expect_runs "$home" "before-episode" c1=1 c2=2 c3=1 c4=1
  [ "$(grep -c 'check c2 stopped after' "$home/state/.wake-queue")" = 1 ] || fail "before-episode: the rerun queued a second notice: $(cat "$home/state/.wake-queue")"
  [ -e "$home/state/c2.check-stopped" ] || fail "before-episode: the resumed sweep never created the episode file"
  cut_watch "$W" TERM
  pass "sweep: a cut between the stopped notice and its episode file keeps one notice and creates the episode on the rerun"
}

run_case() { [ -z "${FM_TEST_ONLY:-}" ] || [ "$1" = "$FM_TEST_ONLY" ] || return 0; "$1"; }
for t in \
  test_term_cut_at_the_third_of_five_checks \
  test_sigkill_cut_at_the_third_of_five_checks \
  test_wake_driven_exit_after_the_close_repeats_no_check_and_loses_no_wake \
  test_repeated_cuts_with_a_sweep_longer_than_the_interval_still_close \
  test_stopped_and_rejected_checks_close_the_sweep_and_run_again_next_sweep \
  test_cut_after_the_wake_and_before_the_stamp_queues_and_delivers_once \
  test_cut_between_the_close_record_and_the_touch_runs_no_check \
  test_cut_after_a_rejected_attempt_rebuilds_the_aggregate_once \
  test_cut_after_the_aggregate_wake_and_before_the_close_record_queues_it_once \
  test_cut_between_the_stopped_notice_and_its_episode_file_queues_one_notice \
  test_after_a_close_the_cadence_is_unchanged \
  test_a_last_check_touch_between_cuts_leaves_the_open_sweep_open \
  test_stale_unreadable_and_removed_records_are_handled \
  test_a_home_with_no_sweep_record_runs_every_check_with_the_production_defaults \
  test_contributions_wake_is_durable_before_its_stamp_and_text_is_unchanged
do
  run_case "$t"
done
