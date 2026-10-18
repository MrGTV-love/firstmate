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

# A bounded writer that holds a descriptor open and appends short lines the way the
# harness did, 13000 lines (65000 bytes) every second for up to 60 rounds. It is paced
# so that it is still writing when the watcher, which takes several seconds to start,
# finds it, and a stopped and then resumed one still has most of its work left. It runs
# under a hard file-size limit and a hard round count: 60 rounds are 3.9 MB, under the
# 4 MiB limit.
start_paced_writer() {  # <shell> <status-file> <pid-file>
  (
    ulimit -f "$HARD_LIMIT_BLOCKS"
    "$1" -c '
      exec 9>>"$1"
      i=0
      while [ "$i" -lt 60 ]; do
        i=$((i + 1))
        printf "text\n%.0s" {1..13000} >&9
        sleep 1 9>&-
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
    FM_STATUS_CAP_SAMPLE_SECS=1 FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 \
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

test_non_omp_and_missing_writers_wake_but_stop_nothing() {
  local dir state status out shell wpid watch_pid
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case foreign-other); state="$dir/state"; status="$state/other.status"; out="$dir/watch.out"
  shell=$(make_named_shell "$dir" notomp)
  : > "$status"
  start_paced_writer "$shell" "$status" "$dir/writer.pid"
  wait_for_file_nonempty "$dir/writer.pid" || fail "the fake writer did not start"
  wpid=$(cat "$dir/writer.pid")
  run_until_cap_wake "$state" "$out" || { kill -9 "$wpid" 2>/dev/null; fail "no wake for a non-omp writer: $(cat "$out" "$out.err" 2>/dev/null)"; }
  grep -q 'check: status-log-over-cap' "$out" || fail "no over-cap wake for a non-omp writer: $(cat "$out")"
  grep -q 'is not an omp process' "$out" || fail "the wake does not say the writer is not omp: $(cat "$out")"
  grep -q 'stopped nothing' "$out" || fail "the wake does not say nothing was stopped: $(cat "$out")"
  [ "$(state_letter "$wpid")" != T ] || fail "a non-omp writer was stopped"
  kill -9 "$wpid" 2>/dev/null

  # No writer at all: a finished log that is simply over the cap.
  dir=$(make_case foreign-none); state="$dir/state"; status="$state/none.status"; out="$dir/watch.out"
  head -c 300000 /dev/zero | tr '\0' 'x' > "$status"
  printf '\n' >> "$status"
  run_until_cap_wake "$state" "$out" || fail "no wake for an over-cap log with no writer: $(cat "$out" "$out.err" 2>/dev/null)"
  grep -q 'writer=none found' "$out" || fail "the wake does not say no writer was found: $(cat "$out")"
  grep -q 'stopped nothing' "$out" || fail "the wake does not say nothing was stopped: $(cat "$out")"
  [ "$(file_size "$status")" -eq 300001 ] || fail "the log was changed"
  pass "a non-omp writer, and no writer at all, still raise the wake and stop nothing"
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
  scan_env=(env FM_STATE_OVERRIDE="$state" FM_STATUS_CAP_BYTES=262144 FM_STATUS_CAP_SAMPLE_SECS=1 FM_STATUS_CAP_LSOF=/usr/bin/false)
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

  secs=$(timed open-decisions fm_run_timed "$READER_BOUND_SECS" bash -c '. "$1"; status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$status") \
    || fail "status_open_decisions did not finish in ${READER_BOUND_SECS}s on a 2 GiB log"
  record_timing "open-decisions fold" "$secs"
  secs=$(timed last-line fm_run_timed "$READER_BOUND_SECS" bash -c '. "$1"; last_status_line "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$status") \
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
  [ "$rc" -ne 0 ] || fail "a whole-file read of a 2 GiB log succeeded"
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

  # The line limit works the same way: a span with more lines than a shell loop should
  # walk is refused, not clipped, unless the caller asks for the byte limit alone; the
  # largest healthy log (5,338 lines) is read whole.
  status="$state/dense.status"
  perl -e 'print "x\n" x 40000' > "$status"
  rc=0
  out=$(bash -c '. "$1/fm-status-io-lib.sh"; fm_status_cat "$2"' _ "$ROOT/bin" "$status" 2>"$dir/lines.err") || rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] || fail "a 40000 line log was read by a line-by-line reader (rc=$rc, ${#out} bytes)"
  grep -q 'refused to read dense.status: more than 32768 lines' "$dir/lines.err" || fail "the line refusal does not name the file and limit: $(cat "$dir/lines.err")"
  [ "$(bash -c '. "$1/fm-status-io-lib.sh"; fm_status_cat "$2" 0 | wc -c' _ "$ROOT/bin" "$status" | tr -d ' ')" -eq 80000 ] \
    || fail "the byte-limit-alone read of the 40000 line log did not return all of it"
  perl -e 'print "working: step $_\n" for 1 .. 5338' > "$status"
  [ "$(bash -c '. "$1/fm-status-io-lib.sh"; fm_status_cat "$2" | wc -l' _ "$ROOT/bin" "$status" | tr -d ' ')" -eq 5338 ] \
    || fail "a log of the largest healthy line count was not read whole"
  pass "a history reader refuses a 2 GiB log and a log of too many lines, names it, and reads nothing; a short span from it is exact"
}

test_a_saved_cursor_never_advances_past_bytes_that_were_not_read() {
  local dir state status cursor out size
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

  # A later growth past the limit is refused too: the cursor stays where it was and the
  # decision it holds is not lost.
  perl -e 'print "working [at=$_]: later step $_ padding padding padding padding\n" for 1 .. 4000' >> "$status"
  out=$(FM_STATUS_CAP_BYTES=65536 FM_STATUS_CAP_RESERVE_BYTES=65536 bash -c '. "$1"; status_open_decisions_incremental "$2"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$status")
  case "$out" in *early-q*) ;; *) fail "a refused span dropped the decision the cursor held: $out" ;; esac
  grep -q "^offset=$size\$" "$cursor" || fail "a refused span moved the cursor: $(cat "$cursor")"
  pass "a fold that cannot read its span leaves the saved cursor and its open decision where they were"
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
  local dir state status first second third
  dir=$(make_case wait-identity); state="$dir/state"; status="$state/w.status"
  { perl -e 'print "working [at=$_]: step $_\n" for 1 .. 5000'; printf 'paused: waiting for CI\n'; } > "$status"
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
  case "$first" in *:5001) ;; *) fail "the identity position is not the pause's true line, 5001: $first" ;; esac
  pass "a long log's declared wait keeps one identity at its true line position however many continuation lines follow"
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
    fm_status_cat "$2" 0 2>/dev/null | wc -c
  ' _ "$ROOT/bin" "$status" | tr -d ' ')
  [ "$bytes" -ge 2147483000 ] || fail "mutation check: with the limit raised past the log the reader took only $bytes bytes; the refusal test above proves nothing"
  bytes=$(fm_run_timed 120 bash -c '
    . "$1/fm-status-io-lib.sh"
    fm_status_cat "$2" 0 2>/dev/null | wc -c
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
  [ -z "$(find "$state" -name '*.unread.*' -o -name '*.span.*' -o -name '*cursor.read.*' 2>/dev/null)" ] \
    || fail "a killed drain left a scratch file: $(find "$state" -name '*.unread.*' -o -name '*.span.*' -o -name '*cursor.read.*')"
  pass "a drain killed with SIGKILL mid-run leaves no scratch or cursor file"
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
  test_without_the_helper_the_same_loop_passes_the_cap
  test_incident_shape_is_refused_at_the_cap_and_loses_no_distinct_line
  test_foreign_omp_writer_is_named_stopped_and_never_deleted
  test_a_resumed_writer_is_woken_for_and_stopped_again
  test_non_omp_and_missing_writers_wake_but_stop_nothing
  test_guard_scan_names_a_sidecar_and_wakes_again_only_on_growth
  test_readers_stay_bounded_on_a_two_gib_log
  test_history_readers_refuse_a_log_past_the_limit_and_name_it
  test_a_saved_cursor_never_advances_past_bytes_that_were_not_read
  test_latest_event_endpoint_is_a_position_in_the_whole_log
  test_declared_wait_identity_is_stable_across_continuation_lines_in_a_long_log
  test_the_fleet_snapshot_script_stays_bounded_on_a_two_gib_log
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
