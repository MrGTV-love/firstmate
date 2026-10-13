#!/usr/bin/env bash
# Behavior tests for bin/fm-timeout-lib.sh's bounds, fm_exec_timed and fm_run_timed:
# TERM to the command's process group at the bound, KILL once the grace has
# passed, a forwarded signal, the caller replaced rather than wrapped, and a
# refusal instead of an unbounded run when nothing on the host can enforce the
# bound. Most cases pin the perl watchdog, the preferred mechanism and the only
# one a stock macOS host has, under a PATH that holds no timeout variant; the
# GNU fallback case runs only where a real timeout exists.
# shellcheck disable=SC2016 # each bounded bash -c script expands its own arguments
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-timeout-lib)

# A PATH with perl and the shell tools the bounded commands use, and no
# timeout variant: fm_exec_timed must take its perl watchdog here.
PERL_ONLY="$TMP_ROOT/perl-only-bin"
mkdir -p "$PERL_ONLY"
for tool in perl bash sleep; do
  ln -s "$(command -v "$tool")" "$PERL_ONLY/$tool"
done

# exec_timed <path> <seconds> <grace> <command...>: source the library under
# the ordinary PATH, then run the bounded call under <path> as the last command
# of a subshell, exactly as a real caller does.
exec_timed() {
  local path=$1
  shift
  (
    . "$ROOT/bin/fm-timeout-lib.sh"
    PATH=$path fm_exec_timed "$@"
  )
}

RUN124="$TMP_ROOT/run124-bin"
mkdir -p "$RUN124"
printf '#!/bin/sh\nshift 3\n"$@"\nexit 124\n' > "$RUN124/timeout"
chmod +x "$RUN124/timeout"

run_timed() {
  (
    . "$ROOT/bin/fm-timeout-lib.sh"
    PATH="$RUN124:$PATH" fm_run_timed "$@"
  )
}

wait_for_file() {  # <path>
  local i=0
  while [ ! -s "$1" ]; do
    i=$((i + 1))
    [ "$i" -lt 500 ] || fail "timed out waiting for $1"
    sleep 0.02
  done
}

test_passes_the_command_status_and_output_through() {
  local out rc=0
  out=$(exec_timed "$PERL_ONLY" 5 1 bash -c 'echo to-stdout; echo to-stderr >&2; exit 7' 2>&1) || rc=$?
  [ "$rc" -eq 7 ] || fail "the watchdog did not pass the command's own status through (rc=$rc)"
  assert_contains "$out" "to-stdout" "the watchdog lost the command's stdout"
  assert_contains "$out" "to-stderr" "the watchdog lost the command's stderr"
  pass "fm_exec_timed passes a command's status and output through unchanged"
}

# Exercise the installed system Bash explicitly, including stock macOS 3.2:
# neither a top-level call nor a subshell may abort before starting its command.
# Unset BASHPID so newer system Bash also covers the missing-variable case.
test_system_bash_preserves_completion_and_signal_statuses() {
  local mode status command out rc
  for mode in top-level subshell; do
    for status in 0 7 137 143; do
      case "$status" in
        137) command='echo ran; kill -KILL $$' ;;
        143) command='echo ran; kill -TERM $$' ;;
        *) command="echo ran; exit $status" ;;
      esac
      rc=0
      out=$(PATH=$PERL_ONLY /bin/bash -c '
        . "$1/bin/fm-timeout-lib.sh"
        unset BASHPID
        if [ "$2" = subshell ]; then
          ( fm_exec_timed 5 1 bash -c "$3" )
        else
          fm_exec_timed 5 1 bash -c "$3"
        fi
      ' _ "$ROOT" "$mode" "$command" 2>&1) || rc=$?
      [ "$rc" -eq "$status" ] || fail "system Bash $mode lost command status $status (rc=$rc: $out)"
      [ "$out" = ran ] || fail "system Bash $mode did not run the command cleanly: $out"
    done
  done
  pass "system Bash top-level and subshell calls preserve success, failure, and signal status"
}

# A command that honors TERM ends at the bound, long before the grace would
# have forced it, and is gone afterwards.
test_term_ends_a_cooperative_command_at_the_bound() {
  local dir rc=0 started elapsed pid
  dir="$TMP_ROOT/term"
  mkdir -p "$dir"
  started=$SECONDS
  exec_timed "$PERL_ONLY" 1 30 bash -c 'echo $$ > "$1"; exec sleep 25' _ "$dir/pid" || rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 124 ] || fail "an expired bound did not report 124 (rc=$rc)"
  [ "$elapsed" -ge 1 ] || fail "the bound fired before it elapsed (${elapsed}s)"
  [ "$elapsed" -lt 15 ] || fail "a TERM-honoring command waited out the grace (${elapsed}s): TERM was not sent at the bound"
  pid=$(cat "$dir/pid")
  ! kill -0 "$pid" 2>/dev/null || fail "the bounded command outlived its bound"
  pass "fm_exec_timed sends TERM at the bound and a cooperative command ends there"
}

# A command that ignores TERM survives the bound and is killed only once the
# grace has passed, so the grace is what separates the two.
test_kill_ends_a_term_ignoring_command_after_the_grace() {
  local dir rc=0 started elapsed pid
  dir="$TMP_ROOT/kill"
  mkdir -p "$dir"
  started=$SECONDS
  exec_timed "$PERL_ONLY" 1 2 bash -c 'trap "" TERM; echo $$ > "$1"; exec sleep 25' _ "$dir/pid" || rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 124 ] || fail "a KILL-forced expiry did not report 124 (rc=$rc)"
  [ "$elapsed" -ge 3 ] || fail "a TERM-ignoring command ended before bound plus grace (${elapsed}s): the grace was skipped"
  [ "$elapsed" -lt 20 ] || fail "a TERM-ignoring command was not killed after the grace (${elapsed}s)"
  pid=$(cat "$dir/pid")
  ! kill -0 "$pid" 2>/dev/null || fail "the TERM-ignoring command survived the KILL"
  pass "fm_exec_timed kills a TERM-ignoring command once the grace has passed"
}

# The bounded command sits where the plain call sat: the calling subshell is
# replaced by the bounding process, whose child the command is. This holds for
# whichever mechanism the host selects, and for the perl watchdog explicitly.
test_the_bound_replaces_the_calling_shell() {
  local dir path caller parent
  dir="$TMP_ROOT/replace"
  mkdir -p "$dir"
  for path in "$PATH" "$PERL_ONLY"; do
    rm -f "$dir/caller" "$dir/parent"
    (
      . "$ROOT/bin/fm-timeout-lib.sh"
      perl -e 'print getppid(), "\n"' > "$dir/caller"
      PATH=$path fm_exec_timed 5 1 bash -c 'echo "$PPID" > "$1"' _ "$dir/parent"
    ) || fail "the bounded probe failed under PATH=$path"
    caller=$(cat "$dir/caller")
    parent=$(cat "$dir/parent")
    [ "$caller" = "$parent" ] \
      || fail "the command's parent $parent is not the replaced caller $caller under PATH=$path"
  done
  pass "fm_exec_timed replaces the calling shell instead of wrapping it"
}

# The regression a direct-child watchdog had: the command dies at the bound
# but a descendant that ignores TERM keeps the captured output open, so the
# caller waits for the descendant instead of the bound.
test_a_descendant_holding_the_output_cannot_outlast_the_bound() {
  local dir out rc=0 started elapsed pid
  dir="$TMP_ROOT/descendant"
  mkdir -p "$dir"
  started=$SECONDS
  # The positional parameter belongs to the bounded shell.
  # shellcheck disable=SC2016
  out=$(exec_timed "$PERL_ONLY" 1 30 bash -c '
    ( trap "" TERM; exec sleep 25 ) &
    echo $! > "$1"
    wait
  ' _ "$dir/pid") || rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 124 ] || fail "an expired bound did not report 124 (rc=$rc)"
  [ "$elapsed" -lt 15 ] \
    || fail "a TERM-ignoring descendant held the captured output for ${elapsed}s past a 1s bound"
  pid=$(cat "$dir/pid")
  ! kill -0 "$pid" 2>/dev/null || fail "the TERM-ignoring descendant survived the bound"
  pass "fm_exec_timed reaps a descendant that would otherwise hold the output past the bound"
}

# A TERM delivered to the bounding process itself - a harness tearing down a
# hook, an operator stopping the caller - reaches the command, and a command
# that then exits on its own reports its own status, not the bound's.
test_a_signal_to_the_bounding_process_reaches_the_command() {
  local dir watchdog rc=0
  dir="$TMP_ROOT/forward"
  mkdir -p "$dir"
  # Backgrounded directly, the subshell's pid is the watchdog it becomes.
  # The positional parameters belong to the bounded shell.
  # shellcheck disable=SC2016
  (
    . "$ROOT/bin/fm-timeout-lib.sh"
    PATH=$PERL_ONLY
    fm_exec_timed 60 30 bash -c '
      trap "echo forwarded > \"\$2\"; exit 3" TERM
      echo $$ > "$1"
      while :; do sleep 0.1; done
    ' _ "$dir/pid" "$dir/term"
  ) 2>/dev/null &
  watchdog=$!
  wait_for_file "$dir/pid"
  kill -TERM "$watchdog" || fail "could not signal the bounding process"
  wait "$watchdog" || rc=$?
  [ "$(cat "$dir/term" 2>/dev/null)" = forwarded ] || fail "the TERM never reached the bounded command"
  [ "$rc" -eq 3 ] || fail "a forwarded TERM did not report the command's own status (rc=$rc)"
  pass "fm_exec_timed forwards a TERM it receives to the bounded command"
}

# A caller that names its owner before launching the watchdog is watched even
# when that owner died while the watchdog was still starting: the watchdog's
# parent is then not the named owner, so the escalation starts at once rather
# than at the bound.
test_a_named_owner_that_is_gone_ends_the_command() {
  local dir gone rc=0 started elapsed pid
  dir="$TMP_ROOT/owner"
  mkdir -p "$dir"
  sleep 0 &
  gone=$!
  wait "$gone" 2>/dev/null || true
  started=$SECONDS
  (
    . "$ROOT/bin/fm-timeout-lib.sh"
    PATH=$PERL_ONLY FM_EXEC_TIMED_OWNER_PID=$gone \
      fm_exec_timed 60 1 bash -c 'echo $$ > "$1"; exec sleep 25' _ "$dir/pid"
  ) || rc=$?
  elapsed=$((SECONDS - started))
  [ "$elapsed" -lt 15 ] || fail "a watchdog whose named owner was gone ran to its bound (${elapsed}s)"
  [ "$rc" -ne 0 ] || fail "a command ended by its owner's death reported success"
  if [ -s "$dir/pid" ]; then
    pid=$(cat "$dir/pid")
    ! kill -0 "$pid" 2>/dev/null || fail "the bounded command outlived its named owner"
  fi
  pass "fm_exec_timed ends the command when its named owner is already gone"
}

# With no named owner the calling script is captured before the watchdog
# starts, so a script that dies while its subshell is still on the way into
# fm_exec_timed - the watchdog then starts already reparented - is still
# detected instead of leaving the command running to its bound.
test_an_owner_that_dies_during_startup_ends_the_command() {
  local dir watchdog started pid
  dir="$TMP_ROOT/startup-owner"
  mkdir -p "$dir"
  # shellcheck disable=SC2016
  PATH=$PERL_ONLY bash -c '
    . "$1/bin/fm-timeout-lib.sh"
    (
      perl -e "print getppid(), qq(\\n)" > "$2/watchdog"
      while kill -0 "$$" 2>/dev/null; do sleep 0.05; done
      fm_exec_timed 60 1 bash -c "echo \$\$ > \"\$1\"; exec sleep 25" _ "$2/pid"
    ) >/dev/null 2>&1 &
    exit 0
  ' _ "$ROOT" "$dir"
  wait_for_file "$dir/watchdog"
  watchdog=$(cat "$dir/watchdog")
  started=$SECONDS
  while kill -0 "$watchdog" 2>/dev/null; do
    if [ "$((SECONDS - started))" -ge 15 ]; then
      if [ -s "$dir/pid" ]; then
        pid=$(cat "$dir/pid")
        kill -KILL -- "-$pid" 2>/dev/null || true
      fi
      kill -KILL "$watchdog" 2>/dev/null || true
      fail "a watchdog whose owner died during startup ran on toward its bound"
    fi
    sleep 0.02
  done
  pass "fm_exec_timed ends the command when its owner dies during watchdog startup"
}

# A top-level calling shell has its own PID in $$, unlike a Bash subshell.
# Capture its parent before exec: that parent can exit while the top-level
# shell is still on its way into the watchdog.
test_a_top_level_parent_that_dies_during_startup_ends_the_command() {
  local dir watchdog started pid
  dir="$TMP_ROOT/top-level-parent"
  mkdir -p "$dir"
  PATH=$PERL_ONLY bash -c '
    bash -c '\''
      . "$1/bin/fm-timeout-lib.sh"
      echo "$$" > "$2/watchdog"
      while kill -0 "$PPID" 2>/dev/null; do sleep 0.05; done
      fm_exec_timed 60 1 bash -c "echo \$\$ > \"\$1\"; exec sleep 300" _ "$2/pid"
    '\'' _ "$1" "$2" >/dev/null 2>&1 &
    while [ ! -s "$2/watchdog" ]; do sleep 0.02; done
    exit 0
  ' _ "$ROOT" "$dir"
  wait_for_file "$dir/watchdog"
  watchdog=$(cat "$dir/watchdog")
  started=$SECONDS
  while kill -0 "$watchdog" 2>/dev/null; do
    if [ "$((SECONDS - started))" -ge 15 ]; then
      if [ -s "$dir/pid" ]; then
        pid=$(cat "$dir/pid")
        kill -KILL -- "-$pid" 2>/dev/null || true
      fi
      kill -KILL "$watchdog" 2>/dev/null || true
      fail "top-level watchdog lost its pre-exec parent and ran toward its bound"
    fi
    sleep 0.02
  done
  pass "fm_exec_timed preserves a top-level shell's parent across exec startup"
}

# perl is preferred whenever it exists, because only its watchdog can reap a
# leftover descendant after replacing the caller.
test_perl_is_preferred_over_timeout() {
  local dir out
  dir="$TMP_ROOT/prefer"
  mkdir -p "$dir/bin"
  for tool in perl bash; do
    ln -s "$(command -v "$tool")" "$dir/bin/$tool"
  done
  printf '#!/bin/sh\necho timeout-used > "%s"\nexit 99\n' "$dir/timeout-used" > "$dir/bin/timeout"
  chmod +x "$dir/bin/timeout"
  out=$(exec_timed "$dir/bin" 5 1 bash -c 'echo ran') || fail "the bounded call failed: $out"
  [ "$out" = ran ] || fail "the bounded call printed '$out'"
  [ ! -e "$dir/timeout-used" ] || fail "fm_exec_timed used timeout although perl was available"
  pass "fm_exec_timed prefers its perl watchdog over timeout"
}

test_refuses_rather_than_running_unbounded() {
  local dir out rc=0
  dir="$TMP_ROOT/unboundable"
  mkdir -p "$dir/bin"
  ln -s "$(command -v bash)" "$dir/bin/bash"
  out=$(exec_timed "$dir/bin" 5 1 bash -c ': > "$1"' _ "$dir/ran" 2>&1) || rc=$?
  [ "$rc" -eq 127 ] || fail "fm_exec_timed ran with nothing to bound it (rc=$rc)"
  assert_contains "$out" "cannot bound bash within 5s" "the refusal did not say what it could not bound"
  [ ! -e "$dir/ran" ] || fail "the command ran although nothing could bound it"
  pass "fm_exec_timed refuses instead of running unbounded when no mechanism exists"
}

test_rejects_malformed_bounds_before_running_anything() {
  local dir out rc
  dir="$TMP_ROOT/malformed"
  mkdir -p "$dir"
  for args in '0 1' '5 0' '05 1' '5 x' '' '5'; do
    rc=0
    # shellcheck disable=SC2086 # deliberate splitting of the bound pair
    out=$(exec_timed "$PERL_ONLY" $args bash -c ': > "$1"' _ "$dir/ran" 2>&1) || rc=$?
    [ "$rc" -eq 125 ] || fail "bounds '$args' were not rejected (rc=$rc: $out)"
    [ ! -e "$dir/ran" ] || fail "bounds '$args' still ran the command"
  done
  rc=0
  out=$(exec_timed "$PERL_ONLY" 5 1 2>&1) || rc=$?
  [ "$rc" -eq 125 ] || fail "a call with no command was not rejected (rc=$rc: $out)"
  assert_contains "$out" "usage: fm_exec_timed" "the rejection did not print the usage"
  pass "fm_exec_timed rejects a zero, padded, non-numeric, or missing bound and a missing command"
}

test_gnu_timeout_kills_a_term_ignoring_command_after_the_grace() {
  local dir fb rc=0 started elapsed verdict
  if ! command -v timeout >/dev/null 2>&1; then
    pass "fm_exec_timed's GNU timeout fallback (skipped: no timeout binary on this host)"
    return 0
  fi
  dir="$TMP_ROOT/gnu"
  fb="$dir/bin"
  mkdir -p "$fb"
  # No perl here, so the call falls back to GNU timeout.
  for tool in timeout bash sleep; do
    ln -s "$(command -v "$tool")" "$fb/$tool"
  done
  started=$SECONDS
  exec_timed "$fb" 1 2 bash -c 'trap "" TERM; exec sleep 25' || rc=$?
  elapsed=$((SECONDS - started))
  verdict=$( . "$ROOT/bin/fm-timeout-lib.sh"; fm_timed_out "$rc" && echo expired)
  [ "$verdict" = expired ] || fail "the GNU path's expiry status $rc is not a timed-out status"
  [ "$elapsed" -ge 3 ] || fail "the GNU path ended a TERM-ignoring command before bound plus grace (${elapsed}s)"
  [ "$elapsed" -lt 20 ] || fail "the GNU path did not kill a TERM-ignoring command after the grace (${elapsed}s)"
  pass "fm_exec_timed's GNU timeout fallback kills a TERM-ignoring command once the grace has passed"
}

test_timed_out_names_exactly_the_bound_statuses() {
  local status verdict
  for status in 124 137 0 1 125 127 143 ''; do
    verdict=$( . "$ROOT/bin/fm-timeout-lib.sh"; if fm_timed_out "$status"; then echo yes; else echo no; fi)
    case "$status" in
      124|137) [ "$verdict" = yes ] || fail "status '$status' was not read as the bound" ;;
      *) [ "$verdict" = no ] || fail "status '$status' was misread as the bound" ;;
    esac
  done
  pass "fm_timed_out accepts 124 and 137 and nothing else"
}

test_run_timed_reports_the_bound_when_the_wrapper_records_a_signal_death() {
  local rc=0
  run_timed 5 bash -c 'kill -TERM $$' || rc=$?
  [ "$rc" -eq 124 ] || fail "a bound-killed read leaked the signal death as its own status (rc=$rc)"
  pass 'fm_run_timed reports 124 when the bound TERMs a read whose wrapper recorded 143'
}

test_run_timed_passes_a_natural_exit_through_a_fired_bound() {
  local out rc=0
  out=$(run_timed 5 bash -c 'echo through') || rc=$?
  [ "$rc" -eq 0 ] || fail "a completed read lost its own status to the fired bound (rc=$rc)"
  [ "$out" = through ] || fail 'a completed read lost its output to the fired bound'
  pass 'fm_run_timed passes a natural exit through when the bound fired after completion'
}

# A busy host schedules a freshly forked child late. SlowPgrp.pm delays only the
# child's own setpgrp(0, 0), by longer than the bound, which is that lateness on
# demand: the bound then fires before the child has made its process group.
# With the parent creating the group too, the bound still reaches the child and
# it never gets to run; without it the TERM and KILL reach nothing and the
# command runs on, orphaned, in a group nothing will ever signal.
SLOW_PGRP="$TMP_ROOT/slow-pgrp-lib"
mkdir -p "$SLOW_PGRP"
cat > "$SLOW_PGRP/SlowPgrp.pm" <<'PM'
package SlowPgrp;
BEGIN {
  no warnings 'once';
  *CORE::GLOBAL::setpgrp = sub {
    select undef, undef, undef, 1.5 if @_ == 2 && $_[0] == 0;
    CORE::setpgrp($_[0], $_[1]);
  };
}
1;
PM

# A stub that records its pid and then blocks, capped at the suite's stub ceiling.
write_blocking_stub() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
fm_test_record_process "$FM_STUB_PIDFILE" || exit 1
while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 1; done
SH
  chmod +x "$1"
}

assert_stub_never_ran_or_is_gone() {  # <pidfile> <needle> <what>
  local i
  # Wait out the child's injected delay: a command the bound missed starts after it.
  sleep 2.5
  for i in 1 2 3 4 5 6 7 8 9 10; do
    fm_test_process_alive "$1" "$2" || return 0
    sleep 0.2
  done
  fail "$3 was left running after the bound fired"
}

test_run_timed_perl_bound_reaches_a_child_slow_to_start() {
  local dir rc=0 stub
  dir="$TMP_ROOT/slow-run-timed"
  mkdir -p "$dir"
  stub="$dir/stub"
  write_blocking_stub "$stub"
  fm_test_track_process "$dir/pid" "$stub"
  (
    . "$ROOT/bin/fm-timeout-lib.sh"
    PATH="$PERL_ONLY" PERL5LIB="$SLOW_PGRP" PERL5OPT=-MSlowPgrp FM_STUB_PIDFILE="$dir/pid" \
      fm_run_timed 1 "$stub"
  ) || rc=$?
  [ "$rc" -eq 124 ] || fail "the expired perl bound did not report 124 (rc=$rc)"
  assert_stub_never_ran_or_is_gone "$dir/pid" "$stub" "a command slow to start"
  pass "fm_run_timed's perl bound reaches a child that was slow to make its process group"
}

test_nm_bounded_perl_bound_reaches_a_child_slow_to_start() {
  local fixture rc=0 stub
  fixture="$TMP_ROOT/slow-nm-bounded"
  mkdir -p "$fixture/bin"
  stub="$fixture/bin/no-mistakes"
  write_blocking_stub "$stub"
  for tool in perl bash sleep; do
    ln -s "$(command -v "$tool")" "$fixture/bin/$tool"
  done
  fm_test_track_process "$fixture/pid" "$stub"
  (
    . "$ROOT/bin/fm-nm-run-lib.sh"
    PATH="$fixture/bin" PERL5LIB="$SLOW_PGRP" PERL5OPT=-MSlowPgrp FM_STUB_PIDFILE="$fixture/pid" \
      fm_nm_run_bounded "$fixture" 1 axi status
  ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 124 ] || fail "the expired no-mistakes bound did not report 124 (rc=$rc)"
  assert_stub_never_ran_or_is_gone "$fixture/pid" "$stub" "a no-mistakes call slow to start"
  pass "fm_nm_bounded's perl bound reaches a child that was slow to make its process group"
}

# The owner torn down by a TERM must not strand the bounded command in the process
# group of its own that it was put in: the bound forwards the signal and exits 143.
test_perl_bound_forwards_a_term_to_the_command() {
  local dir rc=0 stub owner bound i
  dir="$TMP_ROOT/term-forward"
  mkdir -p "$dir"
  stub="$dir/stub"
  write_blocking_stub "$stub"
  fm_test_track_process "$dir/pid" "$stub"
  (
    . "$ROOT/bin/fm-timeout-lib.sh"
    PATH="$PERL_ONLY" FM_STUB_PIDFILE="$dir/pid" fm_timeout_perl_bound 60 "$stub"
  ) &
  # shellcheck disable=SC2031 # This shell just launched the child; the sourced printf -v helper does not modify $!.
  owner=$!
  wait_for_file "$dir/pid"
  bound=$(pgrep -P "$owner" perl | head -1)
  [ -n "$bound" ] || fail "could not find the bounding process under its owner"
  kill -TERM "$bound"
  wait "$owner" || rc=$?
  [ "$rc" -eq 143 ] || fail "a TERMed bounding process did not report 143 (rc=$rc)"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    fm_test_process_alive "$dir/pid" "$stub" || break
    sleep 0.2
  done
  ! fm_test_process_alive "$dir/pid" "$stub" || fail "a TERMed bounding process left its command running"
  pass "the perl bound forwards a TERM to its command's group"
}

test_nested_perl_bound_reaps_a_term_resistant_child() {
  local dir stub out rc=0 started elapsed i
  dir="$TMP_ROOT/nested-bound"
  mkdir -p "$dir"
  stub="$dir/stub"
  cat > "$dir/SlowStop.pm" <<'PM'
package SlowStop;
BEGIN {
  no warnings 'once';
  *CORE::GLOBAL::select = sub {
    my $delay = $_[3];
    $delay = 0.8 if $ENV{FM_TEST_SLOW_STOP} && defined($delay) && $delay == 0.2;
    CORE::select($_[0], $_[1], $_[2], $delay);
  };
}
1;
PM
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
trap "" TERM
fm_test_record_process "$FM_STUB_PIDFILE" || exit 1
echo nested-child-started
while [ "$SECONDS" -lt 6 ]; do sleep 0.1; done
SH
  chmod +x "$stub"
  fm_test_track_process "$dir/pid" "$stub"
  started=$SECONDS
  out=$(
    . "$ROOT/bin/fm-timeout-lib.sh"
    PATH="$PERL_ONLY" PERL5LIB="$dir" PERL5OPT=-MSlowStop FM_STUB_PIDFILE="$dir/pid" \
      fm_run_timed 1 bash -c '
        . "$1/bin/fm-nm-run-lib.sh"
        FM_TEST_SLOW_STOP=1 fm_nm_bounded "$2" 30 "$3"
      ' _ "$ROOT" "$dir" "$stub"
  ) || rc=$?
  elapsed=$((SECONDS - started))
  [ "$rc" -eq 124 ] || fail "the outer nested bound did not report 124 (rc=$rc)"
  assert_contains "$out" nested-child-started "the nested command never started"
  [ "$elapsed" -lt 5 ] || fail "the nested command held stdout after the outer bound (${elapsed}s)"
  for i in 1 2 3 4 5 6 7 8 9 10; do
    fm_test_process_alive "$dir/pid" "$stub" || break
    sleep 0.1
  done
  ! fm_test_process_alive "$dir/pid" "$stub" || fail "the outer bound left its nested command running"
  pass "an outer Perl bound reaps a TERM-resistant nested command"
}

# fm_run_timed keeps the bounded command's status in a temp file. A caller that
# was interrupted while waiting used to leave that file behind, one per call
# (2394 fm-timeout-status.* entries piled up in a shared temp dir, and the bash
# fallback left fm-bash-timeout-command.* the same way). Every exit, normal or
# not, must leave the temp dir empty, for the external-timeout and bash mechanisms.
status_leak_call() {  # <dir> <bin-dir> <mechanism> <seconds> <command...>
  local dir=$1 bindir=$2 mech=$3 seconds=$4
  shift 4
  TMPDIR="$dir/tmp" bash -c '
    . "$1/bin/fm-timeout-lib.sh"
    PATH="$2:$PATH"
    [ "$3" != bash ] || export FM_TIMEOUT_MECHANISM_OVERRIDE=bash
    shift 3
    fm_run_timed "$@"
  ' _ "$ROOT" "$bindir" "$mech" "$seconds" "$@" >/dev/null 2>&1
}

test_no_status_file_survives_any_exit_of_the_caller() {
  local dir sig caller_pid command_pid mech rc
  dir="$TMP_ROOT/status-leak"
  mkdir -p "$dir/tmp" "$dir/bin" "$dir/fired-bin"
  printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$dir/bin/timeout"
  printf '#!/bin/sh\nshift 3\n"$@"\nexit 124\n' > "$dir/fired-bin/timeout"
  chmod +x "$dir/bin/timeout" "$dir/fired-bin/timeout"
  cat > "$dir/caller.sh" <<'SH'
. "$1/bin/fm-timeout-lib.sh"
PATH="$2:$PATH"
[ "$4" != bash ] || export FM_TIMEOUT_MECHANISM_OVERRIDE=bash
fm_run_timed 20 bash -c 'printf "%s\n" "$$" > "$1"; exec sleep 60' _ "$3"
SH
  for mech in timeout bash; do
    rc=0
    status_leak_call "$dir" "$dir/bin" "$mech" 20 true || rc=$?
    [ "$rc" -eq 0 ] || fail "$mech: a completed bounded call reported $rc"
    [ -z "$(ls -A "$dir/tmp")" ] || fail "$mech: a completed bounded call left a status file: $(ls -A "$dir/tmp")"
    rc=0
    status_leak_call "$dir" "$dir/bin" "$mech" 20 bash -c 'exit 3' || rc=$?
    [ "$rc" -eq 3 ] || fail "$mech: a failing bounded call reported $rc, not its own status 3"
    [ -z "$(ls -A "$dir/tmp")" ] || fail "$mech: a failing bounded call left a status file: $(ls -A "$dir/tmp")"
    # The external mechanism needs a timeout that applies the bound; the bash
    # mechanism enforces a real one-second bound on a command that outlasts it.
    rc=0
    if [ "$mech" = bash ]; then
      status_leak_call "$dir" "$dir/bin" bash 1 sleep 30 || rc=$?
    else
      status_leak_call "$dir" "$dir/fired-bin" timeout 1 bash -c 'exit 143' || rc=$?
    fi
    [ "$rc" -eq 124 ] || fail "$mech: a bound that fired reported $rc, not 124"
    [ -z "$(ls -A "$dir/tmp")" ] || fail "$mech: a bound that fired left a status file: $(ls -A "$dir/tmp")"
  done
  for mech in timeout bash; do
    for sig in TERM INT HUP KILL; do
      rm -f "$dir/command.pid"
      # perl restores SIGINT, which a shell's background job otherwise ignores.
      TMPDIR="$dir/tmp" perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' \
        bash "$dir/caller.sh" "$ROOT" "$dir/bin" "$dir/command.pid" "$mech" >/dev/null 2>&1 &
      # shellcheck disable=SC2031 # This shell just launched the caller; no subshell modifies $! here.
      caller_pid=$!
      wait_for_file "$dir/command.pid"
      command_pid=$(cat "$dir/command.pid")
      kill -"$sig" "$caller_pid" 2>/dev/null || true
      wait "$caller_pid" 2>/dev/null || true
      kill -KILL "$command_pid" 2>/dev/null || true
      [ -z "$(ls -A "$dir/tmp")" ] || fail "$mech: a caller ended by $sig left a status file: $(ls -A "$dir/tmp")"
    done
  done
  pass "no bounded-call status file survives a normal, failing, timed-out, or signalled exit of the caller"
}

test_passes_the_command_status_and_output_through
test_system_bash_preserves_completion_and_signal_statuses
test_run_timed_reports_the_bound_when_the_wrapper_records_a_signal_death
test_run_timed_passes_a_natural_exit_through_a_fired_bound
test_term_ends_a_cooperative_command_at_the_bound
test_kill_ends_a_term_ignoring_command_after_the_grace
test_the_bound_replaces_the_calling_shell
test_a_descendant_holding_the_output_cannot_outlast_the_bound
test_a_signal_to_the_bounding_process_reaches_the_command
test_a_named_owner_that_is_gone_ends_the_command
test_an_owner_that_dies_during_startup_ends_the_command
test_a_top_level_parent_that_dies_during_startup_ends_the_command
test_perl_is_preferred_over_timeout
test_refuses_rather_than_running_unbounded
test_rejects_malformed_bounds_before_running_anything
test_gnu_timeout_kills_a_term_ignoring_command_after_the_grace
test_timed_out_names_exactly_the_bound_statuses
test_run_timed_perl_bound_reaches_a_child_slow_to_start
test_nm_bounded_perl_bound_reaches_a_child_slow_to_start
test_perl_bound_forwards_a_term_to_the_command
test_nested_perl_bound_reaps_a_term_resistant_child
test_no_status_file_survives_any_exit_of_the_caller

# Cache-hit wall times must never calibrate a subsequent cold miss.
# This new case exercises the real lint/cache/runner boundary with isolated
# tools; all completion waits use protocol sentinels, not deadlines.
export FM_CACHE_DURATION_ROOT="$ROOT" FM_CACHE_DURATION_TMP="$TMP_ROOT"
"$ROOT/bin/fm-proc-budget.sh" -- python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root = Path(os.environ['FM_CACHE_DURATION_ROOT'])
fixture = Path(os.environ['FM_CACHE_DURATION_TMP']) / 'cold-calibration'
repo = fixture / 'repo'
(repo / 'bin').mkdir(parents=True)
(repo / 'tests').mkdir()
(repo / 'bin/backends').mkdir()
for name in ('fm-lint.sh', 'fm-lint-cache.pl', 'fm-timeout-lib.sh', 'fm-duration-lib.sh', 'fm-duration.py'):
    shutil.copyfile(root / 'bin' / name, repo / 'bin' / name)
(repo / 'bin/fm-lint-workflows.sh').write_text('#!/bin/bash\nexit 0\n')
(repo / 'bin/consumer.sh').write_text('#!/bin/bash\nprintf cold\n')
for path in (repo / 'bin').glob('*.sh'):
    path.chmod(0o755)
fakebin = fixture / 'tools'
fakebin.mkdir()
(fakebin / 'shellcheck').write_text('''#!/bin/bash
if [ "${1:-}" = --version ]; then printf 'version: 0.11.0\\n'; exit 0; fi
printf 'analyzed\\n' >> "$FM_CACHE_ANALYSES"
if [ "${FM_CACHE_HOLD:-0}" = 1 ]; then
  printf 'started\\n' > "$FM_CACHE_HANDSHAKE"
  IFS= read -r release < "$FM_CACHE_RELEASE"
fi
exit 0
''')
(fakebin / 'shellcheck').chmod(0o755)
subprocess.run(['git', 'init', '-q', '-b', 'main', str(repo)], check=True)
subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'cold baseline'], check=True)
ledger = fixture / 'durations.jsonl'
analyses = fixture / 'analyses'
env = dict(os.environ, PATH=str(fakebin) + os.pathsep + os.environ['PATH'],
           FM_HOME=str(fixture), FM_DATA_OVERRIDE=str(fixture / 'data'),
           FM_CONFIG_OVERRIDE=str(fixture / 'config'), FM_STATE_OVERRIDE=str(fixture / 'state'),
           FM_DURATION_FILE=str(ledger), FM_LINT_CACHE_DIR=str(fixture / 'cache'),
           FM_LINT_SLOT_DIR='off', FM_LINT_TELEMETRY='off', FM_CACHE_ANALYSES=str(analyses),
           CI='false', GITHUB_ACTIONS='false')
helper = repo / 'bin/fm-duration.py'
command = [sys.executable, str(helper), 'run', 'lint.full.whole', '--', 'bash', str(repo / 'bin/fm-lint.sh'), '--jobs', '1']
for index in range(3):
    result = subprocess.run(command, cwd=repo, env=env, capture_output=True, text=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    if index == 0:
        analyzed_count = len(analyses.read_text().splitlines())
    else:
        assert len(analyses.read_text().splitlines()) == analyzed_count, 'warm analysis unexpectedly executed ShellCheck'
rows = [json.loads(line) for line in ledger.read_text().splitlines()]
warm = [row for row in rows if row.get('exit') == 0 and row.get('calibration') is False]
assert any(row['key'] == 'lint-root.full.bin/consumer.sh' for row in warm)
assert any(row['key'] == 'lint.full.whole' for row in warm), 'outer runner lost cache classification'
# Remove the cold seed and replay ONLY actual warm observations in both
# independent load-regime fixtures. Neither p99 may infer a cold ceiling.
with ledger.open('w') as output:
    for row in warm:
        for regime in ('idle', 'loaded'):
            output.write(json.dumps(dict(row, regime=regime)) + '\n')
for key in ('lint-root.full.bin/consumer.sh', 'lint.full.whole'):
    result = subprocess.run([sys.executable, str(helper), 'limit', key, '--percentile', '99'], env=env, capture_output=True, text=True, check=True)
    assert result.stdout.strip() == '0' and 'missing idle, loaded' in result.stderr, result
(repo / 'bin/consumer.sh').write_text('#!/bin/bash\nprintf changed-cold\n')
handshake, release = fixture / 'handshake', fixture / 'release'
os.mkfifo(handshake); os.mkfifo(release)
cold_env = dict(env, FM_CACHE_HOLD='1', FM_CACHE_HANDSHAKE=str(handshake), FM_CACHE_RELEASE=str(release))
job = subprocess.Popen(command, cwd=repo, env=cold_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
with handshake.open() as incoming:
    assert incoming.readline() == 'started\n'
assert job.poll() is None, 'the warm cache killed the cold miss'
with release.open('w') as outgoing:
    outgoing.write('complete\n')
out, err = job.communicate()
assert job.returncode == 0, (out, err)
new_rows = [json.loads(line) for line in ledger.read_text().splitlines()]
assert any(row.get('key') == 'lint-root.full.bin/consumer.sh' and row.get('calibration') is True and row.get('exit') == 0 for row in new_rows)
assert len(analyses.read_text().splitlines()) == analyzed_count + 1
print('ok - warm hits in both load regimes leave cold root and outer ceilings uncalibrated; changed cold analysis completes')
PY

