#!/usr/bin/env bash
# tests/fm-status-runaway-guard.test.sh - a runaway append to a task status log can
# no longer grow past the cap or take down the watcher, the drain, the fleet snapshot
# or the readers. The incident this pins: on 2026-10-18 a shell loop inside an agent
# harness appended to three state/<task>.status files until they were 140 GB, 265 GB
# and 122 GB, the disk filled, and every reader multiplied the damage.
#
# Everything here is bounded and runs in temp directories: each fake writer runs
# under a hard file-size limit (ulimit -f) and a hard iteration count, so a broken
# guard fails the assertion instead of filling the disk. The sparse 2 GiB logs occupy
# a few megabytes of real blocks.
#
# The mutation checks run each guard both ways: the same fixture with the guard
# removed (a raw append loop, or a read limit raised past the log) must show the damage
# the guard prevents, so a passing guard test cannot be vacuous.
# shellcheck disable=SC2016 # The inline scripts below are single-quoted on purpose.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

APPEND="$ROOT/bin/fm-status-append.sh"
GUARD="$ROOT/bin/fm-status-cap-guard.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-status-runaway-guard)

# These cases exercise status handling on a home that does not run the supervision
# host, so the drain's BRANCH OUTCOMES section stays out (as in the other drain suites).
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

# Every fake writer carries its own hard byte limit: ulimit -f counts blocks, 1024
# bytes in bash 3.2 and 512 in POSIX mode, so 4096 blocks is at most 4 MiB.
HARD_LIMIT_BLOCKS=4096

# Files over 1 MB that a reader created: every status log is the fixture itself, so
# only the sidecars and scratch files beside them count.
big_files_in() {  # <dir> -> files over 1 MB
  find "$1" -type f -size +1048576c ! -name '*.status' 2>/dev/null
}

file_size() {
  if [ "$(uname)" = Darwin ]; then stat -f %z "$1"; else stat -c %s "$1"; fi
}

# --- the sanctioned writer ----------------------------------------------------

test_sanctioned_loop_stops_growing_at_the_cap() {
  local dir status size i rc refused=0 err
  dir=$(make_case sanctioned-loop); status="$dir/state/loop.status"; err="$dir/loop.err"
  # A loop that repeats one line through the helper is refused once the cap is reached,
  # with exit 75, and the refusal names the file. The loop itself fails the case if it
  # was never refused, and it runs under a hard file-size limit and a hard count.
  FM_STATUS_CAP_BYTES=4096 FM_STATUS_CAP_RESERVE_BYTES=512 bash -c '
    ulimit -f '"$HARD_LIMIT_BLOCKS"'
    i=0
    refused=0
    while [ "$i" -lt 600 ]; do
      i=$((i + 1))
      "$1" "$2" "working [at=$i]: the same line again" 2>>"$3" && continue
      [ "$?" -eq 75 ] || exit 1
      refused=$((refused + 1))
    done
    [ "$refused" -gt 0 ]
  ' _ "$APPEND" "$status" "$err" || fail "the sanctioned loop was never refused at the cap, or failed another way"
  size=$(file_size "$status")
  [ "$size" -le 4096 ] || fail "the sanctioned repeat loop grew to $size bytes, past the 4096 byte cap"
  [ "$size" -gt $((4096 - 64)) ] || fail "the loop was refused well short of the cap, at $size bytes"
  grep -q 'refused' "$err" || fail "the refusal was not said on stderr: $(head -c 300 "$err")"
  grep -q 'loop.status' "$err" || fail "the refusal does not name the file: $(head -c 300 "$err")"
  awk '{ if ($0 != "working [at=" NR "]: the same line again") bad = 1 } END { exit bad }' "$status" \
    || fail "a line before the cap was lost, altered or reordered"

  # Distinct filler is refused loudly at the cap too; nothing is silently lost.
  i=0
  while [ "$i" -lt 400 ]; do
    i=$((i + 1))
    FM_STATUS_CAP_BYTES=4096 FM_STATUS_CAP_RESERVE_BYTES=512 "$APPEND" "$status" "working: filler line number $i padding padding padding" 2>/dev/null
    rc=$?
    if [ "$rc" -eq 75 ]; then refused=$((refused + 1)); elif [ "$rc" -ne 0 ]; then fail "unexpected exit $rc from the writer"; fi
  done
  [ "$refused" -gt 0 ] || fail "no distinct line was ever refused at the cap"
  size=$(file_size "$status")
  [ "$size" -le 4096 ] || fail "filler grew the log to $size bytes, past the cap"

  # A decision or terminal line may still use the reserve above the cap.
  FM_STATUS_CAP_BYTES=4096 FM_STATUS_CAP_RESERVE_BYTES=512 "$APPEND" "$status" "done [at=9]: finished" 2>/dev/null \
    || fail "a done line was refused although the reserve was free"
  tail -1 "$status" | grep -q '^done ' || fail "the done line did not land"
  size=$(file_size "$status")
  [ "$size" -le $((4096 + 512)) ] || fail "the log passed cap plus reserve: $size"

  # Past cap plus reserve every line is refused, terminal ones included, and each names the file.
  head -c 6000 /dev/zero | tr '\0' 'z' >> "$status"
  printf '\n' >> "$status"
  size=$(file_size "$status")
  rc=0
  FM_STATUS_CAP_BYTES=4096 FM_STATUS_CAP_RESERVE_BYTES=512 "$APPEND" "$status" "done [at=10]: too late" 2>"$err" || rc=$?
  [ "$rc" -eq 75 ] || fail "a done line past cap plus reserve was not refused with exit 75 (rc=$rc)"
  grep -q 'loop.status' "$err" || fail "the refusal past cap plus reserve does not name the file: $(cat "$err")"
  [ "$(file_size "$status")" -eq "$size" ] || fail "a refused line changed the log"
  pass "the sanctioned writer holds the cap, refuses a repeat loop and filler loudly, keeps the reserve for done:, and refuses everything past cap plus reserve"
}

test_a_verbless_loop_stops_at_the_cap_and_leaves_the_reserve_for_done() {
  local dir status err size rc line
  dir=$(make_case verbless-loop); status="$dir/state/text.status"; err="$dir/text.err"
  # The 2026-10-18 line had no verb at all. A loop that pushes it through the helper must stop at
  # the cap, not run on into the reserve, so a later done: still has the whole reserve to land in.
  FM_STATUS_CAP_BYTES=4096 FM_STATUS_CAP_RESERVE_BYTES=512 bash -c '
    ulimit -f '"$HARD_LIMIT_BLOCKS"'
    i=0
    refused=0
    while [ "$i" -lt 1500 ]; do
      i=$((i + 1))
      "$1" "$2" "text" 2>>"$3" && continue
      [ "$?" -eq 75 ] || exit 1
      refused=$((refused + 1))
    done
    [ "$refused" -gt 0 ]
  ' _ "$APPEND" "$status" "$err" || fail "the verbless loop was never refused, or failed another way"
  size=$(file_size "$status")
  [ "$size" -le 4096 ] || fail "the verbless loop used the reserve: the log is $size bytes, past the 4096 byte cap"
  # Prose with a colon, and a line whose head is not a verb, stop at the cap too.
  for line in "1793124970: text" "Reason: retrying" "working: still going" "note: aside"; do
    rc=0
    FM_STATUS_CAP_BYTES=4096 FM_STATUS_CAP_RESERVE_BYTES=512 "$APPEND" "$status" "$line" 2>/dev/null || rc=$?
    [ "$rc" -eq 75 ] || fail "the line '$line' was not refused at the cap (rc=$rc)"
  done
  [ "$(file_size "$status")" -eq "$size" ] || fail "a refused line changed the log"
  for line in "done [at=9]: finished" "blocked [key=k1] corr=0123456789abcdef: stuck" "resolved [key=k1]: cleared"; do
    FM_STATUS_CAP_BYTES=4096 FM_STATUS_CAP_RESERVE_BYTES=512 "$APPEND" "$status" "$line" 2>/dev/null \
      || fail "the line '$line' was refused although the reserve was free"
    [ "$(tail -1 "$status")" = "$line" ] || fail "the line '$line' did not land"
  done
  [ "$(file_size "$status")" -le $((4096 + 512)) ] || fail "the log passed cap plus reserve: $(file_size "$status")"
  pass "a verbless text loop through the helper stops at the cap, and done:, blocked: and resolved: still land in the reserve"
}

# A holder of the log's lock, opened read-only so the guard never lists it as a writer.
start_lock_holder() {  # <status-file> <ready-file>
  perl -MFcntl=:flock -e '
    open(my $f, "<", $ARGV[0]) or exit 1;
    flock($f, LOCK_EX) or exit 1;
    open(my $r, ">", $ARGV[1]) or exit 1;
    print $r "locked\n";
    close($r);
    sleep 120;
  ' "$1" "$2" &
}

test_a_stopped_lock_holder_never_hangs_a_sanctioned_append() {
  local dir status err holder rc=0 began elapsed size
  dir=$(make_case stopped-holder); status="$dir/state/held.status"; err="$dir/held.err"
  printf 'working: before\n' > "$status"
  size=$(file_size "$status")
  start_lock_holder "$status" "$dir/ready"
  holder=$!
  wait_for_file_nonempty "$dir/ready" || { kill -9 "$holder" 2>/dev/null; fail "the lock holder did not start"; }
  kill -STOP "$holder"
  began=$SECONDS
  fm_run_timed 40 "$APPEND" "$status" "done: finished" 2>"$err" || rc=$?
  elapsed=$((SECONDS - began))
  kill -9 "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  ! fm_timed_out "$rc" || fail "a sanctioned append hung on a lock held by a stopped writer (still waiting after 40 s)"
  [ "$rc" -eq 75 ] || fail "a sanctioned append behind a stopped lock holder did not return 75 (rc=$rc): $(cat "$err")"
  [ "$elapsed" -le 15 ] || fail "the refusal took $elapsed s, past the 10 s lock bound"
  grep -q 'fm-status-append: refused: .*held.status stayed locked' "$err" || fail "the refusal is not loud or does not name the file: $(cat "$err")"
  [ "$(file_size "$status")" -eq "$size" ] || fail "a refused append changed the log"
  "$APPEND" "$status" "done: finished" || fail "an append after the holder went away did not land"
  [ "$(tail -1 "$status")" = "done: finished" ] || fail "the later append did not land"
  pass "a sanctioned append behind a stopped lock holder is refused loudly with exit 75 within the lock bound, and lands once the lock is free"
}

test_without_the_helper_the_same_loop_passes_the_cap() {
  local dir status size
  dir=$(make_case raw-loop); status="$dir/state/raw.status"
  bash -c '
    ulimit -f '"$HARD_LIMIT_BLOCKS"'
    i=0
    while [ "$i" -lt 600 ]; do
      i=$((i + 1))
      echo "working [at=$i]: the same line again" >> "$1"
    done
  ' _ "$status" || fail "the raw loop fixture failed"
  size=$(file_size "$status")
  [ "$size" -gt 4096 ] || fail "mutation check: the raw loop did not pass the cap ($size); the cap test above proves nothing"
  pass "mutation: the same loop through a raw append passes the cap, so the helper is what holds it"
}

test_incident_shape_is_refused_at_the_cap_and_loses_no_distinct_line() {
  local dir status err args=() i rc size before
  dir=$(make_case incident-shape); status="$dir/state/shape.status"; err="$dir/shape.err"
  i=0
  while [ "$i" -lt 3000 ]; do
    i=$((i + 1))
    args+=("working [at=$i]: distinct event number $i")
  done
  (ulimit -f "$HARD_LIMIT_BLOCKS"; FM_STATUS_CAP_BYTES=262144 "$APPEND" "$status" "${args[@]}") \
    || fail "a burst of 3000 distinct events was refused below the cap"
  [ "$(wc -l < "$status" | tr -d ' ')" -eq 3000 ] || fail "the burst lost events: $(wc -l < "$status") of 3000"
  before=$(file_size "$status")

  # Then one line repeated, enough times to pass the cap (the 2026-10-18 shape).
  args=()
  i=0
  while [ "$i" -lt 8000 ]; do i=$((i + 1)); args+=("working [at=1790000000]: the same line repeated"); done
  rc=0
  (ulimit -f "$HARD_LIMIT_BLOCKS"; FM_STATUS_CAP_BYTES=262144 "$APPEND" "$status" "${args[@]}" 2>"$err") || rc=$?
  [ "$rc" -eq 75 ] || fail "the repeat loop was not refused with exit 75 (rc=$rc)"
  size=$(file_size "$status")
  [ "$size" -le 262144 ] || fail "the repeats grew the log to $size bytes, past the 262144 byte cap"
  [ "$size" -gt "$before" ] || fail "no repeated line was written below the cap"
  grep -q 'fm-status-append: refused: .*shape.status' "$err" || fail "the refusal is not loud or does not name the file: $(head -c 300 "$err")"
  awk 'NR <= 3000 { if ($0 != "working [at=" NR "]: distinct event number " NR) bad = 1 } END { exit bad }' "$status" \
    || fail "a distinct line was lost, altered or reordered before the cap"
  [ "$(sed -n '3001,$p' "$status" | grep -vc '^working \[at=1790000000\]: the same line repeated$')" -eq 0 ] \
    || fail "a line after the distinct ones is not the repeated line"
  pass "the 2026-10-18 shape (3000 distinct lines, then one line repeated) keeps every distinct line and is refused loudly at the cap with exit 75"
}

# --- foreign writers: wake and containment ------------------------------------

# A symlink to bash under another name, so ps and lsof report the writer as `omp`.
# (A copy of the system bash is killed at exec on macOS: its signature no longer
# matches its new path.)
make_named_shell() {  # <dir> <name>
  mkdir -p "$1/bin"
  ln -s "$(command -v bash)" "$1/bin/$2"
  printf '%s\n' "$1/bin/$2"
}

# A bounded writer that holds a descriptor open and appends 65 lines of 1000 bytes
# (65000 bytes) every three seconds for up to 60 rounds. It is paced so that it is
# still writing when the watcher, which takes several seconds to start and far longer on
# a loaded host, finds it, and a stopped and then resumed one still has most of its
# work left. It runs under a hard file-size limit and a hard round count: 60 rounds are
# 3.9 MB, under the 4 MiB limit.
# The lines are long on purpose. The watcher classifies the unread lines of a signaled
# log one at a time in the shell, 2.7 to 5 ms each, and the over-cap check cannot run
# while it does. 13000 five-byte lines per round held one classification for 67 s on a
# loaded host, past the 30 s the wait gives a watcher, so the wake never came.
# The cap is a count of bytes, so long lines reach it the same way, and the
# held-open incident writer without a pause is pinned by its own case below.
start_paced_writer() {  # <shell> <status-file> <pid-file>
  (
    ulimit -f "$HARD_LIMIT_BLOCKS"
    "$1" -c '
      exec 9>>"$1"
      line=$(head -c 999 /dev/zero | tr "\0" x)
      i=0
      while [ "$i" -lt 60 ]; do
        i=$((i + 1))
        printf "${line}\n%.0s" {1..65} >&9
        sleep 3 9>&-
      done
    ' _ "$2" &
    printf '%s\n' "$!" > "$3"
    wait "$!" 2>/dev/null
  ) &
}

wait_watch_exit() {
  wait_for_exit "$@"
}

reap() {
  kill "$1" 2>/dev/null || true
  wait_for_exit "$1" 100 || true
}

ack_cycle() {  # <state>
  local state=$1 err sequence generation
  err="$state/.test-cycle-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null
}

watch_cap() {  # <state> <out> [extra env...]
  local state=$1 out=$2
  shift 2
  FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_STATUS_CAP_BYTES=262144 \
    FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
    FM_HOME_SUMMARY_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_OPEN_LOOPS_INTERVAL=99999999 env "$@" "$WATCH" > "$out" 2> "$out.err" &
}

state_letter() {  # <pid> -> first letter of the ps state
  ps -p "$1" -o state= 2>/dev/null | tr -d ' ' | cut -c1
}

# A growing log wakes the watcher for its ordinary status signal before it reaches the
# cap, and a watcher exits on every wake, so acknowledge those and re-arm until the
# over-cap wake itself arrives (the supervision cycle does the same).
run_until_cap_wake() {  # <state> <out>
  local state=$1 out=$2 attempt=0 pid
  while [ "$attempt" -lt 8 ]; do
    attempt=$((attempt + 1))
    watch_cap "$state" "$out"
    pid=$!
    wait_for_exit "$pid" 300 || { reap "$pid"; return 1; }
    if grep -q 'check: status-log-over-cap' "$out"; then return 0; fi
    ack_cycle "$state" || return 1
  done
  return 1
}

queue_rows_for() {  # <state> -> wake rows naming the over-cap check
  grep -c 'status-log-over-cap' "$1/.wake-queue" 2>/dev/null || true
}

test_foreign_omp_writer_is_named_stopped_and_never_deleted() {
  local dir state status out omp bystander wpid pid watch_pid before_delete rows
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case foreign-omp); state="$dir/state"; status="$state/victim.status"; out="$dir/watch.out"
  omp=$(make_named_shell "$dir" omp)
  : > "$status"
  # A second omp process that holds no status log: containment must leave it alone.
  "$omp" -c 'sleep 600' &
  bystander=$!
  start_paced_writer "$omp" "$status" "$dir/writer.pid"
  wait_for_file_nonempty "$dir/writer.pid" || fail "the fake writer did not start"
  wpid=$(cat "$dir/writer.pid")
  run_until_cap_wake "$state" "$out" || { kill -9 "$wpid" "$bystander" 2>/dev/null; fail "the watcher did not wake for the runaway log: $(cat "$out" "$out.err" 2>/dev/null)"; }
  pid=$wpid
  grep -q 'check: status-log-over-cap' "$out" || fail "no over-cap wake: $(cat "$out")"
  grep -q 'file=victim.status' "$out" || fail "the wake does not name the file: $(cat "$out")"
  grep -Eq 'size=[0-9]+ bytes \(cap 262144\)' "$out" || fail "the wake does not state size and cap: $(cat "$out")"
  grep -Eq 'growth=[0-9]+ bytes/s' "$out" || fail "the wake does not state the growth rate: $(cat "$out")"
  grep -Eq "writer=pid $pid omp" "$out" || fail "the wake does not name the writer pid $pid: $(cat "$out")"
  grep -q "stopped pid $pid (omp) with SIGSTOP" "$out" || fail "the wake does not say the writer was stopped: $(cat "$out")"
  printf '# wake text: %s\n' "$(cat "$out")"
  [ "$(state_letter "$pid")" = T ] || fail "the omp writer pid $pid was not stopped (state $(state_letter "$pid"))"
  [ "$(state_letter "$bystander")" != T ] || fail "a bystander omp process was stopped too"
  [ "$(state_letter $$)" != T ] || fail "the test shell was stopped"
  [ -f "$status" ] || fail "the over-cap log was deleted"
  before_delete=$(file_size "$status")
  [ "$before_delete" -gt 262144 ] || fail "the log is not over the cap ($before_delete); the fixture proves nothing"
  [ "$before_delete" -le $((HARD_LIMIT_BLOCKS * 1024)) ] || fail "the writer ignored its own hard limit"
  rows=$(queue_rows_for "$state")
  [ "$rows" -eq 1 ] || fail "expected exactly one queued over-cap wake, found $rows"
  sleep 1
  [ "$(file_size "$status")" -eq "$before_delete" ] || fail "the stopped writer kept growing the log"

  # A file that has not grown gets no second wake: a watcher over the same log stays quiet.
  ack_cycle "$state" || fail "could not acknowledge the wake"
  watch_cap "$state" "$out.2"
  watch_pid=$!
  wait_for_exit "$watch_pid" 30 && fail "the watcher woke a second time for the same over-cap log: $(cat "$out.2")"
  [ "$(queue_rows_for "$state")" -eq 0 ] || fail "a second over-cap wake was queued"
  reap "$watch_pid"
  [ "$(file_size "$status")" -eq "$before_delete" ] || fail "the log was rewritten or truncated by the guard"
  kill -CONT "$pid" 2>/dev/null; kill -9 "$pid" "$bystander" 2>/dev/null
  pass "a raw omp writer over the cap is detected within polls, named by pid, stopped alone, and the log is left intact with one wake while it does not grow"
}

test_the_incident_writer_that_holds_the_log_open_is_found_and_stopped() {
  local dir state status omp wpid out waited=0 limit_blocks=16384
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case holds-open); state="$dir/state"; status="$state/loop.status"
  omp=$(make_named_shell "$dir" omp)
  : > "$status"
  # The writer of 2026-10-18: one printf whose format has no conversion and that has an
  # extra argument, which the harness shell re-applied without end, appending to a log it
  # opened once and held for its whole run. It wrote 0.7 GB/s, which no loop that opens
  # and closes the log on every append can do, so this fixture holds the descriptor and
  # writes without a pause. Three million lines of five bytes are 15 MB, under the 16 MiB
  # hard limit it carries, and long enough to outlast the scan.
  (
    ulimit -f "$limit_blocks"
    "$omp" -c '
      exec 9>>"$1"
      i=0
      while [ "$i" -lt 3000000 ]; do
        i=$((i + 1))
        printf "text\n" >&9
      done
    ' _ "$status" &
    printf '%s\n' "$!" > "$dir/writer.pid"
    wait "$!" 2>/dev/null
  ) &
  wait_for_file_nonempty "$dir/writer.pid" || fail "the fake writer did not start"
  wpid=$(cat "$dir/writer.pid")
  while [ "$(file_size "$status")" -le 65536 ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ "$(file_size "$status")" -gt 65536 ] || { kill -9 "$wpid" 2>/dev/null; fail "the writer never passed the cap, so the fixture proves nothing"; }
  out=$(FM_STATE_OVERRIDE="$state" FM_STATUS_CAP_BYTES=65536 "$GUARD" scan) \
    || { kill -9 "$wpid" 2>/dev/null; fail "the guard scan failed"; }
  case "$out" in
    *"writer=pid $wpid omp"*"stopped pid $wpid (omp) with SIGSTOP"*) ;;
    *) kill -9 "$wpid" 2>/dev/null; fail "the guard missed the writer that holds the log open: $out" ;;
  esac
  [ "$(state_letter "$wpid")" = T ] || { kill -9 "$wpid" 2>/dev/null; fail "the writer was not stopped (state $(state_letter "$wpid"))"; }
  [ -f "$status" ] || { kill -9 "$wpid" 2>/dev/null; fail "the over-cap log was deleted"; }
  kill -CONT "$wpid" 2>/dev/null; kill -9 "$wpid" 2>/dev/null
  pass "the incident writer, which holds the log open and writes without a pause, is named and stopped by the guard and the log is left in place"
}

test_a_lingering_signal_does_not_hold_back_the_over_cap_stop() {
  local dir state status out omp wpid watch_pid waited=0 deadline
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case linger); state="$dir/state"; status="$state/linger.status"; out="$dir/watch.out"
  omp=$(make_named_shell "$dir" omp)
  : > "$status"
  # The writer's lines are 1000 bytes long, so the 64 KiB log is about 65 lines: classifying
  # the pending signal in the wake's flush takes a moment, where 13000 short lines would
  # take longer than the deadline on a loaded host and hide the grace this test is about.
  # The first status line is a signal and starts the watcher's grace linger, here 120 s.
  # The log passes its 64 KiB cap a few seconds later, inside that linger. The stop must
  # come from the watcher's own cap check during the linger, not from the next watcher
  # after a drain, an ack and a re-arm, and the wake that reports it must not wait out
  # another grace for the pending signal: the watcher has to exit well inside 120 s.
  # The wait is a wall-clock deadline, so a loaded host cannot stretch it past the grace.
  watch_cap "$state" "$out" FM_SIGNAL_GRACE=120 FM_STATUS_CAP_BYTES=65536
  watch_pid=$!
  while [ ! -e "$state/.last-watcher-beat" ] && [ "$waited" -lt 600 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$state/.last-watcher-beat" ] || { reap "$watch_pid"; fail "the watcher never started its loop"; }
  (
    ulimit -f "$HARD_LIMIT_BLOCKS"
    "$omp" -c '
      exec 9>>"$1"
      line=$(head -c 999 /dev/zero | tr "\0" x)
      printf "working: the first line is the signal\n" >&9
      sleep 4 9>&-
      i=0
      while [ "$i" -lt 40 ]; do
        i=$((i + 1))
        printf "${line}\n%.0s" {1..65} >&9
        sleep 1 9>&-
      done
    ' _ "$status" &
    printf '%s\n' "$!" > "$dir/writer.pid"
    wait "$!" 2>/dev/null
  ) &
  wait_for_file_nonempty "$dir/writer.pid" || { reap "$watch_pid"; fail "the fake writer did not start"; }
  wpid=$(cat "$dir/writer.pid")
  deadline=$((SECONDS + 90))
  while is_live_non_zombie "$watch_pid" && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
  if is_live_non_zombie "$watch_pid"; then
    kill -9 "$wpid" 2>/dev/null
    reap "$watch_pid"
    fail "the watcher kept lingering on the status signal while the log ran past the cap: $(cat "$out" "$out.err" 2>/dev/null)"
  fi
  wait "$watch_pid" 2>/dev/null
  grep -q 'check: status-log-over-cap' "$out" || { kill -9 "$wpid" 2>/dev/null; fail "the first wake was not the over-cap check: $(cat "$out")"; }
  grep -q "stopped pid $wpid (omp) with SIGSTOP" "$out" || { kill -9 "$wpid" 2>/dev/null; fail "the wake does not say the writer was stopped: $(cat "$out")"; }
  [ "$(state_letter "$wpid")" = T ] || { kill -9 "$wpid" 2>/dev/null; fail "the omp writer was not stopped (state $(state_letter "$wpid"))"; }
  kill -CONT "$wpid" 2>/dev/null; kill -9 "$wpid" 2>/dev/null
  pass "the watcher checks the cap during the status-signal linger, so the over-cap stop is the first wake and waits for no ack or re-arm"
}

# The incident's writer shape on a held descriptor: five-byte lines. The writer opens the log,
# waits for a gate file, appends <burst> units of 100 lines at once and then <round> units every
# <pause> seconds (default 1) for up to <rounds> rounds (default 60), under a hard file-size limit.
# It builds its unit before it opens the log and writes only with shell builtins, so no forked
# child of it ever holds the log open.
start_gated_tiny_writer() {  # <shell> <status-file> <gate-file> <pid-file> <burst-units> <round-units> [<pause> [<rounds>]]
  (
    ulimit -f "$HARD_LIMIT_BLOCKS"
    "$1" -c '
      printf -v unit "text\n%.0s" {1..100}
      exec 9>>"$1"
      while [ ! -e "$2" ]; do sleep 0.1 9>&-; done
      for ((k = 0; k < $3; k++)); do printf "%s" "$unit" >&9; done
      i=0
      while [ "$i" -lt "$5" ]; do
        i=$((i + 1))
        for ((k = 0; k < $4; k++)); do printf "%s" "$unit" >&9; done
        sleep "$6" 9>&-
      done
    ' _ "$2" "$3" "$5" "$6" "${8:-60}" "${7:-1}" &
    printf '%s\n' "$!" > "$4"
    wait "$!" 2>/dev/null
  ) &
}

# A reader for the watcher's FM_STATUS_SPAN_READER seam. It returns exactly the bytes asked for.
# The first time it is asked for the log named in FM_TEST_GATE_LOG it opens the writer's gate and
# holds the read until the file the writer appends to (FM_TEST_GATE_GROWS, by default that log) is
# larger than FM_TEST_GATE_SIZE, so the file passes the cap after the watcher has chosen to walk the
# log and before it walks it, whatever the speed of the host.
# With FM_TEST_GATE2 set, the first read of that log after the watcher has recorded an over-cap alert
# (the read the over-cap wake's flush makes) does the same for a second gate and a second file
# (FM_TEST_GATE2_GROWS, FM_TEST_GATE2_SIZE): a second writer passes the cap while that wake is in flight.
make_gating_span_reader() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "$FM_TEST_GATE_LOG" ]; then
  : > "$FM_TEST_GATE"
  waited=0
  while [ "$(perl -e 'print -s $ARGV[0]' "${FM_TEST_GATE_GROWS:-$1}")" -le "$FM_TEST_GATE_SIZE" ] && [ "$waited" -lt 400 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  if [ -n "${FM_TEST_GATE2:-}" ] && ls "$FM_STATE_OVERRIDE"/.status-cap-alerted.* >/dev/null 2>&1; then
    : > "$FM_TEST_GATE2"
    waited=0
    while [ "$(perl -e 'print -s $ARGV[0]' "$FM_TEST_GATE2_GROWS")" -le "$FM_TEST_GATE2_SIZE" ] && [ "$waited" -lt 400 ]; do
      sleep 0.05
      waited=$((waited + 1))
    done
  fi
fi
exec perl -e 'open my $f, "<", $ARGV[0] or exit 1; seek $f, $ARGV[1], 0 or exit 1; defined(read $f, my $b, $ARGV[2]) or exit 1; print $b or exit 1' "$1" "$2" "$3"
SH
  chmod +x "$1"
}

test_a_cap_crossing_after_the_span_is_captured_is_stopped_before_the_signal_wake_exits() {
  local dir state status out omp wpid watch_pid reader cap=2048
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case short-span); state="$dir/state"; status="$state/short.status"; out="$dir/watch.out"
  omp=$(make_named_shell "$dir" omp)
  reader="$dir/gating-span-reader"
  make_gating_span_reader "$reader"
  # Forty five-byte lines are unread when the watcher classifies the log, and its poll is 60 s, so
  # the classification is far shorter than one poll and only the check just before the signal wake
  # can see what happens next: the writer passes the 2048 byte cap once the watcher holds its span,
  # before it classifies it.
  perl -e 'print "text\n" x 40' > "$status"
  start_gated_tiny_writer "$omp" "$status" "$dir/gate" "$dir/writer.pid" 4 1
  wait_for_file_nonempty "$dir/writer.pid" || fail "the fake writer did not start"
  wpid=$(cat "$dir/writer.pid")
  watch_cap "$state" "$out" FM_POLL=60 FM_STATUS_CAP_BYTES=$cap FM_STATUS_SPAN_READER="$reader" \
    FM_TEST_GATE_LOG="$status" FM_TEST_GATE="$dir/gate" FM_TEST_GATE_SIZE=$cap
  watch_pid=$!
  wait_for_exit "$watch_pid" 600 || { kill -9 "$wpid" 2>/dev/null; reap "$watch_pid"; fail "the watcher never woke: $(cat "$out" "$out.err" 2>/dev/null)"; }
  grep -q 'check: status-log-over-cap' "$out" \
    || { kill -9 "$wpid" 2>/dev/null; fail "the status signal woke the watcher without a check of the cap that its log had passed: $(cat "$out")"; }
  grep -q "stopped pid $wpid (omp) with SIGSTOP" "$out" || { kill -9 "$wpid" 2>/dev/null; fail "the wake does not say the writer was stopped: $(cat "$out")"; }
  [ "$(state_letter "$wpid")" = T ] || { kill -9 "$wpid" 2>/dev/null; fail "the omp writer was not stopped (state $(state_letter "$wpid"))"; }
  awk -F'\t' '$3 == "signal" { found = 1 } END { exit !found }' "$state/.wake-queue" \
    || { kill -9 "$wpid" 2>/dev/null; fail "the status signal was not queued with the over-cap wake: $(cat "$state/.wake-queue")"; }
  kill -CONT "$wpid" 2>/dev/null; kill -9 "$wpid" 2>/dev/null
  pass "a log that passes the cap while the watcher classifies a short signaled span is checked before the signal wake exits, and its writer is stopped"
}

# A lane whose pane sat at one hash for a poll already, so the next poll finds it stale, over a
# log whose latest event is terminal and that is recorded as already seen. The watcher surfaces
# it: it queues a stale wake, walks the whole log from byte 0 to record the surfaced position, and
# exits on `stale: test:fm-<task>`. The watch environment it needs is stale_lane_env.
make_stale_lane() {  # <dir> <task>
  local dir=$1 task=$2 state="$1/state" window="test:fm-$2" key
  printf 'finished, awaiting review' > "$dir/pane.txt"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/$task.meta"
  printf 'done: PR https://example.test/pr/3\n' >> "$state/$task.status"
  prime_status_seen "$state" "$state/$task.status" || return 1
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'finished, awaiting review')" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
}

stale_lane_env() {  # <dir> <task> -> one watch environment assignment per line
  printf '%s\n' "PATH=$1/fakebin:$PATH" "FM_FAKE_TMUX_WINDOW=test:fm-$2" \
    "FM_FAKE_TMUX_CAPTURE=$1/pane.txt" "FM_CREW_STATE_BIN=$1/fakebin/fm-crew-state.sh"
}

# Shared by the signal, heartbeat and stale cases below. 20000 five-byte lines are unread (100000
# bytes, under the cap) and the watcher walks them one at a time in the shell, at 1.5 to 5 ms
# each: 30 s on a fast host, far longer on a loaded one. The writer passes the cap once the watcher
# holds the span. The stop must come from a check inside the walk, within a few polls, not from
# the end of it, so the case waits 20 s for it while the watcher is still walking.
# <walk> picks which walk reads the log: signal (the log is new), heartbeat (the log is recorded
# as seen and the heartbeat is due) or stale (the log is seen and its lane's pane is stale).
stop_a_writer_during_a_long_walk() {  # <case> <walk: signal|heartbeat|stale>
  local name=$1 walk=$2 dir state status out omp wpid watch_pid reader cap=131072 deadline rows writer_state line stopped=0
  local -a env=()
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case "$name"); state="$dir/state"; status="$state/$name.status"; out="$dir/watch.out"
  omp=$(make_named_shell "$dir" omp)
  reader="$dir/gating-span-reader"
  make_gating_span_reader "$reader"
  perl -e 'print "text\n" x 20000' > "$status"
  case "$walk" in
    signal) ;;
    heartbeat)
      prime_status_seen "$state" "$status" || fail "could not record the log as already seen"
      env=(FM_HEARTBEAT=1)
      ;;
    stale)
      make_stale_lane "$dir" "$name" || fail "could not set up the stale lane"
      while IFS= read -r line; do env+=("$line"); done < <(stale_lane_env "$dir" "$name")
      ;;
  esac
  start_gated_tiny_writer "$omp" "$status" "$dir/gate" "$dir/writer.pid" 65 1
  wait_for_file_nonempty "$dir/writer.pid" || fail "the fake writer did not start"
  wpid=$(cat "$dir/writer.pid")
  watch_cap "$state" "$out" FM_STATUS_CAP_BYTES=$cap FM_STATUS_SPAN_READER="$reader" \
    FM_TEST_GATE_LOG="$status" FM_TEST_GATE="$dir/gate" FM_TEST_GATE_SIZE=$cap ${env[@]+"${env[@]}"}
  watch_pid=$!
  deadline=$((SECONDS + 90))
  while [ ! -e "$dir/gate" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
  [ -e "$dir/gate" ] || { kill -9 "$wpid" 2>/dev/null; reap "$watch_pid"; fail "the watcher never began to walk the log: $(cat "$out" "$out.err" 2>/dev/null)"; }
  deadline=$((SECONDS + 20))
  while [ "$SECONDS" -lt "$deadline" ]; do
    rows=$(queue_rows_for "$state")
    if [ "$(state_letter "$wpid")" = T ] && [ "${rows:-0}" -ge 1 ]; then stopped=1; break; fi
    sleep 0.2
  done
  writer_state=$(state_letter "$wpid")
  is_live_non_zombie "$watch_pid" || { kill -9 "$wpid" 2>/dev/null; fail "the watcher exited before the walk ended: $(cat "$out" "$out.err" 2>/dev/null)"; }
  kill -9 "$wpid" 2>/dev/null
  reap "$watch_pid"
  [ "$stopped" -eq 1 ] || fail "the writer was not stopped, and the over-cap wake not queued, within 20 s of the $walk walk capturing a 20000 line span that the writer then pushed past the cap (writer state ${writer_state:-gone})"
}

test_a_runaway_that_keeps_growing_through_the_over_cap_wake_raises_exactly_one_wake() {
  local dir state side out shell wpid watch_pid resumer waited=0
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case one-wake); state="$dir/state"; side="$state/.one-wake.home-appends.runaway"; out="$dir/watch.out"
  shell=$(make_named_shell "$dir" notomp)
  : > "$side"
  # A writer that is stopped and at once resumed by another process, so it is still growing the file
  # through the whole over-cap wake: 5000 bytes every 20 ms or so against a 2048 byte cap, far more than one cap
  # between the size the guard keeps in its marker and the next look at the file. It starts once the
  # watcher is looping. The check that raised the wake must not run again inside that wake: if it did,
  # each pass would find the file grown by another cap and raise another wake, and the watcher would
  # print nothing until the writer ended. The file is a per-task sidecar, which the cap covers and which
  # raises no status signal, so the wake has no signal walk to wait for. The writer's 200 rounds are
  # 1 MB, under its hard limit.
  start_gated_tiny_writer "$shell" "$side" "$dir/gate" "$dir/writer.pid" 5 10 0.02 200
  wait_for_file_nonempty "$dir/writer.pid" || fail "the fake writer did not start"
  wpid=$(cat "$dir/writer.pid")
  ( while kill -CONT "$wpid" 2>/dev/null; do sleep 0.01; done ) &
  resumer=$!
  watch_cap "$state" "$out" FM_STATUS_CAP_BYTES=2048
  watch_pid=$!
  while [ ! -e "$state/.last-watcher-beat" ] && [ "$waited" -lt 600 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$state/.last-watcher-beat" ] || { kill -9 "$wpid" "$resumer" 2>/dev/null; reap "$watch_pid"; fail "the watcher never started its loop"; }
  : > "$dir/gate"
  wait_for_exit "$watch_pid" 600 || { kill -9 "$wpid" "$resumer" 2>/dev/null; reap "$watch_pid"; fail "the watcher did not exit for a file that kept growing through its over-cap wake: $(cat "$out" "$out.err" 2>/dev/null)"; }
  kill -9 "$resumer" "$wpid" 2>/dev/null
  wait "$resumer" 2>/dev/null
  grep -q 'check: status-log-over-cap: file=.one-wake.home-appends.runaway' "$out" || fail "the watcher's wake is not the over-cap check: $(cat "$out")"
  grep -q "stopped pid $wpid (notomp) with SIGSTOP" "$out" || fail "the wake does not say the writer was stopped: $(cat "$out")"
  [ "$(queue_rows_for "$state")" -eq 1 ] || fail "expected exactly one queued over-cap wake for one runaway file, found $(queue_rows_for "$state"): $(cat "$state/.wake-queue")"
  pass "a runaway that keeps growing through the over-cap wake raises exactly one wake and the watcher exits on it"
}

test_a_long_classification_checks_the_cap_every_poll() {
  stop_a_writer_during_a_long_walk long-span signal || return $?
  pass "the watcher checks the cap after each poll-sized slice of a long classification, so a writer that passes it during the classification is stopped long before the classification ends"
}

test_a_second_writer_that_passes_the_cap_during_the_wake_flush_is_stopped_without_a_second_wake() {
  local dir state status side out omp wpid w2pid watch_pid reader cap=16384 deadline rows_a rows_b
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case second-lane); state="$dir/state"; status="$state/lane-a.status"; side="$state/.lane-b.home-appends.runaway"; out="$dir/watch.out"
  omp=$(make_named_shell "$dir" omp)
  reader="$dir/gating-span-reader"
  make_gating_span_reader "$reader"
  # Lane A: 2500 five-byte lines are unread (12500 bytes, under the 16384 byte cap), so the watcher
  # walks them for several seconds. Its writer passes the cap once the watcher holds the span; the check
  # inside that walk stops it and raises the over-cap wake. That wake's flush walks the lane's pending
  # signal again, 3500 lines, which is the window this case is about. Lane B is a per-task sidecar, so
  # it raises no signal of its own: the first read the flush makes opens its writer's gate and holds the
  # walk until lane B is past the cap. The check inside the flush walk must stop lane B's writer and
  # queue its row, and must raise no second wake: a second wake would print lane B's reason and not
  # lane A's, after a second flush walk of its own.
  perl -e 'print "text\n" x 2500' > "$status"
  : > "$side"
  start_gated_tiny_writer "$omp" "$status" "$dir/gate" "$dir/writer.pid" 10 1
  start_gated_tiny_writer "$omp" "$side" "$dir/gate2" "$dir/writer2.pid" 40 1
  wait_for_file_nonempty "$dir/writer.pid" || fail "the first fake writer did not start"
  wait_for_file_nonempty "$dir/writer2.pid" || fail "the second fake writer did not start"
  wpid=$(cat "$dir/writer.pid"); w2pid=$(cat "$dir/writer2.pid")
  watch_cap "$state" "$out" FM_STATUS_CAP_BYTES=$cap FM_STATUS_SPAN_READER="$reader" \
    FM_TEST_GATE_LOG="$status" FM_TEST_GATE="$dir/gate" FM_TEST_GATE_SIZE=$cap \
    FM_TEST_GATE2="$dir/gate2" FM_TEST_GATE2_GROWS="$side" FM_TEST_GATE2_SIZE=$cap
  watch_pid=$!
  wait_for_exit "$watch_pid" 1800 || { kill -9 "$wpid" "$w2pid" 2>/dev/null; reap "$watch_pid"; fail "the watcher never printed its wake: $(cat "$out" "$out.err" 2>/dev/null)"; }
  rows_a=$(grep -c 'file=lane-a.status' "$state/.wake-queue" 2>/dev/null)
  rows_b=$(grep -c 'file=.lane-b.home-appends.runaway' "$state/.wake-queue" 2>/dev/null)
  [ -e "$dir/gate2" ] || { kill -9 "$wpid" "$w2pid" 2>/dev/null; fail "the over-cap wake never flushed the lane's signal: $(cat "$out")"; }
  [ "$(state_letter "$wpid")" = T ] || { kill -9 "$wpid" "$w2pid" 2>/dev/null; fail "the first writer was not stopped (state $(state_letter "$wpid"))"; }
  [ "$(state_letter "$w2pid")" = T ] || { kill -9 "$wpid" "$w2pid" 2>/dev/null; fail "the second writer was not stopped (state $(state_letter "$w2pid")); rows for lane B: ${rows_b:-0}"; }
  kill -9 "$wpid" "$w2pid" 2>/dev/null
  [ "$(wc -l < "$out" | tr -d ' ')" -eq 1 ] || fail "the watcher printed more than one wake: $(cat "$out")"
  grep -q 'check: status-log-over-cap: file=lane-a.status' "$out" || fail "the printed wake is not the one lane A raised: $(cat "$out")"
  grep -q 'lane-b' "$out" && fail "a second wake for lane B was printed: $(cat "$out")"
  [ "${rows_a:-0}" -eq 1 ] || fail "lane A was reported ${rows_a:-0} times, not once: $(cat "$state/.wake-queue")"
  [ "${rows_b:-0}" -eq 1 ] || fail "lane B was reported ${rows_b:-0} times, not once: $(cat "$state/.wake-queue")"
  pass "a second writer that passes the cap while the over-cap wake flushes is stopped and queued, and raises no second wake"
}

test_the_heartbeat_scan_checks_the_cap_every_poll() {
  stop_a_writer_during_a_long_walk long-heartbeat heartbeat || return $?
  pass "the heartbeat scan checks the cap after each poll-sized slice of a long classification, so a writer that passes it during the scan is stopped long before the scan ends"
}

test_the_stale_surface_checks_the_cap_every_poll() {
  stop_a_writer_during_a_long_walk long-stale stale || return $?
  pass "the stale-pane surface checks the cap after each poll-sized slice of its walk over the lane's log, so a writer that passes it during the walk is stopped long before the walk ends"
}

# Shared by the stale and heartbeat cases below. Forty five-byte lines and a terminal event, and a
# 60 s poll, so the walk is far shorter than one poll and ends in a wake. The writer starts once the
# walk holds its span and appends to a per-task sidecar, which the cap covers and which raises no
# status signal, so the wake's flush has no signal to linger on: only the check just before the wake
# exits can see the sidecar pass the 2048 byte cap.
# <walk> picks the walk: stale (the lane's pane is stale) or heartbeat (the log is recorded as seen
# and the heartbeat is due).
stop_a_sidecar_writer_before_a_short_walk_wake() {  # <case> <walk: stale|heartbeat>
  local name=$1 walk=$2 dir state status side out omp wpid watch_pid reader cap=2048 line
  local -a env=()
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case "$name"); state="$dir/state"; status="$state/$name.status"; out="$dir/watch.out"
  side="$state/.$name.home-appends.runaway"
  omp=$(make_named_shell "$dir" omp)
  reader="$dir/gating-span-reader"
  make_gating_span_reader "$reader"
  perl -e 'print "text\n" x 40' > "$status"
  : > "$side"
  case "$walk" in
    stale)
      make_stale_lane "$dir" "$name" || fail "could not set up the stale lane"
      while IFS= read -r line; do env+=("$line"); done < <(stale_lane_env "$dir" "$name")
      ;;
    heartbeat)
      printf 'done: PR https://example.test/pr/3\n' >> "$status"
      prime_status_seen "$state" "$status" || fail "could not record the log as already seen"
      env=(FM_HEARTBEAT=1)
      ;;
  esac
  start_gated_tiny_writer "$omp" "$side" "$dir/gate" "$dir/writer.pid" 4 1
  wait_for_file_nonempty "$dir/writer.pid" || fail "the fake writer did not start"
  wpid=$(cat "$dir/writer.pid")
  watch_cap "$state" "$out" FM_POLL=60 FM_STATUS_CAP_BYTES=$cap FM_STATUS_SPAN_READER="$reader" \
    FM_TEST_GATE_LOG="$status" FM_TEST_GATE_GROWS="$side" FM_TEST_GATE="$dir/gate" FM_TEST_GATE_SIZE=$cap "${env[@]}"
  watch_pid=$!
  wait_for_exit "$watch_pid" 600 || { kill -9 "$wpid" 2>/dev/null; reap "$watch_pid"; fail "the watcher never woke: $(cat "$out" "$out.err" 2>/dev/null)"; }
  grep -q "check: status-log-over-cap: file=.$name.home-appends.runaway" "$out" \
    || { kill -9 "$wpid" 2>/dev/null; fail "the $walk wake exited without a check of the cap that the sidecar had passed: $(cat "$out")"; }
  grep -q "stopped pid $wpid (omp) with SIGSTOP" "$out" || { kill -9 "$wpid" 2>/dev/null; fail "the wake does not say the writer was stopped: $(cat "$out")"; }
  [ "$(state_letter "$wpid")" = T ] || { kill -9 "$wpid" 2>/dev/null; fail "the omp writer was not stopped (state $(state_letter "$wpid"))"; }
  awk -F'\t' -v kind="$walk" '$3 == kind { found = 1 } END { exit !found }' "$state/.wake-queue" \
    || { kill -9 "$wpid" 2>/dev/null; fail "the $walk wake was not queued with the over-cap wake: $(cat "$state/.wake-queue")"; }
  kill -CONT "$wpid" 2>/dev/null; kill -9 "$wpid" 2>/dev/null
}

test_a_cap_crossing_during_a_short_stale_walk_is_stopped_before_the_stale_wake_exits() {
  stop_a_sidecar_writer_before_a_short_walk_wake short-stale stale || return $?
  pass "a sidecar that passes the cap while the stale surface walks its lane's log is checked before the stale wake exits, and its writer is stopped"
}

test_a_cap_crossing_during_a_short_heartbeat_scan_is_stopped_before_the_heartbeat_wake_exits() {
  stop_a_sidecar_writer_before_a_short_walk_wake short-heartbeat heartbeat || return $?
  pass "a sidecar that passes the cap while a heartbeat scan shorter than one poll walks a log is checked before the heartbeat wake exits, and its writer is stopped"
}

test_the_push_transition_walk_checks_the_cap() {
  local dir state wakes
  dir=$(make_case push-walk); state="$dir/state"; wakes="$dir/wakes"
  : > "$wakes"
  # The push handler walks the lane's unread lines before it wakes. Another log is already over the
  # cap, and a poll has passed since the last check, so the watcher's hook, which the handler calls
  # once per line, must find it during the walk. The watcher is sourced, so wake records instead of
  # exiting, and lsof is a stand-in that lists nothing.
  perl -e 'print "text\n" x 50' > "$state/tk1.status"
  printf 'window=default:wG:pQ\nbackend=herdr\nkind=ship\n' > "$state/tk1.meta"
  head -c 70000 /dev/zero | tr '\0' 'x' > "$state/other.status"
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=1 FM_STATUS_CAP_BYTES=65536 \
    FM_STATUS_CAP_LSOF=/usr/bin/false bash -c '
      wakes=$2
      # shellcheck source=/dev/null
      . "$1/bin/fm-watch.sh"
      wake() { printf "%s\n" "$1" >> "$wakes"; }
      SECONDS=60
      handle_push_transition herdr default "$(fm_transition_record wG:pQ wG "" blocked claude)"
    ' _ "$ROOT" "$wakes" > "$dir/push.out" 2>&1 || fail "the push handler failed: $(tail -c 600 "$dir/push.out")"
  grep -q 'check: status-log-over-cap: file=other.status' "$wakes" \
    || fail "the push handler walked the lane's lines without a check of the cap: $(cat "$wakes")"
  grep -q 'stale: default:wG:pQ' "$wakes" || fail "the push handler did not go on to its own wake: $(cat "$wakes")"
  pass "the push-transition handler checks the cap while it walks the lane's unread lines, then still wakes for the transition"
}

test_the_inbox_steer_fold_checks_the_cap() {
  local dir state wakes
  dir=$(make_case steer-fold); state="$dir/state"; wakes="$dir/wakes"
  : > "$wakes"
  # A due steer retry folds the lane's open decisions before it re-sends. Another log is already
  # over the cap, and a poll has passed since the last check, so the watcher's hook, which the fold
  # calls once per line, must find it during the fold. The lane has an open decision of its own, so
  # the retry stops right after the fold. The watcher is sourced, so wake records instead of exiting,
  # the inbox is stood in for by a due retry, and lsof is a stand-in that lists nothing.
  {
    perl -e 'print "working: step $_\n" for 1 .. 40'
    printf 'needs-decision [key=q1]: which option?\n'
  } > "$state/tk1.status"
  head -c 70000 /dev/zero | tr '\0' 'x' > "$state/other.status"
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=1 FM_STATUS_CAP_BYTES=65536 \
    FM_STATUS_CAP_LSOF=/usr/bin/false bash -c '
      wakes=$2
      # shellcheck source=/dev/null
      . "$1/bin/fm-watch.sh"
      wake() { printf "%s\n" "$1" >> "$wakes"; }
      fm_task_inbox_due_action() { printf "retry 1\n"; }
      SECONDS=60
      inbox_steer_check test:fm-tk1 tk1
    ' _ "$ROOT" "$wakes" > "$dir/steer.out" 2>&1 || fail "the steer check failed: $(tail -c 600 "$dir/steer.out")"
  grep -q 'check: status-log-over-cap: file=other.status' "$wakes" \
    || fail "the steer retry folded the lane's decisions without a check of the cap: $(cat "$wakes")"
  pass "the inbox-steer retry checks the cap while it folds the lane's open decisions"
}

test_a_tick_in_a_captured_read_hands_the_measured_rate_to_the_wake() {
  local dir state status wakes wpid rate
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case captured-tick); state="$dir/state"; status="$state/runaway.status"; wakes="$dir/wakes"
  : > "$wakes"
  head -c 70000 /dev/zero | tr '\0' 'x' > "$status"
  # An omp writer that keeps appending, so a scan measures a real growth rate before it stops it.
  (
    ulimit -f "$HARD_LIMIT_BLOCKS"
    "$(make_named_shell "$dir" omp)" -c '
      printf -v unit "text\n%.0s" {1..100}
      exec 9>>"$1"
      for ((i = 0; i < 6000; i++)); do printf "%s" "$unit" >&9; sleep 0.01 9>&-; done
    ' _ "$status" &
    printf '%s\n' "$!" > "$dir/writer.pid"
    wait "$!" 2>/dev/null
  ) &
  wait_for_file_nonempty "$dir/writer.pid" || fail "the fake writer did not start"
  wpid=$(cat "$dir/writer.pid")
  sleep 0.5
  # A status read the watcher captures ticks first: it stops the writer but cannot wake.
  # The watcher's own next tick then wakes, and must report the rate measured before the
  # stop, not the zero a stopped writer shows. The watcher is sourced, so wake records.
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=1 FM_STATUS_CAP_BYTES=65536 bash -c '
    wakes=$2
    # shellcheck source=/dev/null
    . "$1/bin/fm-watch.sh"
    wake() { printf "%s\n" "$1" >> "$wakes"; }
    captured=$(status_cap_tick)
    [ -z "$captured" ] || printf "the captured tick printed: %s\n" "$captured" >&2
    status_cap_tick
  ' _ "$ROOT" "$wakes" > "$dir/tick.out" 2>&1 || { kill -9 "$wpid" 2>/dev/null; fail "the ticks failed: $(tail -c 600 "$dir/tick.out")"; }
  [ "$(state_letter "$wpid")" = T ] || { kill -9 "$wpid" 2>/dev/null; fail "the captured tick did not stop the omp writer"; }
  kill -9 "$wpid" 2>/dev/null
  [ ! -s "$dir/tick.out" ] || fail "the ticks wrote output: $(cat "$dir/tick.out")"
  grep -q "check: status-log-over-cap: file=runaway.status" "$wakes" || fail "no over-cap wake followed the captured stop: $(cat "$wakes")"
  rate=$(sed -n 's/.*growth=\([0-9][0-9]*\) bytes\/s.*/\1/p' "$wakes" | head -1)
  [ -n "$rate" ] && [ "$rate" -gt 0 ] || fail "the wake reports the stopped writer's rate, not the rate before the stop: $(cat "$wakes")"
  [ -z "$(find "$state" -name '.status-cap-handoff.*')" ] || fail "the handoff record was left behind: $(find "$state" -name '.status-cap-handoff.*')"
  pass "a writer stopped by a tick in a captured read is woken for with the growth rate measured before the stop ($rate bytes/s), and the handoff is removed"
}

# The handoff carries only the growth rate. A captured tick that found no writer (lsof
# answered nothing) hands on the rate it measured; the watcher's own tick then finds the
# omp writer and stops it, and its wake must name that pid and stop, with the carried rate.
test_a_handed_rate_keeps_the_watchers_own_writer_and_stop() {
  local dir state status wakes wpid rate
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case handoff-writer); state="$dir/state"; status="$state/runaway.status"; wakes="$dir/wakes"
  : > "$wakes"
  head -c 70000 /dev/zero | tr '\0' 'x' > "$status"
  # An omp writer that appends until the gate file appears and then idles with the log open.
  (
    ulimit -f "$HARD_LIMIT_BLOCKS"
    "$(make_named_shell "$dir" omp)" -c '
      printf -v unit "text\n%.0s" {1..100}
      exec 9>>"$1"
      for ((i = 0; i < 6000; i++)); do [ ! -e "$2" ] || break; printf "%s" "$unit" >&9; sleep 0.01 9>&-; done
      sleep 60 9>&-
    ' _ "$status" "$dir/idle" &
    printf '%s\n' "$!" > "$dir/writer.pid"
    wait "$!" 2>/dev/null
  ) &
  wait_for_file_nonempty "$dir/writer.pid" || fail "the fake writer did not start"
  wpid=$(cat "$dir/writer.pid")
  sleep 0.3
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=1 FM_STATUS_CAP_BYTES=65536 bash -c '
    wakes=$2
    # shellcheck source=/dev/null
    . "$1/bin/fm-watch.sh"
    wake() { printf "%s\n" "$1" >> "$wakes"; }
    captured=$(FM_STATUS_CAP_LSOF=/usr/bin/false status_cap_tick)
    [ -z "$captured" ] || printf "the captured tick printed: %s\n" "$captured" >&2
    : > "$3"
    sleep 1
    status_cap_tick
  ' _ "$ROOT" "$wakes" "$dir/idle" > "$dir/tick.out" 2>&1 || { kill -9 "$wpid" 2>/dev/null; fail "the ticks failed: $(tail -c 600 "$dir/tick.out")"; }
  [ "$(state_letter "$wpid")" = T ] || { kill -9 "$wpid" 2>/dev/null; fail "the watcher's own tick did not stop the omp writer"; }
  kill -9 "$wpid" 2>/dev/null
  [ ! -s "$dir/tick.out" ] || fail "the ticks wrote output: $(cat "$dir/tick.out")"
  grep -q "writer=pid $wpid omp" "$wakes" || fail "the wake does not name the writer the watcher's own scan found: $(cat "$wakes")"
  grep -q "stopped pid $wpid (omp) with SIGSTOP; resume it with kill -CONT $wpid" "$wakes" || fail "the wake does not report the stop: $(cat "$wakes")"
  rate=$(sed -n 's/.*growth=\([0-9][0-9]*\) bytes\/s (measured at .*/\1/p' "$wakes" | head -1)
  [ -n "$rate" ] && [ "$rate" -gt 0 ] || fail "the wake does not carry the rate measured before the stop: $(cat "$wakes")"
  pass "a handed-on growth rate ($rate bytes/s) joins the watcher's own writer and stop in the wake, never replaces them"
}

# A held rate lives only while its file is due an alert: once the file leaves the due list
# the watcher's next tick deletes it, and a later alert for the same file measures afresh.
test_a_held_rate_does_not_outlive_its_due_alert() {
  local dir state status wakes
  dir=$(make_case handoff-expiry); state="$dir/state"; status="$state/runaway.status"; wakes="$dir/wakes"
  : > "$wakes"
  head -c 70000 /dev/zero | tr '\0' 'x' > "$status"
  FM_STATE_OVERRIDE="$state" FM_ROOT_OVERRIDE="$ROOT" FM_POLL=1 FM_STATUS_CAP_BYTES=65536 FM_STATUS_CAP_LSOF=/usr/bin/false bash -c '
    wakes=$2; status=$3
    # shellcheck source=/dev/null
    . "$1/bin/fm-watch.sh"
    wake() { printf "%s\n" "$1" >> "$wakes"; }
    captured=$(status_cap_tick)
    [ -f "$(status_cap_handoff_path)" ] || { echo "the captured tick held no rate"; exit 1; }
    IFS=$'"'"'\t'"'"' read -r size ident path <<< "$(fm_status_cap_unalerted "$STATE")"
    "$SCRIPT_DIR/fm-status-cap-guard.sh" mark "$path" "$ident" "$size" || exit 1
    status_cap_tick
    [ ! -e "$(status_cap_handoff_path)" ] || { echo "a rate outlived its file in the due list"; exit 1; }
    head -c 70000 /dev/zero | tr "\0" y >> "$status"
    status_cap_tick
  ' _ "$ROOT" "$wakes" "$status" > "$dir/tick.out" 2>&1 || fail "the ticks failed: $(tail -c 600 "$dir/tick.out")"
  grep -q "check: status-log-over-cap: file=runaway.status" "$wakes" || fail "the later alert raised no wake: $(cat "$wakes")"
  ! grep -q "measured at" "$wakes" || fail "the later alert reused the expired held rate: $(cat "$wakes")"
  pass "a held rate is deleted once its file leaves the due list, and a later alert for the same file measures afresh"
}

test_the_open_decisions_fold_calls_its_tick_for_every_line() {
  local dir status ticks out
  dir=$(make_case fold-tick); status="$dir/state/fold.status"; ticks="$dir/ticks"
  # 40 resolved lines and one open decision, all lines the fold walks: a fold from the start walks
  # 41 lines. Then a checkpoint is saved and 20 more land, so the next fold starts from the
  # checkpoint and walks only them.
  {
    perl -e 'print "resolved [key=s$_]: step $_\n" for 1 .. 40'
    printf 'needs-decision [key=q1]: which option?\n'
  } > "$status"
  : > "$ticks"
  out=$(bash -c '
    . "$1/fm-classify-lib.sh"
    ticks=$3
    count_tick() { printf "x\n" >> "$ticks"; }
    plain=$(status_own_open_decisions "$2")
    status_own_open_decisions "$2" whole count_tick || exit 1
    whole_ticks=$(wc -l < "$ticks" | tr -d " ")
    status_open_decisions_incremental "$2" >/dev/null
    perl -e "print qq{resolved [key=t\$_]: later step \$_\\n} for 1 .. 20" >> "$2"
    : > "$ticks"
    status_own_open_decisions "$2" tail count_tick || exit 1
    tail_ticks=$(wc -l < "$ticks" | tr -d " ")
    printf "%s|%s|%s|%s|%s\n" "$plain" "$(printf "%s" "$whole")" "$whole_ticks" "$(printf "%s" "$tail")" "$tail_ticks"
  ' _ "$ROOT/bin" "$status" "$ticks") || fail "the fold run failed: $out"
  IFS='|' read -r plain whole whole_ticks tail tail_ticks <<EOF
$out
EOF
  case "$plain" in q1*) ;; *) fail "the fold did not report the open decision: $out" ;; esac
  [ "$whole" = "$plain" ] || fail "the out-var fold with a tick differs from the printed fold: '$whole' vs '$plain'"
  [ "$tail" = "$plain" ] || fail "the fold from the checkpoint lost the open decision: '$tail' vs '$plain'"
  [ "$whole_ticks" -ge 41 ] || fail "the fold from the start ran its tick $whole_ticks times for 41 lines"
  [ "$tail_ticks" -ge 20 ] || fail "the fold from the checkpoint ran its tick $tail_ticks times for 20 new lines"
  [ "$tail_ticks" -lt 41 ] || fail "the second fold walked the whole log ($tail_ticks ticks), so the checkpoint path was not exercised"
  pass "the open-decisions fold calls its tick once per line it walks, from the start and from a checkpoint, and the tick changes nothing it reports"
}

test_the_span_classifier_calls_its_tick_for_every_line_it_walks() {
  local dir status ticks out plain ticked
  dir=$(make_case classifier-tick); status="$dir/state/tick.status"; ticks="$dir/ticks"
  # 31 routine lines, one keyed decision that is still open (so the classifier folds the span to
  # find out whether it is), and 3 more routine lines: 35 lines, walked once by the classifier and
  # once more by the fold.
  {
    perl -e 'print "working: routine line $_\n" for 1 .. 31'
    printf 'needs-decision [key=q1]: which option?\n'
    perl -e 'print "working: routine line $_\n" for 32 .. 34'
  } > "$status"
  : > "$ticks"
  out=$(bash -c '
    . "$1/fm-classify-lib.sh"
    ticks=$3
    count_tick() { printf "x\n" >> "$ticks"; }
    plain=$(status_span_first_actionable_record "$2" 0; printf "|%s" "$?")
    ticked=$(status_span_first_actionable_record "$2" 0 "" "" count_tick; printf "|%s" "$?")
    printf "%s\n%s\n" "$plain" "$ticked"
  ' _ "$ROOT/bin" "$status" "$ticks") || fail "the classifier run failed: $out"
  plain=$(printf '%s\n' "$out" | sed -n '1p')
  ticked=$(printf '%s\n' "$out" | sed -n '2p')
  [ "$plain" = "$ticked" ] || fail "a tick changed the classification: '$plain' vs '$ticked'"
  case "$plain" in *'needs-decision [key=q1]'*'|0') ;; *) fail "the classifier did not report the open decision: $plain" ;; esac
  [ "$(wc -l < "$ticks" | tr -d ' ')" -ge 70 ] \
    || fail "the tick ran $(wc -l < "$ticks" | tr -d ' ') times for a 35 line span walked twice, not once per line in each walk"
  pass "the span classifier calls its tick once per line in its own walk and in the decision fold, and the tick changes nothing it reports"
}

test_the_guard_never_stops_the_firstmate_session_or_a_reader() {
  local dir state status out wpid rpid
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case guard-spares); state="$dir/state"; status="$state/spared.status"
  head -c 300000 /dev/zero | tr '\0' 'x' > "$status"
  printf '\n' >> "$status"
  bash -c 'exec 9>>"$1"; i=0; while [ "$i" -lt 60 ]; do i=$((i + 1)); sleep 1 9>&-; done' _ "$status" &
  wpid=$!
  bash -c 'exec 8<"$1"; i=0; while [ "$i" -lt 60 ]; do i=$((i + 1)); sleep 1 8<&-; done' _ "$status" &
  rpid=$!
  printf '%s\n' "$wpid" > "$state/.lock"
  sleep 0.3
  out=$(FM_STATE_OVERRIDE="$state" FM_STATUS_CAP_BYTES=262144 "$GUARD" scan) || { kill -9 "$wpid" "$rpid" 2>/dev/null; fail "the guard scan failed"; }
  [ "$(state_letter "$wpid")" != T ] || { kill -9 "$wpid" "$rpid" 2>/dev/null; fail "the firstmate session pid $wpid was stopped"; }
  [ "$(state_letter "$rpid")" != T ] || { kill -9 "$wpid" "$rpid" 2>/dev/null; fail "a process that only reads the log was stopped"; }
  kill -9 "$wpid" "$rpid" 2>/dev/null
  wait "$wpid" "$rpid" 2>/dev/null
  case "$out" in *"writer=pid $wpid bash; stopped nothing: pid $wpid is the firstmate session"*) ;; *) fail "the wake does not name the spared firstmate session: $out" ;; esac
  case "$out" in *"pid $rpid "*) fail "a process that only reads the log was named as a writer: $out" ;; esac
  pass "the guard names but never stops the firstmate session, and never names or stops a process that only reads the log"
}

test_the_guard_never_stops_a_sanctioned_append() {
  local dir state status holder apid ppid='' out i rc=0
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case guard-spares-append); state="$dir/state"; status="$state/busy.status"
  head -c 300000 /dev/zero | tr '\0' 'x' > "$status"
  printf '\n' >> "$status"
  # The capped append holds the over-cap log open for writing while it takes the lock, so a guard
  # scan in that window lists it as a writer. It must leave it running.
  start_lock_holder "$status" "$dir/ready"
  holder=$!
  wait_for_file_nonempty "$dir/ready" || { kill -9 "$holder" 2>/dev/null; fail "the lock holder did not start"; }
  FM_STATUS_CAP_BYTES=262144 "$APPEND" "$status" "done: landed after the scan" 2>"$dir/append.err" &
  apid=$!
  for i in $(seq 1 100); do
    if [ "$(ps -p "$apid" -o comm= 2>/dev/null | tr -d ' ')" = perl ]; then ppid=$apid; else ppid=$(pgrep -P "$apid" perl 2>/dev/null | head -1); fi
    [ -z "$ppid" ] || break
    sleep 0.05
  done
  [ -n "$ppid" ] || { kill -9 "$holder" "$apid" 2>/dev/null; fail "the capped append did not start"; }
  sleep 0.3
  out=$(FM_STATE_OVERRIDE="$state" FM_STATUS_CAP_BYTES=262144 "$GUARD" scan) || { kill -9 "$holder" "$apid" 2>/dev/null; fail "the guard scan failed"; }
  [ "$(state_letter "$ppid")" != T ] || { kill -9 "$holder" "$ppid" "$apid" 2>/dev/null; fail "the guard stopped the capped append pid $ppid: $out"; }
  kill -9 "$holder" 2>/dev/null
  wait "$holder" 2>/dev/null
  wait "$apid" || rc=$?
  [ "$rc" -eq 0 ] || fail "the capped append did not land after the scan (rc=$rc): $(cat "$dir/append.err")"
  case "$out" in *"stopped nothing: pid $ppid is the capped append"*) ;; *) fail "the wake does not name the spared capped append pid $ppid: $out" ;; esac
  [ "$(tail -1 "$status")" = "done: landed after the scan" ] || fail "the held append did not land"
  FM_STATUS_CAP_BYTES=262144 "$APPEND" "$status" "done: a later line" || fail "a later append did not land"
  [ "$(tail -1 "$status")" = "done: a later line" ] || fail "the later append did not land"
  pass "the guard names a capped append that holds an over-cap log open but never stops it, and later appends still land"
}

test_guard_says_unknown_when_lsof_is_missing_or_timed_out() {
  local dir state status scan_env out fakebin
  dir=$(make_case lsof-state); state="$dir/state"; status="$state/lonely.status"; fakebin="$dir/fakebin"
  head -c 300000 /dev/zero | tr '\0' 'x' > "$status"
  printf '\n' >> "$status"
  scan_env=(env FM_STATE_OVERRIDE="$state" FM_STATUS_CAP_BYTES=262144)

  # An lsof that is not installed never looked: the writer is unknown, not absent.
  out=$("${scan_env[@]}" FM_STATUS_CAP_LSOF="$dir/no-such-lsof" "$GUARD" scan) || fail "the guard scan failed without lsof"
  case "$out" in *'writer=unknown (lsof not available)'*'stopped nothing'*) ;; *) fail "a missing lsof was not reported as unknown: $out" ;; esac
  case "$out" in *'none found'*) fail "a missing lsof was reported as no writer found: $out" ;; esac

  # An lsof that did not finish inside its bound reports the status the bound uses: 124.
  printf '#!/bin/sh\nexit 124\n' > "$fakebin/lsof"
  chmod +x "$fakebin/lsof"
  out=$("${scan_env[@]}" FM_STATUS_CAP_LSOF="$fakebin/lsof" "$GUARD" scan) || fail "the guard scan failed when lsof timed out"
  case "$out" in *'writer=unknown (lsof timed out)'*'stopped nothing'*) ;; *) fail "a timed-out lsof was not reported as unknown: $out" ;; esac
  case "$out" in *'none found'*) fail "a timed-out lsof was reported as no writer found: $out" ;; esac

  # An lsof that ran and listed nothing exits 1, and that still means none found.
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/lsof"
  out=$("${scan_env[@]}" FM_STATUS_CAP_LSOF="$fakebin/lsof" "$GUARD" scan) || fail "the guard scan failed when lsof listed nothing"
  case "$out" in *'writer=none found (lsof listed no process holding it open for writing)'*'stopped nothing'*) ;; *) fail "an lsof that listed nothing was not reported as none found: $out" ;; esac
  pass "the guard reports a missing or timed-out lsof as an unknown writer, and an lsof that ran and listed nothing as none found"
}

test_a_bash_writer_is_stopped_and_a_missing_writer_stops_nothing() {
  local dir state status out wpid watch_pid
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case foreign-bash); state="$dir/state"; status="$state/other.status"; out="$dir/watch.out"
  : > "$status"
  # A raw >> loop held open by a plain bash child: the writer is judged by what it does, not by its name.
  start_paced_writer "$(command -v bash)" "$status" "$dir/writer.pid"
  wait_for_file_nonempty "$dir/writer.pid" || fail "the fake writer did not start"
  wpid=$(cat "$dir/writer.pid")
  run_until_cap_wake "$state" "$out" || { kill -9 "$wpid" 2>/dev/null; fail "no wake for a bash writer: $(cat "$out" "$out.err" 2>/dev/null)"; }
  grep -q "writer=pid $wpid bash" "$out" || { kill -9 "$wpid" 2>/dev/null; fail "the wake does not name the bash writer pid $wpid: $(cat "$out")"; }
  grep -q "stopped pid $wpid (bash) with SIGSTOP; resume it with kill -CONT $wpid" "$out" || { kill -9 "$wpid" 2>/dev/null; fail "the wake does not say the bash writer was stopped: $(cat "$out")"; }
  [ "$(state_letter "$wpid")" = T ] || { kill -9 "$wpid" 2>/dev/null; fail "the bash writer pid $wpid was not stopped (state $(state_letter "$wpid"))"; }
  kill -9 "$wpid" 2>/dev/null

  # No writer at all: a finished log that is simply over the cap.
  dir=$(make_case foreign-none); state="$dir/state"; status="$state/none.status"; out="$dir/watch.out"
  head -c 300000 /dev/zero | tr '\0' 'x' > "$status"
  printf '\n' >> "$status"
  run_until_cap_wake "$state" "$out" || fail "no wake for an over-cap log with no writer: $(cat "$out" "$out.err" 2>/dev/null)"
  grep -q 'writer=none found' "$out" || fail "the wake does not say no writer was found: $(cat "$out")"
  grep -q 'stopped nothing' "$out" || fail "the wake does not say nothing was stopped: $(cat "$out")"
  [ "$(file_size "$status")" -eq 300001 ] || fail "the log was changed"
  pass "a raw >> loop held by a bash child is named and stopped, and a log with no writer still wakes and stops nothing"
}

test_a_resumed_writer_is_woken_for_and_stopped_again() {
  local dir state status out omp wpid size_first size_second watch_pid
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case foreign-resumed); state="$dir/state"; status="$state/resumed.status"; out="$dir/watch.out"
  omp=$(make_named_shell "$dir" omp)
  : > "$status"
  start_paced_writer "$omp" "$status" "$dir/writer.pid"
  wait_for_file_nonempty "$dir/writer.pid" || fail "the fake writer did not start"
  wpid=$(cat "$dir/writer.pid")
  run_until_cap_wake "$state" "$out" || { kill -9 "$wpid" 2>/dev/null; fail "no first wake for the paced writer: $(cat "$out" "$out.err" 2>/dev/null)"; }
  [ "$(state_letter "$wpid")" = T ] || { kill -9 "$wpid" 2>/dev/null; fail "the first wake did not stop the writer"; }
  size_first=$(file_size "$status")
  ack_cycle "$state" || fail "could not acknowledge the first wake"

  # The log did not grow, so a watcher over it stays quiet.
  watch_cap "$state" "$out.quiet"
  watch_pid=$!
  wait_for_exit "$watch_pid" 30 && { kill -9 "$wpid" 2>/dev/null; fail "a log that did not grow woke the watcher again: $(cat "$out.quiet")"; }
  reap "$watch_pid"
  [ "$(queue_rows_for "$state")" -eq 0 ] || { kill -9 "$wpid" 2>/dev/null; fail "a log that did not grow queued another over-cap wake"; }

  # The operator resumes the writer, as the wake text says to: it grows by more than one
  # cap, which is a new wake and a new stop.
  kill -CONT "$wpid" 2>/dev/null
  run_until_cap_wake "$state" "$out.2" || { kill -9 "$wpid" 2>/dev/null; fail "a resumed writer raised no second wake: $(cat "$out.2" "$out.2.err" 2>/dev/null)"; }
  grep -q "stopped pid $wpid (omp) with SIGSTOP" "$out.2" || { kill -9 "$wpid" 2>/dev/null; fail "the second wake does not say the writer was stopped again: $(cat "$out.2")"; }
  [ "$(state_letter "$wpid")" = T ] || { kill -9 "$wpid" 2>/dev/null; fail "the resumed writer was not stopped again"; }
  size_second=$(sed -n 's/.*size=\([0-9][0-9]*\) bytes.*/\1/p' "$out.2" | head -1)
  [ -n "$size_second" ] && [ "$size_second" -gt $((size_first + 262144)) ] \
    || { kill -9 "$wpid" 2>/dev/null; fail "the second wake came before the log grew by one cap: first $size_first, second ${size_second:-none}"; }
  kill -CONT "$wpid" 2>/dev/null; kill -9 "$wpid" 2>/dev/null
  pass "a stopped writer that is continued gets a second wake and a second stop, and a log that has not grown gets none"
}

test_guard_scan_names_a_sidecar_and_wakes_again_only_on_growth() {
  local dir state side out ident size scan_env
  dir=$(make_case sidecar); state="$dir/state"; side="$state/.t1.open-decisions-cursor.unread.123"
  scan_env=(env FM_STATE_OVERRIDE="$state" FM_STATUS_CAP_BYTES=262144 FM_STATUS_CAP_LSOF=/usr/bin/false)
  head -c 300000 /dev/zero | tr '\0' 'y' > "$side"
  out=$("${scan_env[@]}" "$GUARD" scan) || fail "the guard scan failed"
  case "$out" in *'file=.t1.open-decisions-cursor.unread.123'*) ;; *) fail "the guard did not name the over-cap cursor scratch: $out" ;; esac
  ident=$(printf '%s' "$out" | cut -f1)
  size=$(printf '%s' "$out" | cut -f3)
  [ "$size" = 300000 ] || fail "the record does not carry the size after containment: $size"
  "${scan_env[@]}" "$GUARD" mark "$side" "$ident" "$size"
  out=$("${scan_env[@]}" "$GUARD" scan)
  [ -z "$out" ] || fail "an alerted file that did not grow was reported again: $out"

  # Growth of less than one cap since the marker stays quiet; more than one cap is due again.
  head -c 100000 /dev/zero | tr '\0' 'y' >> "$side"
  out=$("${scan_env[@]}" "$GUARD" scan)
  [ -z "$out" ] || fail "growth of less than one cap woke again: $out"
  head -c 200000 /dev/zero | tr '\0' 'y' >> "$side"
  out=$("${scan_env[@]}" "$GUARD" scan)
  case "$out" in *'file=.t1.open-decisions-cursor.unread.123'*) ;; *) fail "growth of more than one cap did not wake again: $out" ;; esac
  size=$(printf '%s' "$out" | cut -f3)
  [ "$size" = 600000 ] || fail "the second record does not carry the new size: $size"
  "${scan_env[@]}" "$GUARD" mark "$side" "$ident" "$size"
  out=$("${scan_env[@]}" "$GUARD" scan)
  [ -z "$out" ] || fail "the file woke again right after its second alert: $out"

  # A file that drops under the cap clears its marker, so a later episode alarms again.
  : > "$side"
  FM_STATE_OVERRIDE="$state" FM_STATUS_CAP_BYTES=262144 FM_STATUS_CAP_LSOF=/usr/bin/false "$GUARD" scan >/dev/null
  [ -z "$(ls "$state"/.status-cap-alerted.* 2>/dev/null)" ] || fail "the alert marker survived the file dropping under the cap"
  if "$GUARD" mark "$side" "$ident" 2>/dev/null; then fail "mark accepted a call with no size"; fi
  pass "a per-task sidecar over the cap is named once, wakes again only after one cap of growth, and its marker clears when it shrinks"
}

# --- bounded readers ----------------------------------------------------------

# A sparse log of exactly 2 GiB: 3000 distinct events and one decision at the head,
# then a hole, then 6 MiB of one repeated line at the tail (the 2026-10-18 shape).
make_two_gib_log() {  # <path>
  perl -e '
    my ($path) = @ARGV;
    open my $f, ">", $path or die;
    for my $i (1 .. 3000) { print $f "working [at=$i]: distinct event number $i\n"; }
    print $f "needs-decision [key=old-question]: an early question that is still open\n";
    my $line = "REPOST REQUIRED corr=6be04311231638c7 reply on the parent status channel including corr=6be04311231638c7 padding\n";
    my $tail = $line x 60000;
    seek($f, 2 * 1024 * 1024 * 1024 - length($tail), 0) or die;
    print $f $tail;
    close $f or die;
  ' "$1"
}

timed() {  # <label> <command...> -> seconds on stdout (stderr of the command discarded)
  local start end
  start=$SECONDS
  "${@:2}" >/dev/null 2>&1 || return 1
  end=$SECONDS
  printf '%s' "$((end - start))"
}

READER_BOUND_SECS=60
TIMING_TABLE=""

record_timing() {  # <reader> <seconds>
  TIMING_TABLE="$TIMING_TABLE| $1 | ${2}s |"$'\n'
}

test_readers_stay_bounded_on_a_two_gib_log() {
  local dir state status secs size_after big
  dir=$(make_case two-gib); state="$dir/state"; status="$state/huge.status"
  make_two_gib_log "$status" || fail "could not build the sparse 2 GiB fixture"
  [ "$(file_size "$status")" -eq 2147483648 ] || fail "the fixture is not 2 GiB"
  size_after=$(file_size "$status")

  secs=$(timed open-decisions fm_run_timed "$READER_BOUND_SECS" bash -c '. "$1"; status_open_decisions "$2"; true' _ "$ROOT/bin/fm-classify-lib.sh" "$status") \
    || fail "status_open_decisions did not finish in ${READER_BOUND_SECS}s on a 2 GiB log"
  record_timing "open-decisions fold" "$secs"
  secs=$(timed last-line fm_run_timed "$READER_BOUND_SECS" bash -c '. "$1"; last_status_line "$2"; true' _ "$ROOT/bin/fm-classify-lib.sh" "$status") \
    || fail "last_status_line did not finish in ${READER_BOUND_SECS}s on a 2 GiB log"
  record_timing "status-event library (last_status_line)" "$secs"
  secs=$(timed wait-line fm_run_timed "$READER_BOUND_SECS" bash -c '. "$1"; status_declared_wait_line "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$status") \
    || fail "status_declared_wait_line did not finish in ${READER_BOUND_SECS}s on a 2 GiB log"
  record_timing "status-event library (declared wait)" "$secs"
  secs=$(timed recorded fm_run_timed "$READER_BOUND_SECS" bash -c '. "$1"; status_event_recorded "$2" "working: never written"; true' _ "$ROOT/bin/fm-classify-lib.sh" "$status") \
    || fail "status_event_recorded did not finish in ${READER_BOUND_SECS}s on a 2 GiB log"
  record_timing "retry check (status_event_recorded)" "$secs"

  printf 'meta\n' > /dev/null
  fm_write_meta "$state/huge.meta" "window=firstmate:fm-huge" "worktree=$dir" "project=alpha" "harness=claude" "kind=ship" 2>/dev/null || true
  secs=$(timed drain fm_run_timed "$READER_BOUND_SECS" env FM_STATE_OVERRIDE="$state" "$DRAIN") \
    || fail "the wake drain did not finish in ${READER_BOUND_SECS}s on a 2 GiB log"
  record_timing "wake drain (cold cursor)" "$secs"
  secs=$(timed drain2 fm_run_timed "$READER_BOUND_SECS" env FM_STATE_OVERRIDE="$state" "$DRAIN") \
    || fail "the second drain did not finish in ${READER_BOUND_SECS}s"
  record_timing "wake drain (warm cursor)" "$secs"

  [ "$(file_size "$status")" -eq "$size_after" ] || fail "a reader changed the size of the log"
  big=$(big_files_in "$state")
  [ -z "$big" ] || fail "a reader left a file over 1 MB in the state directory: $big"
  printf '# timing table (seconds, 2 GiB sparse log: 3000 events, a hole, a 6 MiB repeated tail)\n# | reader | seconds |\n%s' "$TIMING_TABLE" | sed 's/^|/# |/'
  pass "every reader finishes inside ${READER_BOUND_SECS}s on a 2 GiB log and creates no file over 1 MB"
}

test_history_readers_refuse_a_log_past_the_limit_and_name_it() {
  local dir state status out rc=0
  dir=$(make_case refuse-huge); state="$dir/state"; status="$state/huge.status"
  make_two_gib_log "$status" || fail "could not build the sparse 2 GiB fixture"

  out=$(bash -c '. "$1/fm-status-io-lib.sh"; fm_status_cat "$2"' _ "$ROOT/bin" "$status" 2>"$dir/cat.err") || rc=$?
  [ "$rc" -eq 2 ] || fail "a whole-file read of a 2 GiB log was not refused with exit status 2 (rc=$rc)"
  [ -z "$out" ] || fail "a whole-file read of a 2 GiB log printed ${#out} bytes"
  grep -q 'refused to read huge.status' "$dir/cat.err" || fail "the refusal does not name the file: $(cat "$dir/cat.err")"

  rc=0
  bash -c '. "$1/fm-status-io-lib.sh"; _fm_status_read_span "$2" 0 2147483648' _ "$ROOT/bin" "$status" > "$dir/span.out" 2> "$dir/span.err" || rc=$?
  [ "$rc" -ne 0 ] && [ ! -s "$dir/span.out" ] || fail "a span of the whole 2 GiB log was read, or its refusal had no failing status (rc=$rc)"
  grep -q 'refused to read huge.status' "$dir/span.err" || fail "the span refusal does not name the file: $(cat "$dir/span.err")"

  # A short span from the same log is exact, so a saved cursor near the end still reads.
  bash -c '. "$1/fm-status-io-lib.sh"; _fm_status_read_span "$2" "$(($3 - 110))" 110' _ "$ROOT/bin" "$status" 2147483648 > "$dir/span.tail" \
    || fail "a short span of the 2 GiB log was refused"
  tail -c 110 "$status" > "$dir/span.want"
  cmp -s "$dir/span.tail" "$dir/span.want" || fail "a short span of the 2 GiB log is not exactly its bytes"

  rc=0
  bash -c '. "$1/fm-classify-lib.sh"; status_event_recorded "$2" "working: never written"' _ "$ROOT/bin" "$status" 2> "$dir/recorded.err" || rc=$?
  [ "$rc" -eq 1 ] || fail "the retry check on a 2 GiB log did not report the event as not recorded (rc=$rc)"
  grep -q 'refused to read huge.status' "$dir/recorded.err" || fail "the retry check refusal does not name the file: $(cat "$dir/recorded.err")"
  [ "$(file_size "$status")" -eq 2147483648 ] || fail "a reader changed the size of the log"

  # The line limit bounds only an unread span a shell loop walks: such a span with more
  # lines is refused, not clipped, while a whole-log history read of the same log, far
  # below the byte limit, is read whole.
  status="$state/dense.status"
  perl -e 'print "x\n" x 40000' > "$status"
  rc=0
  out=$(bash -c '. "$1/fm-status-io-lib.sh"; _fm_status_read_span "$2" 0 80000' _ "$ROOT/bin" "$status" 2>"$dir/lines.err") || rc=$?
  [ "$rc" -eq 2 ] && [ -z "$out" ] || fail "a 40000 line unread span was not refused with exit status 2 (rc=$rc, ${#out} bytes)"
  grep -q 'refused to read dense.status: a span of more than 32768 lines' "$dir/lines.err" || fail "the line refusal does not name the file and limit: $(cat "$dir/lines.err")"
  [ "$(bash -c '. "$1/fm-status-io-lib.sh"; fm_status_cat "$2" | wc -c' _ "$ROOT/bin" "$status" | tr -d ' ')" -eq 80000 ] \
    || fail "a whole-log history read of the 40000 line log did not return all of it"
  pass "a history reader refuses a 2 GiB log, names it, and reads nothing; a short span from it is exact; only an unread span is bounded by lines"
}

# A healthy long-lived lane: 40000 lines of about 80 bytes, about 3.2 MB, the size of the
# largest healthy log the cap was measured from and far below the byte limit. Every
# whole-log history reader and open-decisions fold reads it and answers from it: the
# read limit judges bytes, so no line count refuses a log under the cap.
# A runaway of tiny non-event lines holds a log at the read limit, so the history readers
# read it: the 2026-10-18 `text` shape, a counter (`1793124970: text`) and a label
# (`Reason: retrying`), the last two holding a colon. That must cost no walk of its lines
# in the shell: each reader answers inside TINY_LINE_BOUND_SECS, and a watcher that reads
# the lane on every poll keeps its cap check, so another lane that passes the cap is still
# stopped and woken for within that bound.
TINY_LINE_BOUND_SECS=20
test_a_log_at_the_read_limit_of_tiny_lines_costs_no_line_walk() {
  local dir state status other limit n reader out want line watch_pid
  local FM_STATUS_CAP_BYTES=4194304 FM_STATUS_CAP_RESERVE_BYTES=1048576
  local -a env=()
  export FM_STATUS_CAP_BYTES FM_STATUS_CAP_RESERVE_BYTES
  dir=$(make_case tiny-at-limit); state="$dir/state"; status="$state/a.status"; other="$state/b.status"
  limit=$((FM_STATUS_CAP_BYTES + FM_STATUS_CAP_RESERVE_BYTES))
  printf 'needs-decision [key=q1]: an early question\npaused [key=ext]: waiting on the vendor\n' > "$status"
  n=$(( (limit - $(file_size "$status")) / 39 ))
  perl -e 'print "text\n1793124970: text\nReason: retrying\n" x $ARGV[0]' "$n" >> "$status"
  [ "$(file_size "$status")" -le "$limit" ] && [ "$(file_size "$status")" -gt $((limit - 39)) ] \
    || fail "the fixture is $(file_size "$status") bytes, not at the $limit byte read limit"

  for reader in last_status_line status_declared_wait_line status_open_decisions status_open_decisions_incremental status_declared_wait_identity; do
    out=$(fm_run_timed "$TINY_LINE_BOUND_SECS" bash -c '. "$1/fm-classify-lib.sh"; "$2" "$3"' _ "$ROOT/bin" "$reader" "$status") \
      || fail "$reader did not answer within ${TINY_LINE_BOUND_SECS}s on a log at the read limit of tiny lines"
    case "$reader" in
      last_status_line|status_declared_wait_line) want='paused [key=ext]: waiting on the vendor' ;;
      status_open_decisions*) want=$'q1\tneeds-decision\tan early question' ;;
      *) want="ext:$(printf 'paused [key=ext]: waiting on the vendor' | cksum | cut -d' ' -f1):43" ;;
    esac
    [ "$out" = "$want" ] || fail "$reader answered '$out' on the log at the read limit, not '$want'"
  done
  out=$(fm_run_timed "$TINY_LINE_BOUND_SECS" bash -c '. "$1/fm-classify-lib.sh"; last_status_line "$2" previous >/dev/null || exit; printf "%s" "$previous"' _ "$ROOT/bin" "$status") \
    || fail "last_status_line with a previous event did not answer within ${TINY_LINE_BOUND_SECS}s"
  [ "$out" = 'needs-decision [key=q1]: an early question' ] || fail "last_status_line named '$out' as the previous event"
  [ -z "$(big_files_in "$state")" ] || fail "a reader left a file over 1 MB: $(big_files_in "$state")"

  # The watcher reads this lane's declared wait on every poll. The lane is over the cap, so
  # a first run wakes for it once; a second run must still check the cap while it reads the
  # lane, so the healthy lane b that passes the cap during that run is woken for.
  printf 'window=test:fm-a\nkind=secondmate\n' > "$state/a.meta"
  printf 'idle' > "$dir/pane.txt"
  printf 'working: a healthy lane\n' > "$other"
  prime_status_seen "$state" "$status" && prime_status_seen "$state" "$other" || fail "could not record the logs as already seen"
  while IFS= read -r line; do env+=("$line"); done < <(stale_lane_env "$dir" a)
  watch_cap "$state" "$dir/first.out" FM_STATUS_CAP_BYTES="$FM_STATUS_CAP_BYTES" "${env[@]}"
  watch_pid=$!
  wait_for_exit "$watch_pid" $((TINY_LINE_BOUND_SECS * 10)) || fail "the first watcher run did not wake for the lane over the cap: $(cat "$dir/first.out" "$dir/first.out.err")"
  grep -q 'status-log-over-cap: file=a.status' "$dir/first.out" || fail "the first run did not name the lane over the cap: $(cat "$dir/first.out")"
  ack_cycle "$state" || fail "could not acknowledge the first wake"
  rm -f "$state/.last-watcher-beat"
  watch_cap "$state" "$dir/second.out" FM_STATUS_CAP_BYTES="$FM_STATUS_CAP_BYTES" "${env[@]}"
  watch_pid=$!
  n=0
  while [ ! -e "$state/.last-watcher-beat" ] && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
  sleep 2
  perl -e 'print "y" x $ARGV[0], "\n"' "$FM_STATUS_CAP_BYTES" >> "$other"
  wait_for_exit "$watch_pid" $((TINY_LINE_BOUND_SECS * 10)) \
    || fail "the watcher reading a lane at the read limit did not wake within ${TINY_LINE_BOUND_SECS}s for another lane over the cap"
  grep -q 'status-log-over-cap: file=b.status' "$dir/second.out" || fail "the second run did not name the other lane over the cap: $(cat "$dir/second.out")"
  pass "a log at the read limit of tiny lines is read by every history reader within ${TINY_LINE_BOUND_SECS}s, and a watcher reading it every poll still wakes for another lane over the cap"
}

# The watcher reads a log past one tail window (4 MiB) from that window only, so the
# declared-wait identity must not count from the window's start: it is the byte offset
# of the episode's first line in the log, the same in the watcher and outside it, kept by
# a restated wait and by an unrelated line, and changed by a replacement wait.
test_declared_wait_identity_is_an_absolute_offset_past_the_tail_window() {
  local dir status want tail_id whole_id
  dir=$(make_case identity-offset); status="$dir/state/w.status"
  perl -e 'print "text\n" x 1100000' > "$status"
  want=$(file_size "$status")
  printf 'paused [key=ext]: waiting on the vendor\n' >> "$status"
  tail_id=$(wait_identity_in 1 "$status") || fail "the watcher read gave the wait no identity"
  whole_id=$(wait_identity_in 0 "$status") || fail "the whole-log read gave the wait no identity"
  [ "$tail_id" = "$whole_id" ] || fail "the watcher and whole-log identities differ: $tail_id vs $whole_id"
  case "$tail_id" in "ext:"*":$want") ;; *) fail "the identity is not at the pause's byte offset $want: $tail_id" ;; esac
  printf 'paused [key=ext]: waiting on the vendor\n' >> "$status"
  [ "$(wait_identity_in 1 "$status")" = "$tail_id" ] || fail "restating the wait moved its identity: $(wait_identity_in 1 "$status") vs $tail_id"
  printf '  still waiting, nothing new\n' >> "$status"
  [ "$(wait_identity_in 1 "$status")" = "$tail_id" ] || fail "an unrelated line moved the wait's identity: $(wait_identity_in 1 "$status") vs $tail_id"
  printf 'paused [key=other]: a different wait\n' >> "$status"
  [ "$(wait_identity_in 1 "$status")" != "$tail_id" ] || fail "a replacement wait kept the earlier identity"
  [ "$(wait_identity_in 1 "$status")" = "$(wait_identity_in 0 "$status")" ] || fail "the replacement's watcher and whole-log identities differ"
  pass "past the tail window the declared-wait identity is the episode's byte offset in the log: kept by a restatement and an unrelated line, changed by a replacement, the same in the watcher"
}

wait_identity_in() {  # <tail-mode 0|1> <status-file>
  FM_STATUS_EVENT_SCAN_TAIL=$1 bash -c '. "$1/fm-classify-lib.sh"; status_declared_wait_identity "$2"' _ "$ROOT/bin" "$2"
}

# The watcher's window read starts one tail window before the end. When the byte before
# that start ends a line, the window's first line is whole, and it can be the only event
# in the window: the read keeps it.
test_the_watcher_window_keeps_a_whole_first_line() {
  local dir status event out
  dir=$(make_case window-first-line); status="$dir/state/f.status"
  event='paused [key=ext]: waiting on the vendor'
  perl -e 'print "working [at=1]: older step\n" x 1000' > "$status"
  perl -e 'my ($event, $window) = @ARGV; my $rest = $window - length($event) - 1; print "$event\n", "text\n" x int($rest / 5); print "x" x ($rest % 5 - 1), "\n" if $rest % 5' \
    "$event" 4194304 >> "$status"
  out=$(FM_STATUS_EVENT_SCAN_TAIL=1 bash -c '. "$1/fm-classify-lib.sh"; last_status_line "$2"' _ "$ROOT/bin" "$status")
  [ "$out" = "$event" ] || fail "the watcher read dropped the whole first line of its window: '$out'"
  [ "$(wait_identity_in 1 "$status")" = "$(wait_identity_in 0 "$status")" ] || fail "the watcher identity of the window's first line differs from the whole-log one"
  pass "the watcher's window read keeps a whole first line that starts exactly at the window"
}

# An unknown-verb declaration whose first colon sits inside a bracket tag is an event, so
# when the last 200 lines hold no event the widened read must still find it.
test_a_declaration_with_a_colon_in_its_tag_is_found_past_the_tail() {
  local dir status line out
  dir=$(make_case bracket-colon); status="$dir/state/b.status"
  for line in 'parked [reason: CI] waiting' 'holding [key: x'; do
    { printf 'working: older step\n%s\n' "$line"; perl -e 'print "text\n" x 300'; } > "$status"
    out=$(bash -c '. "$1/fm-classify-lib.sh"; last_status_line "$2"' _ "$ROOT/bin" "$status")
    [ "$out" = "$line" ] || fail "the widened read skipped the declaration '$line' and answered '$out'"
  done
  pass "a declaration whose first colon is inside a bracket tag is found by the widened latest-event read"
}

test_history_readers_read_a_healthy_log_of_many_lines() {
  local dir state status cursor out prev size
  dir=$(make_case healthy-long); state="$dir/state"; status="$state/h.status"; cursor="$state/.h.open-decisions-cursor"
  {
    printf 'needs-decision [at=1790000000] [key=q1]: an early question that is still open for the captain\n'
    perl -e 'printf "working [at=%d]: routine progress line number %05d with some padding text\n", 1790000000 + $_, $_ for 1 .. 40000'
    printf 'resolved [key=other]: closed\n'
  } > "$status"
  size=$(file_size "$status")
  [ "$size" -gt 3000000 ] && [ "$(wc -l < "$status" | tr -d ' ')" -gt 40000 ] || fail "the fixture is not a 3 MB log of more than 40000 lines"

  [ "$(bash -c '. "$1/fm-status-io-lib.sh"; fm_status_cat "$2" | wc -c' _ "$ROOT/bin" "$status" | tr -d ' ')" -eq "$size" ] \
    || fail "fm_status_cat did not read the healthy log whole"
  out=$(run_classify status_open_decisions "$status") || fail "status_open_decisions refused the healthy log"
  case "$out" in q1$'\t'needs-decision$'\t'*) ;; *) fail "status_open_decisions lost q1 in the healthy log: '$out'" ;; esac
  out=$(run_classify status_open_decisions_dated "$status") || fail "status_open_decisions_dated refused the healthy log"
  case "$out" in q1$'\t'needs-decision$'\t'1790000000$'\t'*) ;; *) fail "status_open_decisions_dated lost q1 in the healthy log: '$out'" ;; esac
  [ ! -e "$cursor" ] || fail "a pure reader wrote a fold cursor"
  out=$(run_classify status_open_decisions_incremental "$status") || fail "the cold incremental fold refused the healthy log"
  case "$out" in q1$'\t'needs-decision$'\t'*) ;; *) fail "the cold incremental fold lost q1 in the healthy log: '$out'" ;; esac
  grep -q "^offset=$size\$" "$cursor" || fail "the cold incremental fold of the healthy log wrote no cursor at its end: $(cat "$cursor" 2>/dev/null)"
  out=$(bash -c '. "$1/fm-classify-lib.sh"; last_status_line "$2" previous >/dev/null || exit; printf "%s|%s" "$previous" "$(last_status_line "$2")"' _ "$ROOT/bin" "$status") \
    || fail "last_status_line with a previous event refused the healthy log"
  prev='working [at=1790040000]: routine progress line number 40000 with some padding text'
  [ "$out" = "$prev|resolved [key=other]: closed" ] || fail "last_status_line did not name the previous event of the healthy log: '$out'"

  # A wait declared before 40000 lines of build output and more resolved lines than the
  # tail window holds: the declared-wait read widens to the whole log and finds it.
  status="$state/w.status"
  {
    printf 'paused [key=ext]: waiting on the vendor release before the next build step\n'
    perl -e 'printf "  build output line %05d with some padding text to make the line about eighty\n", $_ for 1 .. 40000'
    perl -e 'printf "resolved [key=other-%03d]: closed the unrelated question number %03d here\n", $_, $_ for 1 .. 201'
  } > "$status"
  out=$(run_classify status_declared_wait_line "$status")
  [ "$out" = 'paused [key=ext]: waiting on the vendor release before the next build step' ] \
    || fail "the declared-wait whole-log read did not find the wait in the healthy log: '$out'"

  # The activity fold walks every line in the shell, so its 40000 lines are blank padding
  # that the fold skips; what is under test is that the read is not refused.
  status="$state/a.status"
  { printf 'paused [key=ext]: waiting on the vendor release\n'; perl -e 'print " " x 79, "\n" for 1 .. 40000'; } > "$status"
  out=$(run_classify status_open_activities "$status") || fail "status_open_activities refused a 40000 line log under the byte limit"
  [ "$out" = "$(printf 'ext\tpaused\twaiting on the vendor release')" ] || fail "status_open_activities lost the open pause: '$out'"
  pass "every whole-log history reader and open-decisions fold reads a healthy 3 MB log of more than 40000 lines and answers from it"
}

test_a_saved_cursor_never_advances_past_bytes_that_were_not_read() {
  local dir state status cursor out size rc
  dir=$(make_case cursor-refusal); state="$dir/state"; status="$state/c.status"; cursor="$state/.c.open-decisions-cursor"
  {
    printf 'needs-decision [key=early-q]: an early question that is still open\n'
    perl -e 'print "working [at=$_]: step $_ padding padding padding padding\n" for 1 .. 4000'
  } > "$status"
  size=$(file_size "$status")
  [ "$size" -gt 131072 ] || fail "the fixture is not past the 131072 byte limit used below"

  # The first fold would have to read more than the limit: it is refused, and the cursor
  # is neither written nor moved to the end of bytes that nobody read.
  out=$(FM_STATUS_CAP_BYTES=65536 FM_STATUS_CAP_RESERVE_BYTES=65536 bash -c '. "$1"; status_open_decisions_incremental "$2"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$status")
  [ -z "$out" ] || fail "a refused fold invented an open set: $out"
  [ ! -e "$cursor" ] || fail "a refused fold wrote a cursor: $(cat "$cursor")"

  # Within the limit the same fold finds the early decision and the cursor reaches the end.
  out=$(bash -c '. "$1"; status_open_decisions_incremental "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$status")
  case "$out" in *early-q*) ;; *) fail "the early decision was not found: $out" ;; esac
  grep -q "^offset=$size\$" "$cursor" || fail "the cursor is not at the end of what was read: $(cat "$cursor")"

  # A later growth past the limit is refused too: the cursor stays where it was, the
  # fold answers status 2 instead of the old set as if it were whole, and the decision
  # the cursor holds is still there for the next fold that can read the span.
  perl -e 'print "working [at=$_]: later step $_ padding padding padding padding\n" for 1 .. 4000' >> "$status"
  rc=0
  out=$(FM_STATUS_CAP_BYTES=65536 FM_STATUS_CAP_RESERVE_BYTES=65536 bash -c '. "$1"; status_open_decisions_incremental "$2"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$status" 2>"$dir/refused.err") || rc=$?
  [ "$rc" -eq 2 ] || fail "a refused span was answered with status $rc, not 2 (output '$out')"
  [ -z "$out" ] || fail "a refused span printed an open set as if it were complete: $out"
  grep -q 'unread suffix' "$dir/refused.err" || fail "a refused span did not name the refused suffix: $(cat "$dir/refused.err")"
  grep -q "^offset=$size\$" "$cursor" || fail "a refused span moved the cursor: $(cat "$cursor")"
  grep -q 'early-q' "$cursor" || fail "a refused span dropped the decision the cursor held: $(cat "$cursor")"
  pass "a fold that cannot read its span leaves the saved cursor and its open decision where they were and answers status 2"
}

run_classify() {  # <function> <args...>: one status-library function in a fresh shell
  bash -c '. "$1/fm-classify-lib.sh"; shift; "$@"' _ "$ROOT/bin" "$@"
}

assert_seeded_refusal() {  # <status> <cursor> <err-file> <key-the-checkpoint-holds-or-empty>
  local status=$1 cursor=$2 err=$3 key=$4 before reader rc out
  before=$(cat "$cursor")
  for reader in status_open_decisions status_open_decisions_incremental; do
    rc=0
    out=$(run_classify "$reader" "$status" 2>"$err") || rc=$?
    [ "$rc" -eq 2 ] || fail "$reader answered a refused unread suffix with status $rc, not 2 (output '$out')"
    [ -z "$out" ] || fail "$reader printed '$out' for a refused unread suffix, as if the checkpoint's set were complete"
    grep -q 'unread suffix' "$err" || fail "$reader did not name the refused suffix: $(cat "$err")"
    [ "$(cat "$cursor")" = "$before" ] || fail "$reader moved or rewrote the checkpoint it could not extend"
  done
  [ -z "$key" ] || grep -q "$key" "$cursor" || fail "the checkpoint lost its open decision $key"
}

test_a_refused_read_is_unknown_never_an_empty_open_set() {
  local dir state status out rc err
  local FM_STATUS_CAP_BYTES=4000 FM_STATUS_CAP_RESERVE_BYTES=1000
  export FM_STATUS_CAP_BYTES FM_STATUS_CAP_RESERVE_BYTES
  dir=$(make_case refused-open-set); state="$dir/state"; status="$state/r.status"; err="$dir/refused.err"
  # A log with an open decision and then 40000 routine lines: 200 KB, past the 5000 byte
  # read limit this test sets.
  { printf 'needs-decision [key=q1]: an early question that is still open\n'; perl -e 'print "text\n" x 40000'; } > "$status"

  # No checkpoint: every pure reader refuses with status 2 and says so, and prints no set.
  for reader in "status_open_decisions $status" "status_open_decisions_dated $status" "status_own_open_decisions $status" "status_current_line $status ship"; do
    rc=0
    # shellcheck disable=SC2086
    out=$(run_classify $reader 2>"$err") || rc=$?
    [ "$rc" -eq 2 ] || fail "${reader%% *} did not refuse with exit status 2 on a log past the read limit (rc=$rc, output '$out')"
    [ -z "$out" ] || fail "${reader%% *} printed '$out' for a log it refused"
    grep -q 'refused to read r.status' "$err" || fail "${reader%% *} did not name the refused log: $(cat "$err")"
  done
  rc=0
  run_classify status_has_open_needs_decision "$status" 2>/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "a refused log answered the needs-decision question with $rc, not the safe no"

  # The drain's incremental fold has no checkpoint here either: it refuses the same way,
  # writes no cursor, and the fleet scan names the log instead of showing an empty set.
  rc=0
  out=$(run_classify status_open_decisions_incremental "$status" 2>"$err") || rc=$?
  [ "$rc" -eq 2 ] || fail "the incremental fold with no checkpoint did not refuse with exit status 2 (rc=$rc, output '$out')"
  [ -z "$out" ] || fail "the incremental fold printed '$out' for a log it refused"
  grep -q 'refused to read r.status' "$err" || fail "the incremental fold did not name the refused log: $(cat "$err")"
  [ -z "$(find "$state" -name '.r.open-decisions-cursor*' -print)" ] || fail "the refused incremental fold wrote a cursor"
  out=$(run_classify scan_open_decisions_incremental "$state" 2>"$err") || fail "the fleet open-decision scan failed on one refused log"
  [ -z "$out" ] || fail "the fleet open-decision scan printed '$out' for a refused log"
  grep -q 'r.status is past the read limits' "$err" || fail "the fleet open-decision scan did not name the refused log: $(cat "$err")"

  # The latest-event reader refuses too when it must read the whole log for the previous event.
  rc=0
  out=$(bash -c '. "$1/fm-classify-lib.sh"; last_status_line "$2" previous; rc=$?; printf "previous=%s\n" "$previous"; exit "$rc"' \
    _ "$ROOT/bin" "$status" 2>/dev/null) || rc=$?
  [ "$rc" -eq 2 ] || fail "last_status_line with a previous event did not refuse with exit status 2 (rc=$rc, output '$out')"
  [ "$out" = $'\nprevious=' ] || fail "last_status_line printed events for a log it refused: '$out'"

  # With a trusted checkpoint a refused tail keeps the checkpoint but is still unknown:
  # both folds answer status 2 and name the refused suffix, and neither prints the
  # checkpoint's set as if it were the whole answer.
  status="$state/seeded.status"; cursor="$state/.seeded.open-decisions-cursor"
  printf 'needs-decision [key=q1]: an early question that is still open\n' > "$status"
  out=$(run_classify status_open_decisions_incremental "$status")
  case "$out" in *q1*) ;; *) fail "the checkpoint fixture did not fold q1: $out" ;; esac
  perl -e 'print "text\n" x 40000' >> "$status"
  assert_seeded_refusal "$status" "$cursor" "$err" q1
  pass "a log the read limits refuse reads as unknown (status 2), never as no open decision, with or without a checkpointed open set"
}

test_a_checkpointed_empty_set_with_a_refused_new_decision_is_unknown() {
  local dir state status cursor err out rc
  local FM_STATUS_CAP_BYTES=4000 FM_STATUS_CAP_RESERVE_BYTES=1000
  export FM_STATUS_CAP_BYTES FM_STATUS_CAP_RESERVE_BYTES
  dir=$(make_case empty-seed-new-decision); state="$dir/state"; status="$state/e.status"; cursor="$state/.e.open-decisions-cursor"; err="$dir/e.err"
  # The reviewer's shape: a checkpoint at byte 23 over an EMPTY open set, then 40000 short
  # lines (past the 5000 byte read limit this test sets) and a new, distinct decision.
  printf 'working: initial event\n' > "$status"
  out=$(run_classify status_open_decisions_incremental "$status") || fail "the seed fold failed"
  [ -z "$out" ] || fail "the seed fixture is not an empty open set: $out"
  grep -q '^offset=23$' "$cursor" || fail "the checkpoint is not at byte 23: $(cat "$cursor")"
  { perl -e 'print "text\n" x 40000'; printf 'needs-decision [key=new-call]: choose a route\n'; } >> "$status"
  [ "$(file_size "$status")" -gt 200000 ] || fail "the fixture is smaller than the 200 KB the reviewer used"
  assert_seeded_refusal "$status" "$cursor" "$err" ''
  rc=0
  out=$(run_classify scan_open_decisions_incremental "$state" 2>"$err") || rc=$?
  [ "$rc" -eq 0 ] || fail "the fleet open-decision scan failed on one refused suffix (rc=$rc)"
  [ -z "$out" ] || fail "the fleet open-decision scan printed '$out'"
  grep -q 'e.status is past the read limits' "$err" || fail "the fleet scan did not name the lane whose open set is unknown: $(cat "$err")"
  pass "a checkpointed empty open set whose unread suffix is refused is unknown (status 2), never a complete empty set that hides new-call"
}

test_a_refused_lane_does_not_hide_the_other_lanes_from_the_drain() {
  local dir state out err
  dir=$(make_case refused-lane); state="$dir/state"; err="$dir/drain.err"
  printf 'needs-decision [key=q1]: a healthy lane still has its decision\n' > "$state/a.status"
  perl -e 'print "text\n" x 5000' > "$state/b.status"
  : > "$state/a.meta"
  : > "$state/b.meta"
  fm_write_meta "$state/a.meta" "window=firstmate:fm-a" "worktree=$dir" "project=alpha" "harness=claude" "kind=ship" 2>/dev/null || true
  fm_write_meta "$state/b.meta" "window=firstmate:fm-b" "worktree=$dir" "project=alpha" "harness=claude" "kind=ship" 2>/dev/null || true
  # b.status is 25000 bytes; with this cap plus reserve the read limit is 5000 bytes.
  out=$(FM_STATUS_CAP_BYTES=4000 FM_STATUS_CAP_RESERVE_BYTES=1000 FM_STATE_OVERRIDE="$state" "$DRAIN" 2>"$err") \
    || fail "the drain failed because one lane's log is past the read limit: $(head -c 400 "$err")"
  case "$out" in *'[key=q1]'*) ;; *) fail "the healthy lane's open decision vanished from the drain: $out" ;; esac
  grep -q 'b.status' "$err" || fail "the drain did not name the refused log: $(head -c 400 "$err")"
  grep -q 'refused\|past the read limits' "$err" || fail "the drain did not say why: $(head -c 400 "$err")"
  pass "one lane's log past the read limits is named on stderr and the drain still presents every other lane's open decisions"
}

# The watcher queues a plain signal row for any status log that changes, and the drain
# annotates a signal row with the log's unread lines. That annotation step must obey
# the same read limits as every other history reader: a log past them is refused and
# named, never read whole into the output.
drain_annotations_in() {  # <case-dir> <cap> <reserve> -> the drain's stdout; its stderr is <case-dir>/drain.err
  local dir=$1 state=$1/state
  printf 'working: a healthy lane\n' > "$state/a.status"
  perl -e 'print "text\n" x 5000' > "$state/b.status"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1/fm-wake-lib.sh"; fm_wake_append signal a.status "signal: a.status" && fm_wake_append signal b.status "signal: b.status"' \
    _ "$ROOT/bin" || return 1
  FM_STATUS_CAP_BYTES=$2 FM_STATUS_CAP_RESERVE_BYTES=$3 FM_STATE_OVERRIDE="$state" "$DRAIN" 2>"$dir/drain.err"
}

test_the_drain_annotation_never_reads_a_log_past_the_limit() {
  local out dir lines
  # b.status is 25000 bytes in 5000 lines; with this cap plus reserve the read limit is 5000 bytes.
  dir=$(make_case annotate-refused)
  out=$(drain_annotations_in "$dir" 4000 1000) || fail "the drain failed on a signal row for a log past the read limit: $(head -c 400 "$dir/drain.err")"
  lines=$(printf '%s\n' "$out" | grep -c 'wake annotation:.*b\.status' || true)
  [ "$lines" -eq 0 ] || fail "the drain printed $lines annotation lines from a log past the read limit"
  case "$out" in *'wake annotation:'*'a.status: working: a healthy lane'*) ;; *) fail "the healthy lane lost its annotation beside a refused one: $out" ;; esac
  grep -q 'refused to read b.status' "$dir/drain.err" || fail "the drain did not name the refused log: $(head -c 400 "$dir/drain.err")"

  # Mutation check: the same fixture with the limit raised past the log is annotated
  # in full, so the refusal above is the read limit and not a missing annotation.
  dir=$(make_case annotate-allowed)
  out=$(drain_annotations_in "$dir" 100000 1000) || fail "mutation check: the drain failed with the limit raised: $(head -c 400 "$dir/drain.err")"
  lines=$(printf '%s\n' "$out" | grep -c 'wake annotation:.*b\.status: text' || true)
  [ "$lines" -eq 5000 ] || fail "mutation check: with the limit raised the drain annotated $lines of 5000 lines, so the refusal test above proves nothing"
  pass "a signal row for a log past the read limit annotates nothing and names the log; a log within the limit is annotated whole"
}

test_latest_event_endpoint_is_a_position_in_the_whole_log() {
  local dir state status size out
  dir=$(make_case endpoint-position); state="$dir/state"; status="$state/e.status"
  # 20000 five-byte lines and then a 23-byte decision: 100023 bytes, more than 4096 lines in its last 64 KiB.
  perl -e 'print "tiny\n" x 20000; print "blocked: needs a human\n"' > "$status"
  size=$(file_size "$status")
  [ "$size" -eq 100023 ] || fail "the fixture is $size bytes, not 100023"
  out=$(bash -c '. "$1/fm-classify-lib.sh"; ident=$(_fm_open_decisions_file_ident "$2"); status_snapshot_latest_event "$2" "$3" "$ident" && printf "%s|%s" "$FM_STATUS_SNAPSHOT_EVENT_ENDPOINT" "$FM_STATUS_SNAPSHOT_EVENT_LINE"' \
    _ "$ROOT/bin" "$status" "$size") || fail "the latest-event read of the 100023 byte log failed"
  [ "$out" = "100023|blocked: needs a human" ] || fail "the latest event endpoint is not the file size: $out"
  pass "the latest-event endpoint of a log of tiny lines is its true byte position, 100023"
}

test_declared_wait_identity_is_stable_across_continuation_lines_in_a_long_log() {
  local dir state status first second third offset
  dir=$(make_case wait-identity); state="$dir/state"; status="$state/w.status"
  perl -e 'print "working [at=$_]: step $_\n" for 1 .. 5000' > "$status"
  offset=$(file_size "$status")
  printf 'paused: waiting for CI\n' >> "$status"
  first=$(bash -c '. "$1/fm-classify-lib.sh"; status_declared_wait_identity "$2"' _ "$ROOT/bin" "$status") \
    || fail "the declared wait of the 5001 line log has no identity"
  printf '  still waiting, nothing new\n' >> "$status"
  second=$(bash -c '. "$1/fm-classify-lib.sh"; status_declared_wait_identity "$2"' _ "$ROOT/bin" "$status") \
    || fail "the declared wait lost its identity after one continuation line"
  printf '  checked again at noon\n' >> "$status"
  third=$(bash -c '. "$1/fm-classify-lib.sh"; status_declared_wait_identity "$2"' _ "$ROOT/bin" "$status") \
    || fail "the declared wait lost its identity after two continuation lines"
  [ "$first" = "$second" ] && [ "$second" = "$third" ] \
    || fail "the identity drifted with continuation lines: $first / $second / $third"
  case "$first" in *:"$offset") ;; *) fail "the identity position is not the pause's byte offset, $offset: $first" ;; esac
  pass "a long log's declared wait keeps one identity at its true byte position however many continuation lines follow"
}

test_the_fleet_snapshot_script_stays_bounded_on_a_two_gib_log() {
  local dir home fakebin out start secs big
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; return 0; }
  dir=$(make_case snapshot-script); home="$dir/home"; fakebin=$(fm_fakebin "$dir")
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config" "$home/wt"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) printf 'codex\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  fm_write_meta "$home/state/huge.meta" "window=firstmate:fm-huge" "worktree=$home/wt" "project=alpha" \
    "harness=claude" "kind=ship" "mode=ship" "yolo=off"
  printf '## In flight\n- [ ] huge - Huge log (repo: alpha) (kind: ship) (since 2026-10-01)\n' > "$home/data/backlog.md"
  make_two_gib_log "$home/state/huge.status" || fail "could not build the sparse 2 GiB fixture"
  out="$dir/summary.json"
  start=$SECONDS
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_SNAPSHOT_NOW=2026-10-08T12:00:00Z FM_CONTRIBUTIONS_NOW=2026-10-08T12:00:00Z \
    fm_run_timed "$READER_BOUND_SECS" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$out" 2> "$dir/err" \
    || fail "the fleet snapshot did not finish in ${READER_BOUND_SECS}s on a 2 GiB log: $(head -c 400 "$dir/err")"
  secs=$((SECONDS - start))
  jq -e '.schema == "fm-secondmate-home-summary.v1" and .counts.endpoints == 1' "$out" >/dev/null \
    || fail "the snapshot did not summarize the task: $(head -c 400 "$out")"
  big=$(big_files_in "$home/state")
  [ -z "$big" ] || fail "the snapshot left a file over 1 MB in the state directory: $big"
  [ "$(file_size "$home/state/huge.status")" -eq 2147483648 ] || fail "the snapshot changed the log"
  grep -q 'refused to read huge.status' "$dir/err" || fail "the snapshot did not name the log it refused to copy: $(head -c 400 "$dir/err")"
  printf '# | fleet snapshot (secondmate home summary) | %ss |\n' "$secs"
  pass "the fleet snapshot summarizes a home with a 2 GiB log inside ${READER_BOUND_SECS}s, names the log it will not copy, and leaves no large file"
}

test_without_the_read_limit_the_same_reader_takes_the_whole_log() {
  local dir state status bytes
  dir=$(make_case mutation-read); state="$dir/state"; status="$state/huge.status"
  make_two_gib_log "$status" || fail "could not build the sparse 2 GiB fixture"
  bytes=$(FM_STATUS_CAP_BYTES=4294967296 fm_run_timed 120 bash -c '
    . "$1/fm-status-io-lib.sh"
    fm_status_cat "$2" 2>/dev/null | wc -c
  ' _ "$ROOT/bin" "$status" | tr -d ' ')
  [ "$bytes" -ge 2147483000 ] || fail "mutation check: with the limit raised past the log the reader took only $bytes bytes; the refusal test above proves nothing"
  bytes=$(fm_run_timed 120 bash -c '
    . "$1/fm-status-io-lib.sh"
    fm_status_cat "$2" 2>/dev/null | wc -c
  ' _ "$ROOT/bin" "$status" | tr -d ' ')
  [ "$bytes" -eq 0 ] || fail "the default read limit let a reader take $bytes bytes of a 2 GiB log"
  pass "mutation: with the read limit raised past the log the same reader takes all 2 GiB; with the default it takes nothing"
}

test_a_killed_drain_leaves_no_large_cursor_file() {
  local dir state status i pid
  dir=$(make_case killed-drain); state="$dir/state"; status="$state/big.status"
  # A healthy-sized log of keyed events, so the drain has real folding to interrupt.
  perl -e 'for my $i (1 .. 4000) { print "working [at=$i]: step $i of the work padding padding padding padding padding\n"; print "needs-decision [key=k$i]: question $i\n" if $i % 50 == 0; }' > "$status"
  : > "$state/big.meta"
  fm_write_meta "$state/big.meta" "window=firstmate:fm-big" "worktree=$dir" "project=alpha" "harness=claude" "kind=ship" 2>/dev/null || true
  for i in 1 2 3; do
    FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 &
    pid=$!
    sleep 0.3
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
  [ -z "$(big_files_in "$state")" ] || fail "a killed drain left a file over 1 MB: $(big_files_in "$state")"
  # A bounded scratch file may survive SIGKILL between its creation and its cleanup (the
  # latest-event reader's span scratch is at most 64 KiB), so the requirement is a size
  # bound on whatever a kill leaves, which the 1 MB check above already holds for every
  # file; only the unbounded cursor-read copies must not survive at all.
  [ -z "$(find "$state" -name '*.span.*' -size +64k 2>/dev/null)" ] \
    || fail "a killed drain left a span scratch file past its 64 KiB bound: $(find "$state" -name '*.span.*' -size +64k)"
  [ -z "$(find "$state" -name '*.unread.*' -o -name '*cursor.read.*' 2>/dev/null)" ] \
    || fail "a killed drain left a cursor copy: $(find "$state" -name '*.unread.*' -o -name '*cursor.read.*')"
  pass "a drain killed with SIGKILL mid-run leaves no cursor file above 1 MB and no cursor copy"
}

test_the_snapshot_copy_stops_at_the_size_it_checked_when_the_log_grows() {
  local dir src dst fn mtime_epoch out rc
  dir=$(make_case snapshot-growing); src="$dir/g.status"; dst="$dir/g.copy"; fn="$dir/capture.sh"
  printf 'working: first event\n' > "$src"
  touch -t 202001010000 "$src"
  mtime_epoch=$(if [ "$(uname)" = Darwin ]; then stat -f %m "$src"; else stat -c %Y "$src"; fi)
  # The snapshot's own copy function, taken from the script verbatim.
  sed -n '/^snapshot_capture_status() {/,/^}/p' "$ROOT/bin/fm-fleet-snapshot.sh" > "$fn"
  [ -s "$fn" ] || fail "could not extract snapshot_capture_status from bin/fm-fleet-snapshot.sh"
  # A writer that appends 64 KiB right after the size allowance and before the copy reads:
  # the copy must hold the bytes that were checked and no more. The ulimit keeps a broken
  # copy from writing more than a few MiB.
  rc=0
  out=$(FM_STATUS_CAP_BYTES=1024 FM_STATUS_CAP_RESERVE_BYTES=1024 bash -c '
    ulimit -f 4096
    . "$1/fm-status-io-lib.sh"
    . "$2"
    grow_target=$3
    eval "$(declare -f fm_status_read_allowed | sed "1s/fm_status_read_allowed/orig_read_allowed/")"
    fm_status_read_allowed() {
      orig_read_allowed "$@" || return
      perl -e "print qq(x) x 65535, qq(\\n)" >> "$grow_target"
    }
    snapshot_capture_status "$3" "$4"
  ' _ "$ROOT/bin" "$fn" "$src" "$dst" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the snapshot copy failed on a growing log (rc=$rc): $out"
  [ "$(file_size "$src")" -gt 65000 ] || fail "the writer did not grow the log, so this case proves nothing"
  [ "$(file_size "$dst")" -eq 21 ] || fail "the snapshot copy took $(file_size "$dst") bytes, not the 21 it had checked"
  [ "$(cat "$dst")" = "working: first event" ] || fail "the snapshot copy is not the checked bytes: $(head -c 100 "$dst")"
  [ "$(if [ "$(uname)" = Darwin ]; then stat -f %m "$dst"; else stat -c %Y "$dst"; fi)" = "$mtime_epoch" ] \
    || fail "the snapshot copy did not keep the source mtime read before the copy"
  pass "the snapshot copy of a log that grows after its size check holds only the checked bytes and keeps the source mtime"
}

wait_for_file_nonempty() {  # <path>
  local path=$1 deadline=$((SECONDS + 15))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ ! -s "$path" ] || return 0
    sleep 0.1
  done
  return 1
}

tests=(
  test_sanctioned_loop_stops_growing_at_the_cap
  test_a_verbless_loop_stops_at_the_cap_and_leaves_the_reserve_for_done
  test_a_stopped_lock_holder_never_hangs_a_sanctioned_append
  test_without_the_helper_the_same_loop_passes_the_cap
  test_incident_shape_is_refused_at_the_cap_and_loses_no_distinct_line
  test_foreign_omp_writer_is_named_stopped_and_never_deleted
  test_a_resumed_writer_is_woken_for_and_stopped_again
  test_the_incident_writer_that_holds_the_log_open_is_found_and_stopped
  test_a_lingering_signal_does_not_hold_back_the_over_cap_stop
  test_a_cap_crossing_after_the_span_is_captured_is_stopped_before_the_signal_wake_exits
  test_a_runaway_that_keeps_growing_through_the_over_cap_wake_raises_exactly_one_wake
  test_a_long_classification_checks_the_cap_every_poll
  test_a_second_writer_that_passes_the_cap_during_the_wake_flush_is_stopped_without_a_second_wake
  test_the_heartbeat_scan_checks_the_cap_every_poll
  test_the_stale_surface_checks_the_cap_every_poll
  test_a_cap_crossing_during_a_short_stale_walk_is_stopped_before_the_stale_wake_exits
  test_a_cap_crossing_during_a_short_heartbeat_scan_is_stopped_before_the_heartbeat_wake_exits
  test_the_push_transition_walk_checks_the_cap
  test_the_inbox_steer_fold_checks_the_cap
  test_a_tick_in_a_captured_read_hands_the_measured_rate_to_the_wake
  test_a_handed_rate_keeps_the_watchers_own_writer_and_stop
  test_a_held_rate_does_not_outlive_its_due_alert
  test_the_open_decisions_fold_calls_its_tick_for_every_line
  test_the_span_classifier_calls_its_tick_for_every_line_it_walks
  test_the_guard_never_stops_the_firstmate_session_or_a_reader
  test_the_guard_never_stops_a_sanctioned_append
  test_guard_says_unknown_when_lsof_is_missing_or_timed_out
  test_a_bash_writer_is_stopped_and_a_missing_writer_stops_nothing
  test_guard_scan_names_a_sidecar_and_wakes_again_only_on_growth
  test_readers_stay_bounded_on_a_two_gib_log
  test_history_readers_refuse_a_log_past_the_limit_and_name_it
  test_history_readers_read_a_healthy_log_of_many_lines
  test_a_log_at_the_read_limit_of_tiny_lines_costs_no_line_walk
  test_declared_wait_identity_is_an_absolute_offset_past_the_tail_window
  test_the_watcher_window_keeps_a_whole_first_line
  test_a_declaration_with_a_colon_in_its_tag_is_found_past_the_tail
  test_a_saved_cursor_never_advances_past_bytes_that_were_not_read
  test_a_refused_read_is_unknown_never_an_empty_open_set
  test_a_checkpointed_empty_set_with_a_refused_new_decision_is_unknown
  test_a_refused_lane_does_not_hide_the_other_lanes_from_the_drain
  test_the_drain_annotation_never_reads_a_log_past_the_limit
  test_latest_event_endpoint_is_a_position_in_the_whole_log
  test_declared_wait_identity_is_stable_across_continuation_lines_in_a_long_log
  test_the_fleet_snapshot_script_stays_bounded_on_a_two_gib_log
  test_the_snapshot_copy_stops_at_the_size_it_checked_when_the_log_grows
  test_without_the_read_limit_the_same_reader_takes_the_whole_log
  test_a_killed_drain_leaves_no_large_cursor_file
)
# Named cases run alone, for a mutation check of one guard.
if [ "$#" -gt 0 ]; then
  for requested in "$@"; do
    selected=0
    for candidate in "${tests[@]}"; do
      [ "$requested" != "$candidate" ] || selected=1
    done
    [ "$selected" -eq 1 ] || fail "unknown status runaway guard test: $requested"
  done
  tests=("$@")
fi
for selected_test in "${tests[@]}"; do
  "$selected_test" || exit "$?"
done
