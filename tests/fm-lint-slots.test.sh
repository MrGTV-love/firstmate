#!/usr/bin/env bash
# bin/fm-lint.sh's host slots and resource bounds: deterministic job
# completion, the CPU-derived host cap, waiter and admission fairness,
# cache hits that skip the pool, disabled or failing slot state, per-root
# deadlines, a named memory-limit death and its retry without external sources.
# Changed-file selection lives in tests/fm-lint.test.sh; modes and installer
# refusals in tests/fm-lint-policy.test.sh; memory fallback and evidence,
# required bounds, the sidecar, seeded parity and CI inputs in
# tests/fm-lint-report.test.sh.
# The groups are contiguous slices of the former registration order, so these
# themes are approximate at the slice edges.
# Shared fixtures: tests/fm-lint-helpers.sh.

# shellcheck source=tests/fm-lint-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-lint-helpers.sh"

test_jobs_are_deterministic_and_complete() {
  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): deterministic bounded jobs check"
    return
  fi
  local tmp good bad_a bad_b out_clean_1 out_clean_2 out_fail_1 out_fail_2 out_fail_2b
  local telemetry telemetry_out cleanup_tmp cleanup_out rc_clean_1 rc_clean_2 rc_fail_1 rc_fail_2 rc_fail_2b rc_bad_jobs
  tmp=$(fm_test_tmproot fm-lint-jobs)
  mkdir -p "$tmp"
  good="$tmp/good.sh"
  bad_a="$tmp/bad-a.sh"
  bad_b="$tmp/bad-b.sh"
  telemetry="$tmp/telemetry.tsv"
  cat > "$good" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$bad_a" <<'SH'
#!/usr/bin/env bash
bad_a() {
  local a= b=
  printf '%s\n' "$a$b"
}
SH
  cat > "$bad_b" <<'SH'
#!/usr/bin/env bash
bad_b() {
  printf '%s\n' $1
}
SH

  rc_clean_1=0
  out_clean_1=$(FM_LINT_JOBS=1 "$LINT" "$good" 2>&1) || rc_clean_1=$?
  rc_clean_2=0
  out_clean_2=$(FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) || rc_clean_2=$?
  [ "$rc_clean_1" -eq 0 ] && [ "$rc_clean_2" -eq 0 ] || fail "clean jobs=1/jobs=2 paths must both pass"
  [ "$out_clean_1" = "$out_clean_2" ] || fail "clean jobs=1/jobs=2 output differs"

  rc_fail_1=0
  out_fail_1=$(FM_LINT_JOBS=1 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_1=$?
  rc_fail_2=0
  out_fail_2=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2=$?
  rc_fail_2b=0
  out_fail_2b=$(FM_LINT_JOBS=2 "$LINT" "$bad_a" "$bad_b" 2>&1) || rc_fail_2b=$?
  [ "$rc_fail_1" -ne 0 ] && [ "$rc_fail_1" -eq "$rc_fail_2" ] && [ "$rc_fail_2" -eq "$rc_fail_2b" ] \
    || fail "failing jobs=1/jobs=2 exit results differ: $rc_fail_1/$rc_fail_2/$rc_fail_2b"
  [ "$out_fail_1" = "$out_fail_2" ] && [ "$out_fail_2" = "$out_fail_2b" ] \
    || fail "failing diagnostics are not byte-identical and deterministic across jobs"
  assert_contains "$out_fail_1" "SC1007" "the first failing root diagnostic was lost"
  assert_contains "$out_fail_1" "SC2086" "the later failing root diagnostic was lost"
  rc_bad_jobs=0
  FM_LINT_JOBS=3 "$LINT" "$good" >/dev/null 2>&1 || rc_bad_jobs=$?
  [ "$rc_bad_jobs" -eq 2 ] || fail "the lint owner must reject unbounded worker counts"

  telemetry_out=$(FM_LINT_JOBS=2 FM_LINT_TELEMETRY="$telemetry" "$LINT" "$good" 2>&1) \
    || fail "telemetry-enabled clean lint failed"
  [ "$telemetry_out" = "$out_clean_2" ] || fail "quiet telemetry changed routine lint output"
  assert_grep $'format\tfm-lint-telemetry-v1' "$telemetry" "telemetry format marker is missing"
  assert_grep $'analysis_mode\tfull' "$telemetry" "telemetry did not record full analysis mode"
  assert_grep $'jobs\t2' "$telemetry" "telemetry did not record bounded jobs"
  assert_grep $'root_count\t1' "$telemetry" "telemetry did not record root count"
  assert_grep $'wall_seconds\t' "$telemetry" "telemetry did not record wall time"
  assert_grep $'user_seconds\t' "$telemetry" "telemetry did not record user CPU"
  assert_grep $'system_seconds\t' "$telemetry" "telemetry did not record system CPU"
  assert_grep $'max_worker_rss_kib\t' "$telemetry" "telemetry did not record maximum RSS"
  assert_grep $'source_boundary_directives\t' "$telemetry" "telemetry did not record source-graph boundaries"
  assert_grep $'shellcheck_processes_start\t' "$telemetry" "telemetry did not record competing ShellCheck conditions"

  cleanup_tmp="$tmp/lint-tmp"
  mkdir -p "$cleanup_tmp"
  cleanup_out=$(TMPDIR="$cleanup_tmp" FM_LINT_JOBS=2 "$LINT" "$good" 2>&1) \
    || fail "cleanup fixture lint failed"
  [ "$cleanup_out" = "$out_clean_2" ] || fail "cleanup fixture changed routine diagnostics"
  [ -z "$(find "$cleanup_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
    || fail "bounded lint left temporary worker state behind"
  pass "jobs=1 and jobs=2 preserve deterministic diagnostics, failures, cleanup bounds, and quiet telemetry"
}

test_host_slots_bound_concurrent_runs() {
  local tmp peak lone baseline
  tmp=$(fm_lint_slot_fixture fm-lint-slots)
  # One run keeps its two workers: the host-wide bound never throttles a lone run.
  lone=$(FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=3 \
    fm_lint_concurrent_runs 1 "$tmp" "$tmp/bin" 2)
  [ "$lone" -eq 2 ] || fail "a lone run peaked at $lone live ShellCheck processes, expected its two workers"
  : > "$tmp/peak"
  baseline=$(FM_LINT_SLOT_DIR=off fm_lint_concurrent_runs 6 "$tmp" "$tmp/bin" 12)
  [ "$baseline" -eq 12 ] || fail "six ungated runs peaked at $baseline live ShellCheck processes, expected 12"
  : > "$tmp/peak"
  # Six runs would start twelve ShellCheck processes if each bounded only itself.
  peak=$(FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=3 \
    fm_lint_concurrent_runs 6 "$tmp" "$tmp/bin" 3)
  [ "$peak" -le 3 ] || fail "six concurrent runs reached $peak live ShellCheck processes, expected at most 3 host-wide"
  [ "$peak" -ge 3 ] || fail "six concurrent runs peaked at $peak, so the slots were not used in parallel"
  pass "six concurrent runs peak at $baseline ShellCheck processes ungated and $peak with a three-slot pool"
}

test_oversubscribed_runs_share_the_cap_and_all_finish() {
  local tmp peak
  tmp=$(fm_lint_slot_fixture fm-lint-slots-oversubscribed)
  # Four runs of two workers each oversubscribe a one-slot pool: the host bound
  # holds and every queued run still completes (fm_lint_concurrent_runs fails on
  # any run that does not exit 0).
  peak=$(FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=1 \
    fm_lint_concurrent_runs 4 "$tmp" "$tmp/bin" 1)
  [ "$peak" -eq 1 ] || fail "four runs on a one-slot pool peaked at $peak live ShellCheck processes, expected 1"
  : > "$tmp/peak"
  # Host load never narrows the pool: the same runs use the whole cap.
  peak=$(FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=6 \
    fm_lint_concurrent_runs 4 "$tmp" "$tmp/bin" 6)
  [ "$peak" -eq 6 ] || fail "four runs on a six-slot pool peaked at $peak live ShellCheck processes, expected 6"
  pass "oversubscribed runs share the CPU-derived cap and every run finishes"
}

test_host_cap_is_cpu_derived_and_occupancy_bounded() {
  local tmp
  tmp=$(fm_test_tmproot fm-lint-slots-cap)
  perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "host cap regression failed"
use strict;
use warnings;
use File::Path qw(make_path);
use Fcntl qw(:flock);
use Time::HiRes qw(time sleep);
my ($gate, $tmp) = @ARGV;
my $command = q{
    use Time::HiRes qw(time sleep);
    my ($started, $release) = @ARGV;
    open(my $fh, '>', $started) or die "$!";
    close $fh;
    my $deadline = time() + 15;
    until (-e $release) { exit 1 if time() > $deadline; sleep 0.01; }
};
for my $case (['', 18, 9], ['', 4, 2], ['', 1, 2], [6, 18, 6]) {
    my ($cap, $ncpu, $expected) = @$case;
    local $ENV{FM_LINT_HOST_SLOTS} = $cap;
    my $dir = "$tmp/$cap.$ncpu";
    make_path($dir);
    my @pids;
    for my $index (0 .. $expected) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if (!$pid) {
            exec $^X, $gate, 'gate', "$dir/slots", $ncpu, 'cap', "$dir/wait.$index",
                '--', $^X, '-e', $command, "$dir/started.$index", "$dir/release";
            die "exec: $!";
        }
        push @pids, $pid;
    }
    my $error;
    eval {
        my $deadline = time() + 10;
        while (1) {
            my @started = glob "$dir/started.*";
            last if @started >= $expected;
            die "admission deadline exceeded\n" if time() > $deadline;
            sleep 0.01;
        }
        sleep 0.25;
        my @started = glob "$dir/started.*";
        die "admitted @started; expected $expected commands\n" unless @started == $expected;
    };
    $error = $@;
    open(my $release, '>', "$dir/release") or die "release: $!";
    close $release;
    for my $pid (@pids) {
        waitpid($pid, 0);
        $error ||= "gated command exited with status $?\n" if $?;
    }
    die "cap '$cap', ncpu $ncpu: $error" if $error;
}
my $dir = "$tmp/occupancy";
make_path("$dir/slots");
my @holders;
for my $index (0 .. 8) {
    open($holders[$index], '>>', "$dir/slots/slot.$index") or die "$!";
    flock($holders[$index], LOCK_EX) or die "$!";
}
local $ENV{FM_LINT_HOST_SLOTS} = 9;
my $pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) {
    close $_ for @holders;
    exec $^X, $gate, 'gate', "$dir/slots", 18, 'occupancy', "$dir/wait",
        '--', $^X, '-e', 'open(my $fh, ">", $ARGV[0]) or die "$!"', "$dir/started";
    die "exec: $!";
}
my $error;
eval {
    sleep 1;
    die "admitted with every slot occupied\n" if -e "$dir/started";
    close $holders[4];
    my $deadline = time() + 5;
    until (-e "$dir/started") {
        die "did not admit after a slot freed\n" if time() > $deadline;
        sleep 0.01;
    }
};
$error = $@;
close $_ for @holders;
kill 'KILL', $pid if $error;
waitpid($pid, 0);
$error ||= "gated command failed: $?\n" if $?;
die $error if $error;
PL
  pass "host caps are CPU-derived, ignore load, and admission respects total occupancy"
}

test_host_waiters_make_progress_without_barging() {
  local tmp
  tmp=$(fm_test_tmproot fm-lint-slot-fairness)
  perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "FIFO admission regression failed"
use strict;
use warnings;
use File::Path qw(make_path);
use Fcntl qw(:flock);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($gate, $tmp) = @ARGV;
open(my $module, '>', "$tmp/WaitLock.pm") or die "$!";
print {$module} <<'MODULE';
package WaitLock;
use Errno qw(EWOULDBLOCK EAGAIN);
use Fcntl qw(LOCK_NB);
use Time::HiRes qw(time sleep);
my $notified;
BEGIN {
    *CORE::GLOBAL::flock = sub {
        my $got = CORE::flock($_[0], $_[1]);
        my $error = 0 + $!;
        if (!$notified && ($_[1] & LOCK_NB)
            && ($ENV{QUEUE_ROLE} eq 'younger' || (!$got && ($error == EWOULDBLOCK || $error == EAGAIN)))) {
            $notified = 1;
            open(my $fh, '>', "$ENV{CASE_DIR}/$ENV{QUEUE_ROLE}.attempt") or die "$!";
            close $fh;
            if ($ENV{QUEUE_ROLE} eq 'older') {
                my $deadline = time() + 15;
                until (-e "$ENV{CASE_DIR}/retry") { die "retry not released\n" if time() > $deadline; sleep 0.01; }
            }
        }
        $! = $error;
        return $got;
    };
}
1;
MODULE
close $module;
sub await_file {
    my ($path) = @_;
    my $deadline = time() + 10;
    until (-e $path) { die "missing $path\n" if time() > $deadline; sleep 0.01; }
}
for my $case (qw(live killed)) {
    my $dir = "$tmp/$case";
    make_path("$dir/slots");
    open(my $holder, '>>', "$dir/slots/slot.0") or die "$!";
    flock($holder, LOCK_EX) or die "$!";
    local %ENV = (%ENV, FM_LINT_HOST_SLOTS => 1, CASE_DIR => $dir);
    my @pids;
    my $error;
    eval {
        for my $role (qw(older younger)) {
            local $ENV{QUEUE_ROLE} = $role;
            my $pid = fork();
            die "fork: $!" unless defined $pid;
            if (!$pid) {
                close $holder;
                exec $^X, "-I$tmp", '-MWaitLock', $gate, 'gate', "$dir/slots", 18, $role,
                    "$dir/$role.wait", '--', $^X, '-e',
                    'open(my $fh, ">>", $ARGV[0]) or die "$!"; print {$fh} "$ARGV[1]\n"',
                    "$dir/order", $role;
                die "exec: $!";
            }
            push @pids, $pid;
            await_file("$dir/$role.attempt");
            close $holder if $role eq 'older' && $case eq 'live';
        }
        if ($case eq 'killed') {
            kill 'KILL', $pids[0];
            waitpid($pids[0], 0);
            shift @pids;
            close $holder;
        } else {
            open(my $retry, '>', "$dir/retry") or die "$!";
            close $retry;
        }
        for my $pid (@pids) {
            my $deadline = time() + 10;
            while (waitpid($pid, WNOHANG) == 0) {
                die "waiter did not finish\n" if time() > $deadline;
                sleep 0.01;
            }
            die "waiter failed: $?\n" if $?;
        }
        @pids = ();
        open(my $order, '<', "$dir/order") or die "$!";
        local $/;
        my $actual = <$order>;
        my $expected = $case eq 'live' ? "older\nyounger\n" : "younger\n";
        die "admission order was $actual, expected $expected" unless $actual eq $expected;
    };
    $error = $@;
    close $holder;
    for my $pid (@pids) { kill 'KILL', $pid; waitpid($pid, 0); }
    die "$case: $error" if $error;
}
PL
  pass "waiting roots precede newer roots and a killed waiter cannot strand admission"
}

test_unequal_runs_share_scarce_slots_per_run() {
  local tmp root pid_two pid_one rc=0
  tmp=$(fm_test_tmproot fm-lint-slots-per-run)
  mkdir -p "$tmp/bin" "$tmp/two" "$tmp/one"
  for root in 1 2 3 4 5 6; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/two/r$root.sh"
  done
  for root in 1 2 3; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/one/r$root.sh"
  done
  cat > "$tmp/bin/shellcheck" <<PL
#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw(:flock);
if ((\$ARGV[0] // '') eq '--version') {
    print "ShellCheck - shell script analysis tool\nversion: 0.11.0\n";
    exit 0;
}
my \$run = \$ARGV[-1] =~ m{/two/} ? 'two' : 'one';
open(my \$log, '>>', "$tmp/starts") or die "\$!";
flock(\$log, LOCK_EX) or die "\$!";
print {\$log} "\$run\n";
close \$log;
select(undef, undef, undef, 2);
exit 0;
PL
  chmod +x "$tmp/bin/shellcheck"
  : > "$tmp/starts"
  # One slot, a two-worker run with backlog, then a one-worker run: per-run
  # service alternates instead of giving the two-worker run two turns per turn.
  FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=1 PATH="$tmp/bin:$PATH" \
    "$LINT" --jobs 2 "$tmp"/two/*.sh > "$tmp/two.out" 2>&1 &
  pid_two=$!
  perl -e 'my $deadline = time() + 30; until (-s $ARGV[0]) { exit 1 if time() > $deadline; select(undef, undef, undef, 0.01); }' \
    "$tmp/starts" || fail "the two-worker run never started a ShellCheck"
  FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=1 PATH="$tmp/bin:$PATH" \
    "$LINT" --jobs 1 "$tmp"/one/*.sh > "$tmp/one.out" 2>&1 &
  pid_one=$!
  wait "$pid_two" || rc=$?
  wait "$pid_one" || rc=$?
  [ "$rc" -eq 0 ] || fail "a per-run fairness lint failed (rc=$rc)"$'\n'"$(cat "$tmp/two.out" "$tmp/one.out")"
  perl - "$tmp/starts" <<'PL' || fail "per-run fair share regression failed"$'\n'"$(tr '\n' ' ' < "$tmp/starts")"
use strict;
use warnings;
open(my $fh, '<', $ARGV[0]) or die "$!";
chomp(my @starts = <$fh>);
my $one = grep { $_ eq 'one' } @starts;
my $two = grep { $_ eq 'two' } @starts;
die "expected 6 two-worker and 3 one-worker starts, got $two and $one\n" unless $two == 6 && $one == 3;
my ($gap, $seen) = (0, 0);
for my $run (@starts) {
    if ($run eq 'one') {
        die "the two-worker run took $gap turns between one-worker turns\n" if $seen && $gap > 1;
        ($gap, $seen) = (0, $seen + 1);
        last if $seen == 3;
        next;
    }
    $gap++;
}
PL
  pass "a two-worker run and a one-worker run alternate turns on a scarce pool"
}

test_stopped_head_waiter_does_not_block_the_queue() {
  local tmp
  tmp=$(fm_test_tmproot fm-lint-slot-stopped-head)
  perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "stopped head regression failed"
use strict;
use warnings;
use File::Path qw(make_path);
use Fcntl qw(:flock);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($gate, $tmp) = @ARGV;
make_path("$tmp/slots");
open(my $holder, '>>', "$tmp/slots/slot.0") or die "$!";
flock($holder, LOCK_EX) or die "$!";
local $ENV{FM_LINT_HOST_SLOTS} = 1;
sub spawn {
    my ($run) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        close $holder;
        exec $^X, $gate, 'gate', "$tmp/slots", 18, $run, "$tmp/$run.wait", '--', $^X, '-e',
            'open(my $fh, ">>", $ARGV[0]) or die "$!"; print {$fh} "$ARGV[1]\n"', "$tmp/order", $run;
        die "exec: $!";
    }
    return $pid;
}
sub finish {
    my ($pid, $what) = @_;
    my $deadline = time() + 10;
    while (waitpid($pid, WNOHANG) == 0) {
        die "$what\n" if time() > $deadline;
        sleep 0.01;
    }
    die "$what: status $?\n" if $?;
}
sub order {
    open(my $fh, '<', "$tmp/order") or return '';
    local $/;
    return <$fh>;
}
my ($stopped, $live);
my $error;
eval {
    $stopped = spawn('stopped');
    my $deadline = time() + 10;
    until (grep { /\.$stopped\.stopped\z/ } glob "$tmp/slots/queue.*") {
        die "the older waiter never queued\n" if time() > $deadline;
        sleep 0.01;
    }
    open(my $coordinator, '>>', "$tmp/slots/admission.lock") or die "$!";
    while (1) {
        kill 'STOP', $stopped;
        if (flock($coordinator, LOCK_EX | LOCK_NB)) { flock($coordinator, LOCK_UN); last; }
        kill 'CONT', $stopped;
        die "could not stop the older waiter outside admission\n" if time() > $deadline;
        sleep 0.05;
    }
    $live = spawn('live');
    sleep 0.25;
    close $holder;
    finish($live, 'a stopped head waiter blocked a live waiter');
    undef $live;
    die "admission order was @{[order()]}\n" unless order() eq "live\n";
    kill 'CONT', $stopped;
    finish($stopped, 'the resumed waiter was never admitted');
    undef $stopped;
    die "admission order was @{[order()]}\n" unless order() eq "live\nstopped\n";
};
$error = $@;
close $holder;
for my $pid (grep { defined } $stopped, $live) { kill 'CONT', $pid; kill 'KILL', $pid; waitpid($pid, 0); }
die $error if $error;
PL
  pass "a stopped head waiter is skipped while a slot is free and is admitted once resumed"
}

test_stopped_admission_coordinator_does_not_freeze_free_capacity() {
  local tmp
  tmp=$(fm_test_tmproot fm-lint-slot-stopped-coordinator)
  perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "stopped coordinator regression failed"
use strict;
use warnings;
use File::Path qw(make_path);
use Fcntl qw(:flock);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($gate, $tmp) = @ARGV;
make_path("$tmp/slots");
open(my $holder, '>>', "$tmp/slots/slot.0") or die "$!";
flock($holder, LOCK_EX) or die "$!";
local $ENV{FM_LINT_HOST_SLOTS} = 1;
# The older waiter stops itself while it owns admission.lock with its ticket
# queued, so the stop is reached by construction instead of by sampling the
# short interval in which a polling gate holds the lock. Admission takes
# non-blocking locks in this order: coordinator, ticket, then each slot.
open(my $module, '>', "$tmp/StopOwner.pm") or die "$!";
print {$module} <<'MODULE';
package StopOwner;
use Fcntl qw(LOCK_NB);
my $locks = 0;
BEGIN {
    *CORE::GLOBAL::flock = sub {
        my $locked = CORE::flock($_[0], $_[1]);
        kill 'STOP', $$ if ($_[1] & LOCK_NB) && ++$locks == 2 && $locked;
        return $locked;
    };
}
1;
MODULE
close $module;
sub spawn {
    my ($run, @inject) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        close $holder;
        exec $^X, @inject, $gate, 'gate', "$tmp/slots", 18, $run, "$tmp/$run.wait", '--', $^X, '-e',
            'open(my $fh, ">>", $ARGV[0]) or die "$!"; print {$fh} "$ARGV[1]\n"', "$tmp/order", $run;
        die "exec: $!";
    }
    return $pid;
}
sub finish {
    my ($pid, $what) = @_;
    my $deadline = time() + 15;
    while (waitpid($pid, WNOHANG) == 0) {
        die "$what\n" if time() > $deadline;
        sleep 0.01;
    }
    die "$what: status $?\n" if $?;
}
sub order {
    open(my $fh, '<', "$tmp/order") or return '';
    local $/;
    return <$fh>;
}
sub is_stopped {
    open(my $ps, '-|', 'ps', '-o', 'stat=', '-p', $_[0]) or return 0;
    my $stat = <$ps> // '';
    close $ps;
    return $stat =~ /\A\s*T/;
}
my ($stopped, $live);
my $error;
eval {
    $stopped = spawn('stopped', "-I$tmp", '-MStopOwner');
    my $deadline = time() + 60;
    until (is_stopped($stopped)) {
        die "the older waiter ended instead of stopping: status $?\n" if waitpid($stopped, WNOHANG) == $stopped;
        die "the older waiter never stopped inside admission\n" if time() > $deadline;
        sleep 0.01;
    }
    open(my $coordinator, '>>', "$tmp/slots/admission.lock") or die "$!";
    die "the stopped waiter does not own admission.lock\n" if flock($coordinator, LOCK_EX | LOCK_NB);
    die "the stopped waiter has no queued ticket\n"
        unless grep { /\.$stopped\.stopped\z/ } glob "$tmp/slots/queue.*";
    $live = spawn('live');
    sleep 0.25;
    close $holder;
    finish($live, 'a stopped coordinator owner froze a free slot');
    undef $live;
    die "admission order was @{[order()]}\n" unless order() eq "live\n";
    kill 'CONT', $stopped;
    finish($stopped, 'the resumed waiter was never admitted');
    undef $stopped;
    die "admission order was @{[order()]}\n" unless order() eq "live\nstopped\n";
};
$error = $@;
close $holder;
for my $pid (grep { defined } $stopped, $live) { kill 'CONT', $pid; kill 'KILL', $pid; waitpid($pid, 0); }
die $error if $error;
PL
  pass "a gate stopped while owning admission does not freeze free capacity"
}

test_queue_scan_survives_odd_slot_paths_and_vanishing_tickets() {
  local tmp
  tmp=$(fm_test_tmproot fm-lint-slot-queue-scan)
  perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "queue scan regression failed"
use strict;
use warnings;
use File::Path qw(make_path);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($gate, $tmp) = @ARGV;
open(my $module, '>', "$tmp/VanishLock.pm") or die "$!";
print {$module} <<'MODULE';
package VanishLock;
use Fcntl qw(LOCK_NB);
my $locks;
BEGIN {
    *CORE::GLOBAL::flock = sub {
        # Coordinator, own ticket, free slot, then the stale request ahead of
        # it: its owner cancels (unlinks) between this scan's open and its lock.
        unlink "$ENV{CASE_DIR}/slots/queue.00000000000000000000.1.stale"
            if ($_[1] & LOCK_NB) && ++$locks == 4;
        return CORE::flock($_[0], $_[1]);
    };
}
1;
MODULE
close $module;
for my $case (qw(spaces vanishing)) {
    my $dir = "$tmp/$case";
    my $slots = $case eq 'spaces' ? "$dir/my slots" : "$dir/slots";
    make_path($slots);
    if ($case eq 'vanishing') {
        open(my $stale, '>', "$slots/queue.00000000000000000000.1.stale") or die "$!";
        close $stale;
    }
    local $ENV{FM_LINT_HOST_SLOTS} = 1;
    local $ENV{CASE_DIR} = $dir;
    my @inject = $case eq 'vanishing' ? ("-I$tmp", '-MVanishLock') : ();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open STDERR, '>', "$dir/err" or die "$!";
        exec $^X, @inject, $gate, 'gate', $slots, 18, 'scan', "$dir/wait",
            '--', $^X, '-e', 'print "analysis ran\n"; exit 23';
        die "exec: $!";
    }
    my $deadline = time() + 15;
    while (waitpid($pid, WNOHANG) == 0) {
        if (time() > $deadline) {
            kill 'KILL', $pid;
            waitpid($pid, 0);
            die "$case: gate did not admit its request\n";
        }
        sleep 0.01;
    }
    die "$case: command exit status was lost: $?\n" unless $? == (23 << 8);
    open(my $err, '<', "$dir/err") or die "$!";
    local $/;
    my $warning = <$err>;
    die "$case: gate ran without the host bound: $warning\n" if $warning =~ /running without/;
    die "$case: gate touched a path split at whitespace\n" if -e "$dir/my";
}
PL
  pass "the queue scan handles slot paths with spaces and tickets cancelled mid-scan"
}

test_cached_success_does_not_wait_for_host_slots() {
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): cached slot bypass"; return; }
  local tmp repo out
  tmp=$(fm_test_tmproot fm-lint-cache-slots)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  out=$(CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$repo/bin/fm-lint.sh" bin/consumer.sh 2>&1) || fail "cache warm-up failed: $out"
  perl - "$repo/bin/fm-lint.sh" "$tmp" <<'PL' || fail "warm cache queued behind an occupied host slot"
use strict;
use warnings;
use File::Path qw(make_path);
use Fcntl qw(:flock);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($lint, $tmp) = @ARGV;
make_path("$tmp/slots");
open(my $holder, '>>', "$tmp/slots/slot.0") or die "$!";
flock($holder, LOCK_EX) or die "$!";
local %ENV = (%ENV, CI => '', GITHUB_ACTIONS => '', FM_LINT_CACHE_DIR => "$tmp/cache",
    FM_LINT_SLOT_DIR => "$tmp/slots", FM_LINT_HOST_SLOTS => 1);
my $pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) {
    close $holder;
    open STDOUT, '>', "$tmp/hit.out" or die "$!";
    open STDERR, '>&', \*STDOUT or die "$!";
    exec '/bin/bash', $lint, 'bin/consumer.sh';
    die "exec: $!";
}
my $error;
my $deadline = time() + 10;
while (waitpid($pid, WNOHANG) == 0) {
    if (time() > $deadline) {
        $error = "cache hit required an analysis slot\n";
        kill 'TERM', $pid;
        close $holder;
        waitpid($pid, 0);
        last;
    }
    sleep 0.01;
}
$error ||= "cache hit failed: $?\n" if $?;
close $holder;
open(my $output, '<', "$tmp/hit.out") or die "$!";
local $/;
my $text = <$output>;
die $error, $text if $error;
die "did not reuse the successful analysis: $text\n" unless $text =~ /cache hit bin\/consumer[.]sh/;
PL
  pass "a content-identical cached success finishes while all host slots remain occupied"
}

test_slot_pool_can_be_disabled_or_misconfigured() {
  local tmp rc out
  tmp=$(fm_lint_slot_fixture fm-lint-slots-off)
  rc=0
  out=$(PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR=off "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a run with the slot pool off failed"$'\n'"$out"
  rc=0
  out=$(PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=zero "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a non-numeric FM_LINT_HOST_SLOTS exited $rc, expected 2"
  assert_contains "$out" "FM_LINT_HOST_SLOTS" "the refusal did not name the setting"
  [ ! -d "$tmp/slots" ] || fail "a refused run still created the slot directory"
  rc=0
  out=$(PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/a.sh/blocked" "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an unusable slot directory must not fail lint"$'\n'"$out"
  assert_contains "$out" "running without the host-wide ShellCheck bound" "an unusable slot directory was not reported"
  pass "the slot pool can be disabled, rejects bad settings, and never fails lint when unusable"
}

test_slot_file_failures_run_ungated() {
  local tmp
  tmp=$(fm_test_tmproot fm-lint-slot-errors)
  perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "slot I/O fallback regression failed"
use strict;
use warnings;
use File::Path qw(make_path);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($gate, $tmp) = @ARGV;
open(my $module, '>', "$tmp/FailLock.pm") or die "$!";
print {$module} <<'MODULE';
package FailLock;
use Errno qw(EIO);
use Fcntl qw(LOCK_NB);
my $locks;
BEGIN {
    *CORE::GLOBAL::flock = sub {
        # Coordinator, ticket, then slot scan; inject a real I/O failure at
        # each admission boundary without changing ordinary contention.
        if (($_[1] & LOCK_NB) && ++$locks == ($ENV{FAIL_LOCK} eq 'scan' ? 3 : 1)) {
            $! = EIO;
            return 0;
        }
        return CORE::flock($_[0], $_[1]);
    };
}
1;
MODULE
close $module;
for my $failure (qw(open scan coordinator)) {
    my $dir = "$tmp/$failure";
    make_path("$dir/slots");
    make_path("$dir/slots/slot.0") if $failure eq 'open';
    local $ENV{FM_LINT_HOST_SLOTS} = 1;
    local $ENV{FAIL_LOCK} = $failure;
    my @inject = $failure eq 'open' ? () : ("-I$tmp", '-MFailLock');
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open STDERR, '>', "$dir/err" or die "$!";
        exec $^X, @inject, $gate, 'gate', "$dir/slots", 18, 'fail', "$dir/wait",
            '--', $^X, '-e', 'print "analysis ran\n"; exit 23';
        die "exec: $!";
    }
    my $deadline = time() + 30;
    while (waitpid($pid, WNOHANG) == 0) {
        if (time() > $deadline) {
            kill 'KILL', $pid;
            waitpid($pid, 0);
            die "$failure failure queued instead of running ungated\n";
        }
        sleep 0.01;
    }
    die "$failure fallback lost the command exit status: $?\n" unless $? == (23 << 8);
    open(my $err, '<', "$dir/err") or die "$!";
    local $/;
    my $warning = <$err>;
    die "$failure fallback omitted the warning\n"
        unless $warning =~ /running without the host-wide ShellCheck bound/;
}
PL
  pass "slot open and non-contention coordinator/scan lock failures warn and run ungated"
}

test_slot_survives_gate_death() {
  local tmp bounded=none
  if fm_lint_bounds_supported; then bounded=perl; fi
  tmp=$(fm_test_tmproot fm-lint-slot-inheritance)
  perl - "$LINT" "$ROOT/bin/fm-lint-cache.pl" "$tmp" "$bounded" <<'PL' || fail "slot lifetime regression failed"
use strict;
use warnings;
use File::Path qw(make_path);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($lint, $gate_script, $tmp, $bound_mechanism) = @ARGV;
open(my $stub, '>', "$tmp/shellcheck") or die "$!";
print {$stub} "#!/usr/bin/env perl\n", <<'STUB';
use Time::HiRes qw(time sleep);
$SIG{TERM} = $SIG{HUP} = $SIG{INT} = 'IGNORE';
my $child = fork();
die "fork: $!" unless defined $child;
if (!$child) {
    my $deadline = time() + 15;
    until (-e "$ENV{CASE_DIR}/release") { last if time() > $deadline; sleep 0.01; }
    exit 0;
}
open(my $fh, '>', "$ENV{CASE_DIR}/started") or die "$!";
print {$fh} "$$ $child\n";
close $fh;
waitpid($child, 0);
STUB
close $stub;
chmod 0755, "$tmp/shellcheck";
for my $bounded ('none', $bound_mechanism eq 'perl' ? ('perl') : ()) {
    my $dir = "$tmp/$bounded";
    make_path("$dir/out");
    open(my $root, '>', "$dir/root.sh") or die "$!";
    print {$root} "#!/bin/bash\nexit 0\n";
    close $root;
    open(my $manifest, '>', "$dir/manifest") or die "$!";
    print {$manifest} "0\t$dir/root.sh\n";
    close $manifest;
    local %ENV = (%ENV, FM_LINT_INTERNAL => 1, FM_LINT_INTERNAL_CACHE => 'off',
        FM_LINT_INTERNAL_SLOT_DIR => "$dir/slots", FM_LINT_INTERNAL_NCPU => 18,
        FM_LINT_INTERNAL_RUN_ID => 'worker',
        FM_LINT_HOST_SLOTS => 1,
        FM_LINT_INTERNAL_BOUNDED => $bounded, FM_LINT_INTERNAL_MEMORY_KIB => 2097152,
        FM_LINT_INTERNAL_ROOT_SECS => 10, FM_LINT_INTERNAL_GRACE => 1,
        FM_LINT_SHELLCHECK => "$tmp/shellcheck", CASE_DIR => $dir);
    my $worker = fork();
    die "fork: $!" unless defined $worker;
    if (!$worker) {
        open STDOUT, '>', "$dir/output" or die "$!";
        open STDERR, '>&', \*STDOUT or die "$!";
        exec '/bin/bash', $lint, '--internal-worker', "$dir/manifest", "$dir/out", 0;
        die "exec: $!";
    }
    my ($command, $descendant, $gate, $queued, $error);
    eval {
        my $deadline = time() + 5;
        until (-s "$dir/started") { die "command never started\n" if time() > $deadline; sleep 0.01; }
        open(my $started, '<', "$dir/started") or die "$!";
        ($command, $descendant) = split / /, <$started>;
        open(my $ps, '-|', 'ps', '-axo', 'pid=,ppid=,args=') or die "$!";
        my (%parent, %args);
        while (<$ps>) {
            next unless /^\s*(\d+)\s+(\d+)\s+(.*)$/;
            $parent{$1} = $2; $args{$1} = $3;
        }
        close $ps;
        my $ancestor = $command;
        while ($ancestor && $ancestor != $worker) {
            if (($args{$ancestor} // '') =~ /\Q$dir\/slots\E/) { $gate = $ancestor; last; }
            $ancestor = $parent{$ancestor};
        }
        die "gate not found in command ancestry\n" unless $gate;
        $queued = fork();
        die "fork: $!" unless defined $queued;
        if (!$queued) {
            exec $^X, $gate_script, 'gate', "$dir/slots", 18, 'queued', "$dir/queued.wait",
                '--', $^X, '-e', q{
                    my ($admitted, $bounded, @protected) = @ARGV;
                    if ($bounded ne 'none') {
                        open(my $ps, '-|', 'ps', '-o', 'stat=', '-p', join(',', @protected)) or die "$!";
                        my @live = grep { !/^\s*Z/ } <$ps>;
                        close $ps;
                        die "admission overlapped a live protected tree\n" if @live;
                    }
                    open(my $fh, '>', $admitted) or die "$!";
                }, "$dir/admitted", $bounded, $command, $descendant;
            die "exec: $!";
        }
        kill 'KILL', $gate;
        if ($bounded eq 'none') {
            sleep 0.2;
            die "queued command started while protected tree survived\n" if -e "$dir/admitted";
            kill 'KILL', $command;
            sleep 0.2;
            die "queued command started while protected descendant survived\n" if -e "$dir/admitted";
            die "protected descendant exited before release\n" unless kill 0, $descendant;
        } else {
            my $deadline = time() + 5;
            until (-e "$dir/admitted") {
                die "watchdog cleanup did not release the slot\n" if time() > $deadline;
                sleep 0.01;
            }
        }
    };
    $error = $@;
    open(my $release, '>', "$dir/release") or die "$!";
    close $release;
    my $deadline = time() + 5;
    if ($queued) {
        while (waitpid($queued, WNOHANG) == 0) {
            if (time() > $deadline) { kill 'KILL', $queued; waitpid($queued, 0); $error ||= "slot never released\n"; last; }
            sleep 0.01;
        }
        $error ||= "queued command failed: $?\n" if $?;
        $error ||= "queued command never admitted\n" unless -e "$dir/admitted";
    }
    kill 'KILL', $command if $command;
    kill 'KILL', $descendant if $descendant;
    kill 'TERM', $worker;
    waitpid($worker, 0);
    if ($error) {
        open(my $output, '<', "$dir/output") or die "$!";
        open(my $analysis, '<', "$dir/out/shard.0.out") or die "$!";
        local $/;
        die "$bounded: $error", <$output>, <$analysis>;
    }
}
PL
  pass "inherited slots prevent overlap after gate death and allow admission after watchdog cleanup"
}

test_queued_roots_use_high_resolution_timings() {
  local tmp bounded=none
  if fm_lint_bounds_supported; then bounded=perl; fi
  tmp=$(fm_test_tmproot fm-lint-slot-clock)
  perl - "$LINT" "$tmp" "$bounded" <<'PL' || fail "queued root clock regression failed"
use strict;
use warnings;
use Fcntl qw(:flock);
use File::Path qw(make_path);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($lint, $tmp, $bounded) = @ARGV;
open(my $env, '>', "$tmp/bash-env") or die "$!";
print {$env} "unset EPOCHREALTIME\n";
close $env;
open(my $stub, '>', "$tmp/shellcheck") or die "$!";
print {$stub} "#!/usr/bin/env perl\n", <<'STUB';
use Time::HiRes qw(sleep);
sleep 0.08;
if ($ENV{RETRY} && grep { $_ eq '--external-sources' } @ARGV) {
    print STDERR "shellcheck: Heap exhausted;\n";
    exit 251;
}
exit 0;
STUB
close $stub;
chmod 0755, "$tmp/shellcheck";
for my $retry (0, 1) {
    my $dir = "$tmp/$retry";
    make_path("$dir/out", "$dir/slots");
    open(my $slot, '>>', "$dir/slots/slot.0") or die "$!";
    flock($slot, LOCK_EX) or die "$!";
    open(my $manifest, '>', "$dir/manifest") or die "$!";
    print {$manifest} "0\t$dir/root.sh\n";
    close $manifest;
    open(my $root, '>', "$dir/root.sh") or die "$!";
    print {$root} "#!/bin/bash\nexit 0\n";
    close $root;
    local %ENV = (%ENV, BASH_ENV => "$tmp/bash-env", RETRY => $retry,
        FM_LINT_INTERNAL => 1, FM_LINT_INTERNAL_CACHE => 'off',
        FM_LINT_INTERNAL_SLOT_DIR => "$dir/slots", FM_LINT_INTERNAL_NCPU => 18,
        FM_LINT_INTERNAL_RUN_ID => 'worker',
        FM_LINT_HOST_SLOTS => 1,
        FM_LINT_INTERNAL_BOUNDED => $bounded, FM_LINT_INTERNAL_MEMORY_KIB => 2097152,
        FM_LINT_INTERNAL_ROOT_SECS => 3, FM_LINT_INTERNAL_GRACE => 1,
        FM_LINT_INTERNAL_ROOTS_LOG => "$dir/roots.tsv", FM_LINT_SHELLCHECK => "$tmp/shellcheck");
    my $launched = time();
    my $worker = fork();
    die "fork: $!" unless defined $worker;
    if (!$worker) {
        close $slot;
        open STDOUT, '>', "$dir/output" or die "$!";
        open STDERR, '>&', \*STDOUT or die "$!";
        exec '/bin/bash', $lint, '--internal-worker', "$dir/manifest", "$dir/out", 0;
        die "exec: $!";
    }
    my $error;
    eval {
        # Controller waits cover host scheduling and worker bookkeeping; the
        # protected root still has its independently enforced three-second bound.
        my $deadline = time() + 30;
        until (-s "$dir/roots.tsv") { die "root never began\n" if time() > $deadline; sleep 0.01; }
        my $began = time();
        sleep 1.5;
        close $slot;
        $deadline = time() + 30;
        while (waitpid($worker, WNOHANG) == 0) {
            die "queued root timed out\n" if time() > $deadline;
            sleep 0.01;
        }
        die "queued root failed: $?\n" if $?;
        my $finished = time();
        my $queued_ms = 0;
        for my $file (glob "$dir/out/*.rss.wait") {
            open(my $wait, '<', $file) or die "$!";
            $queued_ms += <$wait>;
        }
        my $elapsed = ($finished - $launched) * 1000 - $queued_ms;
        open(my $log, '<', "$dir/roots.tsv") or die "$!";
        my @end;
        while (<$log>) { @end = split /\t/ if /^end\t/; }
        die "missing root result\n" unless @end;
        my $expected = $retry ? 'memory-fallback' : 'ok';
        die "wrong root outcome: $end[9]\n" unless $end[9] eq $expected;
        die "root timestamps fall outside the observed lifecycle\n"
            unless $end[5] >= $launched * 1000 - 1 && $end[5] <= $began * 1000 + 1
                && $end[6] >= ($began + 1.5) * 1000 - 1 && $end[6] <= $finished * 1000 + 1;
        die "duration $end[7]ms exceeds $elapsed ms available for analysis\n"
            unless $end[7] >= 70 && $end[7] <= $elapsed + 2;
        die "root wall time omitted the queue\n" unless $end[6] - $end[5] >= 1500;
    };
    $error = $@;
    close $slot if defined fileno($slot);
    kill 'KILL', $worker;
    waitpid($worker, 0);
    die "retry=$retry: $error" if $error;
}
PL
  pass "queued roots and memory retries record precise analysis durations without EPOCHREALTIME"
}

test_worker_trees_stop_on_signal() {
  local tmp fakebin fixture jobs telemetry lint_tmp pid_file out_file telemetry_file
  local parent_pid shellcheck_pid i parent_rc survivor
  tmp=$(fm_test_tmproot fm-lint-signal)
  mkdir -p "$tmp"
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/good.sh"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-ok}"
SH
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
printf '%s\n' "$$" > "$FM_TEST_SHELLCHECK_PID"
trap 'exit 143' HUP INT TERM
while :; do
  sleep 1
done
SH
  chmod +x "$fakebin/shellcheck"

  for jobs in 1 2; do
    for telemetry in off on; do
      lint_tmp="$tmp/lint-$jobs-$telemetry"
      pid_file="$tmp/shellcheck-$jobs-$telemetry.pid"
      out_file="$tmp/output-$jobs-$telemetry"
      telemetry_file=
      mkdir -p "$lint_tmp"
      if [ "$telemetry" = on ]; then
        telemetry_file="$tmp/telemetry-$jobs.tsv"
      fi
      PATH="$fakebin:$PATH" TMPDIR="$lint_tmp" FM_LINT_JOBS="$jobs" \
        FM_LINT_TELEMETRY="$telemetry_file" FM_TEST_SHELLCHECK_PID="$pid_file" \
        "$LINT" "$fixture" > "$out_file" 2>&1 &
      parent_pid=$!
      i=0
      while [ "$i" -lt 500 ] && [ ! -s "$pid_file" ]; do
        kill -0 "$parent_pid" 2>/dev/null || break
        sleep 0.01
        i=$((i + 1))
      done
      [ -s "$pid_file" ] || {
        kill -TERM "$parent_pid" 2>/dev/null || true
        wait "$parent_pid" 2>/dev/null || true
        fail "jobs=$jobs telemetry=$telemetry did not start ShellCheck"
      }
      shellcheck_pid=$(cat "$pid_file")
      kill -TERM "$parent_pid" 2>/dev/null \
        || fail "jobs=$jobs telemetry=$telemetry parent could not be interrupted"
      parent_rc=0
      wait "$parent_pid" 2>/dev/null || parent_rc=$?
      survivor=0
      i=0
      while [ "$i" -lt 100 ] && kill -0 "$shellcheck_pid" 2>/dev/null; do
        sleep 0.01
        i=$((i + 1))
      done
      if kill -0 "$shellcheck_pid" 2>/dev/null; then
        survivor=1
        kill -KILL "$shellcheck_pid" 2>/dev/null || true
      fi
      [ "$parent_rc" -eq 143 ] \
        || fail "jobs=$jobs telemetry=$telemetry signal exit was $parent_rc, expected 143"
      [ "$survivor" -eq 0 ] \
        || fail "jobs=$jobs telemetry=$telemetry left ShellCheck running"
      [ -z "$(find "$lint_tmp" -mindepth 1 -maxdepth 1 -name 'fm-lint.*' -print -quit)" ] \
        || fail "jobs=$jobs telemetry=$telemetry left temporary worker state"
    done
  done
  pass "jobs=1 and jobs=2 stop complete worker trees with and without telemetry"
}

test_root_deadline_names_the_root_and_reaps_the_tree() {
  if ! fm_lint_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): root deadline kill check"
    return
  fi
  local tmp fakebin stub_log telemetry roots_log out rc
  local blocker ok sentinel_pid child_pid_file stub_pid_file child_pid stub_pid
  tmp=$(fm_test_tmproot fm-lint-bound-deadline)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  stub_log="$tmp/stub.log"
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  child_pid_file="$tmp/child.pid"
  stub_pid_file="$tmp/stub.pid"
  blocker="$tmp/blocker.sh"
  ok="$tmp/ok.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$blocker"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ok"

  sleep 300 &
  sentinel_pid=$!
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 \
    FM_LINT_REQUIRE_BOUNDS=1 FM_DURATION_FILE="$tmp/durations.jsonl" \
    FM_LINT_ROOT_SECONDS=1 FM_LINT_ROOT_GRACE=1 \
    FM_TEST_STUB_LOG="$stub_log" FM_TEST_CHILD_PID="$child_pid_file" \
    FM_TEST_STUB_PID="$stub_pid_file" FM_TEST_BLOCK_SECS=300 \
    "$LINT" --telemetry "$telemetry" "$ok" "$blocker" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a root pinned at the wall deadline unexpectedly passed"
  assert_contains "$out" "blocker.sh" "the timed-out root was not named"
  assert_contains "$out" "reason=timeout" "the timed-out root was not reported as a timeout"
  python3 - "$tmp/durations.jsonl" <<'PY' || fail "the timed-out root was not recorded as a timeout in the duration table"
import json
import sys
rows = [json.loads(line) for line in open(sys.argv[1])]
roots = {row['key'].rsplit('/', 1)[-1]: row for row in rows if row.get('key', '').startswith('lint-root.') and 'event' not in row}
assert roots['blocker.sh']['exit'] == 124 and roots['blocker.sh']['timed_out'] is True, roots
assert roots['ok.sh']['timed_out'] is False, roots
assert [row['key'] for row in rows if row.get('event') == 'timeout'] == [roots['blocker.sh']['key']], rows
PY
  kill -0 "$sentinel_pid" 2>/dev/null \
    || fail "the lint deadline killed an unrelated sentinel process"
  kill -KILL "$sentinel_pid" 2>/dev/null || true
  wait "$sentinel_pid" 2>/dev/null || true
  if [ -s "$child_pid_file" ]; then
    child_pid=$(cat "$child_pid_file")
    kill -0 "$child_pid" 2>/dev/null \
      && fail "the blocked root's child survived the deadline kill"
  else
    fail "the blocked root never recorded its child pid"
  fi
  if [ -s "$stub_pid_file" ]; then
    stub_pid=$(cat "$stub_pid_file")
    kill -0 "$stub_pid" 2>/dev/null \
      && fail "the blocked root's ShellCheck process survived the deadline kill"
  else
    fail "the blocked root never recorded its ShellCheck pid"
  fi
  [ -f "$roots_log" ] || fail "the run kept no retained per-root sidecar"
  awk -F '\t' '$1 == "end" && $3 ~ /ok\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar lost the completed root's ok record"
  awk -F '\t' '$1 == "end" && $3 ~ /blocker\.sh$/ && $10 == "timeout" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar did not record the timed-out root by name"
  pass "a root pinned at the wall deadline fails by name, reaps its tree, and leaves the sentinel alive"
}

test_root_memory_limit_reports_a_named_death() {
  if ! fm_lint_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): memory-limit death check"
    return
  fi
  local tmp fakebin stub_log telemetry roots_log out rc hoarder ok
  local sentinel_pid
  tmp=$(fm_test_tmproot fm-lint-bound-memory)
  fakebin=$(fm_fakebin "$tmp")
  fm_lint_stub_reactive_shellcheck "$fakebin"
  stub_log="$tmp/stub.log"
  telemetry="$tmp/lint.tsv"
  roots_log="$tmp/lint.roots.tsv"
  hoarder="$tmp/hoarder.sh"
  ok="$tmp/ok.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$hoarder"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ok"

  # Control: with no memory limit the same allocator succeeds, so a memory
  # death below can only come from the enforced cap.
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 \
    FM_TEST_STUB_LOG="$stub_log" \
    "$LINT" --telemetry "$tmp/control.tsv" "$ok" "$hoarder" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the allocator failed without any memory limit"$'\n'"$out"
  grep -q $'^meta\tbounds_enforced\t0$' "$tmp/control.roots.tsv" \
    || fail "the control run was not unbounded"
  awk -F '\t' '$1 == "end" && $3 ~ /hoarder\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
    "$tmp/control.roots.tsv" || fail "the uncapped allocator root did not complete ok"

  # The hoarder stub allocates 512 MiB; under a 256 MiB address-space limit
  # the allocator is refused and the run must name the root, not survive.
  sleep 300 &
  sentinel_pid=$!
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 \
    FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_ROOT_MEMORY_KIB=262144 \
    FM_TEST_STUB_LOG="$stub_log" \
    "$LINT" --telemetry "$telemetry" "$ok" "$hoarder" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a root killed by its memory limit unexpectedly passed"
  assert_contains "$out" "hoarder.sh" "the memory-limited root was not named"
  assert_contains "$out" "reason=memory" "the memory-limit death was not classified as memory"
  kill -0 "$sentinel_pid" 2>/dev/null \
    || fail "the memory-limit kill took an unrelated sentinel process with it"
  kill -KILL "$sentinel_pid" 2>/dev/null || true
  wait "$sentinel_pid" 2>/dev/null || true
  awk -F '\t' '$1 == "end" && $3 ~ /hoarder\.sh$/ && $10 == "memory" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar did not record the memory-limited root by name"
  awk -F '\t' '$1 == "end" && $3 ~ /ok\.sh$/ && $10 == "ok" { found=1 } END { exit !found }' \
    "$roots_log" || fail "the sidecar lost the clean root's record"
  pass "a root refused by its enforced memory limit fails by name with a memory reason"
}

test_memory_failure_retries_without_external_sources() {
  local tmp fakebin fixture out rc log rss_kib require_bounds=0 mode
  local -a modes=(0)
  if fm_lint_bounds_supported; then
    require_bounds=1
    modes=(1 0)
  fi
  tmp=$(fm_test_tmproot fm-lint-memory-fallback)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/teardown.sh"
  log="$tmp/flags.log"
  printf '#!/usr/bin/env bash\n# shellcheck source=lib.sh\nexit 0\n' > "$fixture"
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
follow=no
exclude=none
while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
  case "$1" in
    --external-sources) follow=yes ;;
    --exclude=*) exclude=${1#--exclude=} ;;
  esac
  shift
done
shift
printf '%s\t%s\n' "$follow" "$exclude" >> "$FM_TEST_FALLBACK_LOG"
if [ "$follow" = yes ]; then
  printf 'shellcheck: Heap exhausted;\n' >&2
  exit 251
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"

  for mode in "${modes[@]}"; do
    : > "$log"
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS="$mode" \
      FM_TEST_FALLBACK_LOG="$log" "$LINT" --telemetry "$tmp/pass.$mode.tsv" "$fixture" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "a clean no-source fallback did not pass (bounded=$mode)"$'\n'"$out"
    assert_grep $'source_directives\t1' "$tmp/pass.$mode.tsv" "telemetry lost the root's source directive"
    assert_grep $'source_followed_directives\t0' "$tmp/pass.$mode.tsv" \
      "telemetry counted a source directive that the passing fallback did not follow"
    [ "$(cat "$log")" = "$(printf 'yes\tnone\nno\tSC1091,SC2034,SC2153,SC2329')" ] \
      || fail "the memory failure did not retry without external sources and exclude only cross-file codes"$'\n'"$(cat "$log")"
    assert_contains "$out" "hit the memory ceiling with --external-sources (reason=memory rc=251)" \
      "the fallback was not identified in the output"
    assert_contains "$out" "fallback passed with cross-file codes excluded (SC1091,SC2034,SC2153,SC2329)" \
      "the narrower fallback result was not disclosed"
    awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ && $9 == 0 && $10 == "memory-fallback" { found=1 } END { exit !found }' \
      "$tmp/pass.$mode.roots.tsv" || fail "the clean fallback was not recorded distinctly"
    rss_kib=$(awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ { print $11 }' "$tmp/pass.$mode.roots.tsv")
    if [ "$mode" -eq 1 ]; then
      assert_grep $'meta\tbounds_enforced\t1' "$tmp/pass.$mode.roots.tsv" \
        "the bounded fallback did not enforce bounds"
      case "$rss_kib" in ''|*[!0-9]*) fail "the fallback attempts lost per-root RSS reporting: $rss_kib" ;; esac
    else
      assert_grep $'meta\tbounds_enforced\t0' "$tmp/pass.$mode.roots.tsv" \
        "the unbounded fallback unexpectedly enforced bounds"
      # Unbounded roots read RSS from /usr/bin/time when the host has it, so the
      # figure is either that reading or the explicit unavailable marker.
      case "$rss_kib" in
        unavailable) ;;
        ''|*[!0-9]*) fail "the unbounded fallback reported a malformed RSS: $rss_kib" ;;
      esac
    fi
  done

  if ! pinned_ready; then
    pass "SKIP (ShellCheck $REQUIRED not resolved): real fallback finding check"
    return
  fi
  local real_shellcheck
  real_shellcheck=$(command -v shellcheck)
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  exec "$FM_REAL_SHELLCHECK" "$@"
fi
for arg in "$@"; do
  if [ "$arg" = --external-sources ]; then
    printf 'shellcheck: Heap exhausted;\n' >&2
    exit 251
  fi
done
exec "$FM_REAL_SHELLCHECK" "$@"
SH
  chmod +x "$fakebin/shellcheck"
  # shellcheck disable=SC2016 # The fixture intentionally contains an unexpanded parameter.
  printf '#!/usr/bin/env bash\nx=$1\nprintf "%%s\\n" $x\n' > "$fixture"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_REAL_SHELLCHECK="$real_shellcheck" \
    FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS="$require_bounds" \
    "$LINT" --telemetry "$tmp/finding.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a real ShellCheck finding in the fallback did not fail lint (exit $rc)"$'\n'"$out"
  assert_contains "$out" "fallback reason=findings rc=1" \
    "the fallback finding was not identified"
  assert_contains "$out" "SC2086" "the real fallback finding was not reported"
  awk -F '\t' '$1 == "end" && $3 ~ /teardown\.sh$/ && $9 == 1 && $10 == "findings" { found=1 } END { exit !found }' \
    "$tmp/finding.roots.tsv" || fail "the fallback finding was not recorded as a failure"
  pass "memory failures retry without source following, exclude cross-file codes, and preserve a real fallback finding"
}

test_cache_key_wait_preserves_root_retry_budget() {
  local tmp repo fakebin out
  tmp=$(fm_test_tmproot fm-lint-cache-retry-clock)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
[ "${FM_TEST_SEED:-0}" = 1 ] && exit 0
for arg in "$@"; do
  if [ "$arg" = --external-sources ]; then
    printf 'shellcheck: Heap exhausted;\n' >&2
    exit 251
  fi
done
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_SEED=1 \
    FM_LINT_CACHE_DIR="$tmp/cache" "$repo/bin/fm-lint.sh" bin/consumer.sh 2>&1) \
    || fail "key identity warm-up failed: $out"
  # The test exercises the real watchdog's time budget, not address-space
  # enforcement. macOS cannot enforce ulimit -v, so only that builtin is
  # simulated in the private fixture; Linux retains the real memory bound.
  : > "$tmp/bash-env"
  if ! fm_lint_bounds_supported; then
    cat > "$tmp/bash-env" <<'SH'
ulimit() {
  if [ "${1:-}" = -v ]; then return 0; fi
  builtin ulimit "$@"
}
SH
  fi
  perl - "$repo/bin/fm-lint.sh" "$fakebin/shellcheck" "$tmp" <<'PL' || fail "cache queue consumed the memory retry budget"
use strict;
use warnings;
use File::Path qw(make_path);
use Fcntl qw(:flock);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($lint, $tool, $tmp) = @ARGV;
my @locks = glob "$tmp/cache/*.lock";
die "expected one warmed root key\n" unless @locks == 1;
unlink $_ for glob "$tmp/cache/*.passed";
open(my $holder, '>>', $locks[0]) or die "$!";
flock($holder, LOCK_EX) or die "$!";
open(my $module, '>', "$tmp/CacheReady.pm") or die "$!";
print {$module} <<'MODULE';
package CacheReady;
use Fcntl qw(LOCK_NB);
BEGIN {
    *CORE::GLOBAL::flock = sub {
        unless ($_[1] & LOCK_NB) {
            open(my $fh, '>', "$ENV{CASE_DIR}/waiting") or die "$!";
            close $fh;
        }
        return CORE::flock($_[0], $_[1]);
    };
}
1;
MODULE
close $module;
make_path("$tmp/out");
open(my $manifest, '>', "$tmp/manifest") or die "$!";
print {$manifest} "0\tbin/consumer.sh\n";
close $manifest;
local %ENV = (%ENV, FM_LINT_INTERNAL => 1, FM_LINT_INTERNAL_CACHE => "$tmp/cache",
    FM_LINT_INTERNAL_SLOT_DIR => 'off', FM_LINT_INTERNAL_NCPU => 18,
    FM_LINT_INTERNAL_BOUNDED => 'perl', FM_LINT_INTERNAL_MEMORY_KIB => 2097152,
    FM_LINT_INTERNAL_ROOT_SECS => 8, FM_LINT_INTERNAL_GRACE => 1,
    FM_LINT_INTERNAL_ROOTS_LOG => "$tmp/roots.tsv", FM_LINT_SHELLCHECK => $tool,
    PERL5OPT => "-I$tmp -MCacheReady", CASE_DIR => $tmp, BASH_ENV => "$tmp/bash-env");
my $pid = fork();
die "fork: $!" unless defined $pid;
if (!$pid) {
    close $holder;
    open STDOUT, '>', "$tmp/worker.out" or die "$!";
    open STDERR, '>&', \*STDOUT or die "$!";
    exec '/bin/bash', $lint, '--internal-worker', "$tmp/manifest", "$tmp/out", 0;
    die "exec: $!";
}
my $error;
eval {
    my $deadline = time() + 30;
    until (-e "$tmp/waiting") { die "key waiter did not start\n" if time() > $deadline; sleep 0.01; }
    sleep 10; # Deliberately longer than the root's eight-second analysis budget.
    close $holder;
    $deadline = time() + 30;
    while (waitpid($pid, WNOHANG) == 0) {
        die "root did not finish\n" if time() > $deadline;
        sleep 0.01;
    }
    die "memory fallback failed: $?\n" if $?;
    open(my $roots, '<', "$tmp/roots.tsv") or die "$!";
    my @ends = map { [split /\t/] } grep { /^end\t/ } <$roots>;
    die "root did not finish with a successful memory retry\n"
        unless @ends == 1 && $ends[0][8] == 0 && $ends[0][9] eq 'memory-fallback';
    my $span = $ends[0][6] - $ends[0][5];
    die "key queue time was charged to root duration\n" unless $span - $ends[0][7] >= 9000;
};
$error = $@;
close $holder;
if ($error) {
    kill 'TERM', $pid;
    waitpid($pid, 0);
    open(my $output, '<', "$tmp/out/shard.0.out") or die "$!";
    local $/;
    die $error, <$output>;
}
PL
  pass "a cache-key wait longer than the root deadline preserves its memory retry budget"
}

# A ShellCheck stand-in whose source-following run grows resident memory by
# 8 MiB every 50 ms for FM_TEST_GROW_STEPS steps, then sleeps up to 20 s
# (FM_TEST_GROW_HOLD=<seconds> holds the memory that long and exits 0 instead).
# The run without --external-sources exits 0 at once.
# FM_TEST_FLAGS_LOG gets one yes/no line per attempt and FM_TEST_PID_FILE the growing process id.
fm_lint_write_growing_shellcheck() {  # <fakebin>
  cat > "$1/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
follow=no
for arg in "$@"; do
  [ "$arg" != --external-sources ] || follow=yes
done
printf '%s\n' "$follow" >> "$FM_TEST_FLAGS_LOG"
[ "$follow" = yes ] || exit 0
printf '%s\n' "$$" > "$FM_TEST_PID_FILE"
exec perl -e '
  my $held = "";
  for (1 .. $ARGV[0]) {
    $held .= "x" x (8 * 1024 * 1024);
    select(undef, undef, undef, 0.05);
  }
  if ($ARGV[1]) { select(undef, undef, undef, $ARGV[1]); exit 0; }
  sleep 20;' "$FM_TEST_GROW_STEPS" "${FM_TEST_GROW_HOLD:-0}"
SH
  chmod +x "$1/shellcheck"
}

test_unbounded_root_over_resident_bound_is_ended_and_retried_narrower() {
  local tmp fakebin fixture out rc roots_log flags_log pid_file pid rss_kib started
  tmp=$(fm_test_tmproot fm-lint-rss-bound)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/grower.sh"
  flags_log="$tmp/flags.log"
  pid_file="$tmp/grower.pid"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture"
  fm_lint_write_growing_shellcheck "$fakebin"
  : > "$flags_log"
  if [ "$(uname)" != Darwin ]; then
    # The resident watch runs only on native macOS, so elsewhere a root that
    # crosses the number is left to its single attempt.
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=0 FM_LINT_ROOT_RSS_KIB=102400 \
      FM_TEST_FLAGS_LOG="$flags_log" FM_TEST_PID_FILE="$pid_file" FM_TEST_GROW_STEPS=40 FM_TEST_GROW_HOLD=1.5 \
      "$LINT" "$fixture" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "an unwatched root did not pass (exit $rc)"$'\n'"$out"
    [ "$(cat "$flags_log")" = yes ] || fail "the resident watch ended a root off macOS"$'\n'"$(cat "$flags_log")"
    pass "off macOS the resident-memory watch leaves a root over the bound to its single attempt"
    return
  fi
  rc=0
  started=$SECONDS
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=0 FM_LINT_ROOT_RSS_KIB=102400 \
    FM_TEST_FLAGS_LOG="$flags_log" FM_TEST_PID_FILE="$pid_file" FM_TEST_GROW_STEPS=40 \
    "$LINT" --telemetry "$tmp/pass.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a root over the resident bound did not pass its narrower retry (exit $rc)"$'\n'"$out"
  [ "$((SECONDS - started))" -lt 15 ] \
    || fail "the root was not ended at the bound: lint waited out the growing process"
  [ "$(cat "$flags_log")" = "$(printf 'yes\nno')" ] \
    || fail "the resident-bound root was not retried once without external sources"$'\n'"$(cat "$flags_log")"
  assert_contains "$out" "hit the memory ceiling with --external-sources (reason=memory rc=98)" \
    "the resident-bound end was not identified in the output"
  assert_contains "$out" "fallback passed with cross-file codes excluded (SC1091,SC2034,SC2153,SC2329)" \
    "the narrower retry result was not disclosed"
  roots_log="$tmp/pass.roots.tsv"
  awk -F '\t' '$1 == "end" && $3 ~ /grower\.sh$/ && $9 == 0 && $10 == "memory-fallback" && $12 == 0 { found=1 } END { exit !found }' \
    "$roots_log" || fail "the roots log did not mark the resident-bound retry as a memory fallback"
  rss_kib=$(awk -F '\t' '$1 == "end" && $3 ~ /grower\.sh$/ { print $11 }' "$roots_log")
  case "$rss_kib" in ''|*[!0-9]*) fail "the roots log lost the peak resident size: $rss_kib" ;; esac
  [ "$rss_kib" -gt 102400 ] || fail "the roots log peak $rss_kib KiB is not above the 102400 KiB bound"
  pid=$(cat "$pid_file")
  ! kill -0 "$pid" 2>/dev/null || { kill -KILL "$pid" 2>/dev/null; fail "the over-bound process $pid outlived the lint"; }
  pass "a root over the resident-memory bound is ended and retried narrower with the roots log marking it"
}

test_unbounded_root_under_resident_bound_is_untouched() {
  local tmp fakebin fixture out rc roots_log flags_log
  tmp=$(fm_test_tmproot fm-lint-rss-normal)
  fakebin=$(fm_fakebin "$tmp")
  fixture="$tmp/normal.sh"
  flags_log="$tmp/flags.log"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture"
  fm_lint_write_growing_shellcheck "$fakebin"
  : > "$flags_log"
  rc=0
  out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=0 FM_LINT_ROOT_RSS_KIB=102400 \
    FM_TEST_FLAGS_LOG="$flags_log" FM_TEST_PID_FILE="$tmp/normal.pid" FM_TEST_GROW_STEPS=3 FM_TEST_GROW_HOLD=1.5 \
    "$LINT" --telemetry "$tmp/pass.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "a root under the resident bound did not pass (exit $rc)"$'\n'"$out"
  [ "$(cat "$flags_log")" = yes ] || fail "a root under the resident bound was not left to one attempt"$'\n'"$(cat "$flags_log")"
  assert_not_contains "$out" "memory ceiling" "a root under the resident bound was reported as a memory failure"
  roots_log="$tmp/pass.roots.tsv"
  awk -F '\t' '$1 == "end" && $3 ~ /normal\.sh$/ && $9 == 0 && $10 == "ok" && $12 == 1 { found=1 } END { exit !found }' \
    "$roots_log" || fail "the normal root was not recorded as an ordinary pass"
  rc=0
  FM_LINT_ROOT_RSS_KIB=0x "$LINT" "$fixture" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a malformed FM_LINT_ROOT_RSS_KIB was not refused (exit $rc)"
  if fm_lint_bounds_supported; then
    # The enforced ulimit envelope keeps its own behavior: the resident watch
    # does not apply, so a root that crosses the number is not ended.
    : > "$flags_log"
    rc=0
    out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_ROOT_RSS_KIB=102400 \
      FM_TEST_FLAGS_LOG="$flags_log" FM_TEST_PID_FILE="$tmp/bounded.pid" FM_TEST_GROW_STEPS=40 FM_TEST_GROW_HOLD=1.5 \
      "$LINT" "$fixture" 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || fail "the enforced envelope run did not pass (exit $rc)"$'\n'"$out"
    [ "$(cat "$flags_log")" = yes ] || fail "the resident watch ended a root inside the enforced envelope"$'\n'"$(cat "$flags_log")"
  fi
  pass "a root under the resident-memory bound, a malformed bound, and the enforced envelope behave as before"
}

test_resident_watch_ends_its_command_when_its_owner_dies() {
  local tmp owner_pid command_pid i
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the resident-memory watch runs only on macOS): owner-death check"
    return
  fi
  tmp=$(fm_test_tmproot fm-lint-rss-owner)
  # The owner is killed outright, so no signal reaches the watch: it must see the
  # lost parent and end the command's own process group.
  bash -c 'perl "$1" rsswatch 8388608 "$2" -- bash -c "echo \$\$ > \"\$1\"; exec sleep 30" _ "$3" & wait' \
    _ "$ROOT/bin/fm-lint-cache.pl" "$tmp/rss" "$tmp/command.pid" > /dev/null 2>&1 &
  owner_pid=$!
  i=0
  while [ "$i" -lt 500 ] && [ ! -s "$tmp/command.pid" ]; do sleep 0.01; i=$((i + 1)); done
  [ -s "$tmp/command.pid" ] || { kill -KILL "$owner_pid" 2>/dev/null || true; fail "the watched command did not start"; }
  command_pid=$(cat "$tmp/command.pid")
  kill -KILL "$owner_pid" 2>/dev/null || true
  wait "$owner_pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 300 ] && kill -0 "$command_pid" 2>/dev/null; do sleep 0.01; i=$((i + 1)); done
  if kill -0 "$command_pid" 2>/dev/null; then
    kill -KILL "$command_pid" 2>/dev/null || true
    fail "the watched command $command_pid outlived its killed owner"
  fi
  pass "the resident-memory watch ends its command when the owner dies"
}

# fm_lint_write_rss_shims <dir>: ps and python3 stand-ins for the resident watch.
# Each runs the absolute binary in FM_TEST_REAL_PS or FM_TEST_REAL_PYTHON once.
# A shim reached again below itself (FM_TEST_RSS_SHIM_DEPTH already set) refuses
# with status 99, so a real path that resolves back to a shim cannot recurse.
# Every entry appends its pid to FM_TEST_SHIM_TRACE when that is set. The ps
# shim logs how many processes each call listed to FM_TEST_PS_LOG, or refuses
# as a sandbox does under FM_TEST_PS_REFUSE=1; the python3 shim logs each
# call's arguments to FM_TEST_PY_LOG.
fm_lint_write_rss_shims() {  # <dir>
  local guard
  guard=$(cat <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_SHIM_TRACE:-}" ] || printf '%s\n' "$$" >> "$FM_TEST_SHIM_TRACE"
if [ -n "${FM_TEST_RSS_SHIM_DEPTH:-}" ]; then
  echo "rss shim: refused a call from inside a shim" >&2
  exit 99
fi
export FM_TEST_RSS_SHIM_DEPTH=1
SH
)
  {
    printf '%s\n' "$guard"
    cat <<'SH'
[ "${FM_TEST_PS_REFUSE:-0}" = 0 ] || exit 1
out=$("$FM_TEST_REAL_PS" "$@") || exit
printf '%s\n' "$out" | grep -c . >> "$FM_TEST_PS_LOG"
printf '%s\n' "$out"
SH
  } > "$1/ps"
  {
    printf '%s\n' "$guard"
    cat <<'SH'
printf '%s\n' "$*" >> "$FM_TEST_PY_LOG"
exec "$FM_TEST_REAL_PYTHON" "$@"
SH
  } > "$1/python3"
  chmod +x "$1/ps" "$1/python3"
}

test_rss_shim_that_resolves_to_itself_is_refused() {
  local tmp shims name rc err
  tmp=$(fm_test_tmproot fm-lint-rss-shim-loop)
  shims="$tmp/shims"
  mkdir -p "$shims"
  fm_lint_write_rss_shims "$shims"
  for name in ps python3; do
    : > "$tmp/trace"
    rc=0
    err=$("$ROOT/bin/fm-proc-budget.sh" 50 -- env -u FM_TEST_RSS_SHIM_DEPTH FM_TEST_SHIM_TRACE="$tmp/trace" \
      FM_TEST_REAL_PS="$shims/ps" FM_TEST_REAL_PYTHON="$shims/python3" \
      FM_TEST_PS_LOG="$tmp/ps.log" FM_TEST_PY_LOG="$tmp/py.log" "$shims/$name" -c 0 2>&1 >/dev/null) || rc=$?
    [ "$rc" -eq 99 ] || fail "a $name shim that resolves to itself was not refused (exit $rc)"$'\n'"$err"
    [ "$(grep -c . "$tmp/trace")" -eq 2 ] \
      || fail "a $name shim that resolves to itself ran $(grep -c . "$tmp/trace") times, not twice"
    assert_contains "$err" "rss shim: refused a call from inside a shim" "the $name shim did not name its refusal"
  done
  pass "a resident-watch shim that resolves to itself is refused at once"
}

test_resident_watch_reads_only_its_own_tree() {
  local tmp shims real_ps real_python refuse rc decoy_pid count
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the resident-memory watch runs only on macOS): own-tree sampling check"
    return
  fi
  tmp=$(fm_test_tmproot fm-lint-rss-narrow)
  shims="$tmp/shims"
  real_ps=/bin/ps
  real_python=$(command -v python3) || fail "python3 is not on PATH"
  case "$real_python" in
    /*) ;;
    *) fail "python3 did not resolve to an absolute path: $real_python" ;;
  esac
  case "$real_python" in
    "$tmp"/*) fail "python3 resolved inside the shim directory: $real_python" ;;
  esac
  mkdir -p "$shims"
  fm_lint_write_rss_shims "$shims"
  if [ ! -x "$real_ps" ] || [ "$real_ps" -ef "$shims/ps" ]; then
    fail "no real ps outside the shim directory"
  fi
  # The watched command starts a decoy that leaves the command's process
  # group and holds 160 MiB, over the 100 MiB bound, while the command lives.
  cat > "$tmp/decoy-parent.sh" <<'SH'
perl -MPOSIX -e 'POSIX::setpgid(0, 0); my $held = "x" x (160 * 1024 * 1024); sleep 30' &
echo "$!" > "$1"
sleep 3
SH
  for refuse in 0 1; do
    : > "$tmp/ps.log"
    : > "$tmp/py.log"
    rm -f "$tmp/rss" "$tmp/decoy.pid"
    rc=0
    "$ROOT/bin/fm-proc-budget.sh" 200 -- env -u FM_TEST_RSS_SHIM_DEPTH PATH="$shims:$PATH" \
      FM_TEST_PS_REFUSE="$refuse" FM_TEST_REAL_PS="$real_ps" FM_TEST_REAL_PYTHON="$real_python" \
      FM_TEST_PS_LOG="$tmp/ps.log" FM_TEST_PY_LOG="$tmp/py.log" \
      perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 102400 "$tmp/rss" -- \
      bash "$tmp/decoy-parent.sh" "$tmp/decoy.pid" > /dev/null 2>&1 || rc=$?
    decoy_pid=$(cat "$tmp/decoy.pid" 2>/dev/null || true)
    [ -z "$decoy_pid" ] || kill -KILL "$decoy_pid" 2>/dev/null || true
    [ -n "$decoy_pid" ] || fail "the decoy did not start"
    [ "$rc" -eq 0 ] && [ ! -e "$tmp/rss" ] \
      || fail "the watch counted a process outside its command's tree (exit $rc, ps refused=$refuse)"
    if [ "$refuse" = 0 ]; then
      [ -s "$tmp/ps.log" ] || fail "the watch never sampled through ps"
      while read -r count; do
        [ "$count" -le 5 ] || fail "a ps sample listed $count processes, not only the watched tree"
      done < "$tmp/ps.log"
    else
      grep -q 'rss-tree' "$tmp/py.log" || fail "the watch did not fall back to the libproc reader when ps was refused"
    fi
  done
  pass "the resident-memory watch samples only its command's own tree"
}

fm_lint_test_cases=(
test_jobs_are_deterministic_and_complete
test_host_slots_bound_concurrent_runs
test_oversubscribed_runs_share_the_cap_and_all_finish
test_host_cap_is_cpu_derived_and_occupancy_bounded
test_host_waiters_make_progress_without_barging
test_unequal_runs_share_scarce_slots_per_run
test_stopped_head_waiter_does_not_block_the_queue
test_stopped_admission_coordinator_does_not_freeze_free_capacity
test_queue_scan_survives_odd_slot_paths_and_vanishing_tickets
test_cached_success_does_not_wait_for_host_slots
test_slot_pool_can_be_disabled_or_misconfigured
test_slot_file_failures_run_ungated
test_slot_survives_gate_death
test_queued_roots_use_high_resolution_timings
test_worker_trees_stop_on_signal
test_root_deadline_names_the_root_and_reaps_the_tree
test_root_memory_limit_reports_a_named_death
test_memory_failure_retries_without_external_sources
test_unbounded_root_over_resident_bound_is_ended_and_retried_narrower
test_unbounded_root_under_resident_bound_is_untouched
test_resident_watch_ends_its_command_when_its_owner_dies
test_rss_shim_that_resolves_to_itself_is_refused
test_resident_watch_reads_only_its_own_tree
test_cache_key_wait_preserves_root_retry_budget
)
fm_lint_run "$@"
