#!/usr/bin/env bash
# bin/fm-lint.sh's host slots and resource bounds: deterministic job
# completion, the CPU-derived host cap, waiter and admission fairness,
# cache hits that skip the pool, refused or failing slot state, per-root
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
# The count-cap tests below isolate the count from the memory budget, which
# the memory tests set for themselves.
export FM_LINT_HOST_RSS_KIB=100000000

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
  baseline=$(FM_LINT_SLOT_DIR="$tmp/baseline-slots" FM_LINT_HOST_SLOTS=99 FM_LINT_HOST_RSS_KIB=1000000000 \
    fm_lint_concurrent_runs 6 "$tmp" "$tmp/bin" 12)
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

test_slow_ps_does_not_hold_admission_against_the_next_root() {
  local tmp real_ps
  tmp=$(fm_test_tmproot fm-lint-slot-slow-ps)
  mkdir -p "$tmp/bin" "$tmp/hide"
  fm_lint_hide_outside_shellcheck "$tmp/hide"
  real_ps="$tmp/hide/ps"
  # The waiter's owner check (ps -p) does not return until the next root has
  # started, or for 30 s. A check made while holding admission.lock locks that
  # root out for the whole time.
  cat > "$tmp/bin/ps" <<SH
#!/bin/sh
case " \$* " in
  *" -p "*)
    : > "$tmp/p-called"
    i=0
    until grep -q next "$tmp/order" 2>/dev/null; do
      i=\$((i + 1))
      if [ "\$i" -ge 600 ]; then : > "$tmp/p-timed-out"; break; fi
      sleep 0.05
    done
    ;;
esac
exec "$real_ps" "\$@"
SH
  chmod +x "$tmp/bin/ps"
  perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "slow ps admission regression failed"
use strict;
use warnings;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($gate, $tmp) = @ARGV;
# Free count slots, but a budget that holds one root: the root after the first
# keeps its turn, and the root behind it keeps checking on that root's owner.
local $ENV{FM_LINT_HOST_SLOTS} = 4;
local $ENV{FM_LINT_HOST_RSS_KIB} = 1000000;
local $ENV{FM_LINT_INTERNAL_ROOT_CAP_KIB} = 800000;
local $ENV{PATH} = "$tmp/bin:$ENV{PATH}";
my $note = 'open(my $fh, ">>", "$ARGV[0]/order") or die "$!"; print {$fh} "$ARGV[1]\n"; close $fh;';
my $hold = 'for (1 .. 1200) { last if -e "$ARGV[0]/p-called"; select(undef, undef, undef, 0.05); }';
sub spawn {
    my ($label, $code) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        exec $^X, $gate, 'gate', "$tmp/slots", 18, 'run', "$tmp/$label.wait", '--', $^X, '-e', $code, $tmp, $label;
        die "exec: $!";
    }
    return $pid;
}
sub until_seen {
    my ($what, $test) = @_;
    my $deadline = time() + 30;
    until ($test->()) {
        die "$what\n" if time() > $deadline;
        sleep 0.01;
    }
}
my @pids;
my $error;
eval {
    push @pids, spawn('first', "$note $hold");
    until_seen('the first root never started', sub { -s "$tmp/order" });
    push @pids, spawn('next', $note);
    until_seen('the next root never queued', sub { grep { /\.run\z/ } glob "$tmp/slots/queue.*" });
    push @pids, spawn('later', $note);
    my $deadline = time() + 90;
    for my $pid (@pids) {
        while (waitpid($pid, WNOHANG) == 0) {
            die "a gate did not finish\n" if time() > $deadline;
            sleep 0.01;
        }
        die "a gate ended with status $?\n" if $?;
    }
    @pids = ();
    die "the waiter never checked on the owner of the next root\n" unless -e "$tmp/p-called";
    die "a waiter's ps kept the next root out of admission\n" if -e "$tmp/p-timed-out";
    open(my $fh, '<', "$tmp/order") or die "$!";
    my $order = join '', <$fh>;
    die "admission order was $order\n" unless $order eq "first\nnext\nlater\n";
};
$error = $@;
for my $pid (@pids) { kill 'KILL', $pid; waitpid($pid, 0); }
die $error if $error;
PL
  pass "a waiter's slow ps does not keep the next root out of admission"
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
  # A stand-in analysis, not the real ShellCheck: the pool directory below is a
  # fixture, which a real ShellCheck may not use.
  local tmp repo out fakebin
  tmp=$(fm_test_tmproot fm-lint-cache-slots)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  cat > "$fakebin/shellcheck" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  out=$(PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_CACHE_DIR="$tmp/cache" \
    "$repo/bin/fm-lint.sh" bin/consumer.sh 2>&1) || fail "cache warm-up failed: $out"
  perl - "$repo/bin/fm-lint.sh" "$tmp" "$fakebin" <<'PL' || fail "warm cache queued behind an occupied host slot"
use strict;
use warnings;
use File::Path qw(make_path);
use Fcntl qw(:flock);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($lint, $tmp, $fakebin) = @ARGV;
make_path("$tmp/slots");
open(my $holder, '>>', "$tmp/slots/slot.0") or die "$!";
flock($holder, LOCK_EX) or die "$!";
local %ENV = (%ENV, PATH => "$fakebin:$ENV{PATH}", CI => '', GITHUB_ACTIONS => '', FM_LINT_CACHE_DIR => "$tmp/cache",
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

test_slot_pool_cannot_be_disabled_and_refuses_bad_settings() {
  local tmp rc out
  tmp=$(fm_lint_slot_fixture fm-lint-slots-off)
  # No setting turns the host-wide bound off: FM_LINT_SLOT_DIR=off is refused by
  # name and starts no ShellCheck, whatever ShellCheck is in use.
  fm_lint_write_memory_shellcheck "$tmp/off-bin" 1 "$tmp/off.starts"
  : > "$tmp/off.starts"
  rc=0
  out=$(PATH="$tmp/off-bin:$PATH" FM_LINT_SLOT_DIR=off "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "FM_LINT_SLOT_DIR=off exited $rc, expected 2"$'\n'"$out"
  assert_contains "$out" "FM_LINT_SLOT_DIR=off is not supported" "the refusal did not name the switch"
  [ ! -s "$tmp/off.starts" ] || fail "FM_LINT_SLOT_DIR=off still started a ShellCheck"
  rc=0
  out=$(FM_LINT_SLOT_DIR=off "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "FM_LINT_SLOT_DIR=off with the real ShellCheck exited $rc, expected 2"$'\n'"$out"
  assert_contains "$out" "FM_LINT_SLOT_DIR=off is not supported" "the real-ShellCheck refusal did not name the switch"
  rc=0
  out=$(PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/slots" FM_LINT_HOST_SLOTS=zero "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a non-numeric FM_LINT_HOST_SLOTS exited $rc, expected 2"
  assert_contains "$out" "FM_LINT_HOST_SLOTS" "the refusal did not name the setting"
  [ ! -d "$tmp/slots" ] || fail "a refused run still created the slot directory"
  for value in zero 0 08 1.5; do
    rc=0
    out=$(env FM_LINT_HOST_RSS_KIB="$value" PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/slots" "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_LINT_HOST_RSS_KIB=$value exited $rc, expected 2"
    assert_contains "$out" "FM_LINT_HOST_RSS_KIB" "the refusal did not name FM_LINT_HOST_RSS_KIB"
  done
  [ ! -d "$tmp/slots" ] || fail "a refused run still created the slot directory"
  # An unusable pool is not a bound: the run stops before any root starts and
  # names the path and the fix, rather than warning and analysing unbounded.
  fm_lint_write_memory_shellcheck "$tmp/memory-bin" 1 "$tmp/refused.starts"
  : > "$tmp/refused.starts"
  rc=0
  out=$(PATH="$tmp/memory-bin:$PATH" FM_LINT_SLOT_DIR="$tmp/a.sh/blocked" "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "an unusable slot directory exited $rc, expected 2"$'\n'"$out"
  assert_contains "$out" "$tmp/a.sh/blocked" "the refusal did not name the unusable path"
  assert_contains "$out" "FM_LINT_SLOT_DIR" "the refusal did not name the fix"
  assert_not_contains "$out" "running without the host-wide ShellCheck bound" "an unusable pool still ran unbounded"
  [ ! -s "$tmp/refused.starts" ] || fail "an unusable pool still started ShellCheck"
  pass "the slot pool cannot be disabled, rejects bad settings, and refuses an unusable directory instead of running unbounded"
}

# fm_lint_write_stepping_shellcheck <fakebin> <steps> <MiB per step> <seconds per step> <log>:
# a stand-in analysis that takes its memory in steps after it starts, then holds
# it for FM_TEST_MEM_HOLD seconds (default 2); with FM_TEST_GROW_AFTER set it
# waits for that many stand-ins to have started before it grows. It appends "start <pid> <time>",
# "mem <pid> <time> <MiB held>" after each step and "end <pid> <time>" to <log>,
# so the memory held at any moment is known without sampling.
fm_lint_write_stepping_shellcheck() {
  mkdir -p "$1"
  cat > "$1/shellcheck" <<PL
#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes qw(time sleep);
BEGIN {
    if ((\$ARGV[0] // '') eq '--version') {
        print "ShellCheck - shell script analysis tool\nversion: 0.11.0\n";
        exit 0;
    }
}
my \$log = '$5';
sub note { open(my \$fh, '>>', \$log) or die "\$!"; printf {\$fh} "%s %d %.6f%s\n", shift, \$\$, time(), @_ ? " \$_[0]" : ''; close \$fh; }
note('start');
# Grow only once FM_TEST_GROW_AFTER stand-ins have started, so every run is
# admitted small before any of them grows.
if (my \$peers = \$ENV{FM_TEST_GROW_AFTER}) {
    my \$deadline = time() + 60;
    while (time() < \$deadline) {
        open(my \$fh, '<', \$log) or last;
        my \$n = () = grep { /^start / } <\$fh>;
        close \$fh;
        last if \$n >= \$peers;
        sleep 0.05;
    }
}
my @blocks;
for my \$step (1 .. $2) {
    push @blocks, 'x' x ($3 * 1048576);
    note('mem', \$step * $3);
    sleep $4;
}
sleep \$ENV{FM_TEST_MEM_HOLD} // 2;
note('end');
exit 0;
PL
  chmod +x "$1/shellcheck"
  fm_lint_hide_outside_shellcheck "$1"
}

# fm_lint_peak_held <log>: the most MiB held at one moment by the stand-ins that
# logged to <log> (each holds its last reported size from its first report until
# its end), and the most that were alive at once. Prints "<MiB> <alive>".
fm_lint_peak_held() {
  perl -ane '
    if ($F[0] eq "start") { push @e, [$F[2], 0, $F[1], 0]; }
    elsif ($F[0] eq "mem") { push @e, [$F[2], 1, $F[1], $F[3]]; }
    elsif ($F[0] eq "end") { push @e, [$F[2], 2, $F[1], 0]; }
    END {
      my (%held, %alive, $peak, $most);
      for (sort { $a->[0] <=> $b->[0] } @e) {
        my ($t, $kind, $pid, $mib) = @$_;
        if ($kind == 0) { $alive{$pid} = 1; }
        elsif ($kind == 1) { $held{$pid} = $mib; }
        else { delete $alive{$pid}; delete $held{$pid}; }
        my $sum = 0; $sum += $_ for values %held;
        $peak = $sum if !defined $peak || $sum > $peak;
        my $n = keys %alive; $most = $n if !defined $most || $n > $most;
      }
      printf "%d %d\n", $peak // 0, $most // 0;
    }' "$1"
}

test_growing_roots_are_held_to_the_budget_across_pools() {
  local tmp run rc pid peak most pids budget history key
  local -a all
  tmp=$(fm_test_tmproot fm-lint-growth)
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  # Each stand-in takes 4 MiB every 0.25 s for 4 s (64 MiB) after its lint run
  # admits it. Four runs from four HOME values each use their own pool directory,
  # and each pool already holds a 16 MiB record for the root, so all four are
  # admitted at once, small, and then grow together.
  fm_lint_write_stepping_shellcheck "$tmp/bin" 16 4 0.25 "$tmp/growth.log"
  key=$(printf "full:%s" "$(cd -P "$tmp" && pwd -P)/a.sh" | perl -MDigest::SHA=sha256_hex -ne 'print sha256_hex($_)')
  for budget in 131072 100000000; do
    : > "$tmp/growth.log"
    pids=()
    for run in 1 2 3 4; do
      history="$tmp/pool.$budget.$run/history"
      mkdir -p "$history" "$tmp/home.$run/.cache"
      printf '16384\n' > "$history/$key"
      env HOME="$tmp/home.$run" XDG_CACHE_HOME="$tmp/home.$run/.cache" FM_HOME="$tmp/fm.$run" \
        FM_LINT_SLOT_DIR="$tmp/pool.$budget.$run" FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB="$budget" \
        FM_LINT_ROOT_RSS_KIB=262144 FM_TEST_GATE_POOL_PREFIX="$tmp/pool.$budget." FM_TEST_GROW_AFTER=4 PATH="$tmp/bin:$PATH" \
        "$LINT" --jobs 1 "$tmp/a.sh" > "$tmp/growth.$budget.$run.out" 2>&1 &
      pids+=("$!")
    done
    rc=0
    for pid in "${pids[@]}"; do wait "$pid" || rc=$?; done
    [ "$rc" -eq 0 ] || fail "a growing run failed under budget $budget (rc=$rc)"$'\n'"$(cat "$tmp"/growth.$budget.*.out)"
    read -r peak most <<<"$(fm_lint_peak_held "$tmp/growth.log")"
    all+=("$budget:$peak:$most")
    if [ "$budget" -eq 131072 ]; then
      # The budget is 128 MiB; one root grows to 64 MiB beyond its interpreter, so
      # budget plus one root is 192 MiB.
      [ "$peak" -le 192 ] || fail "four growing roots in four pools held $peak MiB, above the 128 MiB budget plus one 64 MiB root: ${all[*]}"
      [ "$(grep -c '^end ' "$tmp/growth.log")" -eq 4 ] || fail "not every growing root finished under the budget: ${all[*]}"
    else
      # The control: with no effective budget the same roots stack.
      [ "$peak" -gt 192 ] || fail "four growing roots held only $peak MiB without a budget, so this test cannot show a bound: ${all[*]}"
    fi
  done
  pass "growing roots from four pools stay within the budget plus one root and all finish; without a budget they stack (${all[*]} as budget:peak MiB:alive)"
}

test_a_wrapper_around_the_real_shellcheck_shares_the_host_wide_memory_bound() {
  local tmp rc out outside pid deadline real before after
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): wrapper around the real ShellCheck"; return; }
  tmp=$(fm_test_tmproot fm-lint-wrapper)
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  real=$(command -v shellcheck)
  printf '#!/bin/sh\n[ "${1:-}" = --version ] || : > "%s/analysis.marker"\nexec "%s" "$@"\n' "$tmp" "$real" > "$tmp/bin/shellcheck"
  chmod +x "$tmp/bin/shellcheck"
  fm_lint_hide_outside_shellcheck "$tmp/bin"
  # Compliant: a one-line wrapper with no pool setting goes through the shared
  # host pool, takes a ticket there and makes no scratch pool of its own.
  before=$(cat "/var/tmp/firstmate-lint-$(id -u)/lint-slots/queue.next" 2>/dev/null || printf 0)
  rc=0
  out=$(env -u FM_LINT_SLOT_DIR PATH="$tmp/bin:$PATH" TMPDIR="$tmp" FM_LINT_HOST_RSS_KIB=1000000000 "$LINT" --jobs 1 "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the wrapper run failed (rc=$rc)"$'\n'"$out"
  [ -e "$tmp/analysis.marker" ] || fail "the wrapper never ran the real analysis"
  after=$(cat "/var/tmp/firstmate-lint-$(id -u)/lint-slots/queue.next" 2>/dev/null || printf 0)
  [ "$((after - before))" -ge 1 ] || fail "the wrapper run took no ticket in the host pool (tickets $before -> $after)"
  [ -z "$(find "$tmp" -maxdepth 2 -name slots -print -quit)" ] || fail "the wrapper run made a pool of its own under its scratch directory"
  # Harmful: the same wrapper pointed at its own pool, while a real ShellCheck
  # outside it holds more than the 4 MiB budget, is not admitted although its pool
  # is empty, and runs once the outside one ends.
  rm -f "$tmp/analysis.marker"
  mkfifo "$tmp/hold"
  "$real" - < "$tmp/hold" > /dev/null 2>&1 &
  outside=$!
  exec 9> "$tmp/hold"
  sleep 2
  PATH="$tmp/bin:$PATH" FM_TEST_COUNTED_SHELLCHECK_PID="$outside" FM_LINT_SLOT_DIR="$tmp/own-pool" FM_LINT_HOST_SLOTS=9 \
    FM_LINT_HOST_RSS_KIB=4096 "$LINT" "$tmp/a.sh" > "$tmp/wrapper.out" 2>&1 9>&- &
  pid=$!
  sleep 4
  if [ -e "$tmp/analysis.marker" ]; then
    exec 9>&-
    kill "$outside" "$pid" 2>/dev/null || true
    fail "a wrapper in its own pool started while a real shellcheck outside it held more than the 4 MiB budget"
  fi
  exec 9>&-
  wait "$outside" 2>/dev/null || true
  deadline=$((SECONDS + 30))
  until [ -e "$tmp/analysis.marker" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { kill "$pid" 2>/dev/null || true; fail "the wrapper stayed queued after the outside shellcheck ended"; }
    sleep 0.2
  done
  wait "$pid" || fail "the wrapper run failed after the outside shellcheck ended"$'\n'"$(cat "$tmp/wrapper.out")"
  pass "a wrapper around the real ShellCheck uses the host pool by default and is held back by real shellcheck memory outside its own pool"
}

test_slot_file_failures_refuse_and_never_run_unbounded() {
  local tmp
  tmp=$(fm_test_tmproot fm-lint-slot-errors)
  perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "slot I/O refusal regression failed"
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
for my $failure (qw(open scan coordinator counter)) {
    my $dir = "$tmp/$failure";
    make_path("$dir/slots");
    make_path("$dir/slots/slot.0") if $failure eq 'open';
    if ($failure eq 'counter') {
        open(my $counter, '>', "$dir/slots/queue.next") or die "$!";
        print {$counter} "not a number\n";
        close $counter;
    }
    local $ENV{FM_LINT_HOST_SLOTS} = 1;
    local $ENV{FAIL_LOCK} = $failure;
    my @inject = $failure =~ /\A(?:open|counter)\z/ ? () : ("-I$tmp", '-MFailLock');
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open STDERR, '>', "$dir/err" or die "$!";
        open STDOUT, '>', "$dir/out" or die "$!";
        exec $^X, @inject, $gate, 'gate', "$dir/slots", 18, 'fail', "$dir/wait",
            '--', $^X, '-e', 'print "analysis ran\n"; exit 23';
        die "exec: $!";
    }
    my $deadline = time() + 30;
    while (waitpid($pid, WNOHANG) == 0) {
        if (time() > $deadline) {
            kill 'KILL', $pid;
            waitpid($pid, 0);
            die "$failure failure queued instead of refusing\n";
        }
        sleep 0.01;
    }
    die "$failure failure exited with status $?, expected a refusal with exit 2\n" unless $? == (2 << 8);
    open(my $out, '<', "$dir/out") or die "$!";
    local $/;
    my $ran = <$out>;
    die "$failure failure still ran the analysis unbounded\n" if defined $ran && length $ran;
    open(my $err, '<', "$dir/err") or die "$!";
    my $message = <$err>;
    die "$failure refusal omitted the cause: $message\n" unless $message =~ /host slot pool unusable at \Q$dir\E\/slots/;
    die "$failure refusal omitted the fix: $message\n" unless $message =~ /writable/;
    die "$failure refusal offers a way to run without the bound: $message\n" if $message =~ /FM_LINT_SLOT_DIR/;
    die "$failure refusal still claims to run unbounded: $message\n" if $message =~ /running without the host-wide ShellCheck bound/;
}
PL
  pass "slot open, counter and non-contention coordinator/scan lock failures refuse naming the path and never run the analysis"
}

# fm_lint_write_memory_shellcheck <fakebin> <MiB> <start-log>: a stand-in
# analysis that holds a known resident size. FM_TEST_MEM_DELAY sets how many
# seconds it waits after it starts before it allocates (default 0), and
# FM_TEST_MEM_HOLD how many seconds it holds the memory (default 1.5). A
# --version call answers before it allocates. It appends its pid to
# <start-log> once it holds the memory, and "<pid> <held from> <held until>"
# to <start-log>.spans when it ends.
fm_lint_write_memory_shellcheck() {
  mkdir -p "$1"
  cat > "$1/shellcheck" <<PL
#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes qw(time);
BEGIN {
    if ((\$ARGV[0] // '') eq '--version') {
        print "ShellCheck - shell script analysis tool\nversion: 0.11.0\n";
        exit 0;
    }
    select(undef, undef, undef, \$ENV{FM_TEST_MEM_DELAY} // 0);
}
my \$block = 'x' x ($2 * 1048576);
my \$held = time();
open(my \$log, '>>', '$3') or die "\$!";
print {\$log} "\$\$\n";
close \$log;
select(undef, undef, undef, \$ENV{FM_TEST_MEM_HOLD} // 1.5);
open(my \$spans, '>>', '$3.spans') or die "\$!";
printf {\$spans} "%d %.6f %.6f\n", \$\$, \$held, time();
close \$spans;
exit(length(\$block) ? 0 : 1);
PL
  chmod +x "$1/shellcheck"
  fm_lint_hide_outside_shellcheck "$1"
}

# fm_lint_memory_runs <tmp> <fakebin> <runs> [VAR=value...]: start <runs> lint
# runs at once, each with its own HOME, XDG_CACHE_HOME and FM_HOME and three
# roots. Prints "<peak concurrent> <started>": the most stand-in analyses that
# held their memory at the same moment, taken from their own start and end
# times rather than from a sampler, and how many started.
fm_lint_memory_runs() {
  local tmp=$1 fakebin=$2 runs=$3 run rc=0 pid most
  local -a pids
  shift 3
  : > "$tmp/mem.starts"
  : > "$tmp/mem.starts.spans"
  for run in $(seq 1 "$runs"); do
    mkdir -p "$tmp/home.$run/.cache" "$tmp/fm.$run"
    env FM_TEST_MEM_HOLD="${FM_TEST_MEM_HOLD:-4}" "$@" HOME="$tmp/home.$run" XDG_CACHE_HOME="$tmp/home.$run/.cache" FM_HOME="$tmp/fm.$run" \
      PATH="$fakebin:$PATH" "$LINT" --jobs 2 "$tmp/a.sh" "$tmp/b.sh" "$tmp/c.sh" > "$tmp/mem.run.$run.out" 2>&1 &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || rc=$?
  done
  [ "$rc" -eq 0 ] || fail "a stand-in lint run failed (rc=$rc)"$'\n'"$(cat "$tmp"/mem.run.*.out)"
  most=$(perl -ane 'push @e, [$F[1], 1], [$F[2], -1];
    END { my ($n, $m) = (0, 0);
      for (sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @e) { $n += $_->[1]; $m = $n if $n > $m }
      print "$m\n" }' "$tmp/mem.starts.spans")
  printf '%s %s\n' "$most" "$(wc -l < "$tmp/mem.starts" | tr -d ' ')"
}

# fm_lint_max_recorded_peak <slot-dir>: the largest root peak (KiB) the pool's
# history records, or 0 when it records none.
fm_lint_max_recorded_peak() {
  local max=0 value file
  for file in "$1"/history/*; do
    [ -f "$file" ] || continue
    value=$(cat "$file")
    if [ "$value" -gt "$max" ]; then max=$value; fi
  done
  printf '%s\n' "$max"
}

test_memory_budget_bounds_the_aggregate_across_homes() {
  local tmp limit record budget baseline cold warm lone peak most starts
  tmp=$(fm_test_tmproot fm-lint-memory-budget)
  mkdir -p "$tmp/bin"
  for root in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$root.sh"; done
  fm_lint_write_memory_shellcheck "$tmp/bin" 64 "$tmp/mem.starts"
  # The per-root watch bound is also the charge of a root with no record; it
  # sits well above one stand-in, so the watch never ends one.
  limit=$((65536 * 4))
  # Without a budget, four runs from four homes stack on one count cap of nine.
  baseline=$(fm_lint_memory_runs "$tmp" "$tmp/bin" 4 FM_LINT_SLOT_DIR="$tmp/base" \
    FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=100000000 FM_LINT_ROOT_RSS_KIB="$limit")
  record=$(fm_lint_max_recorded_peak "$tmp/base")
  { [ "$record" -gt 0 ] && [ "$record" -lt "$limit" ]; } \
    || fail "the unbudgeted runs recorded a stand-in peak of $record KiB, expected above 0 and below $limit"
  # Two recorded stand-ins fit the budget and three do not; two unrecorded ones
  # (charged the watch bound) do not. The aggregate at any moment is the number
  # of stand-ins whose own start and end times overlap, each at the recorded
  # stand-in peak.
  budget=$((record * 5 / 2))
  read -r most starts <<<"$baseline"
  peak=$((most * record))
  [ "$peak" -gt $((budget + record)) ] \
    || fail "four unbudgeted runs peaked at only $peak KiB ($most at once), so this test cannot show a bound: $baseline"
  # A pool with no records charges each root the watch bound until its first
  # copy ends, so the aggregate stays within the budget although each stand-in
  # waits after its admission before it allocates, and no reading taken at
  # admission sees its memory.
  cold=$(fm_lint_memory_runs "$tmp" "$tmp/bin" 4 FM_LINT_SLOT_DIR="$tmp/shared" FM_LINT_HOST_SLOTS=9 \
    FM_LINT_HOST_RSS_KIB="$budget" FM_LINT_ROOT_RSS_KIB="$limit" FM_TEST_MEM_DELAY=0.5 FM_TEST_MEM_HOLD=1)
  read -r most starts <<<"$cold"
  peak=$((most * record))
  [ "$peak" -le $((budget + 16384)) ] \
    || fail "four runs with no records reached $peak KiB of stand-in memory, above the $budget KiB budget: $cold"
  [ "$most" -le 2 ] || fail "a pool with no records ran $most roots at once, more than two recorded roots fit: $cold"
  [ "$starts" -eq 12 ] || fail "$starts of 12 roots completed in a pool with no records: $cold"
  # The same four runs once every root is recorded: two run at once, and the
  # aggregate stays within the budget although each allocates after admission.
  warm=$(fm_lint_memory_runs "$tmp" "$tmp/bin" 4 FM_LINT_SLOT_DIR="$tmp/shared" FM_LINT_HOST_SLOTS=9 \
    FM_LINT_HOST_RSS_KIB="$budget" FM_LINT_ROOT_RSS_KIB="$limit" FM_TEST_MEM_DELAY=0.5 FM_TEST_MEM_HOLD=1.5)
  read -r most starts <<<"$warm"
  peak=$((most * record))
  [ "$peak" -le $((budget + 16384)) ] \
    || fail "four runs with records reached $peak KiB of stand-in memory, above the $budget KiB budget: $warm"
  [ "$most" -eq 2 ] || fail "recorded roots ran $most at once, expected the two that fit the budget: $warm"
  [ "$starts" -eq 12 ] || fail "$starts of 12 recorded roots completed under the budget: $warm"
  # A lone run keeps its two workers once its roots are recorded. Each stand-in
  # holds its memory for eight seconds, so a second worker that starts seconds
  # late on a loaded host still overlaps the first; a gate that admits them one
  # at a time still leaves no overlap.
  lone=$(fm_lint_memory_runs "$tmp" "$tmp/bin" 1 FM_LINT_SLOT_DIR="$tmp/shared" FM_LINT_HOST_SLOTS=9 \
    FM_LINT_HOST_RSS_KIB="$budget" FM_LINT_ROOT_RSS_KIB="$limit" FM_TEST_MEM_HOLD=8)
  read -r most starts <<<"$lone"
  [ "$most" -eq 2 ] || fail "a lone run with recorded roots peaked at $most stand-ins, expected its two workers: $lone"
  pass "four runs with four HOME values stay within the memory budget with and without records, run two recorded roots at once, and finish all 12 roots (unbudgeted: $baseline; no records: $cold; records: $warm)"
}

test_root_larger_than_the_budget_runs_alone_and_a_killed_run_frees_its_charge() {
  local tmp stand out first second pid_a pid_b deadline
  tmp=$(fm_test_tmproot fm-lint-memory-alone)
  mkdir -p "$tmp/bin"
  for root in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$root.sh"; done
  fm_lint_write_memory_shellcheck "$tmp/bin" 64 "$tmp/mem.starts"
  stand=65536
  # A budget smaller than one root: each root still runs, one at a time.
  out=$(fm_lint_memory_runs "$tmp" "$tmp/bin" 1 FM_LINT_SLOT_DIR="$tmp/alone" \
    FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=$((stand / 2)))
  [ "$(printf '%s' "$out" | cut -d' ' -f1)" -eq 1 ] || fail "a root larger than the budget did not run alone: $out"
  [ "$(printf '%s' "$out" | cut -d' ' -f2)" -eq 3 ] || fail "a root larger than the budget did not complete every root: $out"
  # A run killed while it holds the only admissible charge frees it for the waiter.
  : > "$tmp/mem.starts"
  FM_TEST_MEM_HOLD=60 FM_LINT_SLOT_DIR="$tmp/kill" FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=$((stand * 3 / 2)) \
    PATH="$tmp/bin:$PATH" "$LINT" --jobs 1 "$tmp/a.sh" > "$tmp/kill.a.out" 2>&1 &
  pid_a=$!
  deadline=$((SECONDS + 20))
  until [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -ge 1 ]; do
    [ "$SECONDS" -lt "$deadline" ] || { kill "$pid_a" 2>/dev/null; fail "the first run never started its root"; }
    sleep 0.1
  done
  FM_TEST_MEM_HOLD=0.3 FM_LINT_SLOT_DIR="$tmp/kill" FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=$((stand * 3 / 2)) \
    PATH="$tmp/bin:$PATH" "$LINT" --jobs 1 "$tmp/b.sh" > "$tmp/kill.b.out" 2>&1 &
  pid_b=$!
  sleep 2
  [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -eq 1 ] || fail "the waiter started while the first root held the whole budget"
  kill -TERM "$pid_a" 2>/dev/null || true
  wait "$pid_a" 2>/dev/null || true
  deadline=$((SECONDS + 30))
  until [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -ge 2 ]; do
    [ "$SECONDS" -lt "$deadline" ] || { kill "$pid_b" 2>/dev/null; fail "the waiter stayed queued after the holding run was killed"; }
    sleep 0.1
  done
  wait "$pid_b" || fail "the waiter failed after the killed run released its charge"$'\n'"$(cat "$tmp/kill.b.out")"
  first=$(find "$tmp/kill" -name 'queue.0*' -print | head -1)
  [ -z "$first" ] || fail "a killed or finished run left a queue ticket behind: $first"
  second=$(FM_TEST_MEM_HOLD=0.2 FM_LINT_SLOT_DIR="$tmp/kill" FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=$((stand * 3 / 2)) \
    PATH="$tmp/bin:$PATH" "$LINT" --jobs 1 "$tmp/c.sh" 2>&1) \
    || fail "a later run failed on the pool a killed run used: $second"
  pass "a root larger than the budget runs alone, and a killed run frees its charge and leaves no ticket"
}

test_memory_charge_survives_unknown_records_and_an_unreadable_table() {
  local tmp
  tmp=$(fm_test_tmproot fm-lint-memory-state)
  mkdir -p "$tmp/shim" "$tmp/lonely" "$tmp/hide"
  printf '#!/bin/sh\nexit 1\n' > "$tmp/shim/ps"
  chmod +x "$tmp/shim/ps"
  fm_lint_hide_outside_shellcheck "$tmp/hide"
  cp "$ROOT/bin/fm-lint-cache.pl" "$tmp/lonely/fm-lint-cache.pl"
  PATH="$tmp/hide:$PATH" perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "memory charge state regression failed"
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use Fcntl qw(:flock);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($gate, $tmp) = @ARGV;
my $waiting = q{
    use Time::HiRes qw(time sleep);
    my ($started, $release, $peak, $rss) = @ARGV;
    if (length $peak) {
        open(my $fh, '>', $ENV{FM_LINT_INTERNAL_SLOT_PEAK_FILE}) or die "$!";
        print {$fh} "$peak\n";
        close $fh;
    }
    if (length $rss) {
        open(my $fh, '>', $ENV{FM_LINT_INTERNAL_ROOT_RSS_FILE}) or die "$!";
        print {$fh} "max_rss_kib=$rss\n";
        close $fh;
    }
    open(my $fh, '>', $started) or die "$!";
    close $fh;
    my $deadline = time() + 20;
    until (-e $release) { exit 1 if time() > $deadline; sleep 0.01; }
};
sub launch {
    my ($gate_script, $dir, $name, $env, $peak, $rss) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        %ENV = (%ENV, FM_LINT_INTERNAL_ROOT_RSS_FILE => "$dir/rss.$name", %$env);
        exec $^X, $gate_script, 'gate', "$dir/slots", 18, $name, "$dir/wait.$name", '--',
            $^X, '-e', $waiting, "$dir/started.$name", "$dir/release.$name", $peak // '', $rss // '';
        die "exec: $!";
    }
    return $pid;
}
sub await {
    my ($path, $seconds) = @_;
    my $deadline = time() + $seconds;
    until (-e $path) { return 0 if time() > $deadline; sleep 0.01; }
    return 1;
}
sub release {
    my ($dir, $name, $pid) = @_;
    open(my $fh, '>', "$dir/release.$name") or die "$!";
    close $fh;
    waitpid($pid, 0);
    die "$name failed: $?\n" if $?;
}
sub history { "$_[0]/slots/history/" . sha256_hex($_[1]) }
sub record {
    my ($dir, $key, $kib) = @_;
    make_path("$dir/slots/history");
    open(my $fh, '>', history($dir, $key)) or die "$!";
    print {$fh} "$kib\n";
    close $fh;
}
sub recorded {
    open(my $fh, '<', history(@_)) or return '';
    my $line = <$fh> // '';
    chomp $line;
    return $line;
}
# 1. A dead holder's record is not a held slot, and an empty pool admits a root
# even when the budget is smaller than its charge.
{
    my $dir = "$tmp/stale";
    make_path("$dir/slots");
    open(my $record, '>', "$dir/slots/slot.0") or die "$!";
    print {$record} "dead\t7\t999999\t5\n";
    close $record;
    my $pid = launch($gate, $dir, 'stale', {FM_LINT_HOST_SLOTS => 2, FM_LINT_HOST_RSS_KIB => 10});
    await("$dir/started.stale", 10) or do { kill 'KILL', $pid; die "a stale record blocked an empty pool\n" };
    release($dir, 'stale', $pid);
}
# 2. A held slot whose record names no charge is charged the worst case, then
# frees the moment its holder ends.
{
    my $dir = "$tmp/unknown";
    make_path("$dir/slots");
    record($dir, 'small', 100);
    open(my $holder, '>>', "$dir/slots/slot.0") or die "$!";
    flock($holder, LOCK_EX) or die "$!";
    print {$holder} "garbage without a tab\n";
    my %env = (FM_LINT_HOST_SLOTS => 2, FM_LINT_HOST_RSS_KIB => 1050, FM_LINT_INTERNAL_ROOT_CAP_KIB => 1000,
        FM_LINT_INTERNAL_ROOT_KEY => 'small');
    my $pid = launch($gate, $dir, 'unknown', \%env);
    if (await("$dir/started.unknown", 1.5)) { kill 'KILL', $pid; die "a held slot with an unknown record was charged less than the worst case\n" }
    close $holder;
    await("$dir/started.unknown", 10) or do { kill 'KILL', $pid; die "the waiter stayed queued after the unknown holder ended\n" };
    release($dir, 'unknown', $pid);
}
# 3. Three roots recorded at 100000 KiB fit a 1500000 KiB budget when the table
# can be read. With no readable process table (ps fails and no libproc helper
# sits beside the gate), every held root is charged the worst case, so the
# third waits where two fit.
for my $case (['readable', $gate, {}, 3], ['unreadable', "$tmp/lonely/fm-lint-cache.pl", {PATH => "$tmp/shim:$ENV{PATH}"}, 2]) {
    my ($label, $gate_script, $extra, $expected) = @$case;
    my $dir = "$tmp/$label";
    make_path("$dir/slots");
    record($dir, 'seeded', 100000);
    my %env = (FM_LINT_HOST_SLOTS => 9, FM_LINT_HOST_RSS_KIB => 1500000, FM_LINT_INTERNAL_ROOT_CAP_KIB => 1000000,
        FM_LINT_INTERNAL_ROOT_KEY => 'seeded', %$extra);
    my @pids = map { launch($gate_script, $dir, "n$_", \%env) } 1 .. 3;
    my $deadline = time() + 15;
    sleep 0.05 until (grep { -e "$dir/started.n$_" } 1 .. 3) >= $expected || time() > $deadline;
    sleep 1.5;
    my @started = grep { -e "$dir/started.n$_" } 1 .. 3;
    if (@started != $expected) { kill 'KILL', @pids; die "with a $label table " . scalar(@started) . " roots were admitted, expected $expected\n" }
    for my $name (1 .. 3) { open(my $fh, '>', "$dir/release.n$name") or die "$!"; close $fh; }
    for my $pid (@pids) { waitpid($pid, 0); die "a $label-table root failed: $?\n" if $?; }
    die "a queued root never ran with a $label table\n" unless 3 == grep { -e "$dir/started.n$_" } 1 .. 3;
}
# 4. A held root is charged what it holds now when that exceeds its record (the
# watch's published peak), and a root's record is raised to its measured peak
# when it ends (the watch's peak, or /usr/bin/time's maximum resident size) and
# never lowered.
{
    my $dir = "$tmp/growth";
    make_path("$dir/slots");
    record($dir, $_, 1000) for qw(holder waiter);
    my %env = (FM_LINT_HOST_SLOTS => 9, FM_LINT_HOST_RSS_KIB => 1000000, FM_LINT_INTERNAL_ROOT_CAP_KIB => 1000000);
    my $holder = launch($gate, $dir, 'holder', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'holder'}, 2000000);
    await("$dir/started.holder", 10) or do { kill 'KILL', $holder; die "the holder never started\n" };
    my $waiter = launch($gate, $dir, 'waiter', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'waiter'}, undef, 500);
    if (await("$dir/started.waiter", 1.5)) { kill 'KILL', $holder, $waiter; die "a holder past its record was charged only its record\n" }
    release($dir, 'holder', $holder);
    await("$dir/started.waiter", 10) or do { kill 'KILL', $waiter; die "the waiter stayed queued after the grown holder ended\n" };
    release($dir, 'waiter', $waiter);
    die "the watch's peak did not raise the record: " . recorded($dir, 'holder') . "\n" unless recorded($dir, 'holder') eq '2000000';
    die "a lower peak lowered the record: " . recorded($dir, 'waiter') . "\n" unless recorded($dir, 'waiter') eq '1000';
    my $lower = launch($gate, $dir, 'lower', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'holder'}, undef, 50);
    release($dir, 'lower', $lower);
    die "a lower peak lowered the record: " . recorded($dir, 'holder') . "\n" unless recorded($dir, 'holder') eq '2000000';
    my $higher = launch($gate, $dir, 'higher', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'waiter'}, undef, 3000);
    release($dir, 'higher', $higher);
    die "the maximum resident size did not raise the record: " . recorded($dir, 'waiter') . "\n" unless recorded($dir, 'waiter') eq '3000';
}
# 5. A root with no record is charged the worst case: it waits beside a small
# held root that a recorded root joins.
{
    my $dir = "$tmp/fresh";
    make_path("$dir/slots");
    record($dir, $_, 1000) for qw(holder known);
    my %env = (FM_LINT_HOST_SLOTS => 9, FM_LINT_HOST_RSS_KIB => 1000000, FM_LINT_INTERNAL_ROOT_CAP_KIB => 1000000);
    my $holder = launch($gate, $dir, 'holder', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'holder'});
    await("$dir/started.holder", 10) or do { kill 'KILL', $holder; die "the small holder never started\n" };
    my $known = launch($gate, $dir, 'known', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'known'});
    await("$dir/started.known", 10) or do { kill 'KILL', $holder, $known; die "a recorded root did not join a small held root\n" };
    my $fresh = launch($gate, $dir, 'fresh', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'fresh'});
    if (await("$dir/started.fresh", 1.5)) { kill 'KILL', $holder, $known, $fresh; die "a root with no record was charged less than the worst case\n" }
    release($dir, $_->[0], $_->[1]) for ['holder', $holder], ['known', $known];
    await("$dir/started.fresh", 10) or do { kill 'KILL', $fresh; die "the unrecorded root stayed queued in an empty pool\n" };
    release($dir, 'fresh', $fresh);
}
# 6. A gate stopped by a signal leaves no record, so the root's next request is
# still charged the worst case.
{
    my $dir = "$tmp/signalled";
    make_path("$dir/slots");
    my $pid = launch($gate, $dir, 'cut', {FM_LINT_INTERNAL_ROOT_KEY => 'cut'}, 500, 500);
    await("$dir/started.cut", 10) or do { kill 'KILL', $pid; die "the signalled root never started\n" };
    kill 'TERM', $pid;
    waitpid($pid, 0);
    die "a signalled gate exited 0\n" unless $?;
    die "a signalled analysis set a record: " . recorded($dir, 'cut') . "\n" if length recorded($dir, 'cut');
}
# 7. A held slot beyond this run's count cap still counts toward the budget.
{
    my $dir = "$tmp/beyond";
    make_path("$dir/slots");
    record($dir, 'small', 200000);
    open(my $holder, '>>', "$dir/slots/slot.5") or die "$!";
    flock($holder, LOCK_EX) or die "$!";
    print {$holder} "wide\t1\t$$\t900000\n";
    my $pid = launch($gate, $dir, 'narrow', {FM_LINT_HOST_SLOTS => 1, FM_LINT_HOST_RSS_KIB => 1000000,
        FM_LINT_INTERNAL_ROOT_KEY => 'small'});
    if (await("$dir/started.narrow", 1.5)) { kill 'KILL', $pid; die "a run with a cap of one ignored a slot held beyond its cap\n" }
    close $holder;
    await("$dir/started.narrow", 10) or do { kill 'KILL', $pid; die "the narrow run stayed queued after the wide holder ended\n" };
    release($dir, 'narrow', $pid);
}
PL
  pass "stale records are reclaimed, unknown records and an unreadable table are charged the worst case, a root with no record is charged the worst case, a root past its record is charged its current peak, records only rise and only after a complete analysis, and slots beyond a run's cap count"
}

test_fast_record_does_not_lower_the_full_charge() {
  local tmp limit record budget holder waiter starts deadline
  tmp=$(fm_test_tmproot fm-lint-memory-mode)
  mkdir -p "$tmp/bin"
  for root in a b; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$root.sh"; done
  fm_lint_write_memory_shellcheck "$tmp/bin" 1 "$tmp/mem.starts"
  limit=$((65536 * 4))
  # A --fast lint records the small peak of a.sh in fast mode only.
  CI='' GITHUB_ACTIONS='' FM_TEST_MEM_HOLD=0.1 FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_ROOT_RSS_KIB="$limit" PATH="$tmp/bin:$PATH" \
    "$LINT" --fast --jobs 1 "$tmp/a.sh" > "$tmp/fast.out" 2>&1 || fail "the fast seeding run failed"$'\n'"$(cat "$tmp/fast.out")"
  record=$(fm_lint_max_recorded_peak "$tmp/pool")
  { [ "$record" -gt 0 ] && [ $((record * 2)) -lt "$limit" ]; } \
    || fail "the fast run recorded a peak of $record KiB, expected above 0 and below half of $limit"
  # The budget fits an unrecorded holder plus a.sh at its fast record, but not
  # two unrecorded roots.
  budget=$((limit + record * 2))
  : > "$tmp/mem.starts"
  FM_TEST_MEM_HOLD=60 FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_ROOT_RSS_KIB="$limit" FM_LINT_HOST_RSS_KIB="$budget" \
    PATH="$tmp/bin:$PATH" "$LINT" --jobs 1 "$tmp/b.sh" > "$tmp/holder.out" 2>&1 &
  holder=$!
  deadline=$((SECONDS + 20))
  until [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -ge 1 ]; do
    [ "$SECONDS" -lt "$deadline" ] || { kill "$holder" 2>/dev/null; fail "the holding run never started its root"; }
    sleep 0.1
  done
  # A fast request of a.sh is charged its fast record and joins the holder.
  CI='' GITHUB_ACTIONS='' FM_TEST_MEM_HOLD=0.1 FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_ROOT_RSS_KIB="$limit" FM_LINT_HOST_RSS_KIB="$budget" \
    PATH="$tmp/bin:$PATH" "$LINT" --fast --jobs 1 "$tmp/a.sh" > "$tmp/fast2.out" 2>&1 &
  waiter=$!
  deadline=$((SECONDS + 20))
  until [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -ge 2 ]; do
    [ "$SECONDS" -lt "$deadline" ] || { kill "$holder" "$waiter" 2>/dev/null; fail "a fast request was not charged its fast record"; }
    sleep 0.1
  done
  wait "$waiter" || { kill "$holder" 2>/dev/null; fail "the fast request failed beside the holder"$'\n'"$(cat "$tmp/fast2.out")"; }
  # A full request of a.sh has no full record, so it is charged the worst case and waits.
  FM_TEST_MEM_HOLD=0.1 FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_ROOT_RSS_KIB="$limit" FM_LINT_HOST_RSS_KIB="$budget" \
    PATH="$tmp/bin:$PATH" "$LINT" --jobs 1 "$tmp/a.sh" > "$tmp/full.out" 2>&1 &
  waiter=$!
  sleep 2
  starts=$(wc -l < "$tmp/mem.starts" | tr -d ' ')
  if [ "$starts" -ne 2 ]; then
    kill "$holder" "$waiter" 2>/dev/null
    fail "a full request of a root with only a fast record started beside an unrecorded holder ($starts starts)"
  fi
  kill -TERM "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  wait "$waiter" || fail "the full request failed after the holder ended"$'\n'"$(cat "$tmp/full.out")"
  pass "a --fast record charges later fast requests only; a full request of the same root is still charged the worst case"
}

test_default_pool_is_one_directory_for_every_home() {
  local tmp pool run fixture mark
  # The real ShellCheck: its pool is always the live per-user host pool, which no
  # PATH entry, HOME or setting can change. Each run leaves a history record that
  # only its own fixture path can name, and the test removes that record.
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): default pool for every HOME"; return; }
  tmp=$(fm_test_tmproot fm-lint-default-pool)
  pool="/var/tmp/firstmate-lint-$(id -u)/lint-slots"
  for run in 1 2; do
    fixture="$tmp/run.$run.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture"
    mkdir -p "$tmp/home.$run/.cache"
    env -u FM_LINT_SLOT_DIR HOME="$tmp/home.$run" XDG_CACHE_HOME="$tmp/home.$run/.cache" FM_HOME="$tmp/fm.$run" \
      "$LINT" --jobs 1 --telemetry "$tmp/run.$run.tsv" "$fixture" >/dev/null 2>&1 \
      || fail "a lint run with the default pool failed (home $run)"
    [ ! -e "$tmp/home.$run/.cache/firstmate/lint-slots" ] || fail "run $run still used a pool under its own HOME"
    mark="$pool/history/$(perl -MDigest::SHA=sha256_hex -e 'print sha256_hex($ARGV[0])' "full:$fixture")"
    [ -s "$mark" ] || fail "run $run with its own HOME, XDG_CACHE_HOME and FM_HOME left no record in $pool"
    rm -f "$mark"
  done
  pass "runs with different HOME, XDG_CACHE_HOME and FM_HOME values record in the same per-user pool"
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
    FM_LINT_INTERNAL_SLOT_DIR => "$tmp/slots", FM_LINT_INTERNAL_NCPU => 18, FM_LINT_INTERNAL_RUN_ID => 'worker',
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
# shim logs how many processes each call listed to FM_TEST_PS_LOG; the python3 shim logs each
# call's arguments to FM_TEST_PY_LOG, fails at once under FM_TEST_PY_REFUSE=1,
# and with FM_TEST_PY_MEMORY set answers each line a mem-tree reader is sent
# with that value instead of reading memory; with FM_TEST_PY_PLAN=<file> too,
# the Nth mem-tree reader started follows line N of <file>: stall answers its
# first line 3 s late, slow answers its first line 1 s late, slow-later answers
# its second line 1 s late, exit exits before any reply, and anything else (or
# no such line) answers at once. The python3 shim names itself as the
# interpreter lint resolves for the watch's readers.
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
out=$("$FM_TEST_REAL_PS" "$@") || exit
printf '%s\n' "$out" | grep -c . >> "$FM_TEST_PS_LOG"
printf '%s\n' "$out"
SH
  } > "$1/ps"
  {
    printf '%s\n' "$guard"
    cat <<'SH'
if [ "$*" = "-c import sys; print(sys.executable)" ]; then
  printf '%s\n' "$0"
  exit 0
fi
printf '%s\n' "$*" >> "$FM_TEST_PY_LOG"
[ "${FM_TEST_PY_REFUSE:-0}" = 0 ] || exit 1
if [ -n "${FM_TEST_PY_MEMORY:-}" ] && [ "${2:-}" = mem-tree ]; then
  plan=
  [ -z "${FM_TEST_PY_PLAN:-}" ] || plan=$(sed -n "$(grep -c mem-tree "$FM_TEST_PY_LOG")p" "$FM_TEST_PY_PLAN")
  [ "$plan" != exit ] || exit 1
  line=0
  while read -r _; do
    line=$((line + 1))
    case "$plan:$line" in
      stall:1) sleep 3 ;;
      slow:1|slow-later:2) sleep 1 ;;
    esac
    printf '%s\n' "$FM_TEST_PY_MEMORY"
  done
  exit 0
fi
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
    # Harm: a runaway tree, here a shim that recurses into itself. Observable:
    # the tree's own member count. Expiry: the tree is stopped and the wrapper
    # exits 98. The ceiling of 50 is unchanged.
    err=$("$ROOT/bin/fm-proc-budget.sh" --own-procs 50 -- env -u FM_TEST_RSS_SHIM_DEPTH FM_TEST_SHIM_TRACE="$tmp/trace" \
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
  local tmp shims real_ps real_python refuse rc decoy_pid count samples
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
  # The libproc reader samples first; refusing it leaves ps as the fallback.
  for refuse in 0 1; do
    : > "$tmp/ps.log"
    : > "$tmp/py.log"
    rm -f "$tmp/rss" "$tmp/decoy.pid"
    rc=0
    fm_test_tree_leash env -u FM_TEST_RSS_SHIM_DEPTH PATH="$shims:$PATH" \
      FM_TEST_PY_REFUSE="$refuse" FM_TEST_REAL_PS="$real_ps" FM_TEST_REAL_PYTHON="$real_python" \
      FM_TEST_PS_LOG="$tmp/ps.log" FM_TEST_PY_LOG="$tmp/py.log" \
      perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 102400 "$tmp/rss" -- \
      bash "$tmp/decoy-parent.sh" "$tmp/decoy.pid" > /dev/null 2>&1 || rc=$?
    decoy_pid=$(cat "$tmp/decoy.pid" 2>/dev/null || true)
    [ -z "$decoy_pid" ] || kill -KILL "$decoy_pid" 2>/dev/null || true
    [ -n "$decoy_pid" ] || fail "the decoy did not start"
    if [ "$rc" -ne 0 ] || grep -q '^max_rss_kib=' "$tmp/rss"; then
      fail "the watch counted a process outside its command's tree (exit $rc, libproc refused=$refuse)"
    fi
    samples=$(sed -n 's/^rss_samples=//p' "$tmp/rss")
    [ "$(grep -c 'mem-tree' "$tmp/py.log")" -eq 1 ] \
      || fail "the watch did not start exactly one libproc reader"$'\n'"$(cat "$tmp/py.log")"
    if [ "$refuse" = 0 ]; then
      [ ! -s "$tmp/ps.log" ] || fail "the watch ran ps while the libproc reader answered"
      case "$samples" in libproc:[1-9]*,ps:0) ;; *) fail "the libproc samples were not recorded: $samples" ;; esac
    else
      [ -s "$tmp/ps.log" ] || fail "the watch never fell back to ps when libproc was refused"
      while read -r count; do
        [ "$count" -le 5 ] || fail "a ps sample listed $count processes, not only the watched tree"
      done < "$tmp/ps.log"
      case "$samples" in libproc:0,ps:[1-9]*) ;; *) fail "the ps fallback samples were not recorded: $samples" ;; esac
      [ "$(sed -n 's/^rss_reader_unavailable=//p' "$tmp/rss")" = exited-at-start ] \
        || fail "the refused reader was not recorded once as exited at start"$'\n'"$(cat "$tmp/rss")"
    fi
  done
  pass "the resident-memory watch samples only its command's own tree"
}

# fm_lint_footprint_lint <tmp> [<env>...]: lint <tmp>/footprint.sh, whose
# source-following run holds 8 MiB for 4 s, under the resident-watch shims and a
# process budget, with a fake reader that reports 1024 KiB resident and 204800
# KiB footprint against a 102400 KiB bound. Extra <env> assignments reach lint.
# Leaves lint's output in <tmp>/out, its status in <tmp>/rc, each attempt's
# flag in <tmp>/flags.log, reader starts in <tmp>/py.log and the roots log in
# <tmp>/pass.roots.tsv; on a host other than macOS it returns 1 untouched.
fm_lint_footprint_lint() {  # <tmp> [<env>...]
  local tmp=$1 fakebin shims real_python rc=0
  shift
  [ "$(uname)" = Darwin ] || return 1
  fakebin=$(fm_fakebin "$tmp")
  shims="$tmp/shims"
  real_python=$(command -v python3) || fail "python3 is not on PATH"
  case "$real_python" in
    "$tmp"/*|[!/]*) fail "python3 did not resolve to an absolute path outside the shims: $real_python" ;;
  esac
  mkdir -p "$shims"
  fm_lint_write_rss_shims "$shims"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/footprint.sh"
  fm_lint_write_growing_shellcheck "$fakebin"
  : > "$tmp/flags.log"
  : > "$tmp/py.log"
  fm_test_tree_leash env -u FM_TEST_RSS_SHIM_DEPTH PATH="$fakebin:$shims:$PATH" \
    FM_TEST_REAL_PS=/bin/ps FM_TEST_REAL_PYTHON="$real_python" \
    FM_TEST_PS_LOG="$tmp/ps.log" FM_TEST_PY_LOG="$tmp/py.log" FM_TEST_PY_MEMORY="1024 204800" \
    FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=0 FM_LINT_ROOT_RSS_KIB=102400 \
    FM_TEST_FLAGS_LOG="$tmp/flags.log" FM_TEST_PID_FILE="$tmp/footprint.pid" FM_TEST_GROW_STEPS=1 FM_TEST_GROW_HOLD=4 \
    "$@" "$LINT" --telemetry "$tmp/pass.tsv" "$tmp/footprint.sh" > "$tmp/out" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$tmp/rc"
}

# A reader that reports a resident size under the bound and a footprint over it
# stands for compressed pages: resident size leaves them out and jetsam counts
# them, so the root is ended and retried narrower all the same. The narrower
# retry ends before its first tick, so it starts no reader at all.
test_resident_watch_bounds_footprint_beyond_resident() {
  local tmp out roots_log rss_kib
  tmp=$(fm_test_tmproot fm-lint-rss-footprint)
  if ! fm_lint_footprint_lint "$tmp"; then
    pass "SKIP (the resident-memory watch runs only on macOS): footprint bound check"
    return
  fi
  out=$(cat "$tmp/out")
  [ "$(cat "$tmp/rc")" -eq 0 ] || fail "a root over the bound by footprint did not pass its narrower retry (exit $(cat "$tmp/rc"))"$'\n'"$out"
  [ "$(cat "$tmp/flags.log")" = "$(printf 'yes\nno')" ] \
    || fail "a root over the bound by footprint alone was not ended and retried narrower"$'\n'"$(cat "$tmp/flags.log")"
  assert_contains "$out" "hit the memory ceiling with --external-sources (reason=memory rc=98)" \
    "the footprint-bound end was not identified in the output"
  roots_log="$tmp/pass.roots.tsv"
  awk -F '\t' '$1 == "end" && $3 ~ /footprint\.sh$/ && $10 == "memory-fallback" && $16 ~ /(^|,)libproc:[1-9]/ { found=1 } END { exit !found }' \
    "$roots_log" || fail "the roots log did not mark the footprint end with its libproc samples"$'\n'"$(cat "$roots_log")"
  rss_kib=$(awk -F '\t' '$1 == "end" && $3 ~ /footprint\.sh$/ { print $11 }' "$roots_log")
  [ "$rss_kib" = 204800 ] || fail "the roots log peak $rss_kib KiB is not the 204800 KiB footprint"
  [ "$(grep -c 'mem-tree' "$tmp/py.log")" -eq 1 ] \
    || fail "a reader started for an attempt that ended before its first tick"$'\n'"$(cat "$tmp/py.log")"
  pass "a root whose footprint crosses the bound while its resident size does not is ended and retried narrower"
}

# A reader that answers one tick past the deadline costs only that tick: ps
# samples it, a new reader takes over, and the footprint it reports on the next
# tick still ends the root.
test_resident_watch_replaces_a_stalled_reader() {
  local tmp out samples
  tmp=$(fm_test_tmproot fm-lint-rss-stall)
  printf 'stall\n' > "$tmp/plan"
  if ! fm_lint_footprint_lint "$tmp" FM_TEST_PY_PLAN="$tmp/plan" FM_TEST_GROW_HOLD=6; then
    pass "SKIP (the resident-memory watch runs only on macOS): stalled reader check"
    return
  fi
  out=$(cat "$tmp/out")
  [ "$(cat "$tmp/rc")" -eq 0 ] || fail "a root over the bound after a stalled reply did not pass its narrower retry (exit $(cat "$tmp/rc"))"$'\n'"$out"
  [ "$(cat "$tmp/flags.log")" = "$(printf 'yes\nno')" ] \
    || fail "a root over the bound by footprint after one stalled reply was not ended and retried narrower"$'\n'"$(cat "$tmp/flags.log")"
  samples=$(awk -F '\t' '$1 == "end" && $3 ~ /footprint\.sh$/ { print $16 }' "$tmp/pass.roots.tsv")
  [ "$samples" = libproc:1,ps:1 ] \
    || fail "the stalled tick did not fall back to ps alone with footprint used on the next tick: $samples"
  [ "$(grep -c 'mem-tree' "$tmp/py.log")" -eq 2 ] \
    || fail "the stalled reader was not replaced exactly once"$'\n'"$(cat "$tmp/py.log")"
  pass "a reader that misses one deadline is replaced and footprint ends the root on the next tick"
}

# A reader's first reply has its own longer deadline, so a reader that starts
# slowly on a busy host still has its footprint used, with no ps fallback.
test_resident_watch_waits_for_a_slow_first_reply() {
  local tmp out samples
  tmp=$(fm_test_tmproot fm-lint-rss-slow-start)
  printf 'slow\n' > "$tmp/plan"
  if ! fm_lint_footprint_lint "$tmp" FM_TEST_PY_PLAN="$tmp/plan"; then
    pass "SKIP (the resident-memory watch runs only on macOS): slow first reply check"
    return
  fi
  out=$(cat "$tmp/out")
  [ "$(cat "$tmp/rc")" -eq 0 ] || fail "a root over the bound after a slow first reply did not pass its narrower retry (exit $(cat "$tmp/rc"))"$'\n'"$out"
  [ "$(cat "$tmp/flags.log")" = "$(printf 'yes\nno')" ] \
    || fail "a root over the bound by footprint after a slow first reply was not ended and retried narrower"$'\n'"$(cat "$tmp/flags.log")"
  samples=$(awk -F '\t' '$1 == "end" && $3 ~ /footprint\.sh$/ { print $16 }' "$tmp/pass.roots.tsv")
  [ "$samples" = libproc:1,ps:0 ] \
    || fail "a first reply 1 s late was not used as the footprint sample: $samples"
  [ "$(grep -c 'mem-tree' "$tmp/py.log")" -eq 1 ] \
    || fail "a reader whose first reply was 1 s late was replaced"$'\n'"$(cat "$tmp/py.log")"
  pass "a reader whose first reply is 1 s late keeps footprint in use"
}

# A later reply keeps the short deadline: one 1 s late costs only that tick,
# which ps samples, and a new reader answers every tick after it.
test_resident_watch_samples_a_slow_later_reply_by_ps() {
  local tmp out samples
  tmp=$(fm_test_tmproot fm-lint-rss-slow-later)
  printf 'slow-later\n' > "$tmp/plan"
  if ! fm_lint_footprint_lint "$tmp" FM_TEST_PY_PLAN="$tmp/plan" FM_TEST_PY_MEMORY="1024 2048" FM_TEST_GROW_HOLD=5; then
    pass "SKIP (the resident-memory watch runs only on macOS): slow later reply check"
    return
  fi
  out=$(cat "$tmp/out")
  [ "$(cat "$tmp/rc")" -eq 0 ] || fail "a root under the bound with one slow reply did not pass (exit $(cat "$tmp/rc"))"$'\n'"$out"
  [ "$(cat "$tmp/flags.log")" = yes ] \
    || fail "a root under the bound with one slow reply was not left to its one attempt"$'\n'"$(cat "$tmp/flags.log")"
  samples=$(awk -F '\t' '$1 == "end" && $3 ~ /footprint\.sh$/ { print $16 }' "$tmp/pass.roots.tsv")
  case "$samples" in
    libproc:[2-9],ps:1) ;;
    *) fail "a later reply 1 s late was not sampled by ps for that tick alone: $samples" ;;
  esac
  [ "$(grep -c 'mem-tree' "$tmp/py.log")" -eq 2 ] \
    || fail "the reader with a slow later reply was not replaced exactly once"$'\n'"$(cat "$tmp/py.log")"
  pass "a later reply 1 s late is sampled by ps for that tick only"
}

# A replacement reader that exits before its first reply is one failed restart,
# not a reader that exited at start: the next replacement answers and the
# footprint it reports still ends the root.
test_resident_watch_retries_a_replacement_that_exits() {
  local tmp out samples
  tmp=$(fm_test_tmproot fm-lint-rss-replacement-exit)
  printf 'stall\nexit\n' > "$tmp/plan"
  if ! fm_lint_footprint_lint "$tmp" FM_TEST_PY_PLAN="$tmp/plan" FM_TEST_GROW_HOLD=8; then
    pass "SKIP (the resident-memory watch runs only on macOS): failed replacement check"
    return
  fi
  out=$(cat "$tmp/out")
  [ "$(cat "$tmp/rc")" -eq 0 ] || fail "a root over the bound after a failed replacement did not pass its narrower retry (exit $(cat "$tmp/rc"))"$'\n'"$out"
  [ "$(cat "$tmp/flags.log")" = "$(printf 'yes\nno')" ] \
    || fail "a replacement that exited before replying gave the footprint up for the root"$'\n'"$(cat "$tmp/flags.log")"
  samples=$(awk -F '\t' '$1 == "end" && $3 ~ /footprint\.sh$/ { print $16 }' "$tmp/pass.roots.tsv")
  [ "$samples" = libproc:1,ps:2 ] \
    || fail "the failed replacement's tick did not fall back to ps alone with footprint used after it: $samples"
  [ "$(grep -c 'mem-tree' "$tmp/py.log")" -eq 3 ] \
    || fail "the failed replacement was not replaced exactly once"$'\n'"$(cat "$tmp/py.log")"
  pass "a replacement reader that exits before replying is retried and footprint still ends the root"
}

# Three failed replacements in a row give the reader up for the rest of the
# root, with that reason recorded once in the roots log.
test_resident_watch_gives_up_after_three_failed_restarts() {
  local tmp out samples
  tmp=$(fm_test_tmproot fm-lint-rss-restarts-failed)
  printf 'stall\nexit\nexit\nexit\n' > "$tmp/plan"
  if ! fm_lint_footprint_lint "$tmp" FM_TEST_PY_PLAN="$tmp/plan" FM_TEST_GROW_HOLD=9; then
    pass "SKIP (the resident-memory watch runs only on macOS): restarts-failed check"
    return
  fi
  out=$(cat "$tmp/out")
  [ "$(cat "$tmp/rc")" -eq 0 ] || fail "a root whose readers kept failing did not pass (exit $(cat "$tmp/rc"))"$'\n'"$out"
  [ "$(cat "$tmp/flags.log")" = yes ] \
    || fail "a root no reader answered for was not left to its one attempt"$'\n'"$(cat "$tmp/flags.log")"
  samples=$(awk -F '\t' '$1 == "end" && $3 ~ /footprint\.sh$/ { print $16 }' "$tmp/pass.roots.tsv")
  case "$samples" in
    libproc:0,ps:[1-9]*,reader-unavailable:restarts-failed) ;;
    *) fail "three failed replacements did not give the reader up as restarts-failed: $samples" ;;
  esac
  [ "$(grep -c 'mem-tree' "$tmp/py.log")" -eq 4 ] \
    || fail "the watch did not stop starting readers after three failed replacements"$'\n'"$(cat "$tmp/py.log")"
  pass "three failed replacement readers in a row give the reader up as restarts-failed"
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
test_slow_ps_does_not_hold_admission_against_the_next_root
test_queue_scan_survives_odd_slot_paths_and_vanishing_tickets
test_cached_success_does_not_wait_for_host_slots
test_slot_pool_cannot_be_disabled_and_refuses_bad_settings
test_slot_file_failures_refuse_and_never_run_unbounded
test_growing_roots_are_held_to_the_budget_across_pools
test_a_wrapper_around_the_real_shellcheck_shares_the_host_wide_memory_bound
test_memory_budget_bounds_the_aggregate_across_homes
test_root_larger_than_the_budget_runs_alone_and_a_killed_run_frees_its_charge
test_memory_charge_survives_unknown_records_and_an_unreadable_table
test_fast_record_does_not_lower_the_full_charge
test_default_pool_is_one_directory_for_every_home
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
test_resident_watch_bounds_footprint_beyond_resident
test_resident_watch_replaces_a_stalled_reader
test_resident_watch_waits_for_a_slow_first_reply
test_resident_watch_samples_a_slow_later_reply_by_ps
test_resident_watch_retries_a_replacement_that_exits
test_resident_watch_gives_up_after_three_failed_restarts
test_cache_key_wait_preserves_root_retry_budget
)
fm_lint_run "$@"
