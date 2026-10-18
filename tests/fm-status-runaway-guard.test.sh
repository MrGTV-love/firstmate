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
# removed (a raw append loop, or an unbounded read window) must show the damage the
# guard prevents, so a passing guard test cannot be vacuous.
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
  local dir status size i rc refused=0
  dir=$(make_case sanctioned-loop); status="$dir/state/loop.status"
  FM_STATUS_CAP_BYTES=4096 FM_STATUS_CAP_RESERVE_BYTES=512 bash -c '
    ulimit -f '"$HARD_LIMIT_BLOCKS"'
    i=0
    while [ "$i" -lt 600 ]; do
      i=$((i + 1))
      "$1" "$2" "working [at=$i]: the same line again" 2>/dev/null || exit 1
    done
  ' _ "$APPEND" "$status" || fail "the sanctioned loop failed or hit the hard limit"
  size=$(file_size "$status")
  [ "$size" -le 4096 ] || fail "the sanctioned repeat loop grew to $size bytes, past the 4096 byte cap"
  [ "$(grep -c 'the same line again' "$status")" -eq 1 ] || fail "the repeated line was written more than once"
  [ "$(grep -c 'fm-status-collapsed' "$status")" -eq 1 ] || fail "the repeats did not collapse into exactly one counter line"
  grep -q 'repeats=000000000599 ' "$status" || fail "the counter is not exact: $(grep fm-status-collapsed "$status")"

  # Distinct filler reaches the cap and is refused loudly; nothing is silently lost.
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
  pass "the sanctioned writer holds the cap, counts repeats exactly, refuses filler loudly, and keeps the reserve for done:"
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

test_distinct_burst_survives_and_the_incident_shape_keeps_one_counter() {
  local dir status args=() i before after
  dir=$(make_case incident-shape); status="$dir/state/shape.status"
  i=0
  while [ "$i" -lt 3000 ]; do
    i=$((i + 1))
    args+=("working [at=$i]: distinct event number $i")
  done
  "$APPEND" "$status" "${args[@]}" || fail "a burst of 3000 distinct events was refused"
  [ "$(wc -l < "$status" | tr -d ' ')" -eq 3000 ] || fail "the burst lost events: $(wc -l < "$status") of 3000"
  i=0
  while [ "$i" -lt 3000 ]; do
    i=$((i + 1))
    [ "$(sed -n "${i}p" "$status")" = "working [at=$i]: distinct event number $i" ] || fail "event $i was altered or reordered"
  done

  # Then one line repeated; the byte size must not depend on how many times.
  args=()
  i=0
  while [ "$i" -lt 5000 ]; do i=$((i + 1)); args+=("REPOST REQUIRED corr=6be04311231638c7 reply on the parent channel"); done
  "$APPEND" "$status" "${args[@]}" 2>/dev/null || fail "the repeated line was refused"
  before=$(file_size "$status")
  "$APPEND" "$status" "${args[@]}" 2>/dev/null || fail "the second repeat batch was refused"
  after=$(file_size "$status")
  [ "$before" -eq "$after" ] || fail "ten thousand repeats grew the log by $((after - before)) bytes after the first batch"
  [ "$(grep -c 'fm-status-collapsed' "$status")" -eq 1 ] || fail "the repeats made more than one counter line"
  [ "$(grep -c 'REPOST REQUIRED' "$status")" -eq 1 ] || fail "the repeated line was written more than once"
  grep -q 'repeats=000000009999 ' "$status" || fail "the count is not exact: $(grep fm-status-collapsed "$status")"
  [ "$(sed -n 1,3000p "$status" | grep -c 'distinct event number')" -eq 3000 ] \
    || fail "a distinct line was lost when the repeats were collapsed"
  pass "the 2026-10-18 shape keeps all 3000 distinct lines and one exact counter however many repeats follow"
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

# A bounded writer that holds a descriptor open and appends the way the harness
# did. It runs under a hard file-size limit and a hard iteration count.
start_foreign_writer() {  # <shell> <status-file> <pid-file>
  (
    ulimit -f "$HARD_LIMIT_BLOCKS"
    "$1" -c '
      exec 9>>"$1"
      i=0
      while [ "$i" -lt 600000 ]; do
        i=$((i + 1))
        printf "text\n" >&9
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
  start_foreign_writer "$omp" "$status" "$dir/writer.pid"
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

  # One wake per episode: a second watcher over the same still-over-cap log stays quiet.
  ack_cycle "$state" || fail "could not acknowledge the wake"
  watch_cap "$state" "$out.2"
  watch_pid=$!
  wait_for_exit "$watch_pid" 30 && fail "the watcher woke a second time for the same over-cap log: $(cat "$out.2")"
  [ "$(queue_rows_for "$state")" -eq 0 ] || fail "a second over-cap wake was queued"
  reap "$watch_pid"
  [ "$(file_size "$status")" -eq "$before_delete" ] || fail "the log was rewritten or truncated by the guard"
  kill -CONT "$pid" 2>/dev/null; kill -9 "$pid" "$bystander" 2>/dev/null
  pass "a raw omp writer over the cap is detected within polls, named by pid, stopped alone, and the log is left intact with one wake"
}

test_non_omp_and_missing_writers_wake_but_stop_nothing() {
  local dir state status out shell wpid watch_pid
  command -v lsof >/dev/null 2>&1 || { echo "skip: lsof not found"; return 0; }
  dir=$(make_case foreign-other); state="$dir/state"; status="$state/other.status"; out="$dir/watch.out"
  shell=$(make_named_shell "$dir" notomp)
  : > "$status"
  start_foreign_writer "$shell" "$status" "$dir/writer.pid"
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

test_guard_scan_names_a_sidecar_and_resets_after_it_shrinks() {
  local dir state side out
  dir=$(make_case sidecar); state="$dir/state"; side="$state/.t1.open-decisions-cursor.unread.123"
  head -c 300000 /dev/zero | tr '\0' 'y' > "$side"
  out=$(FM_STATE_OVERRIDE="$state" FM_STATUS_CAP_BYTES=262144 FM_STATUS_CAP_SAMPLE_SECS=1 FM_STATUS_CAP_LSOF=/usr/bin/false "$GUARD" scan) \
    || fail "the guard scan failed"
  case "$out" in *'file=.t1.open-decisions-cursor.unread.123'*) ;; *) fail "the guard did not name the over-cap cursor scratch: $out" ;; esac
  FM_STATE_OVERRIDE="$state" "$GUARD" mark "$side" "$(printf '%s' "$out" | cut -f1)"
  out=$(FM_STATE_OVERRIDE="$state" FM_STATUS_CAP_BYTES=262144 FM_STATUS_CAP_SAMPLE_SECS=1 FM_STATUS_CAP_LSOF=/usr/bin/false "$GUARD" scan)
  [ -z "$out" ] || fail "an alerted file was reported again: $out"
  : > "$side"
  FM_STATE_OVERRIDE="$state" FM_STATUS_CAP_BYTES=262144 FM_STATUS_CAP_LSOF=/usr/bin/false "$GUARD" scan >/dev/null
  [ -z "$(ls "$state"/.status-cap-alerted.* 2>/dev/null)" ] || fail "the alert marker survived the file dropping under the cap"
  pass "a per-task sidecar over the cap is named once, and its marker clears when it shrinks"
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

test_the_fleet_snapshot_captures_a_bounded_copy() {
  local dir state status out copy
  dir=$(make_case snapshot-bound); state="$dir/state"; status="$state/huge.status"
  make_two_gib_log "$status" || fail "could not build the sparse 2 GiB fixture"
  copy="$dir/capture.status"
  fm_run_timed 60 bash -c '
    . "$1/fm-status-io-lib.sh"
    window=$(fm_status_window_bytes)
    fm_status_window_cat "$2" > "$3" 2>/dev/null
    [ -s "$3" ]
  ' _ "$ROOT/bin" "$status" "$copy" || fail "the bounded capture did not finish"
  out=$(file_size "$copy")
  [ "$out" -le 4194304 ] || fail "the snapshot-style capture of a 2 GiB log is $out bytes, past the 4 MiB window"
  tail -1 "$copy" | grep -q 'REPOST REQUIRED' || fail "the capture does not end at the log's last line"
  [ "$(file_size "$status")" -eq 2147483648 ] || fail "the capture changed the source log"
  pass "a snapshot-style capture of a 2 GiB log is its last whole lines, $out bytes, and the source is untouched"
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
  printf '# | fleet snapshot (secondmate home summary) | %ss |\n' "$secs"
  pass "the fleet snapshot summarizes a home with a 2 GiB log inside ${READER_BOUND_SECS}s and leaves no large file"
}

test_unbounded_read_window_would_read_the_whole_log() {
  local dir state status bytes
  dir=$(make_case mutation-read); state="$dir/state"; status="$state/huge.status"
  make_two_gib_log "$status" || fail "could not build the sparse 2 GiB fixture"
  bytes=$(FM_STATUS_READ_WINDOW_BYTES=4294967296 FM_STATUS_READ_WINDOW_LINES=2147483647 fm_run_timed 120 bash -c '
    . "$1/fm-status-io-lib.sh"
    fm_status_window_cat "$2" 2>/dev/null | wc -c
  ' _ "$ROOT/bin" "$status" | tr -d ' ')
  [ "$bytes" -ge 2147483000 ] || fail "mutation check: with the window removed the reader took only $bytes bytes; the bound test above proves nothing"
  bytes=$(fm_run_timed 120 bash -c '
    . "$1/fm-status-io-lib.sh"
    fm_status_window_cat "$2" 2>/dev/null | wc -c
  ' _ "$ROOT/bin" "$status" | tr -d ' ')
  [ "$bytes" -le 4194304 ] || fail "the default window took $bytes bytes of a 2 GiB log"
  pass "mutation: with the window removed the same reader takes all 2 GiB; with it, $bytes bytes"
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
  test_distinct_burst_survives_and_the_incident_shape_keeps_one_counter
  test_foreign_omp_writer_is_named_stopped_and_never_deleted
  test_non_omp_and_missing_writers_wake_but_stop_nothing
  test_guard_scan_names_a_sidecar_and_resets_after_it_shrinks
  test_readers_stay_bounded_on_a_two_gib_log
  test_the_fleet_snapshot_captures_a_bounded_copy
  test_the_fleet_snapshot_script_stays_bounded_on_a_two_gib_log
  test_unbounded_read_window_would_read_the_whole_log
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
