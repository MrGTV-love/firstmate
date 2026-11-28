#!/usr/bin/env bash
# Post-close cleanup for bin/fm-teardown.sh: leaked processes and the bounded
# reap, foreign and held copies with their closeout driver, private no-mistakes
# launch agents, Docker stacks and their retained records, Herdr projection
# journals, and secondmate delivery and retirement.
# The landed-work proof matrix lives in tests/fm-teardown.test.sh; pool slots
# and returns live in tests/fm-teardown-pool.test.sh. Shared fixtures:
# tests/fm-teardown-helpers.sh.
# Usage: bash tests/fm-teardown-docker.test.sh [test_function_name ...]

set -u

# shellcheck source=tests/fm-teardown-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-teardown-helpers.sh"

test_leaked_tasktmp_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-tasktmp-reap)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/tasktmp"
  land_shippable_commit "$case_dir"

  teardown_fixture_start "$case_dir/tasktmp" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-tasktmp-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-tasktmp-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    teardown_fixture_stop "$pid"
    fail "leaked-tasktmp-reap: leaked tasktmp process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-tasktmp-reap: teardown did not report reaping the leaked tasktmp process"
  pass "a leaked descendant process rooted under the task's per-task tasktmp is reaped by teardown too"
}

test_lsof_absent_refuses_without_signalling() {
  local case_dir rc pid path_without_lsof survived=0
  case_dir=$(make_case lsof-absent-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
    && fail "lsof-absent-refusal: fixture path unexpectedly exposes lsof"

  teardown_fixture_start "$case_dir/wt" KILL perl -e 'setpgrp(0, 0); exec "sleep", "300"'
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "lsof-absent-refusal: setup sleeper did not start"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ] && [ "\${*: -1}" = '#{pane_pid}' ]; then
  printf '%s\n' '$pid'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/tmux"

  rc=0
  FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill -0 "$pid" 2>/dev/null && survived=1
  teardown_fixture_stop "$pid"

  expect_code 1 "$rc" "lsof-absent-refusal: teardown should refuse even with force"
  [ "$survived" -eq 1 ] || fail "lsof-absent-refusal: an unaudited signal reached the pane process group"
  assert_grep "(lsof is unavailable, so no signal target can be audited)" "$case_dir/stderr" \
    "lsof-absent-refusal: teardown did not explain the missing-lsof refusal"
  assert_present "$case_dir/wt" "lsof-absent-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-absent-refusal: teardown removed task metadata"
  assert_absent "$case_dir/state/task-x1.teardown-processes" \
    "lsof-absent-refusal: an unscanned process was recorded as a signal target"
  pass "missing lsof refuses teardown instead of sending unaudited process-group signals"
}

test_lsof_error_refuses_before_removal() {
  local case_dir rc
  case_dir=$(make_case lsof-error-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-error-refusal: teardown should refuse"
  assert_grep "REFUSED: cannot determine leaked processes under $case_dir/wt for task-x1 (lsof failed)" "$case_dir/stderr" \
    "lsof-error-refusal: teardown did not explain the lsof refusal"
  assert_present "$case_dir/wt" "lsof-error-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-error-refusal: teardown removed task metadata"
  assert_absent "$case_dir/treehouse.log" "lsof-error-refusal: teardown returned the worktree"
  pass "an erroring lsof scan refuses teardown and preserves the task"
}

test_reused_pid_identity_is_not_force_killed() {
  local case_dir rc pid
  case_dir=$(make_case reused-pid-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  teardown_fixture_start "$case_dir" KILL perl -e "$(cat <<'PERL'
$SIG{TERM} = "IGNORE"; sleep 300
PERL
  )"
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.2
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f '$case_dir/lsof-count' ] || count=\$(cat '$case_dir/lsof-count')
count=\$((count + 1))
printf '%s\n' "\$count" > '$case_dir/lsof-count'
if [ "\$count" -le 3 ]; then printf 'p%s\nfcwd\nn%s\n' '$pid' '$case_dir/wt'; fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_REUSED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  count=0
  [ ! -f "$FM_FAKE_PS_COUNT" ] || count=$(cat "$FM_FAKE_PS_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_PS_COUNT"
  if [ "$count" -le 4 ]; then printf 'Tue Aug  4 10:00:00 2026\n'
  else printf 'Tue Aug  4 10:00:01 2026\n'; fi
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_REUSED_PID="$pid" FM_FAKE_PS_COUNT="$case_dir/ps-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "reused-pid-identity: teardown should skip the replacement process"
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "reused-pid-identity: teardown force-killed a process whose start time changed"
  fi
  teardown_fixture_stop "$pid"
  assert_grep $'\tTERM\t'"$pid"$'\t' "$case_dir/state/task-x1.teardown-processes" \
    "reused-pid-identity: the original identity was not sent TERM before the grace period"
  assert_no_grep $'\tKILL\t' "$case_dir/state/task-x1.teardown-processes" \
    "reused-pid-identity: a KILL was audited for a changed identity"
  pass "a reused pid with a different start time is never force-killed"
}

test_exec_changed_process_is_still_reaped() {
  local case_dir rc pid marker done_flag survived=0
  case_dir=$(make_case exec-changed-process)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  marker="$case_dir/exec-now"
  done_flag="$case_dir/exec-done"

  teardown_fixture_start "$case_dir/wt" KILL perl -e "$(cat <<'PERL'
      my ($marker, $done) = @ARGV;
      until (-e $marker) { select undef, undef, undef, 0.01; }
      open my $fh, ">", $done or die "open";
      close $fh;
      exec "perl", "-e", '$SIG{TERM} = "IGNORE"; sleep 300';
PERL
    )" "$marker" "$done_flag"
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.2
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXEC_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  out=$("$REAL_PS_FOR_TEST" "$@") || exit $?
  [ -e "$FM_FAKE_EXEC_MARKER" ] || : > "$FM_FAKE_EXEC_MARKER"
  printf '%s\n' "$out"
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_FAKE_LSOF_COUNT" ] || count=$(cat "$FM_FAKE_LSOF_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_LSOF_COUNT"
if [ "$count" -eq 2 ]; then
  i=0
  while [ "$i" -lt 100 ]; do
    [ ! -e "$FM_FAKE_EXEC_DONE" ] || break
    sleep 0.01
    i=$((i + 1))
  done
fi
exec "$REAL_LSOF_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/lsof"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_EXEC_PID="$pid" FM_FAKE_EXEC_MARKER="$marker" \
  FM_FAKE_EXEC_DONE="$done_flag" FM_FAKE_LSOF_COUNT="$case_dir/lsof-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    teardown_fixture_stop "$pid"
  fi
  expect_code 0 "$rc" "exec-changed-process: teardown should succeed"
  [ "$survived" -eq 0 ] || fail "exec-changed-process: exec-changed leaked process survived teardown"
  pass "an exec change preserves birth identity and the process is reaped"
}

test_process_spawned_during_grace_is_reaped_on_later_pass() {
  local case_dir rc pid child_file child_pid="" parent_survived=0 child_survived=0
  case_dir=$(make_case grace-spawn-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  child_file="$case_dir/child.pid"

  teardown_fixture_start "$case_dir/wt" HUP perl -e "$(cat <<'PERL'
      use POSIX qw(SIG_BLOCK SIG_SETMASK SIGTERM SIGHUP SIGINT SIGQUIT);
      require $ENV{FM_TEARDOWN_FIXTURE_HELPERS};
      my ($file, $ready) = @ARGV;
      my ($child, $leave_child);
      END {
        if (defined $child && $child > 0 && !$leave_child) {
          kill "KILL", $child;
          waitpid($child, 0);
        }
      }
      $SIG{HUP} = sub {
        exit 0;
      };
      $SIG{TERM} = sub {
        return if defined $child;
        my $old = POSIX::SigSet->new;
        my $blocked = POSIX::SigSet->new(SIGTERM, SIGHUP, SIGINT, SIGQUIT);
        POSIX::sigprocmask(SIG_BLOCK, $blocked, $old) or die "block signals";
        $child = fork();
        die "fork" unless defined $child;
        if (!$child) {
          $SIG{TERM} = $SIG{HUP} = $SIG{INT} = $SIG{QUIT} = "DEFAULT";
          POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
          exec "sleep", "300"; die "exec";
        }
        fixture_track($child);
        open my $fh, ">", $file or die "open";
        print {$fh} "$child\n";
        close $fh or die "close";
        POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
        $leave_child = 1;
        exit 0;
      };
      open my $fh, ">", $ready or die "ready"; close $fh;
      sleep 300;
PERL
    )" "$child_file" "$case_dir/ready"
  pid=$TEARDOWN_FIXTURE_PID
  local i=0
  while [ ! -e "$case_dir/ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$case_dir/ready" ] || fail "grace-spawn-convergence: parent not ready"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if [ -f "$child_file" ]; then child_pid=$(cat "$child_file"); fi
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    child_survived=1
    teardown_fixture_stop "$child_pid"
  fi
  if kill -0 "$pid" 2>/dev/null; then
    parent_survived=1
    teardown_fixture_stop "$pid"
  fi
  expect_code 0 "$rc" "grace-spawn-convergence: teardown should converge"
  assert_present "$child_file" "grace-spawn-convergence: TERM handler did not spawn a child"
  [ "$child_survived" -eq 0 ] || fail "grace-spawn-convergence: spawned child survived"
  [ "$parent_survived" -eq 0 ] || fail "grace-spawn-convergence: original process survived"
  pass "a process spawned during grace is reaped on a later pass"
}

test_persistent_scan_refuses_after_bounded_retries() {
  local case_dir rc spawner i=0
  case_dir=$(make_case persistent-reap-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  # A real parent outside the task roots immediately replenishes leaked children.
  # Each killed child has a distinct kernel birth identity and a real cwd.
  teardown_fixture_start "$case_dir" TERM perl -e "$(cat <<'PERL'
    use POSIX qw(SIG_BLOCK SIG_SETMASK SIGTERM SIGINT SIGHUP SIGQUIT WNOHANG);
    require $ENV{FM_TEARDOWN_FIXTURE_HELPERS};
    my ($root, $ready) = @ARGV;
    my ($child, $stopping);
    my $owner = $$;
    my $blocked = POSIX::SigSet->new(SIGTERM, SIGINT, SIGHUP, SIGQUIT);
    $SIG{TERM} = $SIG{INT} = $SIG{HUP} = $SIG{QUIT} = sub { $stopping = 1; };
    END {
      if ($owner == $$) {
        kill "KILL", $child if defined $child;
        waitpid($child, 0) if defined $child;
        unlink $ready;
      }
    }
    while (!$stopping) {
      my $old = POSIX::SigSet->new;
      POSIX::sigprocmask(SIG_BLOCK, $blocked, $old) or die "block signals";
      $child = fork(); defined $child or die "fork";
      if (!$child) {
        $SIG{TERM} = $SIG{INT} = $SIG{HUP} = $SIG{QUIT} = "DEFAULT";
        POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
        chdir $root or die "chdir";
        my $birth = fixture_track($$);
        open my $fh, ">", "$ready.$$" or die "ready";
        print {$fh} "$$\t$birth\n";
        close $fh or die "close readiness";
        rename "$ready.$$", $ready or die "publish readiness";
        exec "sleep", "300"; die "exec";
      }
      fixture_track($child);
      POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
      while (!$stopping && defined $child) {
        POSIX::sigprocmask(SIG_BLOCK, $blocked, $old) or die "block signals";
        my $exited = waitpid($child, WNOHANG);
        undef $child if $exited != 0;
        POSIX::sigprocmask(SIG_SETMASK, $old) or die "restore signals";
        select undef, undef, undef, 0.01 if defined $child && !$stopping;
      }
      unlink $ready;
    }
PERL
  )" "$case_dir/wt" "$case_dir/child-ready"
  spawner=$TEARDOWN_FIXTURE_PID
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
for ((i=0; i<1000; i++)); do
  if IFS=$'\t' read -r pid birth < "$FM_FAKE_CHILD_READY" 2>/dev/null \
     && teardown_fixture_live "$pid" "$birth"; then
    exec "$REAL_LSOF_FOR_TEST" "$@"
  fi
  sleep 0.01
done
printf 'fixture child never became ready\n' >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
  while [ ! -s "$case_dir/child-ready" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$case_dir/child-ready" ] || fail "persistent-reap-refusal: child not ready"
  rc=0
  FM_FAKE_CHILD_READY="$case_dir/child-ready" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  teardown_fixture_stop "$spawner"

  expect_code 1 "$rc" "persistent-reap-refusal: teardown should refuse"
  assert_grep "remain after 3 reap attempts" "$case_dir/stderr" \
    "persistent-reap-refusal: teardown did not report bounded non-convergence"
  assert_present "$case_dir/wt" "persistent-reap-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "persistent-reap-refusal: teardown removed task metadata"
  pass "persistent leaked processes refuse teardown after bounded retries"
}

test_process_exit_during_identity_lookup_does_not_refuse() {
  local case_dir rc wt_path fake_pid=99999998
  case_dir=$(make_case identity-exit-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f "$case_dir/lsof-count" ] || count=\$(cat "$case_dir/lsof-count")
count=\$((count + 1))
printf '%s\n' "\$count" > "$case_dir/lsof-count"
if [ "\$count" -eq 1 ]; then
  printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXITED_PID:-}" ]; then
  exit 1
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'returned\n' > "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_EXITED_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "identity-exit-convergence: teardown should succeed"
  assert_present "$case_dir/treehouse.log" \
    "identity-exit-convergence: teardown did not reach worktree return"
  ! grep -q REFUSED "$case_dir/stderr" || \
    fail "identity-exit-convergence: a disappeared process caused teardown refusal"
  pass "a process exiting during identity lookup does not block teardown"
}

test_run_abort_precedes_process_reap_precedes_worktree_removal() {
  local case_dir rc head pid abort_log
  case_dir=$(make_case abort-then-reap-then-remove-order)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  abort_log="$case_dir/nm-abort.log"

  teardown_fixture_start "$case_dir/wt" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "abort-then-reap-then-remove-order: setup sleeper did not start"

  # A treehouse fake that snapshots, at the exact moment the destructive
  # worktree return runs, whether the run was already aborted and whether the
  # leaked process was already reaped - direct causal proof of ordering from
  # real observed state, not a source-text or line-number correlation.
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ -s "$abort_log" ]; then echo "abort-already-happened" >> "$case_dir/order.log"; fi
if ! kill -0 $pid 2>/dev/null; then echo "reap-already-happened" >> "$case_dir/order.log"; fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$abort_log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "abort-then-reap-then-remove-order: teardown should still succeed"
  teardown_fixture_stop "$pid"

  assert_present "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the destructive worktree return was never invoked"
  assert_grep "abort-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the run was not yet aborted when the worktree return ran"
  assert_grep "reap-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the leaked process was not yet reaped when the worktree return ran"
  pass "the run abort and the leaked-process reap both complete before the destructive worktree return"
}

# The incident: a worker's private no-mistakes home ran as a launchd agent whose
# daemon held a directory inside the task copy. Without a retire step, teardown
# found a process it could not prove custody of and refused (and a plain kill is
# undone by launchd KeepAlive).
test_private_nm_launch_agent_is_retired_before_teardown() {
  local case_dir rc pid label shared_state
  case_dir=$(make_case private-nm-agent)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  add_fake_launchctl "$case_dir"
  shared_state="$case_dir/shared-daemon-state"
  printf '%s\n' running > "$shared_state"
  FM_FAKE_NM_SHARED_DAEMON_STATE="$shared_state" "$case_dir/fakebin/no-mistakes" daemon stop
  [ "$(cat "$shared_state")" = stopped ] || fail "private-nm-agent: fake daemon stop did not stop the shared daemon"
  printf '%s\n' running > "$shared_state"
  mkdir -p "$case_dir/wt/.no-mistakes/h"
  teardown_fixture_start "$case_dir/wt/.no-mistakes/h" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "private-nm-agent: setup daemon did not start"
  label="$NM_AGENT_PREFIX.3baa54c9"
  add_nm_launch_agent "$case_dir" 3baa54c9 "$(cd "$case_dir/wt" && pwd -P)/.no-mistakes/h" "$pid"

  rc=0
  FM_FAKE_NM_SHARED_DAEMON_STATE="$shared_state" FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if kill -0 "$pid" 2>/dev/null; then
    teardown_fixture_stop "$pid"
    fail "private-nm-agent: the private daemon survived teardown"
  fi
  expect_code 0 "$rc" "private-nm-agent: teardown must finish once the agent is retired"
  assert_grep "bootout gui/$(id -u)/$label" "$case_dir/launchctl-calls" \
    "private-nm-agent: teardown did not boot the agent out of the user domain"
  assert_absent "$case_dir/launchagents/$label.plist" \
    "private-nm-agent: the plist is still installed, so the agent returns at next login"
  assert_present "$case_dir/data/task-x1/launchagent-backup/$label.plist" \
    "private-nm-agent: the plist was not archived under the task's data"
  assert_grep "retired task-private no-mistakes launch agent $label" "$case_dir/stderr" \
    "private-nm-agent: teardown did not report the retired agent"
  [ "$(cat "$shared_state")" = running ] || fail "private-nm-agent: teardown stopped the shared daemon"
  pass "a no-mistakes launch agent rooted in the task's copy is booted out and archived, then teardown finishes"
}

test_private_nm_launch_agent_equivalent_roots_are_retired() {
  local spelling case_dir wt root pid label rc
  for spelling in dot separators parent symlink; do
    case_dir=$(make_case "private-nm-agent-$spelling")
    write_meta "$case_dir" no-mistakes ship
    land_shippable_commit "$case_dir"
    add_fake_launchctl "$case_dir"
    wt=$(cd "$case_dir/wt" && pwd -P)
    mkdir -p "$wt/.no-mistakes/h" "$wt/.no-mistakes/staging"
    ln -s "$wt/.no-mistakes/h" "$case_dir/private-home"
    case "$spelling" in
      dot) root="$wt/./.no-mistakes/h" ;;
      separators) root="$wt//.no-mistakes//h/" ;;
      parent) root="$wt/.no-mistakes/staging/../h" ;;
      symlink) root="$case_dir/private-home" ;;
    esac
    teardown_fixture_start "$wt/.no-mistakes/h" KILL sleep 300
    pid=$TEARDOWN_FIXTURE_PID
    label="$NM_AGENT_PREFIX.3baa54c9"
    add_nm_launch_agent "$case_dir" 3baa54c9 "$root" "$pid"

    rc=0
    FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    if kill -0 "$pid" 2>/dev/null; then
      teardown_fixture_stop "$pid"
      fail "private-nm-agent-$spelling: the private daemon survived teardown"
    fi
    expect_code 0 "$rc" "private-nm-agent-$spelling: teardown must finish"
    assert_absent "$case_dir/launchctl-loaded/$label" \
      "private-nm-agent-$spelling: the agent is still loaded"
    assert_absent "$case_dir/launchagents/$label.plist" \
      "private-nm-agent-$spelling: the plist is still installed"
    assert_present "$case_dir/data/task-x1/launchagent-backup/$label.plist" \
      "private-nm-agent-$spelling: the plist was not archived"
    assert_absent "$case_dir/state/task-x1.meta" \
      "private-nm-agent-$spelling: the task record survived teardown"
  done
  pass "equivalent private roots unload their agents and allow teardown to finish"
}

test_nested_nm_launch_agents_are_left_alone() {
  local registrar damage case_dir registry nested lane pid label rc hash
  for registrar in project sibling; do
    for damage in none no-git deleted; do
      case_dir=$(make_case "nested-nm-agent-$registrar-$damage")
      write_meta "$case_dir" no-mistakes ship
      land_shippable_commit "$case_dir"
      add_fake_launchctl "$case_dir"
      registry="$case_dir/project"
      if [ "$registrar" = sibling ]; then
        registry="$case_dir/sibling-clone"
        git clone -q "$case_dir/origin.git" "$registry"
      fi
      nested="$case_dir/wt/other-lane"
      git -C "$registry" worktree add -q --detach "$nested" main
      git -C "$registry" worktree lock "$nested"
      lane=$(cd "$nested" && pwd -P)
      fm_write_meta "$case_dir/state/other-lane.meta" "worktree=$lane" "project=$registry" "kind=ship"
      mkdir -p "$lane/.no-mistakes/h"
      ln -s "$lane/.no-mistakes/h" "$case_dir/lane-home"
      teardown_fixture_start "$lane/.no-mistakes/h" KILL sleep 300
      pid=$TEARDOWN_FIXTURE_PID
      add_nm_launch_agent "$case_dir" 00000001 "$lane/./.no-mistakes//h" "$pid"
      add_nm_launch_agent "$case_dir" 00000002 "$lane/.no-mistakes/missing/../h"
      add_nm_launch_agent "$case_dir" 00000003 "$case_dir/lane-home"
      case "$damage" in
        no-git) rm -f "$nested/.git" ;;
        deleted) rm -rf "$nested" ;;
      esac

      rc=0
      FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
        run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      if ! kill -0 "$pid" 2>/dev/null; then
        fail "nested-nm-agent-$registrar-$damage: another lane's daemon was killed"
      fi
      teardown_fixture_stop "$pid"
      expect_code 1 "$rc" "nested-nm-agent-$registrar-$damage: teardown must refuse the foreign process"
      [ ! -s "$case_dir/launchctl-calls" ] \
        || fail "nested-nm-agent-$registrar-$damage: teardown addressed another lane's agent"
      for hash in 00000001 00000002 00000003; do
        label="$NM_AGENT_PREFIX.$hash"
        assert_present "$case_dir/launchagents/$label.plist" "nested-nm-agent: foreign plist was removed"
      done
      assert_present "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.00000001" "nested-nm-agent: foreign agent was unloaded"
      assert_absent "$case_dir/data/task-x1/launchagent-backup" "nested-nm-agent: foreign plist was archived"
      assert_present "$case_dir/state/task-x1.meta" "nested-nm-agent: task record was removed"
    done
  done
  pass "nested-lane agents remain loaded and installed across registry, path, and lane-damage variants"
}

test_absent_copy_nm_launch_agents_preserve_nested_ownership() {
  local recovery registrar case_dir wt registry nested home hash label root rc head
  local -a flags
  for recovery in merged forced; do
    for registrar in project sibling; do
      case_dir=$(make_case "absent-nm-agent-$recovery-$registrar")
      write_meta "$case_dir" no-mistakes ship
      add_fake_launchctl "$case_dir"
      wt=$(cd "$case_dir/wt" && pwd -P)
      registry="$case_dir/project"
      home="$case_dir/primary-home"
      if [ "$registrar" = sibling ]; then
        registry="$case_dir/sibling-clone"
        git clone -q "$case_dir/origin.git" "$registry"
        home="$case_dir/mate-home"
        mkdir -p "$case_dir/primary-home/data"
        printf -- '- mate-x - fixture scope (home: %s; scope: fixture; projects: alpha; added 2026-07-14)\n' \
          "$home" > "$case_dir/primary-home/data/secondmates.md"
      fi
      mkdir -p "$home/state"
      nested="$wt/other-lane"
      git -C "$registry" worktree add -q --detach "$nested" main
      git -C "$registry" worktree lock "$nested"
      fm_write_meta "$home/state/other-lane.meta" "worktree=$nested" "project=$registry" "kind=ship"
      flags=()
      if [ "$recovery" = merged ]; then
        append_pr_meta_url "$case_dir"
        head=$(git -C "$wt" rev-parse HEAD)
        add_gh_pr_merged_for_head "$case_dir" "$head"
      else
        flags=(--force --drop-file "$(fm_test_drop_file)")
      fi
      hash=0
      for root in "$wt" "$wt/.no-mistakes/h" "$wt" "$wt/.no-mistakes/h"; do
        hash=$((hash + 1))
        add_nm_launch_agent "$case_dir" "$hash" "$root"
        [ "$hash" -gt 2 ] || : > "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.$hash"
      done
      add_nm_launch_agent "$case_dir" nested "$nested/.no-mistakes/h"
      : > "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.nested"
      rm -rf "$wt"

      rc=0
      FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
        run_teardown "$case_dir" "${flags[@]+"${flags[@]}"}" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "absent-nm-agent-$recovery-$registrar: recovery refused: $(cat "$case_dir/stderr")"
      for hash in 1 2 3 4; do
        label="$NM_AGENT_PREFIX.$hash"
        assert_absent "$case_dir/launchctl-loaded/$label" "absent-nm-agent: private agent remains loaded"
        assert_absent "$case_dir/launchagents/$label.plist" "absent-nm-agent: private plist remains installed"
        assert_present "$case_dir/data/task-x1/launchagent-backup/$label.plist" "absent-nm-agent: private plist not archived"
        if [ "$hash" -le 2 ]; then
          assert_grep "bootout gui/$(id -u)/$label" "$case_dir/launchctl-calls" "absent-nm-agent: loaded private agent not booted out"
        fi
      done
      label="$NM_AGENT_PREFIX.nested"
      assert_present "$case_dir/launchctl-loaded/$label" "absent-nm-agent: nested agent was unloaded"
      assert_present "$case_dir/launchagents/$label.plist" "absent-nm-agent: nested plist was removed"
      assert_no_grep "$label" "$case_dir/launchctl-calls" "absent-nm-agent: nested agent was addressed"
      assert_absent "$case_dir/data/task-x1/launchagent-backup/$label.plist" "absent-nm-agent: nested plist was archived"
      assert_present "$home/state/other-lane.meta" "absent-nm-agent: nested task record was removed"
      assert_absent "$case_dir/state/task-x1.meta" "absent-nm-agent: recovered task record remains"
    done
  done
  pass "absent-copy recovery retires private agents but preserves nested agents registered by local task projects"
}

# Every agent whose root is not inside THIS task's copy stays loaded and
# installed: the shared ~/.no-mistakes agent, another task's agent, a sibling
# directory that only shares a name prefix, and a root that climbs out with `..`.
test_foreign_nm_launch_agents_are_left_alone() {
  local case_dir rc wt calls hash
  case_dir=$(make_case foreign-nm-agents)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  add_fake_launchctl "$case_dir"
  wt=$(cd "$case_dir/wt" && pwd -P)
  printf '%s\n' '.no-mistakes/' >> "$(git -C "$wt" rev-parse --git-path info/exclude)"
  add_nm_launch_agent "$case_dir" 00000001 "$case_dir/home/.no-mistakes" 999991
  add_nm_launch_agent "$case_dir" 00000002 "$case_dir/other-wt/.no-mistakes/h" 999992
  add_nm_launch_agent "$case_dir" 00000003 "$wt-sibling/.no-mistakes/h" 999993
  add_nm_launch_agent "$case_dir" 00000004 "$wt/../escape/.no-mistakes/h" 999994
  mkdir -p "$case_dir/escape/h" "$wt/.no-mistakes"
  ln -s "$case_dir/escape" "$wt/.no-mistakes/outside"
  add_nm_launch_agent "$case_dir" 00000006 "$wt/missing/../../escape/.no-mistakes/h"
  add_nm_launch_agent "$case_dir" 00000007 "$wt/.no-mistakes/outside/h"
  add_nm_launch_agent "$case_dir" 00000008 "$wt/.no-mistakes/outside/../.no-mistakes/h"
  add_nm_launch_agent "$case_dir" 00000009 "$wt/missing/../.no-mistakes/outside/h"
  for hash in 00000006 00000007 00000008 00000009; do
    : > "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.$hash"
  done
  mkdir -p "$case_dir/launchagents"
  printf '%s\n' 'not a plist' > "$case_dir/launchagents/com.kunchenguid.no-mistakes.daemon.00000005.plist"
  printf '%s\n' unrelated > "$case_dir/launchagents/com.example.other.plist"

  rc=0
  FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "foreign-nm-agents: teardown should be unaffected by other agents: $(cat "$case_dir/stderr")"
  calls=$(cat "$case_dir/launchctl-calls")
  assert_not_contains "$calls" "bootout" "foreign-nm-agents: teardown unloaded an agent that is not this task's"
  [ "$(find "$case_dir/launchagents" -name '*.plist' | wc -l | tr -d ' ')" = 10 ] \
    || fail "foreign-nm-agents: an installed plist was moved or removed"
  for hash in 00000001 00000002 00000003 00000004 00000006 00000007 00000008 00000009; do
    assert_present "$case_dir/launchctl-loaded/$NM_AGENT_PREFIX.$hash" \
      "foreign-nm-agents: an outside-root agent was unloaded"
  done
  assert_absent "$case_dir/data/task-x1/launchagent-backup" \
    "foreign-nm-agents: something was archived for a task that owned no agent"
  assert_grep "leaving unreadable no-mistakes launch agent $case_dir/launchagents/$NM_AGENT_PREFIX.00000005.plist as found" "$case_dir/stderr" \
    "foreign-nm-agents: an unparsable plist was skipped silently"
  pass "agents rooted outside the task's copy, and unparsable plists, are never unloaded or moved"
}

# An agent that will not unload still owns its process and respawns it, so
# teardown must stop with the plist and the task record intact.
test_private_nm_launch_agent_bootout_failure_refuses() {
  local case_dir rc pid label
  case_dir=$(make_case private-nm-agent-stuck)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  add_fake_launchctl "$case_dir"
  mkdir -p "$case_dir/wt/.no-mistakes/h"
  teardown_fixture_start "$case_dir/wt/.no-mistakes/h" KILL sleep 300
  pid=$TEARDOWN_FIXTURE_PID
  sleep 0.3
  label="$NM_AGENT_PREFIX.3baa54c9"
  add_nm_launch_agent "$case_dir" 3baa54c9 "$(cd "$case_dir/wt" && pwd -P)/.no-mistakes/h" "$pid"

  rc=0
  FAKE_LAUNCHCTL_BOOTOUT_FAILS=1 FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  kill -0 "$pid" 2>/dev/null || { teardown_fixture_stop "$pid"; fail "private-nm-agent-stuck: process was signalled around a loaded agent"; }
  teardown_fixture_stop "$pid"
  expect_code 1 "$rc" "private-nm-agent-stuck: teardown must refuse when the agent stays loaded"
  assert_present "$case_dir/launchagents/$label.plist" "private-nm-agent-stuck: plist removed although the agent is still loaded"
  assert_present "$case_dir/state/task-x1.meta" "private-nm-agent-stuck: task record removed"
  assert_present "$case_dir/wt" "private-nm-agent-stuck: task copy removed"
  assert_grep "REFUSED: no-mistakes launch agent $label (rooted in task-x1's copy) is still loaded" "$case_dir/stderr" \
    "private-nm-agent-stuck: refusal does not name the agent"
  pass "an agent that stays loaded after bootout stops teardown with its plist and the task copy intact"
}

# A plist left behind by a reboot or a manual bootout has no loaded service; it
# still brings the daemon back at next login, so it is archived too.
test_private_nm_launch_agent_not_loaded_is_archived() {
  local case_dir rc label wt root hash=0
  case_dir=$(make_case private-nm-agent-unloaded)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  add_fake_launchctl "$case_dir"
  wt=$(cd "$case_dir/wt" && pwd -P)
  for root in "$wt/.no-mistakes/h" "$wt/./.no-mistakes/h" "$wt//.no-mistakes//h/" \
    "$wt/missing/../.no-mistakes/h" "$wt/missing/./h" "$wt/missing/h/.." "$wt/."; do
    hash=$((hash + 1))
    add_nm_launch_agent "$case_dir" "$hash" "$root"
  done

  rc=0
  FM_LAUNCH_AGENTS_DIR="$case_dir/launchagents" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "private-nm-agent-unloaded: teardown should finish"
  for hash in 1 2 3 4 5 6 7; do
    label="$NM_AGENT_PREFIX.$hash"
    assert_absent "$case_dir/launchagents/$label.plist" "private-nm-agent-unloaded: plist still installed"
    assert_present "$case_dir/data/task-x1/launchagent-backup/$label.plist" \
      "private-nm-agent-unloaded: plist not archived"
  done
  pass "a private no-mistakes plist with no loaded service is still archived"
}

test_docker_differently_named_metadata_hardlinks_preserve_longer_siblings() {
  local caller separator case_dir home meta id sibling sibling_home store rc
  for caller in top-level forced-child; do
    for separator in - _; do
      case_dir=$(make_case "docker-hardlink-$caller-$separator")
      write_meta "$case_dir" local-only ship
      home="$case_dir/state"
      meta="$home/task-x1.meta"
      id=task-x1
      if [ "$caller" = forced-child ]; then
        write_meta "$case_dir" local-only secondmate
        configure_secondmate_with_tmux_children "$case_dir"
        home="$case_dir/secondmate-home/state"
        meta="$home/child-a.meta"
        id="child-a"
      fi
      fm_write_meta "$meta" "window=firstmate:fm-$id" "endpoint_task_id=$id" \
        "worktree=$case_dir/missing-wt" "project=$case_dir/project" \
        "kind=ship" "mode=local-only" "spawn_gen=teardown-test-$id"
      sibling="$id${separator}v2"
      sibling_home="$case_dir/sibling-home"
      mkdir -p "$sibling_home/state" "$sibling_home/data" "$case_dir/primary-home/data"
      ln "$meta" "$sibling_home/state/$sibling.meta"
      printf -- '- mate - fixture (home: %s; scope: test; projects: project; added 2026-01-01)\n' \
        "$sibling_home" > "$case_dir/primary-home/data/secondmates.md"
      store="$case_dir/docker-store"
      : > "$store"
      docker_store_add "$store" container c-own "$id-db" "fm.task=$id" ""
      docker_store_add "$store" container c-sibling "$sibling-db" "com.docker.compose.project=longer-project" ""
      docker_store_add "$store" network n-own own-network "fm.task=$id"
      docker_store_add "$store" network n-sibling sibling-network "com.docker.compose.project=longer-project"
      docker_store_add "$store" volume own-volume "fm.task=$id"
      docker_store_add "$store" volume sibling-volume "fm.task=$sibling"
      rc=0
      FM_FAKE_DOCKER_STORE="$store" \
        run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
          > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "$caller $separator hardlink: teardown failed: $(cat "$case_dir/stderr")"
      assert_absent "$case_dir/state/task-x1.meta" "$caller $separator hardlink: owner task was not retired"
      assert_present "$sibling_home/state/$sibling.meta" "$caller $separator hardlink: foreign sibling metadata was retired"
      assert_equals "$sibling-db " "$(docker_store_names "$store" container)" \
        "$caller $separator hardlink: longer sibling container was removed or own container survived"
      assert_equals "sibling-network " "$(docker_store_names "$store" network)" \
        "$caller $separator hardlink: longer sibling network was removed or own network survived"
      assert_equals "sibling-volume " "$(docker_store_names "$store" volume)" \
        "$caller $separator hardlink: sibling volume was removed or own volume survived"
    done
  done
  pass "differently named metadata hardlinks preserve longer sibling stacks in top-level and forced-child cleanup"
}

test_teardown_retires_the_dsh_launch_state() {
  local case_dir rc wt_head
  case_dir=$(make_case dsh-launch-state)
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt landed "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  mkdir -p "$case_dir/state/task-x1.dsh/g1/dsh/sessions" "$case_dir/state/task-x1.dsh/g2/dsh" "$case_dir/state/task-x2.dsh/g1"
  printf 'secret\n' > "$case_dir/state/task-x1.dsh/g2/dsh/.credentials.yaml"
  printf '{}\n' > "$case_dir/state/task-x1.dsh-session"
  printf '{}\n' > "$case_dir/state/task-x2.dsh-session"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "dsh-launch-state: teardown refused: $(cat "$case_dir/stderr")"
  [ ! -e "$case_dir/state/task-x1.dsh" ] && [ ! -e "$case_dir/state/task-x1.dsh-session" ] \
    || fail "dsh-launch-state: teardown left the task's dsh credentials copy, session logs, or binding"
  [ -d "$case_dir/state/task-x2.dsh/g1" ] && [ -f "$case_dir/state/task-x2.dsh-session" ] \
    || fail "dsh-launch-state: teardown removed another task's dsh launch state"
  pass "teardown retires the task's own dsh launch state and no other task's"
}

test_teardown_removes_the_tasks_own_docker_stacks() {
  local case_dir rc
  case_dir=$(make_docker_case docker-own-stacks)
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" \
  FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "docker-own-stacks: teardown should succeed: $(cat "$case_dir/stderr")"
  assert_equals "gre1675-throwaway-pg other-compose-1 other-db supabase_db_vernant task-x1-cache task-x1-v2-pg task-x10-pg " \
    "$(docker_store_names "$case_dir/docker-store" container)" \
    "docker-own-stacks: wrong containers remained"
  assert_equals "other_default supabase_network_vernant task-x1_shared " \
    "$(docker_store_names "$case_dir/docker-store" network)" \
    "docker-own-stacks: wrong networks remained"
  assert_equals "other-data other_pgdata supabase_db_vernant task-x1-unlabelled task-x1_beaten " \
    "$(docker_store_names "$case_dir/docker-store" volume)" \
    "docker-own-stacks: wrong volumes remained"
  assert_grep "removing Docker container(s) owned by task-x1" "$case_dir/stderr" \
    "docker-own-stacks: teardown did not say which containers it removed"
  pass "teardown removes the task's labelled, named, compose-project and worktree-compose stacks and its marker- or project-labelled volumes, and leaves every other Docker object"
}

test_docker_removal_failure_keeps_the_task_records_until_a_rerun_succeeds() {
  local case_dir rc
  case_dir=$(make_docker_case docker-rm-fails)
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
echo returned >> "$case_dir/treehouse.log"
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" FM_FAKE_DOCKER_RM_FAIL=task-x1-test-pg \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "docker-rm-fails: an owned container that survives removal must stop teardown"
  assert_grep "still present after removal: task-x1-test-pg" "$case_dir/stderr" "docker-rm-fails: the surviving container was not named"
  assert_grep "Error: cannot remove container task-x1-test-pg" "$case_dir/stderr" "docker-rm-fails: Docker's own removal error was hidden"
  assert_present "$case_dir/state/task-x1.meta" "docker-rm-fails: the task record was removed while a container survived"
  assert_absent "$case_dir/treehouse.log" "docker-rm-fails: the worktree was returned while a container survived"
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "docker-rm-fails: the rerun should finish: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "docker-rm-fails: the rerun left the task record"
  assert_equals "other_default supabase_network_vernant task-x1_shared " \
    "$(docker_store_names "$case_dir/docker-store" network)" \
    "docker-rm-fails: partial container removal lost derived network ownership on retry"
  pass "an owned container that cannot be removed stops teardown with the record kept, and a rerun finishes it"
}

test_docker_removal_error_without_a_survivor_does_not_stop_teardown() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-rm-error-no-survivor)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-own owned-container "fm.task=task-x1" ""
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_RM_ERROR_AFTER_REMOVE=1 FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "rm-error-no-survivor: a removal error with no surviving container stopped teardown: $(cat "$case_dir/stderr")"
  assert_grep 'docker rm -f -v c-own' "$case_dir/docker.log" "rm-error-no-survivor: the failing removal was not exercised"
  assert_absent "$case_dir/state/task-x1.meta" "rm-error-no-survivor: the task record was retained"
  assert_equals "" "$(docker_store_names "$store" container)" "rm-error-no-survivor: the owned container survived"
  pass "a Docker removal error that leaves no owned container does not stop teardown"
}

test_docker_failed_lane_scan_names_its_cause() {
  local case_dir home store before rc
  case_dir=$(make_case docker-lane-scan-fails)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_tmux_children "$case_dir"
  home="$case_dir/secondmate-home"
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-own owned-child "fm.task=child-a" ""
  before=$(cat "$store")
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
case "\${1:-}" in
  kill-window|kill-pane) : > "$case_dir/lane-scan-armed" ;;
esac
exit 0
EOF
  cat > "$case_dir/fakebin/git" <<EOF
#!/usr/bin/env bash
if [ -e "$case_dir/lane-scan-armed" ] && [ "\${1:-}" = -C ] && [ "\${3:-} \${4:-}" = "worktree list" ]; then
  exit 1
fi
exec "$(command -v git)" "\$@"
EOF
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/git"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  rm -f "$case_dir/fakebin/git" "$case_dir/lane-scan-armed"
  expect_code 1 "$rc" "lane-scan-fails: an unreadable worktree registry allowed retirement"
  assert_present "$home/state/child-a.meta" "lane-scan-fails: the child record was retired"
  assert_present "$case_dir/state/task-x1.meta" "lane-scan-fails: the parent record was retired"
  assert_equals "$before" "$(cat "$store")" "lane-scan-fails: Docker state changed"
  assert_absent "$case_dir/docker.log" "lane-scan-fails: Docker ran without a lane inventory"
  assert_grep "cannot establish nested worktree lanes for child-a (worktree registration could not be read: " \
    "$case_dir/stderr" "lane-scan-fails: the refusal did not name its cause"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "lane-scan-fails: retry failed: $(cat "$case_dir/retry.stderr")"
  assert_absent "$home" "lane-scan-fails: retry retained the secondmate home"
  assert_equals "" "$(docker_store_names "$store" container)" "lane-scan-fails: retry left the owned container"
  pass "a failed lane scan before Docker cleanup names its cause and retains records until retry"
}

test_forced_teardown_retains_records_after_a_docker_removal_failure() {
  local case_dir rc
  case_dir=$(make_docker_case docker-rm-fails-forced)
  rc=0
  FM_FAKE_DOCKER_STORE="$case_dir/docker-store" FM_FAKE_DOCKER_RM_FAIL=task-x1-test-pg \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "docker-rm-fails-forced: --force must not bypass Docker cleanup"
  assert_present "$case_dir/state/task-x1.meta" "docker-rm-fails-forced: task identity was retired"
  assert_present "$case_dir/wt" "docker-rm-fails-forced: worktree was removed"
  assert_grep "task-x1-test-pg" "$case_dir/docker-store" "docker-rm-fails-forced: fixture did not retain the failed container"
  pass "--force retains task identity when Docker container removal fails"
}

test_stopped_docker_daemon_blocks_teardown() {
  local path retained case_dir meta id store before rc
  for path in ship scout forced-child; do
    for retained in yes no; do
      case_dir=$(make_case "docker-daemon-down-$path-$retained")
      meta="$case_dir/state/task-x1.meta"
      id=task-x1
      case "$path" in
        ship)
          write_meta "$case_dir" no-mistakes ship
          land_shippable_commit "$case_dir"
          ;;
        scout)
          write_meta "$case_dir" no-mistakes scout
          mkdir -p "$case_dir/data/task-x1"
          printf 'Delivered investigation report.\n' > "$case_dir/data/task-x1/report.md"
          ;;
        forced-child)
          write_meta "$case_dir" local-only secondmate
          configure_secondmate_with_tmux_children "$case_dir"
          meta="$case_dir/secondmate-home/state/child-a.meta"
          id="child-a"
          ;;
      esac
      [ "$retained" = no ] || printf 'docker_projects= derived\n' >> "$meta"
      store="$case_dir/docker-store"
      : > "$store"
      docker_store_add "$store" container c-own owned-container "fm.task=$id;com.docker.compose.project=derived" ""
      docker_store_add "$store" network n-own derived-network "com.docker.compose.project=derived"
      before=$(cat "$store")
      rc=0
      if [ "$path" != ship ]; then
        FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_DOWN=1 \
          run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
            > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      else
        FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_DOWN=1 \
          run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      fi
      assert_equals "$before" "$(cat "$store")" "daemon-down $path $retained: Docker state changed"
      assert_grep "warning: Docker container listing failed" "$case_dir/stderr" \
        "daemon-down $path $retained: the failed container listing was not named"
      assert_grep "Cannot connect to the Docker daemon" "$case_dir/stderr" \
        "daemon-down $path $retained: Docker's own listing error was hidden"
      if [ "$retained" = yes ]; then
        expect_code 1 "$rc" "daemon-down $path: a record with docker_projects must stop teardown"
        assert_present "$meta" "daemon-down $path: task identity was retired"
        assert_present "$case_dir/state/task-x1.meta" "daemon-down $path: top-level identity was retired"
        assert_grep "docker_projects= derived" "$meta" "daemon-down $path: retained project identities were lost"
        assert_grep "Docker could not be listed for $id" "$case_dir/stderr" \
          "daemon-down $path: the refusal did not name the unlistable daemon: $(cat "$case_dir/stderr")"
        rc=0
        if [ "$path" != ship ]; then
          FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
            > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
        else
          FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" \
            > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
        fi
        expect_code 0 "$rc" "daemon-down $path: retry with Docker running failed: $(cat "$case_dir/retry.stderr")"
        assert_absent "$meta" "daemon-down $path: retry retained task identity"
        assert_equals "" "$(docker_store_names "$store" container)" "daemon-down $path: retry left the owned container"
        assert_equals "" "$(docker_store_names "$store" network)" "daemon-down $path: retry left the derived network"
      else
        expect_code 0 "$rc" "daemon-down $path: a record without docker_projects must not stop teardown: $(cat "$case_dir/stderr")"
        assert_absent "$meta" "daemon-down $path: task identity was retained"
        assert_absent "$case_dir/state/task-x1.meta" "daemon-down $path: top-level identity was retained"
        assert_grep "Docker could not be listed for $id" "$case_dir/stderr" \
          "daemon-down $path: the skipped Docker cleanup was not reported"
        assert_grep "Docker cleanup was skipped" "$case_dir/stderr" \
          "daemon-down $path: the warning did not say cleanup was skipped"
      fi
    done
  done
  pass "a stopped Docker daemon stops ship, scout and forced-child teardown only when the task record retains docker_projects; otherwise it warns and continues"
}

test_teardown_without_a_docker_binary_skips_docker_cleanup() {
  local case_dir rc before
  case_dir=$(make_docker_case docker-absent)
  before=$(cat "$case_dir/docker-store")
  rm -f "$case_dir/fakebin/docker"
  rc=0
  FM_TEARDOWN_TEST_PATH=$(fm_test_base_path_sans "$PATH" docker) \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "docker-absent: teardown without Docker should succeed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "docker-absent: task record was not retired"
  assert_equals "$before" "$(cat "$case_dir/docker-store")" "docker-absent: Docker state changed"
  pass "a host without Docker retires task records without changing Docker state"
}

test_docker_configured_supabase_identity_vetoes_all_heuristics() {
  local case_dir store protected rc
  for protected in runtime-shared task-x1; do
    case_dir=$(make_docker_case "docker-protected-$protected")
    store="$case_dir/docker-store"
    : > "$store"
    mkdir -p "$case_dir/project/supabase"
    printf 'project_id = "%s" # shared stack\n\n[api]\nenabled = true\n' "$protected" \
      > "$case_dir/project/supabase/config.toml"
    docker_store_add "$store" container c-name task-x1-supabase-db "com.supabase.cli.project=$protected" ""
    docker_store_add "$store" container c-project task-x1-cross-project "com.docker.compose.project=task-x1;com.supabase.cli.project=$protected" ""
    docker_store_add "$store" container c-path shared-path "com.docker.compose.project=$protected;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" container c-primary task-x1-primary "com.docker.compose.project=project;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" container c-marker marked-task "fm.task=task-x1;com.supabase.cli.project=$protected" ""
    docker_store_add "$store" container c-own own-path "com.docker.compose.project=isolated;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" network n-cross cross-project "com.docker.compose.project=task-x1;com.supabase.cli.project=$protected"
    docker_store_add "$store" network n-reverse reverse-project "com.docker.compose.project=$protected;com.supabase.cli.project=task-x1"
    docker_store_add "$store" network n-marker marked-network "fm.task=task-x1;com.supabase.cli.project=$protected"
    docker_store_add "$store" volume cross-volume "com.docker.compose.project=task-x1;com.supabase.cli.project=$protected"
    docker_store_add "$store" volume reverse-volume "com.docker.compose.project=$protected;com.supabase.cli.project=task-x1"
    docker_store_add "$store" volume marked-volume "fm.task=task-x1;com.supabase.cli.project=$protected"
    rc=0
    FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "$protected: teardown failed: $(cat "$case_dir/stderr")"
    assert_equals "shared-path task-x1-cross-project task-x1-supabase-db " \
      "$(docker_store_names "$store" container)" "$protected: protected project was claimed by a heuristic"
    assert_equals "cross-project reverse-project " "$(docker_store_names "$store" network)" \
      "$protected: protected network was claimed or explicit marker was ignored"
    assert_equals "cross-volume reverse-volume " "$(docker_store_names "$store" volume)" \
      "$protected: protected volume was claimed or explicit marker was ignored"
  done
  pass "actual configured Supabase identity vetoes names, paths and either project label, but not explicit markers"
}

test_docker_unreadable_supabase_config_refuses_and_absence_proceeds() {
  local caller failure case_dir home meta id store before rc config
  for caller in top-level forced-child; do
    for failure in unreadable-file missing-file missing-parent; do
      case_dir=$(make_case "docker-config-$caller-$failure")
      write_meta "$case_dir" local-only ship
      meta="$case_dir/state/task-x1.meta"
      id=task-x1
      if [ "$caller" = forced-child ]; then
        write_meta "$case_dir" local-only secondmate
        configure_secondmate_with_tmux_children "$case_dir"
        home="$case_dir/secondmate-home"
        meta="$home/state/child-a.meta"
        id="child-a"
      fi
      mkdir -p "$case_dir/project/supabase"
      config="$case_dir/project/supabase/config.toml"
      printf 'project_id = "vernant"\n' > "$config"
      store="$case_dir/docker-store"
      : > "$store"
      docker_store_add "$store" container c-shared "$id-shared" "com.docker.compose.project=vernant" ""
      docker_store_add "$store" container c-own owned-container "fm.task=$id" ""
      docker_store_add "$store" network n-own owned-network "fm.task=$id"
      docker_store_add "$store" volume owned-volume "fm.task=$id"
      before=$(cat "$store")
      case "$failure" in
        unreadable-file)
          chmod 000 "$config"
          [ ! -r "$config" ] || fail "Supabase fixture config remains readable"
          ;;
        missing-file) rm "$config" ;;
        missing-parent) rm -rf "${config%/*}" ;;
      esac
      rc=0
      FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
        run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
          > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      case "$failure" in
        missing-file|missing-parent)
          expect_code 0 "$rc" "$caller $failure: config absence refused teardown: $(cat "$case_dir/stderr")"
          assert_absent "$meta" "$caller $failure: task record was retained"
          assert_equals "" "$(docker_store_names "$store" container)" "$caller $failure: owned containers survived"
          ;;
        *)
          chmod 644 "$config"
          expect_code 1 "$rc" "$caller $failure: uncertain Supabase protection permitted teardown"
          assert_present "$meta" "$caller $failure: task record was retired"
          assert_present "$case_dir/state/task-x1.meta" "$caller $failure: parent record was retired"
          assert_equals "$before" "$(cat "$store")" "$caller $failure: Docker resources changed"
          assert_absent "$case_dir/docker.log" "$caller $failure: Docker ran before establishing Supabase protection"
          assert_grep "cannot identify the shared Supabase stack for $id" \
            "$case_dir/stderr" "$caller $failure: unreadable config was not exercised"
          rc=0
          FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
            > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
          expect_code 0 "$rc" "$caller $failure: retry failed: $(cat "$case_dir/retry.stderr")"
          assert_absent "$meta" "$caller $failure: retry retained task record"
          assert_equals "$id-shared " "$(docker_store_names "$store" container)" \
            "$caller $failure: retry removed the protected stack or retained owned containers"
          ;;
      esac
      assert_equals "" "$(docker_store_names "$store" network)" "$caller $failure: owned network survived"
      assert_equals "" "$(docker_store_names "$store" volume)" "$caller $failure: owned volume survived"
    done
  done
  pass "Supabase protection refuses an unreadable config, preserves the shared stack on retry, and permits an absent config"
}

test_docker_project_labels_require_the_exact_task_id() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-exact-project)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-compose exact-compose "com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-supabase exact-supabase "com.supabase.cli.project=task-x1" ""
  docker_store_add "$store" container c-prefix prefixed-compose "com.docker.compose.project=task-x1-stack" ""
  docker_store_add "$store" container c-prefix2 prefixed-supabase "com.supabase.cli.project=task-x1_stack" ""
  docker_store_add "$store" container c-name task-x1-db "" ""
  docker_store_add "$store" container c-exact-name task-x1 "" ""
  docker_store_add "$store" container c-name2 task-x1_cache "" ""
  docker_store_add "$store" container c-sibling task-x1-v2-db "" ""
  docker_store_add "$store" network n-compose exact-compose "com.docker.compose.project=task-x1"
  docker_store_add "$store" network n-supabase exact-supabase "com.supabase.cli.project=task-x1"
  docker_store_add "$store" network n-prefix prefixed-compose "com.docker.compose.project=task-x1-stack"
  docker_store_add "$store" network n-prefix2 prefixed-supabase "com.supabase.cli.project=task-x1_stack"
  docker_store_add "$store" volume exact-compose "com.docker.compose.project=task-x1"
  docker_store_add "$store" volume exact-supabase "com.supabase.cli.project=task-x1"
  docker_store_add "$store" volume prefixed-compose "com.docker.compose.project=task-x1-stack"
  docker_store_add "$store" volume prefixed-supabase "com.supabase.cli.project=task-x1_stack"
  docker_store_add "$store" volume task-x1-named ""
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "exact-project: teardown failed: $(cat "$case_dir/stderr")"
  assert_equals "prefixed-compose prefixed-supabase task-x1-v2-db " "$(docker_store_names "$store" container)" \
    "exact-project: project prefixes or live sibling names were claimed"
  assert_equals "prefixed-compose prefixed-supabase " "$(docker_store_names "$store" network)" \
    "exact-project: project prefix network was claimed"
  assert_equals "prefixed-compose prefixed-supabase task-x1-named " "$(docker_store_names "$store" volume)" \
    "exact-project: a volume was claimed by a project prefix or its name, or an exact project volume survived"
  pass "project labels match only the exact id for containers, networks and volumes while container names retain boundary and live-sibling rules"
}

test_docker_workdirs_canonicalize_and_exclude_foreign_lanes_and_tasktmp() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-canonical-paths)
  store="$case_dir/docker-store"
  : > "$store"
  mkdir -p "$case_dir/wt/own-stack" "$case_dir/tasktmp/stack" "$case_dir/foreign/stack"
  git -C "$case_dir/project" worktree add -q --detach "$case_dir/wt/git-lane" main
  git -C "$case_dir/project" worktree add -q --detach "$case_dir/wt/registered-lane" main
  git -C "$case_dir/project" worktree lock "$case_dir/wt/registered-lane"
  rm -f "$case_dir/wt/registered-lane/.git"
  ln -s "$case_dir/wt" "$case_dir/wt-alias"
  ln -s "$case_dir/foreign" "$case_dir/wt/foreign-link"
  ln -s "$case_dir/wt/git-lane" "$case_dir/git-alias"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" "endpoint_task_id=task-x1" "worktree=$case_dir/wt-alias" \
    "project=$case_dir/project" "kind=ship" "mode=no-mistakes" \
    "tasktmp=$case_dir/tasktmp" "spawn_gen=teardown-test-task-x1"
  fm_write_meta "$case_dir/state/foreign-lane.meta" "kind=ship" "worktree=$case_dir/wt/registered-lane"
  docker_store_add "$store" container c-own own-real-path "com.docker.compose.project.working_dir=$case_dir/wt/own-stack" ""
  docker_store_add "$store" container c-alias own-alias-path "com.docker.compose.project.working_dir=$case_dir/wt-alias/own-stack" ""
  docker_store_add "$store" container c-git nested-git-path "com.docker.compose.project.working_dir=$case_dir/git-alias" ""
  docker_store_add "$store" container c-reg nested-record-path "com.docker.compose.project.working_dir=$case_dir/wt-alias/registered-lane" ""
  docker_store_add "$store" container c-foreign symlink-foreign "com.docker.compose.project.working_dir=$case_dir/wt/foreign-link/stack" ""
  docker_store_add "$store" container c-tmp temporary-path "com.docker.compose.project.working_dir=$case_dir/tasktmp/stack" ""
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  # The nested lanes are registered copies this task has not proven, so the
  # forced return refuses them after the Docker sweep and keeps them.
  expect_code 1 "$rc" "canonical-paths: unproven nested copies must stop the return: $(cat "$case_dir/stderr")"
  assert_grep "contains registered copy $case_dir/wt/git-lane" "$case_dir/stderr" "canonical-paths: custody refusal omitted the nested Git worktree"
  assert_equals "nested-git-path nested-record-path symlink-foreign temporary-path " "$(docker_store_names "$store" container)" \
    "canonical-paths: canonical custody or worktree-only boundary was ignored"
  assert_present "$case_dir/state/foreign-lane.meta" "canonical-paths: foreign task record was removed"
  assert_present "$case_dir/wt/git-lane" "canonical-paths: nested Git worktree was removed"
  pass "Docker workdir ownership canonicalizes both sides and excludes nested lanes, foreign symlinks and task temp roots"
}

test_docker_mixed_project_carriers_spare_empty_heuristic_networks() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-mixed-networks)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-task own-exact "fm.task=task-x1;com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-other foreign-exact "fm.task=other;com.supabase.cli.project=task-x1" ""
  docker_store_add "$store" container c-derived own-derived "com.docker.compose.project=derived;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" container c-foreign foreign-derived "com.supabase.cli.project=derived" ""
  docker_store_add "$store" container c-all own-dual "com.docker.compose.project=all-owned;com.supabase.cli.project=all-owned-supa;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" network n-exact empty-exact "com.docker.compose.project=task-x1"
  docker_store_add "$store" network n-exact-supa empty-exact-supa "com.supabase.cli.project=task-x1"
  docker_store_add "$store" network n-derived empty-derived "com.docker.compose.project=derived"
  docker_store_add "$store" network n-derived-supa empty-derived-supa "com.supabase.cli.project=derived"
  docker_store_add "$store" network n-owned all-owned-net "com.docker.compose.project=all-owned"
  docker_store_add "$store" network n-owned-supa all-owned-supa-net "com.supabase.cli.project=all-owned-supa"
  docker_store_add "$store" network n-explicit explicit-mixed "fm.task=task-x1;com.docker.compose.project=task-x1"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "mixed-networks: teardown failed: $(cat "$case_dir/stderr")"
  assert_equals "foreign-derived foreign-exact " "$(docker_store_names "$store" container)" \
    "mixed-networks: wrong project carriers were removed"
  assert_equals "all-owned-supa-net empty-derived empty-derived-supa empty-exact empty-exact-supa " "$(docker_store_names "$store" network)" \
    "mixed-networks: foreign project label did not veto an empty heuristic network or all-owned propagation failed"
  pass "foreign project carriers veto empty heuristic networks, all-owned projects propagate and explicit markers remain authoritative"
}

test_docker_latest_foreign_carriers_veto_network_removal() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-latest-carriers)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-exact own-exact "fm.task=task-x1;com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-derived own-derived "com.docker.compose.project=derived;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$case_dir/arriving-containers" container c-foreign arriving-foreign \
    "fm.task=other;com.docker.compose.project=task-x1;com.supabase.cli.project=derived" ""
  docker_store_add "$store" network n-exact exact-compose "com.docker.compose.project=task-x1"
  docker_store_add "$store" network n-supa exact-supabase "com.supabase.cli.project=task-x1"
  docker_store_add "$store" network n-derived derived-compose "com.docker.compose.project=derived"
  docker_store_add "$store" network n-derived-supa derived-supabase "com.supabase.cli.project=derived"
  docker_store_add "$store" network n-marked explicitly-owned "fm.task=task-x1;com.docker.compose.project=derived"
  docker_store_add "$store" volume exact-volume "com.docker.compose.project=task-x1"
  docker_store_add "$store" volume marked-volume "fm.task=task-x1;com.docker.compose.project=task-x1"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_ADD_AFTER_RM="$case_dir/arriving-containers" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "latest-carriers: teardown failed: $(cat "$case_dir/stderr")"
  assert_equals "arriving-foreign " "$(docker_store_names "$store" container)" \
    "latest-carriers: foreign carrier was removed"
  assert_equals "derived-compose derived-supabase exact-compose exact-supabase " "$(docker_store_names "$store" network)" \
    "latest-carriers: latest foreign evidence was ignored or explicit marker was vetoed"
  assert_equals "exact-volume " "$(docker_store_names "$store" volume)" \
    "latest-carriers: a foreign carrier did not veto the project-label volume or the explicit marker was vetoed"
  pass "foreign carriers observed after container removal veto both project-label heuristics but not explicit network markers"
}

# Retiring a secondmate whose own registered home is already gone must not be
# refused by the custody scan's walk over that same home: nothing there can be
# lost. Any other registered home that cannot be read still refuses, with or
# without --force.
test_secondmate_retirement_exempts_only_its_own_missing_home() {
  local case_dir shape rc gone
  for shape in own other; do
    case_dir=$(make_case "secondmate-missing-home-$shape")
    gone="$case_dir-gone"
    write_meta "$case_dir" local-only secondmate
    printf 'home=%s\ntasktmp=%s\n' "$gone/secondmate-home" "$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
    mkdir -p "$case_dir/tasktmp"
    printf -- '- task-x1 - task-x1 (home: %s; scope: fixture; projects: P; added 2026-10-08)\n' \
      "$gone/secondmate-home" > "$case_dir/data/secondmates.md"
    rc=0
    if [ "$shape" = own ]; then
      FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "missing-home-own: retiring a secondmate whose own home is gone must succeed: $(cat "$case_dir/stderr")"
      assert_absent "$case_dir/state/task-x1.meta" "missing-home-own: the record was not retired"
      continue
    fi
    printf -- '- ghost - ghost (home: %s; scope: fixture; projects: P; added 2026-10-08)\n' \
      "$gone/ghost-home" >> "$case_dir/data/secondmates.md"
    FM_HOME="$case_dir" run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "missing-home-other: another unreadable registered home must still refuse"
    assert_grep "registered local Firstmate home is unavailable: $gone/ghost-home" "$case_dir/stderr" \
      "missing-home-other: the refusal did not name the other home"
    assert_present "$case_dir/state/task-x1.meta" "missing-home-other: the refusal retired the record"
  done
  pass "secondmate retirement exempts only its own missing home from the custody walk"
}

# A stored preservation bundle can be the only copy of unlanded commits, so
# retiring the home that keeps it, forced or not, refuses before any removal,
# including a forced retirement's child cleanup, until the bundle has left it.
test_secondmate_retirement_keeps_stored_preservation_bundles() {
  local case_dir posture home bundle moved rc child_wt
  for posture in ordinary forced; do
    case_dir=$(make_case "secondmate-stored-bundle-$posture")
    write_meta "$case_dir" local-only secondmate
    home="$case_dir/secondmate-home"
    mkdir -p "$home/state"
    printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
    printf 'home=%s\n' "$home" >> "$case_dir/state/task-x1.meta"
    bundle="$home/data/child-a/preserved-bundles/$(printf 'ab%.0s' {1..32}).bundle"
    mkdir -p "${bundle%/*}"
    printf 'only copy of unlanded commits\n' > "$bundle"
    child_wt="$case_dir/child-a-wt"
    if [ "$posture" = forced ]; then
      git -C "$case_dir/project" worktree add -q -b fm/child-a "$child_wt" main
      fm_write_meta "$home/state/child-a.meta" "window=firstmate:fm-child-a" "endpoint_task_id=child-a" \
        "worktree=$child_wt" "project=$case_dir/project" "kind=ship" "mode=local-only"
      : > "$home/state/child-a.status"
    fi
    rc=0
    if [ "$posture" = forced ]; then
      run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    expect_code 1 "$rc" "$posture stored-bundle: retirement must refuse while the home keeps a stored bundle"
    assert_grep "REFUSED: secondmate home $home holds bundle-preserved commits" "$case_dir/stderr" \
      "$posture stored-bundle: the refusal did not name the home: $(cat "$case_dir/stderr")"
    assert_grep "  $bundle" "$case_dir/stderr" "$posture stored-bundle: the refusal did not list the stored bundle"
    assert_grep 'move it to a durable location outside this home' "$case_dir/stderr" \
      "$posture stored-bundle: the refusal did not name the completing step"
    assert_equals 'only copy of unlanded commits' "$(cat "$bundle")" "$posture stored-bundle: the stored bundle was lost"
    assert_present "$home/.fm-secondmate-home" "$posture stored-bundle: the home was removed"
    assert_present "$case_dir/state/task-x1.meta" "$posture stored-bundle: the record was retired"
    if [ "$posture" = forced ]; then
      assert_present "$home/state/child-a.meta" "forced stored-bundle: the refusal came after the child was retired"
      assert_present "$child_wt/.git" "forced stored-bundle: the refusal came after the child copy was removed"
    fi
    moved="$case_dir/durable/${bundle##*/}"
    mkdir -p "${moved%/*}"
    mv "$bundle" "$moved"
    rc=0
    if [ "$posture" = forced ]; then
      run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
    else
      run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2" || rc=$?
    fi
    expect_code 0 "$rc" "$posture stored-bundle: retirement after moving the bundle must succeed: $(cat "$case_dir/stderr2")"
    assert_absent "$home" "$posture stored-bundle: the home was not retired"
    assert_equals 'only copy of unlanded commits' "$(cat "$moved")" "$posture stored-bundle: the moved bundle was lost"
  done
  pass "retiring a home that keeps a stored preservation bundle refuses until the bundle leaves it"
}

test_standalone_secondmate_skips_docker_cleanup() {
  local case_dir posture rc
  for posture in ordinary forced; do
    case_dir=$(make_case "docker-secondmate-$posture")
    write_meta "$case_dir" local-only secondmate
    mkdir -p "$case_dir/secondmate-home/state"
    printf '%s\n' task-x1 > "$case_dir/secondmate-home/.fm-secondmate-home"
    printf 'home=%s\n' "$case_dir/secondmate-home" >> "$case_dir/state/task-x1.meta"
    rc=0
    if [ "$posture" = forced ]; then
      FM_FAKE_DOCKER_DOWN=1 FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
        run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      FM_FAKE_DOCKER_DOWN=1 FM_FAKE_DOCKER_LOG="$case_dir/docker.log" \
        run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    expect_code 0 "$rc" "$posture secondmate: teardown failed: $(cat "$case_dir/stderr")"
    assert_absent "$case_dir/state/task-x1.meta" "$posture secondmate: supervisor record was not retired"
    assert_absent "$case_dir/secondmate-home" "$posture secondmate: supervisor home was not removed"
    assert_absent "$case_dir/docker.log" "$posture secondmate: standalone retirement contacted Docker"
  done
  pass "standalone secondmate retirement skips Docker even when the daemon is unavailable"
}

test_docker_project_record_failure_prevents_container_removal() {
  local case_dir store rc before
  case_dir=$(make_docker_case docker-project-record-failure)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-own own-derived "com.docker.compose.project=derived;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" network n-own derived-network "com.docker.compose.project=derived"
  before=$(cat "$case_dir/state/task-x1.meta")
  printf '#!/usr/bin/env bash\nexit 1\n' > "$case_dir/fakebin/mv"
  chmod +x "$case_dir/fakebin/mv"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 0 "" "$2" "$3"' \
      _ "$ROOT" "$case_dir/state/task-x1.meta" "$case_dir/wt" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "project-record-failure: cleanup ignored failed record publication"
  assert_equals "$before" "$(cat "$case_dir/state/task-x1.meta")" \
    "project-record-failure: existing task metadata was changed"
  assert_equals "own-derived " "$(docker_store_names "$store" container)" \
    "project-record-failure: container was removed before its project identity was retained"
  assert_equals "derived-network " "$(docker_store_names "$store" network)" \
    "project-record-failure: network was removed after record failure"
  pass "failed project-identity publication preserves the task record and container evidence"
}

test_docker_verified_cleanup_clears_retained_projects() {
  local case_dir store meta rc
  case_dir=$(make_docker_case docker-clears-projects)
  store="$case_dir/docker-store"
  meta="$case_dir/state/task-x1.meta"
  : > "$store"
  docker_store_add "$store" container c-own own-derived "com.docker.compose.project=derived;com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" network n-own derived-network "com.docker.compose.project=derived"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_NETWORK_RM_FAIL=derived-network PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 0 "" "$2" "$3"' \
      _ "$ROOT" "$meta" "$case_dir/wt" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "clears-projects: a failed network removal reported success"
  assert_grep 'docker_projects= derived' "$meta" "clears-projects: an incomplete cleanup did not retain project identities"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 0 "" "$2" "$3"' \
      _ "$ROOT" "$meta" "$case_dir/wt" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "clears-projects: verified cleanup failed: $(cat "$case_dir/stderr")"
  assert_equals "" "$(docker_store_names "$store" network)" "clears-projects: derived network survived"
  assert_no_grep 'docker_projects=' "$meta" "clears-projects: verified cleanup left retained project identities"
  assert_grep 'kind=ship' "$meta" "clears-projects: clearing project identities damaged the task record"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_DOWN=1 PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 0 "" "$2" "$3"' \
      _ "$ROOT" "$meta" "$case_dir/wt" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "clears-projects: a stopped daemon refused a task whose cleanup was already verified: $(cat "$case_dir/stderr")"
  pass "a verified Docker cleanup clears retained project identities, so a later stopped daemon does not refuse the retry"
}

test_docker_ambiguous_ids_trust_only_worktree_evidence() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-ambiguous-id)
  store="$case_dir/docker-store"
  : > "$store"
  docker_store_add "$store" container c-name task-x1-db "" ""
  docker_store_add "$store" container c-label marked-only "fm.task=task-x1" ""
  docker_store_add "$store" container c-project exact-project "com.docker.compose.project=task-x1" ""
  docker_store_add "$store" container c-path own-worktree "com.docker.compose.project.working_dir=$case_dir/wt" ""
  docker_store_add "$store" network n-label marked-network "fm.task=task-x1"
  docker_store_add "$store" volume marked-volume "fm.task=task-x1"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-task-docker-lib.sh"; fm_task_docker_cleanup task-x1 "" 1 "" "$2" "$3"' \
      _ "$ROOT" "$case_dir/state/task-x1.meta" "$case_dir/wt" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "ambiguous-id: cleanup failed: $(cat "$case_dir/stderr")"
  assert_equals "exact-project marked-only task-x1-db " "$(docker_store_names "$store" container)" \
    "ambiguous-id: ambiguous identity authorized removal"
  assert_equals "marked-network " "$(docker_store_names "$store" network)" "ambiguous-id: ambiguous network marker was trusted"
  assert_equals "marked-volume " "$(docker_store_names "$store" volume)" "ambiguous-id: ambiguous volume marker was trusted"
  pass "ambiguous task ids authorize only worktree evidence"
}

test_docker_all_failure_channels_retain_forced_tasks_until_retry() {
  local channel case_dir store rc fail_operation ps_fail network_fail volume_fail
  for channel in verify-ps final-ps container-rm network-ls volume-ls network-rm volume-rm; do
    case_dir=$(make_docker_case "docker-failure-$channel")
    store="$case_dir/docker-store"
    : > "$store"
    : > "$case_dir/state/task-x1.status"
    docker_store_add "$store" container c-own owned-container "com.docker.compose.project=derived;com.supabase.cli.project=derived-supa;com.docker.compose.project.working_dir=$case_dir/wt" ""
    docker_store_add "$store" network n-own owned-network "com.docker.compose.project=derived"
    docker_store_add "$store" network n-supa owned-supa-project-network "com.docker.compose.project=derived-supa"
    docker_store_add "$store" volume owned-volume "fm.task=task-x1"
    cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf '%s\n' returned >> "$case_dir/retired"
EOF
    chmod +x "$case_dir/fakebin/treehouse"
    fail_operation='' ps_fail='' network_fail='' volume_fail=''
    case "$channel" in
      verify-ps) ps_fail=2 ;;
      final-ps) ps_fail=3 ;;
      container-rm) fail_operation='rm' ;;
      network-ls) fail_operation=network-ls ;;
      volume-ls) fail_operation=volume-ls ;;
      network-rm) network_fail=owned-network ;;
      volume-rm) volume_fail=owned-volume ;;
    esac
    rc=0
    FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_FAIL="$fail_operation" \
      FM_FAKE_DOCKER_PS_FAIL_AT="$ps_fail" \
      FM_FAKE_DOCKER_NETWORK_RM_FAIL="$network_fail" FM_FAKE_DOCKER_VOLUME_RM_FAIL="$volume_fail" \
      run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$channel: --force bypassed Docker failure"
    assert_present "$case_dir/state/task-x1.meta" "$channel: task metadata was removed"
    assert_present "$case_dir/state/task-x1.status" "$channel: task status was removed"
    assert_present "$case_dir/wt" "$channel: worktree was removed"
    assert_absent "$case_dir/retired" "$channel: worktree return ran before confirmed Docker cleanup"
    assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" "$channel: teardown falsely reported completion"
    assert_grep 'docker_projects= derived derived-supa' "$case_dir/state/task-x1.meta" \
      "$channel: retained task record lost its derived project identities"
    case "$channel" in
      verify-ps|final-ps)
        assert_grep "warning: Docker container listing failed" "$case_dir/stderr" \
          "$channel: the failed container listing was not named"
        assert_grep "fake docker: ps failed" "$case_dir/stderr" \
          "$channel: Docker's own container listing error was hidden"
        ;;
      network-ls|volume-ls)
        assert_grep "warning: Docker ${channel%-ls} listing failed" "$case_dir/stderr" \
          "$channel: the failed listing was not named"
        assert_grep "fake docker: $channel failed" "$case_dir/stderr" \
          "$channel: Docker's own listing error was hidden"
        ;;
      network-rm)
        assert_grep "Error: cannot remove network owned-network" "$case_dir/stderr" \
          "$channel: Docker's own network removal error was hidden"
        ;;
      volume-rm)
        assert_grep "Error: cannot remove volume owned-volume" "$case_dir/stderr" \
          "$channel: Docker's own volume removal error was hidden"
        ;;
    esac
    if [ "$channel" = network-rm ]; then
      assert_equals "" "$(docker_store_names "$store" container)" "$channel: regression requires container removal to succeed"
      assert_equals "owned-network owned-supa-project-network " "$(docker_store_names "$store" network)" \
        "$channel: regression requires derived networks to survive the first attempt"
    fi
    rc=0
    FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
      > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
    expect_code 0 "$rc" "$channel: retry failed: $(cat "$case_dir/retry.stderr")"
    assert_absent "$case_dir/state/task-x1.meta" "$channel: retry did not retire metadata"
    assert_equals "" "$(docker_store_names "$store" container)" "$channel: owned container survived retry"
    assert_equals "" "$(docker_store_names "$store" network)" "$channel: owned network survived retry"
    assert_equals "" "$(docker_store_names "$store" volume)" "$channel: owned volume survived retry"
  done
  pass "every Docker listing, verification and removal failure retains forced task records until a successful retry"
}

test_top_level_pipeline_discovery_failures_remain_best_effort() {
  local case_dir failure rc advanced out
  for failure in status ledger; do
    case_dir=$(make_case "top-level-query-$failure")
    write_meta "$case_dir" no-mistakes ship
    land_shippable_commit "$case_dir"
    advanced=$(make_unfetched_pipeline_heads "$case_dir")
    out=$(parked_axi_status_toon fm/task-x1 "$advanced")
    rc=0
    FM_FAKE_AXI_STATUS="$out" FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
      FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
      FM_FAKE_NM_STATUS_FAIL="$([ "$failure" != status ] || printf 1)" \
      FM_FAKE_NM_RUNS_FAIL="$([ "$failure" != ledger ] || printf 1)" \
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "top-level $failure query failure blocked teardown"
    assert_absent "$case_dir/state/task-x1.meta" "top-level $failure failure retained task"
    assert_absent "$case_dir/nm-abort.log" "top-level $failure failure authorized an abort"
    if [ "$failure" = ledger ]; then
      assert_present "$case_dir/nm-runs.log" "top-level ledger failure was not exercised"
    fi
  done
  pass "top-level status and ledger query failures remain best effort"
}

test_forced_secondmate_cleans_each_child_docker_before_retirement_and_retries() {
  assert_forced_child_docker_cleanup_and_retry tmux
  pass "forced secondmate closes each child endpoint before its Docker cleanup and retains failures for retry"
}

test_forced_orca_children_clean_docker_before_worktree_removal() {
  assert_forced_child_docker_cleanup_and_retry orca
  pass "forced Orca children clean Docker before worktree removal and retain identity and worktrees on failure"
}

test_forced_nested_secondmate_cleans_grandchild_docker_before_retirement_and_retries() {
  local case_dir home nested_home grandchild_wt store rc
  case_dir=$(make_case docker-grandchild)
  write_meta "$case_dir" local-only secondmate
  grandchild_wt="$case_dir/grandchild-herdr-wt"
  git -C "$case_dir/project" worktree add -q -b fm/grandchild-herdr "$grandchild_wt" main
  configure_nested_secondmate_with_herdr_grandchild "$case_dir" "$grandchild_wt"
  home="$case_dir/secondmate-home"
  nested_home="$home/nested-home"
  store="$case_dir/docker-store"
  configure_child_docker_race "$case_dir"
  : > "$case_dir/child-producers/grandchild-herdr.live"
  printf '%s\n' grandchild-herdr > "$case_dir/current-child"
  : > "$store"
  docker_store_add "$store" container c-grandchild owned-grandchild "fm.task=grandchild-herdr" ""
  docker_store_add "$store" container c-path grandchild-path "com.docker.compose.project.working_dir=$grandchild_wt" ""
  docker_store_add "$store" container c-foreign foreign-grandchild "fm.task=other" ""
  docker_store_add "$store" network n-grandchild grandchild-network "fm.task=grandchild-herdr"
  docker_store_add "$store" volume grandchild-volume "fm.task=grandchild-herdr"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_DOCKER_RM_FAIL=owned-grandchild FM_FAKE_HERDR_CONFIRMED_GONE=1 \
    FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "grandchild: Docker failure must stop recursive retirement"
  assert_present "$case_dir/state/task-x1.meta" "grandchild: parent identity retired"
  assert_present "$home/state/nested-sm.meta" "grandchild: nested secondmate identity retired"
  assert_present "$nested_home/state/grandchild-herdr.meta" "grandchild: grandchild identity retired"
  assert_present "$nested_home/state/grandchild-herdr.status" "grandchild: grandchild status retired"
  assert_present "$nested_home" "grandchild: nested home removed"
  assert_present "$case_dir/closed" "grandchild: endpoint was not closed before Docker cleanup"
  assert_equals "foreign-grandchild owned-grandchild " "$(docker_store_names "$store" container)" \
    "grandchild: containers produced before the endpoint closed survived the cleanup attempt"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" FM_FAKE_HERDR_CONFIRMED_GONE=1 \
    FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
    run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "grandchild: retry failed: $(cat "$case_dir/retry.stderr")"
  assert_absent "$home" "grandchild: retry retained secondmate homes"
  assert_absent "$case_dir/state/task-x1.meta" "grandchild: retry retained parent record"
  assert_equals "foreign-grandchild " "$(docker_store_names "$store" container)" "grandchild: wrong Docker objects survived"
  assert_equals "" "$(docker_store_names "$store" network)" "grandchild: network survived"
  assert_equals "" "$(docker_store_names "$store" volume)" "grandchild: volume survived"
  pass "recursive forced secondmate cleanup closes the grandchild endpoint before Docker cleanup and retains failed identity for retry"
}

test_docker_container_arriving_during_resource_cleanup_blocks_retirement() {
  local case_dir store rc
  case_dir=$(make_docker_case docker-late-container)
  store="$case_dir/docker-store"
  configure_child_docker_race "$case_dir"
  : > "$store"
  docker_store_add "$store" container c-own owned-container "fm.task=task-x1" ""
  docker_store_add "$case_dir/arriving-containers" container c-late arriving-container "fm.task=task-x1" ""
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "late-container: cleanup falsely reported success"
  assert_present "$case_dir/state/task-x1.meta" "late-container: retry identity was retired"
  assert_present "$case_dir/wt" "late-container: worktree was retired"
  assert_equals "arriving-container " "$(docker_store_names "$store" container)" "late-container: arrival was not exercised"
  rc=0
  FM_FAKE_DOCKER_STORE="$store" run_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" \
    > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "late-container: retry failed: $(cat "$case_dir/retry.stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "late-container: retry retained identity"
  assert_equals "" "$(docker_store_names "$store" container)" "late-container: owned arrival survived retry"
  pass "a container arriving during network cleanup blocks retirement until retry removes it"
}

test_missing_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-startup-source"
  pass "a missing teardown startup source refuses before cleanup"
}

test_unreadable_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case unreadable-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  cp "$ROOT/bin/fm-nm-run-lib.sh" "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  chmod 000 "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  if [ -r "$case_dir/test-root/bin/fm-nm-run-lib.sh" ]; then
    pass "unreadable startup source skipped: this user can read mode-000 files"
    return 0
  fi
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "unreadable-startup-source"
  pass "an unreadable teardown startup source refuses before cleanup"
}

test_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-adapter-sibling)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-session-lock-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-adapter-sibling"
  pass "a missing adapter sibling refuses before cleanup"
}

test_forced_child_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir home rc log closed
  case_dir=$(make_case missing-child-adapter-sibling)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  prepare_teardown_source_copy "$case_dir"
  log="$case_dir/herdr.log"
  closed="$case_dir/closed"
  : > "$log"
  rm -f "$case_dir/test-root/bin/fm-transition-lib.sh"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-child-source"
  [ ! -s "$log" ] || fail "missing-child-source: teardown reached the child's runtime with its required source missing"
  [ -e "$home/state/child-herdr.meta" ] || fail "missing-child-source: the refusal erased the child record"
  [ -d "$home" ] || fail "missing-child-source: the refusal removed the secondmate home"
  ln -s "$ROOT/bin/fm-transition-lib.sh" "$case_dir/test-root/bin/fm-transition-lib.sh"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_copied_teardown "$case_dir" --force > "$case_dir/restored.stdout" 2> "$case_dir/restored.stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "restored-child-source: teardown ignored the unresolvable child runtime"
  [ -s "$log" ] || fail "restored-child-source: the valid fixture never reached child runtime admission: $(cat "$case_dir/restored.stderr")"
  assert_source_refusal_preserved_state "$case_dir" "restored-child-source"
  [ -e "$home/state/child-herdr.meta" ] || fail "restored-child-source: the refusal erased the child record"
  [ ! -e "$closed" ] || fail "restored-child-source: refusal attempted a child close"
  pass "a forced descendant with a missing adapter sibling refuses before cleanup"
}

test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup() {
  local case_dir home rc
  case_dir=$(make_case missing-own-adapter-sibling)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=zs:3" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "backend=zellij" \
    "zellij_session=zs" \
    "zellij_tab_id=1" \
    "zellij_pane_id=3" \
    "spawn_gen=teardown-test-task-x1"
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-tmux.meta" \
    "window=childsession:fm-child-tmux" \
    "endpoint_task_id=child-tmux" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  : > "$home/state/child-tmux.status"
  prepare_teardown_source_copy "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tmux.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  : > "$case_dir/tmux.log"
  rm -f "$case_dir/test-root/bin/fm-backend-hometag-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-own-source"
  [ -e "$home/state/child-tmux.meta" ] || fail "missing-own-source: the refusal erased the child record"
  [ -e "$home/state/child-tmux.status" ] || fail "missing-own-source: the refusal erased the child status"
  [ -d "$home" ] || fail "missing-own-source: the refusal removed the secondmate home"
  if grep -q "kill" "$case_dir/tmux.log"; then
    fail "missing-own-source: the refusal killed the child endpoint: $(cat "$case_dir/tmux.log")"
  fi
  pass "a forced secondmate with a missing own adapter sibling refuses before child cleanup"
}

test_retained_sources_still_reach_the_ordinary_refusal() {
  local case_dir rc
  case_dir=$(make_case retained-sources)
  prepare_teardown_source_copy "$case_dir"
  rc=0
  FM_HOME="${FM_HOME:-$case_dir/primary-home}" \
  FM_ROOT_OVERRIDE="$case_dir/test-root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/fm-teardown.sh" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 2 ] || fail "retained-sources: a present source tree should still reject a request with no task id (rc=$rc)"
  assert_grep "invalid teardown request" "$case_dir/stderr" \
    "retained-sources: the ordinary refusal was replaced"
  pass "present required sources still reach the ordinary teardown refusal"
}

test_task_teardown_preserves_another_homes_abandoned_worker() {
  local case_dir foreign_root pid rc
  case_dir=$(make_case caller-confined-reaping)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  prepare_teardown_source_copy "$case_dir"
  foreign_root="$case_dir/other-home"
  mkdir -p "$foreign_root/bin"
  cat > "$foreign_root/bin/fm-remote-job-worker.sh" <<'SH'
#!/usr/bin/env bash
trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit' TERM
sleep "$FM_TEST_STUB_MAX_BLOCK_SECONDS" &
child=$!
printf '%s\n' ready > "$FM_FOREIGN_WORKER_READY"
wait "$child"
SH
  teardown_fixture_start "$case_dir" TERM env FM_FOREIGN_WORKER_READY="$case_dir/foreign-ready" \
    perl -e 'setpgrp(0, 0); exec @ARGV' \
    "$BASH" "$foreign_root/bin/fm-remote-job-worker.sh" --serve
  pid=$TEARDOWN_FIXTURE_PID
  local tries=0
  while [ ! -e "$case_dir/foreign-ready" ] && [ "$tries" -lt 100 ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  if [ ! -e "$case_dir/foreign-ready" ]; then
    fail "caller-confinement: foreign worker did not start"
  fi
  rm -rf "$foreign_root"

  # Bound the administrative reaper's account scan to our one real fixture
  # process, never any actual account worker. Other ps queries stay native.
  cat > "$case_dir/fakebin/ps" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -u ]; then
  exec "$REAL_PS_FOR_TEST" -p "$pid" -o pid=,command=
fi
exec "$REAL_PS_FOR_TEST" "\$@"
SH
  chmod +x "$case_dir/fakebin/ps"
  rc=0
  run_copied_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "caller-confinement: task teardown killed another home's abandoned worker"
  fi
  teardown_fixture_stop "$pid"
  expect_code 0 "$rc" "caller-confinement: ordinary task teardown should complete"
  assert_absent "$case_dir/state/task-x1.meta" \
    "caller-confinement: ordinary task cleanup did not complete"
  pass "task teardown completes without reaping another home's abandoned worker"
}

# A cleanup holds its task's lease-command lock until it ends (bin/fm-lease-lib.sh
# owns the contract), and that lock once covered the whole home: one slow
# cleanup left every steer to every other task undelivered until it finished.
# The fixture stalls the cleanup at its endpoint close, which runs inside the
# guard, and requires a steer to a different task to complete while the cleanup
# is still stalled. Ordering against the stalled cleanup is the assertion, so no
# time bound is involved; on a home-wide lock the steer waits until the stub's
# own bound lets the cleanup finish, and the cleanup is no longer running.
test_teardown_never_holds_up_a_steer_to_another_task() {
  local case_dir fakebin rc teardown_pid send_rc
  case_dir=$(make_case guard-scope)
  fakebin="$case_dir/fakebin"
  write_meta "$case_dir" local-only ship
  wt_commit_file "$case_dir" feature.txt landed "merged work"
  git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  fm_write_meta "$case_dir/state/task-y2.meta" "window=firstmate:fm-task-y2" "kind=ship"
  : > "$case_dir/config/supervision-host"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window)
    : > "$FM_TEST_READY"
    n=0
    while [ ! -e "$FM_TEST_RELEASE" ] && [ "$n" -lt 2000 ]; do sleep 0.01; n=$((n + 1)); done
    exit 0 ;;
  send-keys) printf 'send-keys %s\n' "$*" >> "$FM_TEST_TMUX_LOG"; exit 0 ;;
  display-message)
    case " $* " in
      *cursor_y*) printf '1\n' ;;
      *pane_current_command*) printf 'claude\n' ;;
      *) printf '%%1\n' ;;
    esac
    exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"

  FM_TEST_READY="$case_dir/kill-ready" FM_TEST_RELEASE="$case_dir/kill-release" \
    FM_TEST_TMUX_LOG="$case_dir/tmux.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" &
  teardown_pid=$!
  fm_test_wait_until --while-alive "$teardown_pid" --progress-file "$case_dir/stdout" --progress-file "$case_dir/stderr" -- test -e "$case_dir/kill-ready" \
    || { : > "$case_dir/kill-release"; wait "$teardown_pid" 2>/dev/null; fail "guard-scope: teardown never reached its endpoint close: $(cat "$case_dir/stderr")"; }
  compgen -G "$case_dir/state/.fm-lease-command*.lock" >/dev/null \
    || { : > "$case_dir/kill-release"; wait "$teardown_pid" 2>/dev/null; fail "guard-scope: the cleanup held no lease-command lock, so the case proves nothing"; }

  send_rc=0
  PATH="$fakebin:$PATH" FM_HOME="$case_dir/primary-home" FM_ROOT_OVERRIDE="$case_dir/code-root" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_CONFIG_OVERRIDE="$case_dir/config" FM_SEND_SETTLE=0 \
    FM_TEST_TMUX_LOG="$case_dir/tmux.log" \
    "$case_dir/code-root/bin/fm-send.sh" task-y2 "ruling for the other lane" \
    > "$case_dir/send.out" 2> "$case_dir/send.err" || send_rc=$?
  kill -0 "$teardown_pid" 2>/dev/null \
    || fail "guard-scope: the steer to another task returned only after the cleanup ended (rc=$send_rc): $(cat "$case_dir/send.err")"
  expect_code 0 "$send_rc" "guard-scope: the steer to another task failed: $(cat "$case_dir/send.err")"
  grep -qF 'ruling for the other lane' "$case_dir/state/task-y2.inbox/001.msg" \
    || fail "guard-scope: the steer to another task was not recorded in its inbox"

  : > "$case_dir/kill-release"
  rc=0
  wait "$teardown_pid" || rc=$?
  expect_code 0 "$rc" "guard-scope: the stalled cleanup did not complete: $(cat "$case_dir/stderr")"
  pass "a steer to another task completes while a cleanup holds its own task's lease lock"
}

# The lane-registry scan runs three times in one cleanup and reads the worktree
# registry of every project named by every task record in every local home.
# Records naming one clone used to be read once each, so the scan cost grew with
# the fleet's record count and reached over a minute per scan; each distinct
# registry is now read once per scan. The assertion compares one home with and
# without a large set of extra records naming the same clone.
test_lane_registry_scan_reads_each_distinct_registry_once() {
  local case_dir variant homes metas h m reads_with='' reads_without=''
  for variant in without with; do
    case_dir=$(make_case registry-scan-$variant)
    write_meta "$case_dir" local-only ship
    wt_commit_file "$case_dir" feature.txt landed "merged work"
    git -C "$case_dir/project" update-ref refs/heads/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
    mkdir -p "$case_dir/primary-home/data"
    : > "$case_dir/primary-home/data/secondmates.md"
    homes=3 metas=0
    [ "$variant" != with ] || metas=6
    for ((h = 1; h <= homes; h++)); do
      mkdir -p "$case_dir/fleet-home-$h/state" "$case_dir/fleet-home-$h/data"
      printf -- '- lane-%s - scan lane (home: %s; scope: scan; projects: p; added 2026-10-10)\n' \
        "$h" "$case_dir/fleet-home-$h" >> "$case_dir/primary-home/data/secondmates.md"
      for ((m = 1; m <= metas; m++)); do
        printf 'project=%s\nkind=ship\n' "$case_dir/project" > "$case_dir/fleet-home-$h/state/lane-$h-task-$m.meta"
      done
    done
    cat > "$case_dir/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" worktree list "*) printf '%s\n' "\$*" >> "$case_dir/worktree-list.log" ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
    chmod +x "$case_dir/fakebin/git"
    : > "$case_dir/worktree-list.log"
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "registry-scan-$variant: teardown failed: $(cat "$case_dir/stderr")"
    if [ "$variant" = with ]; then
      reads_with=$(wc -l < "$case_dir/worktree-list.log" | tr -d ' ')
    else
      reads_without=$(wc -l < "$case_dir/worktree-list.log" | tr -d ' ')
    fi
  done
  [ "$reads_without" -gt 0 ] || fail "registry-scan: the cleanup never read a worktree registry, so the case proves nothing"
  [ "$reads_with" = "$reads_without" ] \
    || fail "registry-scan: $reads_with registry reads with 18 extra records naming one clone, $reads_without without; the scan must read each distinct registry once"
  pass "the lane-registry scan reads each distinct registry once however many records name it"
}

test_locked_own_copy_is_released_by_the_closeout_driver() {
  local rc head
  dead_launcher_pid
  make_foreign_copy_case foreign-locked-own "$FOREIGN_DEAD_PID"
  head=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
  run_foreign_teardown rc
  expect_code 0 "$rc" "locked-own: a landed Vernant-locked copy must be released: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --execute-cleanup" "$(cat "$FOREIGN_CASE/closeout.log")" \
    "locked-own: the driver was not run once from the slot with the copy and the execute flag"
  assert_absent "$FOREIGN_COPY" "locked-own: the copy survived"
  git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -F "worktree $FOREIGN_COPY" >/dev/null \
    && fail "locked-own: the copy is still registered"
  assert_equals "$head" "$(git -C "$FOREIGN_CASE/project" rev-parse refs/heads/fm/task-x1-v2)" \
    "locked-own: the copy's branch moved"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "locked-own: the slot was not returned"
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" "locked-own: the task record survived"
  pass "a landed copy locked by Vernant is released through the closeout driver, removed, and the slot is returned"
}

test_unlocked_landed_foreign_copy_is_removed_without_the_driver() {
  local rc
  make_foreign_copy_case foreign-landed-unlocked
  run_foreign_teardown rc
  expect_code 0 "$rc" "foreign-landed: an unlocked landed copy must be removed: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_COPY" "foreign-landed: the copy survived; stdout=$(cat "$FOREIGN_CASE/stdout"); stderr=$(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_CASE/closeout.log" "foreign-landed: the driver ran for an unlocked copy"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "foreign-landed: the slot was not returned"
  pass "an unlocked landed foreign copy is removed with a plain git worktree remove and the slot is returned"
}

# bin/fm-idle-session-reap.sh keeps only the first output line that names a
# refusal as the written reason. For a foreign copy that stays, that line must be
# the copy's own reason, not the generic custody refusal that follows it. The
# reaper's own first_refusal_line runs on the real teardown's refusal output.
test_idle_reap_keeps_the_per_copy_reason_of_a_foreign_copy_refusal() {
  local rc line
  make_foreign_copy_case foreign-reap-reason
  printf 'edit\n' > "$FOREIGN_COPY/untracked.txt"
  run_foreign_teardown rc
  expect_code 1 "$rc" "reap-reason: a dirty copy must be refused: $(cat "$FOREIGN_CASE/stderr")"
  eval "$(sed -n '/^first_refusal_line() {/,/^}/p' "$ROOT/bin/fm-idle-session-reap.sh")"
  line=$(first_refusal_line "$(cat "$FOREIGN_CASE/stdout" "$FOREIGN_CASE/stderr")")
  # Preserve the actual typed refusal as the reaper's reason rather than pinning
  # presentation wording; it must name the dirty copy.
  [[ "$line" == *"rule=copy-preserved"* && "$line" == *"$FOREIGN_COPY"* ]] \
    || fail "reaper discarded the per-copy predicate: $line"
  jq -e 'select(.rule_id == "copy-preserved" and .outcome == "blocked")' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail "missing typed landing refusal"
  pass "the reaper's first refusal line for a foreign copy that stays is the copy's own written reason"
}

test_foreign_copy_with_unsaved_files_is_refused() {
  local rc
  make_foreign_copy_case foreign-dirty
  printf 'edit\n' > "$FOREIGN_COPY/untracked.txt"
  run_foreign_teardown rc
  expect_code 1 "$rc" "foreign-dirty: a copy with uncommitted files must be refused: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "contains registered copy $FOREIGN_COPY" "$FOREIGN_CASE/stderr" "foreign-dirty: the refusal changed"
  assert_foreign_copy_untouched foreign-dirty
  assert_present "$FOREIGN_COPY/untracked.txt" "foreign-dirty: the file was lost"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "foreign-dirty: a refused close wrote a held-copy record"
  pass "uncommitted files make a foreign copy refuse the close"
}

test_a_foreign_copy_with_only_unique_ignored_files_is_held_and_the_slot_is_not_returned() {
  local rc record
  make_held_case held-ignored-only
  held_ignored_file "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-ignored-only: a landed task must close beside a foreign copy whose only blocker is a unique ignored file: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-ignored-only
  held_assert_untouched held-ignored-only "$FOREIGN_CASE" "$FOREIGN_COPY"
  assert_absent "$FOREIGN_CASE/treehouse.log" "held-ignored-only: treehouse return --force ran"
  assert_present "$FOREIGN_COPY" "held-ignored-only: the foreign copy was removed"
  assert_equals "only here" "$(cat "$FOREIGN_COPY/unique.dat")" "held-ignored-only: the foreign copy's ignored file changed"
  assert_absent "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" "held-ignored-only: the held copy's files were copied as if it were released"
  assert_no_grep "REFUSED" "$FOREIGN_CASE/stderr" "held-ignored-only: a close that succeeded printed a refusal"
  assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: it holds ignored files that exist nowhere else: unique.dat." \
    "$FOREIGN_CASE/stdout" "held-ignored-only: the output did not list the held copy: $(cat "$FOREIGN_CASE/stdout")"
  record=$FOREIGN_CASE/data/held-foreign-copies.log
  awk -F'\t' -v c="$FOREIGN_COPY" '$2 == "task-x1" && $3 == "'"$FOREIGN_SLOT"'" && $4 == c && $5 == "it holds ignored files that exist nowhere else: unique.dat" { ok = 1 } END { exit !ok }' "$record" \
    || fail "held-ignored-only: the record line is missing or its reason is not exact: $(cat "$record")"
  pass "an own landed copy beside a foreign copy with only a unique ignored file closes, the foreign copy is kept byte-identical, treehouse return --force is not called, and the record has one line"
}

test_the_next_step_for_a_copy_held_for_ignored_files_never_names_a_removal() {
  local rc copy_q
  make_held_case held-ignored-notice
  held_ignored_file "$FOREIGN_COPY"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-ignored-notice: a landed task must close beside a copy held for an ignored file: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-ignored-notice
  held_assert_untouched held-ignored-notice "$FOREIGN_CASE" "$FOREIGN_COPY"
  printf -v copy_q '%q' "$FOREIGN_COPY"
  assert_grep "next step for the owner of $FOREIGN_COPY: review its ignored files with git -C $copy_q status --ignored" "$FOREIGN_CASE/stdout" \
    "held-ignored-notice: the next step did not tell the owner to review the ignored files: $(cat "$FOREIGN_CASE/stdout")"
  assert_no_grep "worktree remove" "$FOREIGN_CASE/stdout" \
    "held-ignored-notice: the next step names a removal that deletes the ignored files it protects: $(cat "$FOREIGN_CASE/stdout")"
  assert_no_grep "--cleanup-worktree" "$FOREIGN_CASE/stdout" \
    "held-ignored-notice: the next step names a removal that deletes the ignored files it protects: $(cat "$FOREIGN_CASE/stdout")"
  assert_grep "nothing returns it automatically; a held copy is removed only on the owner's word naming it." "$FOREIGN_CASE/stdout" \
    "held-ignored-notice: the closing sentence did not say a copy held for ignored files goes only on the owner's word: $(cat "$FOREIGN_CASE/stdout")"
  assert_no_grep "once its HEAD is landed" "$FOREIGN_CASE/stdout" \
    "held-ignored-notice: the output promises a landing removes a copy held for ignored files: $(cat "$FOREIGN_CASE/stdout")"
  pass "the next step for a copy held for ignored files says to review and save them, and names no removal"
}

test_held_copy_notices_and_record_show_no_control_character_and_quote_the_command() {
  local rc quoted record
  make_held_case held-hostile-names
  quoted="$FOREIGN_SLOT/.claude/worktrees/it's"
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/other-lane "$quoted" main
  printf '%s\n' 'esc*name.dat' >> "$(git -C "$quoted" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'only here\n' > "$quoted/"$'esc\033[31mred\rname.dat'
  held_snapshot "$FOREIGN_CASE" "$quoted"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-hostile-names: a landed task must close beside a copy whose names hold control characters: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-hostile-names
  held_assert_untouched held-hostile-names "$FOREIGN_CASE" "$quoted"
  record=$FOREIGN_CASE/data/held-foreign-copies.log
  assert_equals 1 "$(wc -l < "$record" | tr -d ' ')" "held-hostile-names: the record is not one line"
  if LC_ALL=C grep -q '[[:cntrl:]]' "$FOREIGN_CASE/stdout"; then
    fail "held-hostile-names: the notice carries a control character: $(cat -v "$FOREIGN_CASE/stdout")"
  fi
  if LC_ALL=C tr -d '\t\n' < "$record" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    fail "held-hostile-names: the record carries a control character: $(cat -v "$record")"
  fi
  assert_grep 'esc?[31mred?name.dat' "$FOREIGN_CASE/stdout" "held-hostile-names: the notice did not show the cleaned file name: $(cat -v "$FOREIGN_CASE/stdout")"
  assert_grep 'esc?[31mred?name.dat' "$record" "held-hostile-names: the record did not show the cleaned file name: $(cat -v "$record")"
  printf -v quoted '%q' "$quoted"
  assert_grep "git -C $quoted status --ignored" "$FOREIGN_CASE/stdout" \
    "held-hostile-names: the printed command does not quote the copy path with printf %q: $(cat -v "$FOREIGN_CASE/stdout")"
  pass "held-copy notices and the record show control characters as ?, and the printed command quotes the copy path so it pastes back unchanged"
}

test_a_forced_close_preserves_and_releases_a_foreign_copy_with_unique_ignored_files() {
  local rc
  make_foreign_copy_case forced-foreign-ignored
  seed_backlog_in_flight "$FOREIGN_CASE"
  held_ignored_file "$FOREIGN_COPY"
  FOREIGN_TEARDOWN_ARGS=(--force --drop-file "$(fm_test_drop_file)")
  run_foreign_teardown rc
  FOREIGN_TEARDOWN_ARGS=()
  expect_code 0 "$rc" "forced-foreign-ignored: a forced close never holds, so the copy's ignored file must be preserved and the copy released: $(cat "$FOREIGN_CASE/stderr")"
  assert_foreign_ignored_preserved_and_released forced-foreign-ignored "$FOREIGN_COPY"
  pass "a forced close preserves a foreign copy's unique ignored file with its SHA-256 and releases the copy, as the held-copy rule never applies to it"
}

# graft's generated output (tests/lib.sh fm_test_graft_output) is not unique
# work: alone it neither holds a foreign copy nor is preserved from a released
# own copy. A custom .ignore or a clone below graft/ beside it keeps the existing
# protection on both paths (data/fm-merge-prune-graft-scratch/report.md).
graft_output_variant() {  # <copy> <generated|custom-ignore|nested-git>
  fm_test_graft_output "$1"
  case "$2" in
    custom-ignore) printf 'project-private/\n' >> "$1/.ignore" ;;
    nested-git) git init -q "$1/graft/n1" ;;
  esac
}

test_graft_output_alone_does_not_hold_a_foreign_copy() {
  local rc variant label entry
  for variant in generated custom-ignore nested-git; do
    label=held-graft-$variant
    make_held_case "$label"
    graft_output_variant "$FOREIGN_COPY" "$variant"
    run_foreign_teardown rc
    expect_code 0 "$rc" "$label: the landed task did not close: $(cat "$FOREIGN_CASE/stderr")"
    assert_absent "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" "$label: a released or held copy's graft output was copied to task data"
    case "$variant" in
      generated)
        assert_absent "$FOREIGN_COPY" "$label: a foreign copy holding only graft output was not released: $(cat "$FOREIGN_CASE/stdout")"
        assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "$label: graft output alone held the foreign copy"
        ;;
      *)
        case "$variant" in custom-ignore) entry=.ignore ;; *) entry=graft ;; esac
        assert_present "$FOREIGN_COPY/graft" "$label: the held copy lost its graft directory"
        assert_grep "held foreign copy $FOREIGN_COPY stays in pool slot $FOREIGN_SLOT: it holds ignored files that exist nowhere else: $entry." \
          "$FOREIGN_CASE/stdout" "$label: the copy was not held for $entry: $(cat "$FOREIGN_CASE/stdout")"
        ;;
    esac
  done
  pass "graft output alone does not hold a foreign copy; a custom .ignore or a clone below graft/ still does"
}

test_graft_output_is_not_preserved_from_a_released_own_nested_copy() {
  local rc variant label root
  for variant in generated custom-ignore nested-git; do
    label=own-locked-graft-$variant
    dead_launcher_pid
    make_own_locked_copy_case "$label" enclosing "$FOREIGN_DEAD_PID"
    graft_output_variant "$FOREIGN_COPY" "$variant"
    run_foreign_teardown rc
    expect_code 0 "$rc" "$label: the copy must be released: $(cat "$FOREIGN_CASE/stderr")"
    assert_absent "$FOREIGN_COPY" "$label: the copy survived"
    root=$FOREIGN_CASE/data/task-x1/nested-copy-preserved
    case "$variant" in
      generated)
        assert_absent "$root" "$label: graft output was copied to task data"
        ;;
      custom-ignore)
        [ -n "$(find "$root" -path '*/.ignore' -type f 2>/dev/null)" ] || fail "$label: the custom .ignore was not preserved"
        [ -z "$(find "$root" -path '*/graft' 2>/dev/null)" ] || fail "$label: graft output was copied to task data"
        ;;
      nested-git)
        [ -n "$(find "$root" -path '*/graft/n1/.git' 2>/dev/null)" ] || fail "$label: the clone below graft/ was not preserved"
        [ -z "$(find "$root" -path '*/.ignore' 2>/dev/null)" ] || fail "$label: graft's generated .ignore was copied to task data"
        ;;
    esac
  done
  pass "a released own nested copy preserves none of its graft output; a custom .ignore or a clone below graft/ is still preserved"
}

test_a_foreign_copy_inside_an_own_nested_copy_with_unique_ignored_files_is_preserved_and_released() {
  local rc inner
  dead_launcher_pid
  make_own_locked_copy_case inside-own-ignored enclosing "$FOREIGN_DEAD_PID"
  seed_backlog_in_flight "$FOREIGN_CASE"
  inner=$FOREIGN_COPY/.claude/worktrees/fc-inner
  git -C "$FOREIGN_CASE/project" worktree add -q -b fm/inner-lane "$inner" main
  held_ignored_file "$inner"
  run_foreign_teardown rc
  expect_code 0 "$rc" "inside-own-ignored: a copy the close removes with the own copy must have its ignored file preserved, not refuse: $(cat "$FOREIGN_CASE/stderr")"
  assert_foreign_ignored_preserved_and_released inside-own-ignored "$inner"
  assert_absent "$FOREIGN_COPY" "inside-own-ignored: the own nested copy survived"
  pass "a foreign copy inside the task's own nested copy keeps its unique ignored file preserved and is released with it, never refused for that file"
}

test_the_held_record_dedupe_matches_a_name_holding_a_backslash() {
  local rc exclude
  make_held_case held-backslash
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' 'a\\tb.dat' >> "$exclude"
  printf 'only here\n' > "$FOREIGN_COPY/"'a\tb.dat'
  stuck_endpoint_tmux "$FOREIGN_CASE"
  : > "$FOREIGN_CASE/endpoint-stuck"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "held-backslash: a stuck endpoint must refuse the close: $(cat "$FOREIGN_CASE/stderr")"
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" \
    "held-backslash: the refused close did not leave its one record line"
  assert_grep 'it holds ignored files that exist nowhere else: a\tb.dat' "$FOREIGN_CASE/data/held-foreign-copies.log" \
    "held-backslash: the record did not carry the name as it is"
  rm -f "$FOREIGN_CASE/endpoint-stuck"
  run_foreign_teardown rc
  expect_code 0 "$rc" "held-backslash: the rerun must close once the endpoint closes: $(cat "$FOREIGN_CASE/stderr")"
  held_assert_closed held-backslash
  assert_equals 1 "$(wc -l < "$FOREIGN_CASE/data/held-foreign-copies.log" | tr -d ' ')" \
    "held-backslash: the rerun repeated a record line for a name holding a backslash"
  pass "a rerun adds no second record line for a held copy whose ignored file name holds a backslash followed by a letter"
}

test_foreign_copy_regenerable_ignored_files_need_no_preservation() {
  local rc exclude
  make_foreign_copy_case foreign-regenerable
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf '.next/\n*.tsbuildinfo\n.import_linter_cache/\n.tac/tmp/\n.tac/uv-cache/\ngraphify-out/\n' >> "$exclude"
  mkdir -p "$FOREIGN_COPY/.next/cache" "$FOREIGN_COPY/.import_linter_cache" "$FOREIGN_COPY/.tac/tmp" "$FOREIGN_COPY/.tac/uv-cache" "$FOREIGN_COPY/graphify-out"
  printf 'built\n' > "$FOREIGN_COPY/.next/cache/chunk"
  printf '{}\n' > "$FOREIGN_COPY/app.tsbuildinfo"
  printf 'cache\n' > "$FOREIGN_COPY/.import_linter_cache/result"
  printf 'tmp\n' > "$FOREIGN_COPY/.tac/tmp/work"
  printf 'cache\n' > "$FOREIGN_COPY/.tac/uv-cache/archive"
  printf 'graph\n' > "$FOREIGN_COPY/graphify-out/graph.json"
  run_foreign_teardown rc
  expect_code 0 "$rc" "foreign-regenerable: regenerable caches must not block retirement: $(cat "$FOREIGN_CASE/stderr")"
  assert_absent "$FOREIGN_COPY" "foreign-regenerable: the copy survived"
  assert_grep "return --force $FOREIGN_SLOT" "$FOREIGN_CASE/treehouse.log" "foreign-regenerable: the slot was not returned"
  [ ! -e "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" ] \
    || fail "foreign-regenerable: regenerable caches were needlessly preserved"
  pass "regenerable ignored caches are allow-listed and need no preservation or refusal"
}

test_a_foreign_copy_with_durable_tac_state_is_held_and_tac_tmp_is_not_the_reason() {
  local shape rc exclude
  for shape in nested whole; do
    make_held_case "foreign-tac-$shape"
    exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
    if [ "$shape" = nested ]; then
      printf '.tac/loop-state/\n.tac/tmp/\n' >> "$exclude"
    else
      printf '.tac/\n' >> "$exclude"
    fi
    mkdir -p "$FOREIGN_COPY/.tac/loop-state" "$FOREIGN_COPY/.tac/tmp"
    printf 'durable cursor\n' > "$FOREIGN_COPY/.tac/loop-state/cursor"
    printf 'scratch\n' > "$FOREIGN_COPY/.tac/tmp/work"
    held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
    run_foreign_teardown rc
    expect_code 0 "$rc" "foreign-tac-$shape: durable .tac state must hold the copy, not refuse the close: $(cat "$FOREIGN_CASE/stderr")"
    held_assert_closed "foreign-tac-$shape"
    held_assert_untouched "foreign-tac-$shape" "$FOREIGN_CASE" "$FOREIGN_COPY"
    assert_equals "durable cursor" "$(cat "$FOREIGN_COPY/.tac/loop-state/cursor")" "foreign-tac-$shape: the durable .tac state changed"
    assert_grep "it holds ignored files that exist nowhere else: .tac/loop-state." "$FOREIGN_CASE/stdout" \
      "foreign-tac-$shape: the reason did not name the durable state alone: $(tr '\n' ' ' < "$FOREIGN_CASE/stdout")"
    assert_no_grep ".tac/tmp" "$FOREIGN_CASE/data/held-foreign-copies.log" "foreign-tac-$shape: regenerable .tac/tmp was named as a reason"
  done
  pass "durable .tac state holds a foreign copy untouched, while regenerable .tac/tmp is never the reason"
}

test_a_foreign_copy_whose_ignored_files_cannot_be_listed_is_refused_not_held() {
  local rc
  make_held_case foreign-unlistable
  held_ignored_file "$FOREIGN_COPY"
  cat > "$FOREIGN_CASE/fakebin/git" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" ls-files "*" --ignored "*) echo "fatal: simulated listing failure" >&2; exit 128 ;;
esac
exec "$REAL_GIT_FOR_TEST" "\$@"
SH
  chmod +x "$FOREIGN_CASE/fakebin/git"
  held_snapshot "$FOREIGN_CASE" "$FOREIGN_COPY"
  run_foreign_teardown rc
  expect_code 1 "$rc" "foreign-unlistable: a copy whose ignored files cannot be listed must refuse the close: $(cat "$FOREIGN_CASE/stderr")"
  assert_grep "stays in pool slot $FOREIGN_SLOT: its ignored files could not be listed" "$FOREIGN_CASE/stderr" \
    "foreign-unlistable: the refusal did not say why: $(cat "$FOREIGN_CASE/stderr")"
  assert_present "$FOREIGN_CASE/state/task-x1.meta" "foreign-unlistable: the task record was removed"
  assert_absent "$FOREIGN_CASE/data/held-foreign-copies.log" "foreign-unlistable: a refused close wrote a held-copy record"
  assert_present "$FOREIGN_COPY/unique.dat" "foreign-unlistable: the ignored file was lost"
  rm -f "$FOREIGN_CASE/fakebin/git"
  held_assert_untouched foreign-unlistable "$FOREIGN_CASE" "$FOREIGN_COPY"
  pass "a foreign copy whose ignored files cannot be listed is refused, never held and never treated as having nothing to keep"
}

test_typed_preservation_exit_completes_cleanup() {
  local rc exclude route line preserved ownership operation
  # A foreign copy that holds ignored bytes is held and never reaches preservation
  # (test_a_foreign_copy_with_only_unique_ignored_files_is_held_and_the_slot_is_not_returned)
  # unless the hold cannot apply to it, as inside the task's own nested copy.
  for ownership in own inside; do
  route=
  dead_launcher_pid
  make_own_locked_copy_case "typed-$ownership-preservation-route" enclosing "$FOREIGN_DEAD_PID"
  if [ "$ownership" = inside ]; then
    git -C "$FOREIGN_CASE/project" worktree add -q -b fm/inner-lane "$FOREIGN_COPY/.claude/worktrees/fc-inner" main
    FOREIGN_COPY=$FOREIGN_COPY/.claude/worktrees/fc-inner
  fi
  exclude=$(git -C "$FOREIGN_COPY" rev-parse --path-format=absolute --git-path info/exclude)
  printf 'unique.dat\n' >> "$exclude"
  printf 'unique retained bytes\n' > "$FOREIGN_COPY/unique.dat"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FOREIGN_CASE/fakebin/cp"
  chmod +x "$FOREIGN_CASE/fakebin/cp"
  run_foreign_teardown rc
  expect_code 1 "$rc" "failed preservation must keep refusing"
  assert_foreign_copy_untouched typed-preservation-route
  assert_equals 'unique retained bytes' "$(cat "$FOREIGN_COPY/unique.dat")" 'unproven ignored bytes changed'
  assert_no_grep 'human-only-exit:' "$FOREIGN_CASE/stderr" 'an unforced run must keep its printed completing command'
  assert_grep 'it was not removed. Restore readable source and writable preservation storage, then run the completing command.' "$FOREIGN_CASE/stderr" \
    'an unforced run lost the guidance that names its completing command'
  jq -es 'length == 1 and .[0].schema == "fm-friction.v1" and .[0].rule_id == "ignored-bytes-preserved" and .[0].exit_kind == "machine" and .[0].execution_kind == "test"' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail 'preservation refusal was absent or counted twice'
  while IFS= read -r line; do
    case "$line" in 'completing-command: '*) route=${line#completing-command: } ;; esac
  done < "$FOREIGN_CASE/stderr"
  [ -n "$route" ] || fail 'preservation refusal omitted its executable completing command'
  operation=$(jq -r '.operation_id' "$FOREIGN_CASE/home/state/friction.jsonl")
  case "$route" in
    "FM_FRICTION_OPERATION_ID=$operation FM_FRICTION_EPISODE_ID=$operation "*) ;;
    *) fail "printed route does not carry the refusal's operation and episode: $route" ;;
  esac
  # While storage is still broken the route is refused again, as another
  # attempt of the same operation that prints the same route.
  run_printed_route "$route" rc
  expect_code 1 "$rc" "printed route must keep refusing while storage is broken: $(cat "$FOREIGN_CASE/completed.stderr")"
  assert_equals "$route" "$(sed -n 's/^completing-command: //p' "$FOREIGN_CASE/completed.stderr")" 'a repeated refusal printed a different route'
  jq -es --arg op "$operation" 'map(.outcome) == ["blocked", "retried", "blocked"] and (map(.operation_id) | unique == [$op])' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null || fail 'a refused retry was not one more attempt of the same operation'
  # Restore storage, then execute the printed route through the real teardown graph.
  rm "$FOREIGN_CASE/fakebin/cp"
  run_printed_route "$route" rc
  expect_code 0 "$rc" "printed route failed after storage restored: $(cat "$FOREIGN_CASE/completed.stderr")"
  assert_absent "$FOREIGN_COPY" 'printed route did not retire copy'
  assert_absent "$FOREIGN_CASE/state/task-x1.meta" 'printed route did not close task'
  preserved=$(find "$FOREIGN_CASE/data/task-x1/nested-copy-preserved" -name unique.dat -type f)
  assert_equals 'unique retained bytes' "$(cat "$preserved")" 'completing route lost ignored bytes'
  jq -es --arg op "$operation" '
      map(.outcome) == ["blocked", "retried", "blocked", "retried", "retry-succeeded", "completed"]
      and (map(.operation_id) | unique == [$op]) and (map(.episode_id) | unique == [$op])
      and (map(.rule_id) | unique == ["ignored-bytes-preserved"]) and (map(.subject.identity) | unique | length == 1)
      and (map(.event_id) | unique | length == 6) and all(.execution_kind == "test")
      and (.[:4] | all(.elapsed_ms == null)) and (.[4:] | all(.elapsed_ms | type == "number" and . >= 0))' \
    "$FOREIGN_CASE/home/state/friction.jsonl" >/dev/null \
    || fail "a refusal and its successful retry must be one operation ending in retry-succeeded and completed: $(cat "$FOREIGN_CASE/home/state/friction.jsonl")"
  done
  pass 'the typed preservation refusal of an own copy and of a foreign copy inside it retains unique bytes, and its printed command completes cleanup after storage repair as one operation'
}

test_forced_preservation_refusal_prints_no_completing_command() {
  local ownership
  for ownership in own foreign; do
    run_preservation_refusal "$ownership" typed-forced current --force --drop-file "$(fm_test_drop_file)"
    assert_preservation_refusal_without_route "forced-$ownership"
  done
  pass 'a forced teardown whose ignored files cannot be preserved ends in a human-only exit with no command and no flag, for the own copy and a foreign copy'
}


teardown_test_cases=(
test_teardown_never_holds_up_a_steer_to_another_task
test_lane_registry_scan_reads_each_distinct_registry_once
test_task_teardown_preserves_another_homes_abandoned_worker
test_missing_startup_source_refuses_before_cleanup
test_unreadable_startup_source_refuses_before_cleanup
test_missing_adapter_sibling_refuses_before_cleanup
test_forced_child_missing_adapter_sibling_refuses_before_cleanup
test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup
test_retained_sources_still_reach_the_ordinary_refusal
test_top_level_pipeline_discovery_failures_remain_best_effort
test_leaked_tasktmp_process_is_reaped
test_lsof_absent_refuses_without_signalling
test_lsof_error_refuses_before_removal
test_reused_pid_identity_is_not_force_killed
test_exec_changed_process_is_still_reaped
test_process_spawned_during_grace_is_reaped_on_later_pass
test_persistent_scan_refuses_after_bounded_retries
test_process_exit_during_identity_lookup_does_not_refuse
test_run_abort_precedes_process_reap_precedes_worktree_removal
test_locked_own_copy_is_released_by_the_closeout_driver
test_unlocked_landed_foreign_copy_is_removed_without_the_driver
test_idle_reap_keeps_the_per_copy_reason_of_a_foreign_copy_refusal
test_foreign_copy_with_unsaved_files_is_refused
test_a_foreign_copy_with_only_unique_ignored_files_is_held_and_the_slot_is_not_returned
test_the_next_step_for_a_copy_held_for_ignored_files_never_names_a_removal
test_held_copy_notices_and_record_show_no_control_character_and_quote_the_command
test_a_forced_close_preserves_and_releases_a_foreign_copy_with_unique_ignored_files
test_graft_output_alone_does_not_hold_a_foreign_copy
test_graft_output_is_not_preserved_from_a_released_own_nested_copy
test_a_foreign_copy_inside_an_own_nested_copy_with_unique_ignored_files_is_preserved_and_released
test_the_held_record_dedupe_matches_a_name_holding_a_backslash
test_foreign_copy_regenerable_ignored_files_need_no_preservation
test_a_foreign_copy_with_durable_tac_state_is_held_and_tac_tmp_is_not_the_reason
test_a_foreign_copy_whose_ignored_files_cannot_be_listed_is_refused_not_held
test_typed_preservation_exit_completes_cleanup
test_forced_preservation_refusal_prints_no_completing_command
test_private_nm_launch_agent_is_retired_before_teardown
test_private_nm_launch_agent_equivalent_roots_are_retired
test_foreign_nm_launch_agents_are_left_alone
test_nested_nm_launch_agents_are_left_alone
test_absent_copy_nm_launch_agents_preserve_nested_ownership
test_private_nm_launch_agent_bootout_failure_refuses
test_private_nm_launch_agent_not_loaded_is_archived
test_teardown_removes_the_tasks_own_docker_stacks
test_docker_differently_named_metadata_hardlinks_preserve_longer_siblings
test_docker_removal_failure_keeps_the_task_records_until_a_rerun_succeeds
test_forced_teardown_retains_records_after_a_docker_removal_failure
test_docker_removal_error_without_a_survivor_does_not_stop_teardown
test_docker_failed_lane_scan_names_its_cause
test_stopped_docker_daemon_blocks_teardown
test_teardown_without_a_docker_binary_skips_docker_cleanup
test_docker_configured_supabase_identity_vetoes_all_heuristics
test_docker_unreadable_supabase_config_refuses_and_absence_proceeds
test_docker_project_labels_require_the_exact_task_id
test_docker_workdirs_canonicalize_and_exclude_foreign_lanes_and_tasktmp
test_docker_mixed_project_carriers_spare_empty_heuristic_networks
test_docker_latest_foreign_carriers_veto_network_removal
test_standalone_secondmate_skips_docker_cleanup
test_secondmate_retirement_exempts_only_its_own_missing_home
test_secondmate_retirement_keeps_stored_preservation_bundles
test_docker_project_record_failure_prevents_container_removal
test_docker_verified_cleanup_clears_retained_projects
test_docker_ambiguous_ids_trust_only_worktree_evidence
test_docker_all_failure_channels_retain_forced_tasks_until_retry
test_forced_secondmate_cleans_each_child_docker_before_retirement_and_retries
test_forced_orca_children_clean_docker_before_worktree_removal
test_forced_nested_secondmate_cleans_grandchild_docker_before_retirement_and_retries
test_docker_container_arriving_during_resource_cleanup_blocks_retirement
test_teardown_retires_the_dsh_launch_state
)

# Restore errexit before the first case of this slice to match the original combined run.
errexit_restored=false
fm_test_before_case() {
  if [ "$errexit_restored" = false ] && [ "$1" = test_teardown_never_holds_up_a_steer_to_another_task ]; then
    set -e
    errexit_restored=true
  fi
}
fm_test_run_cases "${teardown_test_cases[@]}" -- "$@"
