#!/usr/bin/env bash
# bin/fm-lint.sh's host slots and resource bounds: deterministic job
# completion, the CPU-derived host cap, waiter and admission fairness,
# refused or failing slot state, per-root
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
# bin/fm-lint.sh holds the host-wide ShellCheck memory budget fixed and nothing
# sets it for a test. The count-cap tests below keep their roots small instead:
# an unrecorded root is charged its per-root watch bound, 256 MiB here, so
# fourteen roots fit the budget at once. A test that needs one root at a time
# sets the per-root bound itself, or seeds the pool's history with a larger
# recorded peak.
export FM_LINT_ROOT_RSS_KIB=262144
# The gate tests below start the private gate helper directly, a direct test of
# the private helper, which takes its budget and its host lock from the private
# variables that bin/fm-lint.sh would pass it. The host lock is this process's own
# (and so its ledger beside it), never the host's. bin/fm-lint.sh itself takes both
# from its own constants and ignores these variables, even for a worker started
# directly (test_a_worker_started_directly_takes_the_hosts_lock_and_budget_not_the_callers).
export FM_LINT_INTERNAL_HOST_RSS_KIB=100000000
FM_LINT_TEST_HOST_DIR=$(fm_test_tmproot fm-lint-test-host)
export FM_LINT_INTERNAL_HOST_LOCK="$FM_LINT_TEST_HOST_DIR/host.lock"

# fm_lint_gate_root <budget KiB> <pool> <run id> <root> -- <command...>: one root
# through the private gate helper, the way bin/fm-lint.sh starts it. The helper's
# budget is a private argument: bin/fm-lint.sh fixes it at its header value and no
# setting reaches it, so only a test of the helper itself passes its own. Every
# pool under one parent directory shares one admission lock, as every pool on the
# host shares the host lock.
fm_lint_gate_root() {
  local budget=$1 pool=$2 id=$3 root=$4
  shift 5
  mkdir -p "$(dirname "$pool")"
  env FM_LINT_INTERNAL_HOST_RSS_KIB="$budget" FM_LINT_INTERNAL_ROOT_KEY="full:$root" \
    FM_LINT_INTERNAL_ROOT_BYTES="$(wc -c < "$root" | tr -d ' ')" FM_LINT_INTERNAL_ROOT_CAP_KIB=262144 \
    FM_LINT_INTERNAL_HOST_LOCK="$(dirname "$pool")/host.lock" FM_LINT_HOST_SLOTS="${FM_LINT_HOST_SLOTS:-9}" \
    perl "$ROOT/bin/fm-lint-cache.pl" gate "$pool" 18 "$id" "$pool.wait.$id" -- "$@"
}

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
  baseline=$(FM_LINT_SLOT_DIR="$tmp/baseline-slots" FM_LINT_HOST_SLOTS=99 \
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
  FM_TEST_GATE_POOL_PREFIX="$tmp/" perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "slow ps admission regression failed"
use strict;
use warnings;
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($gate, $tmp) = @ARGV;
# Free count slots, but a budget that holds one root: the root after the first
# keeps its turn, and the root behind it keeps checking on that root's owner.
local $ENV{FM_LINT_HOST_SLOTS} = 4;
local $ENV{FM_LINT_INTERNAL_HOST_RSS_KIB} = 1000000;
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

# fm_lint_native_version_stub <fakebin> <starts log> <version>: a native ShellCheck
# stand-in (a compiled program, because a script is a wrapper and is probed every
# run) that logs its arguments, answers --version (after 0.15 s) and exits 0 for
# everything else, after FM_TEST_ANALYSIS_SECS seconds when that is set.
# Returns 1 when the host has no C compiler.
fm_lint_native_version_stub() {
  local fakebin=$1 log=$2 version=$3 src
  command -v cc >/dev/null 2>&1 || return 1
  src="$fakebin/stub.c"
  cat > "$src" <<C
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  FILE *f = fopen("$log", "a");
  if (f) { for (int i = 1; i < argc; i++) fprintf(f, "%s%s", i > 1 ? " " : "", argv[i]); fprintf(f, "\n"); fclose(f); }
  if (argc > 1 && strcmp(argv[1], "--version") == 0) { usleep(150000); printf("ShellCheck - shell script analysis tool\nversion: $version\n"); return 0; }
  const char *secs = getenv("FM_TEST_ANALYSIS_SECS");
  if (secs) sleep((unsigned) atoi(secs));
  return 0;
}
C
  cc -o "$fakebin/shellcheck" "$src" 2>/dev/null || return 1
  rm -f "$src"
}

# A ShellCheck that is a script is probed every run: its version is not a
# function of its bytes, and a remembered version would let a changed delegate
# pass or fail the version policy wrongly.
test_a_wrapper_around_shellcheck_is_probed_every_run_and_its_current_version_decides() {
  local tmp repo fakebin rc out
  tmp=$(fm_test_tmproot fm-lint-wrapper-version)
  repo="$tmp/repo"
  fm_lint_small_repo "$repo"
  fakebin=$(fm_fakebin "$tmp/fake")
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\\nversion: %s\\n' "\$(cat "$tmp/delegate.version")"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  perl -pi -e "s{^HOST_POOL_ROOT=.*\$}{HOST_POOL_ROOT=$tmp/host}" "$repo/bin/fm-lint.sh"
  # The delegate reports the pinned version: strict mode accepts it.
  printf '0.11.0\n' > "$tmp/delegate.version"
  rc=0
  # FM_LINT_STRICT_VERSION=1 sets the strict version policy on every host; --strict-version
  # also refuses off macOS (exit 2) before the probe.
  ( cd "$repo" && PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_SLOT_DIR="$tmp/pool" \
      FM_LINT_STRICT_VERSION=1 "$repo/bin/fm-lint.sh" bin/consumer.sh > "$tmp/first.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] || fail "a wrapper whose delegate reports the pinned version was rejected ($rc): $(cat "$tmp/first.out")"
  # The delegate changes; the wrapper's own bytes do not. The run must see the
  # new version and refuse it under the strict policy.
  printf '0.10.0\n' > "$tmp/delegate.version"
  rc=0
  ( cd "$repo" && PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_SLOT_DIR="$tmp/pool" \
      FM_LINT_STRICT_VERSION=1 "$repo/bin/fm-lint.sh" bin/consumer.sh > "$tmp/second.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 1 ] || fail "a wrapper whose delegate changed to 0.10.0 passed the strict version policy on a remembered version ($rc): $(cat "$tmp/second.out")"
  grep -q 'found 0.10.0' "$tmp/second.out" || fail "the refusal did not name the delegate's current version: $(cat "$tmp/second.out")"
  # And back: the corrected delegate is accepted again, not rejected on the record of the bad one.
  printf '0.11.0\n' > "$tmp/delegate.version"
  rc=0
  ( cd "$repo" && PATH="$fakebin:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_SLOT_DIR="$tmp/pool" \
      FM_LINT_STRICT_VERSION=1 "$repo/bin/fm-lint.sh" bin/consumer.sh > "$tmp/third.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] || fail "a corrected delegate was rejected on a remembered version ($rc): $(cat "$tmp/third.out")"
  pass "a script ShellCheck is probed every run: a changed delegate is refused under the strict policy and a corrected one accepted, with the wrapper's bytes unchanged"
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
  # No setting changes the bound: the old name is refused by name, and a name
  # that once lowered it for tests is ignored (its run keeps the fixed budget).
  fm_lint_write_memory_shellcheck "$tmp/budget-bin" 1 "$tmp/budget.starts"
  : > "$tmp/budget.starts"
  for value in 1000000000 4096; do
    rc=0
    out=$(env FM_LINT_HOST_RSS_KIB="$value" PATH="$tmp/budget-bin:$PATH" FM_LINT_SLOT_DIR="$tmp/slots" "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "FM_LINT_HOST_RSS_KIB=$value exited $rc, expected 2"
    assert_contains "$out" "FM_LINT_HOST_RSS_KIB is not supported" "the refusal did not name the removed setting"
  done
  [ ! -s "$tmp/budget.starts" ] || fail "a refused budget setting still started ShellCheck"
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

test_host_budget_default_is_one_number_stated_by_both_docs() {
  local tmp kib bytes doc smallest_level_two_kib
  tmp=$(fm_lint_slot_fixture fm-lint-slots-budget)
  # The default is read from what the run publishes (the budget line of its
  # roots log), not from the script text, then compared with each doc.
  env PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/default-pool" \
    FM_LINT_TELEMETRY="$tmp/default.tsv" "$LINT" "$tmp/a.sh" >/dev/null 2>&1 \
    || fail "a lint run with the default budget failed"
  kib=$(awk -F '\t' '$1 == "meta" && $2 == "host_memory_budget_kib" { print $3 }' "$tmp/default.roots.tsv")
  case "$kib" in ''|*[!0-9]*) fail "the roots log did not publish the host budget: '$kib'" ;; esac
  bytes=$((kib * 1024))
  # The contract's first rule: at or below the smallest ShellCheck aggregate in the
  # pressure-level-2 readings of state/memory-readings.jsonl. 3761984 KiB is that
  # figure for the superseded 2026-11-06 window (1344 readings), kept as this check.
  # The M1 snapshot of 2026-11-15 (3207 readings) has a smaller one, 692704 KiB from
  # one ShellCheck entry; Main 1923 decided it is context, not a B input, so the
  # budget is not changed.
  smallest_level_two_kib=3761984
  [ "$kib" -le "$smallest_level_two_kib" ] \
    || fail "the default budget $kib KiB is above the smallest level-2 aggregate $smallest_level_two_kib KiB"
  for doc in docs/configuration.md docs/host-guards.md; do
    assert_contains "$(cat "$ROOT/$doc")" "$kib KiB" "$doc does not state the default budget $kib KiB"
    assert_contains "$(cat "$ROOT/$doc")" "$bytes bytes" "$doc does not state the default budget $bytes bytes"
  done
  # No name lowers it: a lowered per-root bound, a count cap and the name that
  # once lowered the budget for tests leave the published budget as it was.
  env FM_LINT_FIXTURE_HOST_RSS_KIB=4096 FM_LINT_ROOT_RSS_KIB=65536 FM_LINT_HOST_SLOTS=2 PATH="$tmp/bin:$PATH" \
    FM_LINT_SLOT_DIR="$tmp/other-pool" FM_LINT_TELEMETRY="$tmp/other.tsv" "$LINT" "$tmp/a.sh" >/dev/null 2>&1 \
    || fail "a lint run with the settings that once lowered the budget failed"
  assert_grep $'meta\thost_memory_budget_kib\t'"$kib" "$tmp/other.roots.tsv" "a setting changed the published budget"
  pass "the default host budget is one number, at or below the smallest level-2 aggregate, published by the run and stated by both docs; no setting changes it"
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
  local tmp run rc pid peak most pids budget history key bytes
  local -a all
  tmp=$(fm_test_tmproot fm-lint-growth)
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  # Each stand-in takes 4 MiB every 0.25 s for 4 s (64 MiB) after its lint run
  # admits it. Four runs from four HOME values each use their own pool directory,
  # and each pool already holds a 16 MiB record for the root measured on its
  # unchanged input (a.sh follows no file, so its input is its own size), so all
  # four are admitted at once, small, and then grow together beyond their record.
  bytes=$(wc -c < "$tmp/a.sh" | tr -d ' ')
  fm_lint_write_stepping_shellcheck "$tmp/bin" 16 4 0.25 "$tmp/growth.log"
  key=$(printf "full:%s" "$(cd -P "$tmp" && pwd -P)/a.sh" | perl -MDigest::SHA=sha256_hex -ne 'print sha256_hex($_)')
  for budget in 131072 100000000; do
    : > "$tmp/growth.log"
    pids=()
    for run in 1 2 3 4; do
      history="$tmp/pool.$budget.$run/history"
      mkdir -p "$history" "$tmp/home.$run/.cache"
      printf '16384 %s\n' "$bytes" > "$history/$key"
      FM_TEST_GATE_POOL_PREFIX="$tmp/pool.$budget." FM_TEST_GROW_AFTER=4 PATH="$tmp/bin:$PATH" \
        fm_lint_gate_root "$budget" "$tmp/pool.$budget.$run" "growth$run" "$tmp/a.sh" -- \
        "$tmp/bin/shellcheck" --norc -- "$tmp/a.sh" > "$tmp/growth.$budget.$run.out" 2>&1 &
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

# fm_lint_write_barrier_shellcheck <fakebin> <MiB> <log>: a stand-in that logs its
# start, waits until FM_TEST_BARRIER starts (its own and its peers') are logged
# or FM_TEST_BARRIER_SECS (default 30) pass, then allocates and holds <MiB>
# (FM_TEST_MEM_MIB when set) at once, so every root admitted small grows inside
# one reading of the host. Its log lines are "<start|held|end> <pid> <time>".
fm_lint_write_barrier_shellcheck() {
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
my \$log = '$3';
sub note { open(my \$fh, '>>', \$log) or die "\$!"; printf {\$fh} "%s %d %.6f\n", shift, \$\$, time(); close \$fh; }
note('start');
if (my \$peers = \$ENV{FM_TEST_BARRIER}) {
    my \$deadline = time() + (\$ENV{FM_TEST_BARRIER_SECS} // 30);
    while (time() < \$deadline) {
        open(my \$fh, '<', \$log) or last;
        my \$n = () = grep { /^start / } <\$fh>;
        close \$fh;
        last if \$n >= \$peers;
        sleep 0.05;
    }
}
my \$block = 'x' x ((\$ENV{FM_TEST_MEM_MIB} // $2) * 1048576);
note('held');
sleep \$ENV{FM_TEST_MEM_HOLD} // 2;
note('end');
exit(length(\$block) ? 0 : 1);
PL
  chmod +x "$1/shellcheck"
  fm_lint_hide_outside_shellcheck "$1"
}

# fm_lint_sample_stand_ins <marker> <out> <stop-file>: an independent sampler,
# one process table read about every 0.2 s through ps, that writes
# "<time> <KiB resident in every process whose command holds <marker>> <the
# largest single process KiB> <how many processes>" to <out> until <stop-file> exists. It reads
# nothing the gate keeps.
fm_lint_sample_stand_ins() {
  FM_TEST_INFO="$ROOT/bin/fm-proc-info.py" perl -MTime::HiRes=time,sleep -MJSON::PP -e '
    my ($marker, $out, $stop) = @ARGV;
    open(my $fh, ">", $out) or die "$!";
    select((select($fh), $| = 1)[0]);
    # Where ps is refused (a sandbox), the same census comes from the libproc
    # helper, and the stand-ins are the processes the stand-in itself logged
    # as started and not yet ended.
    my $have_ps = system("ps -o pid= -p $$ >/dev/null 2>&1") == 0;
    my $log = $ENV{FM_TEST_SAMPLER_LOG} // "";
    until (-e $stop) {
      my $t = time();
      my ($sum, $top, $count) = (0, 0, 0);
      if ($have_ps) {
        if (open(my $ps, "-|", "ps", "-axww", "-o", "pid=,rss=,command=")) {
          while (my $line = <$ps>) {
            chomp $line;
            next unless $line =~ /\A\s*[0-9]+\s+([0-9]+)\s+(.*)\z/;
            my ($rss, $command) = ($1, $2);
            next unless $command =~ /\A\S*perl\S*\s+\Q$marker\E(?:\s|\z)/;
            $sum += $rss; $top = $rss if $rss > $top; $count++;
          }
          close $ps;
        }
      } elsif (length $log && open(my $lf, "<", $log)) {
        my %live;
        while (my $line = <$lf>) {
          $live{$2} = 1 if $line =~ /\A(start) ([0-9]+) /;
          delete $live{$2} if $line =~ /\A(end) ([0-9]+) /;
        }
        close $lf;
        if (%live && open(my $census, "-|", "python3", $ENV{FM_TEST_INFO}, "memory")) {
          my $rows = eval { JSON::PP::decode_json(join "", <$census>) } || [];
          close $census;
          for my $row (@$rows) {
            next unless $live{$row->{pid}} && defined $row->{rss_bytes};
            my $rss = int($row->{rss_bytes} / 1024);
            $sum += $rss; $top = $rss if $rss > $top; $count++;
          }
        }
      }
      printf {$fh} "%.3f %d %d %d\n", $t, $sum, $top, $count;
      my $left = 0.2 - (time() - $t);
      sleep $left if $left > 0;
    }' "$1" "$2" "$3"
}

# fm_lint_over_allowance <samples> <budget KiB>: "<samples above the allowance>
# <largest total KiB> <largest single KiB> <samples>" from a sampler file; the
# allowance is the budget plus the largest single process any sample saw.
fm_lint_over_allowance() {
  BUDGET=$2 perl -ane '
    push @rows, [@F[1, 2]];
    END {
      my ($peak, $top, $above) = (0, 0, 0);
      for (@rows) { $peak = $_->[0] if $_->[0] > $peak; $top = $_->[1] if $_->[1] > $top; }
      for (@rows) { $above++ if $_->[0] > $ENV{BUDGET} + $top; }
      printf "%d %d %d %d\n", $above, $peak, $top, scalar @rows;
    }' "$1"
}

# fm_lint_barrier_growth <tmp> <label> <budget KiB> <hold s> <barrier s>: four
# roots through the private gate helper, from four pool directories (the helper
# takes its own budget argument, see fm_lint_gate_root). Each pool first holds a
# 16 MiB record for the root, then the root grows by more than 10 percent
# (comment lines appended), so the record describes an older input. The four
# gates then run it under <budget> while every stand-in waits until all four have
# started (or <barrier s> pass) and then allocates and holds 64 MiB at once.
# An independent sampler reads every stand-in during that pass. Prints
# "<samples above the allowance> <peak KiB> <largest single KiB> <samples>
# <starts> <ends>".
fm_lint_barrier_growth() {
  local tmp=$1 label=$2 budget=$3 hold=$4 barrier=$5 run rc=0 pid root sampler stop line bytes key
  local -a pids
  root="$tmp/$label.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root"
  : > "$tmp/barrier.log"
  # Each pool already holds a 16 MiB record for the root on its present input.
  bytes=$(wc -c < "$root" | tr -d ' ')
  key=$(printf 'full:%s' "$root" | perl -MDigest::SHA=sha256_hex -ne 'print sha256_hex($_)')
  for run in 1 2 3 4; do
    mkdir -p "$tmp/pool.$label.$run/history"
    printf '16384 %s\n' "$bytes" > "$tmp/pool.$label.$run/history/$key"
  done
  for line in 1 2 3 4 5 6; do printf '# comment line %s, which makes this root more than 10 percent larger\n' "$line" >> "$root"; done
  : > "$tmp/barrier.log"
  stop="$tmp/$label.stop"
  rm -f "$stop"
  FM_TEST_SAMPLER_LOG="$tmp/barrier.log" fm_lint_sample_stand_ins "$tmp/bin/shellcheck" "$tmp/$label.samples" "$stop" &
  sampler=$!
  pids=()
  for run in 1 2 3 4; do
    FM_TEST_GATE_POOL_PREFIX="$tmp/pool.$label." FM_TEST_BARRIER=4 FM_TEST_BARRIER_SECS="$barrier" \
      FM_TEST_MEM_HOLD="$hold" PATH="$tmp/bin:$PATH" \
      fm_lint_gate_root "$budget" "$tmp/pool.$label.$run" "$label$run" "$root" -- \
      "$tmp/bin/shellcheck" --norc -- "$root" > "$tmp/$label.$run.out" 2>&1 &
    pids+=("$!")
  done
  rc=0
  for pid in "${pids[@]}"; do wait "$pid" || rc=$?; done
  : > "$stop"
  wait "$sampler" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "a growing run failed under budget $budget (rc=$rc)"$'\n'"$(cat "$tmp/$label".?.out)"
  printf '%s %s %s\n' "$(fm_lint_over_allowance "$tmp/$label.samples" "$budget")" \
    "$(grep -c '^start ' "$tmp/barrier.log")" "$(grep -c '^end ' "$tmp/barrier.log")"
}

test_simultaneous_growth_after_admission_is_brought_back_within_the_allowance() {
  local tmp budget result above peak top samples starts ends control lone
  tmp=$(fm_test_tmproot fm-lint-barrier)
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/b.sh"
  fm_lint_write_barrier_shellcheck "$tmp/bin" 64 "$tmp/barrier.log"
  budget=131072
  # Four roots, each recorded at about 16 MiB on its old input (so four such
  # records fit the 128 MiB budget), are linted again after their input grew by
  # more than 10 percent, and all four then allocate and hold 64 MiB at once. No
  # polling guard can undo what they allocate inside one reading of the host, so
  # the bound must come from the charge: a record measured on another input is
  # not trusted. An independent sampler reads every stand-in about every 0.2 s,
  # and no sample may exceed the budget plus the largest single stand-in.
  result=$(fm_lint_barrier_growth "$tmp" bounded "$budget" 1.5 2)
  read -r above peak top samples starts ends <<<"$result"
  [ "$top" -gt 60000 ] || fail "the sampler saw no 64 MiB stand-in (largest $top KiB), so this test measured nothing: $result"
  { [ "$starts" -eq 4 ] && [ "$ends" -eq 4 ]; } || fail "$starts starts and $ends ends of 4 growing roots under a $budget KiB budget: $result"
  [ "$above" -eq 0 ] \
    || fail "$above of $samples samples saw four roots with stale records above the $budget KiB budget plus one root (peak $peak KiB, largest single $top KiB): $result"
  # The control: with no effective budget the same roots stack above that
  # allowance, so the check above can fail.
  control=$(fm_lint_barrier_growth "$tmp" unbounded 100000000 1.5 30)
  read -r above peak top samples starts ends <<<"$control"
  [ "$peak" -gt $((budget + top)) ] \
    || fail "four growing roots without a budget peaked at only $peak KiB, so this test cannot show a bound: $control"
  # A root larger than the whole budget still runs, alone, to its end, and is
  # never ended for a total only it holds.
  : > "$tmp/barrier.log"
  FM_TEST_BARRIER=0 FM_TEST_MEM_HOLD=3 FM_LINT_SLOT_DIR="$tmp/pool.lone" FM_LINT_HOST_SLOTS=9 \
    FM_LINT_ROOT_RSS_KIB=8388608 PATH="$tmp/bin:$PATH" \
    "$LINT" --jobs 2 "$tmp/a.sh" "$tmp/b.sh" > "$tmp/lone.out" 2>&1 \
    || fail "a root larger than the budget failed"$'\n'"$(cat "$tmp/lone.out")"
  lone="$(grep -c '^start ' "$tmp/barrier.log") $(grep -c '^end ' "$tmp/barrier.log")"
  [ "$lone" = "2 2" ] || fail "two roots each larger than the budget did not each start and finish once (starts and ends: $lone)"$'\n'"$(cat "$tmp/lone.out")"
  pass "four roots whose records describe an older input, growing together after admission, never exceed the budget plus one root at any sample (bounded: $result as samples above, peak KiB, largest KiB, samples, starts, ends; unbudgeted control: $control)"
}

# fm_lint_trusted_growth <tmp> <label> <budget KiB> <record KiB> <actual MiB> <peers> [<barrier s>]:
# four gates of one pool (the shape of the default host pool) run the same root,
# whose record in the pool names <record KiB> on its present input, so the record
# is trusted. Each stand-in waits until <peers> have started (or <barrier s>
# pass, 20 by default), holding nothing meanwhile, then allocates and
# holds <actual MiB>. An independent sampler reads every stand-in about every
# 0.2 s. Prints "<peak total KiB> <largest single KiB> <most at once> <starts>
# <ends>".
fm_lint_trusted_growth() {
  local tmp=$1 label=$2 budget=$3 record=$4 actual=$5 peers=$6 barrier=${7:-20} run rc=0 pid root sampler stop bytes key
  local -a pids
  root="$tmp/$label.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root"
  : > "$tmp/barrier.log"
  bytes=$(wc -c < "$root" | tr -d ' ')
  key=$(printf 'full:%s' "$root" | perl -MDigest::SHA=sha256_hex -ne 'print sha256_hex($_)')
  mkdir -p "$tmp/pool.$label/history"
  printf '%s %s\n' "$record" "$bytes" > "$tmp/pool.$label/history/$key"
  stop="$tmp/$label.stop"
  rm -f "$stop"
  FM_TEST_SAMPLER_LOG="$tmp/barrier.log" fm_lint_sample_stand_ins "$tmp/bin/shellcheck" "$tmp/$label.samples" "$stop" &
  sampler=$!
  pids=()
  for run in 1 2 3 4; do
    FM_TEST_GATE_POOL_PREFIX="$tmp/pool.$label" FM_TEST_BARRIER="$peers" FM_TEST_BARRIER_SECS="$barrier" \
      FM_TEST_MEM_MIB="$actual" FM_TEST_MEM_HOLD=3 PATH="$tmp/bin:$PATH" \
      fm_lint_gate_root "$budget" "$tmp/pool.$label" "$label$run" "$root" -- \
      "$tmp/bin/shellcheck" --norc -- "$root" > "$tmp/$label.$run.out" 2>&1 &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || rc=$?; done
  : > "$stop"
  wait "$sampler" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "a trusted-record run failed under budget $budget (rc=$rc)"$'\n'"$(cat "$tmp/$label".?.out)"
  printf '%s %s %s %s\n' "$(perl -ane 'push @r, [@F[1, 2, 3]]; END { my ($p, $t, $n) = (0, 0, 0); for (@r) { $p = $_->[0] if $_->[0] > $p; $t = $_->[1] if $_->[1] > $t; $n = $_->[2] if $_->[2] > $n } print "$p $t $n" }' "$tmp/$label.samples")" \
    "$(grep -c '^start ' "$tmp/barrier.log")" "$(grep -c '^end ' "$tmp/barrier.log")" ""
}

# The bound the admission really gives (the header states it): at admission the
# charges of the running roots fit the budget; later the total is at most the
# budget plus, for each running root, what it holds beyond its charge. A charge
# is the root's record times 1.10 plus 64 MiB.
test_the_stated_bound_holds_under_trusted_records_and_growth_beyond_the_charge() {
  local tmp budget record charge peak top most starts ends control_peak limit
  tmp=$(fm_test_tmproot fm-lint-stated-bound)
  mkdir -p "$tmp/bin"
  fm_lint_write_barrier_shellcheck "$tmp/bin" 64 "$tmp/barrier.log"
  budget=256000                                  # 250 MiB
  record=40960                                   # 40 MiB recorded on the present input
  charge=$(( (record * 11 + 9) / 10 + 65536 ))   # 110592 KiB = 108 MiB: two fit, three do not (a charge of the record alone, 40 MiB, would admit all four)
  # (1) Growth inside the charge (92 MiB held against a 108 MiB charge): no
  # sample may exceed the budget itself, and two roots do run at once.
  read -r peak top most starts ends _ <<<"$(fm_lint_trusted_growth "$tmp" within "$budget" "$record" 92 4 6)"
  [ "$top" -gt 90000 ] || fail "the sampler saw no 92 MiB stand-in (largest $top KiB), so this test measured nothing"
  { [ "$starts" -eq 4 ] && [ "$ends" -eq 4 ]; } || fail "$starts starts and $ends ends of 4 roots with trusted records (budget $budget KiB)"
  [ "$most" -eq 2 ] || fail "$most roots ran at once, expected the two whose charges fit the budget"
  # The invariant the stated bound rests on, and the one an over-admitting gate
  # breaks: the charges of the roots running together fit the budget.
  [ $((most * charge)) -le "$budget" ] || fail "$most roots ran at once with charges $((most * charge)) KiB, above the $budget KiB budget"
  [ "$peak" -le "$budget" ] || fail "roots growing inside their charge reached $peak KiB, above the $budget KiB budget"
  # (2) Growth beyond the charge (200 MiB held against 108 MiB): the total may
  # pass the budget by what the running roots hold beyond their charges, and no
  # more; every root still finishes.
  read -r peak top most starts ends _ <<<"$(fm_lint_trusted_growth "$tmp" beyond "$budget" "$record" 200 4 6)"
  { [ "$starts" -eq 4 ] && [ "$ends" -eq 4 ]; } || fail "$starts starts and $ends ends of 4 roots growing beyond their charge"
  [ "$most" -le 2 ] || fail "$most roots ran at once, more than the charges admit"
  [ $((most * charge)) -le "$budget" ] || fail "$most roots ran at once with charges $((most * charge)) KiB, above the $budget KiB budget"
  limit=$(( budget + most * (top - charge) ))
  [ "$peak" -le "$limit" ] || fail "roots growing beyond their charge reached $peak KiB, above the stated bound $limit KiB (budget $budget plus $most roots times ($top minus charge $charge))"
  # (3) The controls: with the admission broken (no effective budget) the same
  # four roots stack above both bounds, so each check above can fail.
  read -r control_peak top most starts ends _ <<<"$(fm_lint_trusted_growth "$tmp" unbounded 100000000 "$record" 200 4)"
  [ "$control_peak" -gt $(( budget + 2 * (top - charge) )) ] \
    || fail "four roots without a budget peaked at only $control_peak KiB, so this test cannot show the bound"
  [ $((most * charge)) -gt "$budget" ] \
    || fail "four roots without a budget ran only $most at once (charges $((most * charge)) KiB), so the charge-fit check above cannot fail"
  pass "with trusted records two roots run at once; growth inside the charge never passes the budget ($budget KiB), and growth beyond it passes by at most the running roots' excess (limit $limit KiB, peak seen $peak KiB; no budget: $control_peak KiB)"
}

# fm_lint_two_pool_growth <tmp> <label> <budget KiB>: two gates in two pools
# (one parent directory, so one host lock and one ledger). Pool A's root has no
# record, so it is charged the 256 MiB per-root worst case; it holds almost
# nothing when its turn is decided and grows to 200 MiB. Pool B's root has a
# trusted 100 MiB record (charge 174 MiB) and grows to 100 MiB. Both wait for
# each other to start (4 s at most) and then allocate at once. An independent
# sampler reads every stand-in. Prints "<peak total KiB> <most at once> <starts>
# <ends>".
fm_lint_two_pool_growth() {
  local tmp=$1 label=$2 budget=$3 rc=0 a b stop sampler bytes key pid_a pid_b
  a="$tmp/$label.a.sh"
  b="$tmp/$label.b.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$a"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$b"
  : > "$tmp/barrier.log"
  bytes=$(wc -c < "$b" | tr -d ' ')
  key=$(printf 'full:%s' "$b" | perl -MDigest::SHA=sha256_hex -ne 'print sha256_hex($_)')
  mkdir -p "$tmp/$label/poolB/history"
  printf '102400 %s\n' "$bytes" > "$tmp/$label/poolB/history/$key"
  stop="$tmp/$label.stop"
  rm -f "$stop"
  FM_TEST_SAMPLER_LOG="$tmp/barrier.log" fm_lint_sample_stand_ins "$tmp/bin/shellcheck" "$tmp/$label.samples" "$stop" &
  sampler=$!
  FM_TEST_BARRIER=2 FM_TEST_BARRIER_SECS=4 FM_TEST_MEM_MIB=200 FM_TEST_MEM_HOLD=3 PATH="$tmp/bin:$PATH" \
    fm_lint_gate_root "$budget" "$tmp/$label/poolA" "${label}a" "$a" -- "$tmp/bin/shellcheck" --norc -- "$a" > "$tmp/$label.a.out" 2>&1 &
  pid_a=$!
  sleep 0.5
  FM_TEST_BARRIER=2 FM_TEST_BARRIER_SECS=4 FM_TEST_MEM_MIB=100 FM_TEST_MEM_HOLD=3 PATH="$tmp/bin:$PATH" \
    fm_lint_gate_root "$budget" "$tmp/$label/poolB" "${label}b" "$b" -- "$tmp/bin/shellcheck" --norc -- "$b" > "$tmp/$label.b.out" 2>&1 &
  pid_b=$!
  wait "$pid_a" || rc=$?
  wait "$pid_b" || rc=$?
  : > "$stop"
  wait "$sampler" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "a two-pool run failed under budget $budget (rc=$rc)"$'\n'"$(cat "$tmp/$label".?.out)"
  printf '%s %s %s\n' "$(perl -ane 'my ($p, $n) = (0, 0); push @r, [@F[1, 3]]; END { for (@r) { $p = $_->[0] if $_->[0] > $p; $n = $_->[1] if $_->[1] > $n } print "$p $n" }' "$tmp/$label.samples")" \
    "$(grep -c '^start ' "$tmp/barrier.log")" "$(grep -c '^end ' "$tmp/barrier.log")"
}

# Two pools on one host share one ledger of charges: a root just admitted in
# pool A is charged what its record names (its worst case here), not the few MiB
# it holds when pool B decides, so pool B's root cannot share the budget with it.
test_two_pools_charge_one_host_wide_ledger_so_the_budget_holds_across_them() {
  local tmp budget peak most starts ends control_peak control_most
  tmp=$(fm_test_tmproot fm-lint-two-pools)
  mkdir -p "$tmp/bin"
  fm_lint_write_barrier_shellcheck "$tmp/bin" 64 "$tmp/barrier.log"
  budget=256000   # 250 MiB: below the 256 MiB worst case of pool A's unrecorded root
  read -r peak most starts ends <<<"$(fm_lint_two_pool_growth "$tmp" ledger "$budget")"
  { [ "$starts" -eq 2 ] && [ "$ends" -eq 2 ]; } || fail "$starts starts and $ends ends of the two roots (each must finish)"
  [ "$peak" -gt 190000 ] || fail "the sampler saw only $peak KiB, so no stand-in grew to 200 MiB and this test measured nothing"
  [ "$most" -eq 1 ] || fail "$most roots from two pools ran at once, but one is charged 256 MiB against a 250 MiB budget and must run alone"
  [ "$peak" -le "$budget" ] || fail "two pools reached $peak KiB, above the $budget KiB budget, though neither root grew beyond its charge"
  # The control: with no effective budget the same two roots run together and
  # reach the 300 MiB the budget forbids, so the checks above can fail.
  read -r control_peak control_most _ _ <<<"$(fm_lint_two_pool_growth "$tmp" unbounded 100000000)"
  [ "$control_most" -eq 2 ] && [ "$control_peak" -gt "$budget" ] \
    || fail "without a budget the two roots peaked at $control_peak KiB with $control_most at once, so this test cannot show the bound"
  pass "a root admitted in one pool is charged in every pool: two pools never run roots whose charges exceed the budget together (peak $peak KiB, $most at once; no budget: $control_peak KiB, $control_most at once)"
}

# The roots log keeps /usr/bin/time's reading of the analysis process and the
# resident-memory watch's own peak of the whole tree in two columns, so a figure
# taken from the log says which measurement it is.
test_the_roots_log_keeps_the_time_reading_and_the_watch_peak_in_separate_columns() {
  local tmp row time_rss watch_peak
  [ -x /usr/bin/time ] || { pass "SKIP (no /usr/bin/time): roots log peak columns"; return; }
  tmp=$(fm_test_tmproot fm-lint-peak-columns)
  # The worker runs under a lint run's entry (the owner stand-in), in a copy whose
  # host-wide directory is the test's own.
  local repo
  repo=$(fm_lint_isolated_copy "$tmp" peaks)
  fm_lint_write_owner_stand_in "$tmp/owner" "$repo" "$(command -v python3)"
  mkdir -p "$tmp/bin" "$tmp/w/out"
  fm_lint_write_barrier_shellcheck "$tmp/bin" 24 "$tmp/barrier.log"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/w/root.sh"
  printf '0\t%s\n' "$tmp/w/root.sh" > "$tmp/w/manifest"
  FM_TEST_RUN_MEMORY_KIB=2097152 FM_TEST_RUN_RSS_KIB=2097152 bash "$tmp/owner/fm-lint.sh" \
    env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_SLOT_DIR="$tmp/w/slots" FM_LINT_INTERNAL_NCPU=18 \
    FM_LINT_INTERNAL_RUN_ID=peaks FM_LINT_INTERNAL_ROOT_SECS=20 FM_LINT_INTERNAL_GRACE=1 \
    FM_LINT_INTERNAL_ROOTS_LOG="$tmp/roots.tsv" FM_LINT_SHELLCHECK="$tmp/bin/shellcheck" FM_TEST_MEM_HOLD=2.5 \
    PATH="$tmp/bin:$PATH" FM_TEST_GATE_POOL_PREFIX="$tmp/w" \
    bash "$repo/bin/fm-lint.sh" --internal-worker "$tmp/w/manifest" "$tmp/w/out" 0 > "$tmp/worker.out" 2>&1 \
    || fail "the worker failed: $(cat "$tmp/worker.out")"
  row=$(awk -F '\t' '$1 == "end"' "$tmp/roots.tsv")
  [ -n "$row" ] || fail "the roots log has no end row: $(cat "$tmp/roots.tsv")"
  time_rss=$(printf '%s\n' "$row" | awk -F '\t' '{ print $18 }')
  watch_peak=$(printf '%s\n' "$row" | awk -F '\t' '{ print $19 }')
  case "$time_rss" in ''|*[!0-9]*) fail "the end row has no numeric time_rss_kib field (18): '$time_rss' in: $row" ;; esac
  [ "$time_rss" -gt 20000 ] || fail "time_rss_kib $time_rss KiB is below the 24 MiB the analysis held"
  if [ "$(uname)" = Darwin ]; then
    case "$watch_peak" in ''|*[!0-9]*) fail "the end row has no numeric watch_peak_kib field (19) from the macOS watch: '$watch_peak' in: $row" ;; esac
    [ "$watch_peak" -gt 20000 ] || fail "watch_peak_kib $watch_peak KiB is below the 24 MiB the tree held"
  else
    [ "$watch_peak" = unavailable ] || fail "a host without the watch recorded a watch peak: '$watch_peak'"
  fi
  pass "the roots log keeps /usr/bin/time's reading ($time_rss KiB) and the watch's own peak ($watch_peak KiB) in separate fields"
}

test_an_unreadable_host_census_never_starts_a_root_in_any_pool() {
  local tmp run rc pid
  local -a pids
  tmp=$(fm_test_tmproot fm-lint-census)
  mkdir -p "$tmp/bin" "$tmp/deny" "$tmp/repo"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  fm_lint_write_memory_shellcheck "$tmp/bin" 48 "$tmp/mem.starts"
  # Every census route fails: ps exits 1, and the lint copy has no
  # fm-proc-info.py to fall back on. No unrelated host row is hidden: the
  # gate must not be able to see anything, in any pool.
  cp -R "$ROOT/bin" "$tmp/repo/bin"
  rm -f "$tmp/repo/bin/fm-proc-info.py"
  printf '#!/bin/sh\nexit 1\n' > "$tmp/deny/ps"
  chmod +x "$tmp/deny/ps"
  : > "$tmp/mem.starts"
  pids=()
  for run in 1 2; do
    mkdir -p "$tmp/home.$run/.cache"
    env HOME="$tmp/home.$run" XDG_CACHE_HOME="$tmp/home.$run/.cache" FM_HOME="$tmp/fm.$run" \
      FM_LINT_SLOT_DIR="$tmp/pool.$run" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=8388608 \
      FM_TEST_MEM_HOLD=4 PATH="$tmp/deny:$tmp/bin:$PATH" \
      "$tmp/repo/bin/fm-lint.sh" --jobs 1 "$tmp/a.sh" > "$tmp/deny.$run.out" 2>&1 &
    pids+=("$!")
  done
  for run in 1 2; do
    pid=${pids[$((run - 1))]}
    rc=0
    wait "$pid" || rc=$?
    [ "$rc" -ne 0 ] || fail "run $run succeeded with no readable process table"$'\n'"$(cat "$tmp/deny.$run.out")"
  done
  [ ! -s "$tmp/mem.starts" ] || fail "a root started while no process table could be read: $(cat "$tmp/mem.starts")"
  for run in 1 2; do
    grep -q 'process table' "$tmp/deny.$run.out" \
      || fail "run $run did not name the unreadable process table"$'\n'"$(cat "$tmp/deny.$run.out")"
  done
  # With the table readable again the same two runs queue behind one another
  # and both finish.
  : > "$tmp/mem.starts"
  : > "$tmp/mem.starts.spans"
  pids=()
  for run in 1 2; do
    env HOME="$tmp/home.$run" XDG_CACHE_HOME="$tmp/home.$run/.cache" FM_HOME="$tmp/fm.$run" \
      FM_LINT_SLOT_DIR="$tmp/pool.$run" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=8388608 \
      FM_TEST_MEM_HOLD=3 FM_TEST_GATE_POOL_PREFIX="$tmp/pool." PATH="$tmp/bin:$PATH" \
      "$LINT" --jobs 1 "$tmp/a.sh" > "$tmp/ok.$run.out" 2>&1 &
    pids+=("$!")
  done
  rc=0
  for pid in "${pids[@]}"; do wait "$pid" || rc=$?; done
  [ "$rc" -eq 0 ] || fail "the two runs failed once the process table was readable (rc=$rc)"$'\n'"$(cat "$tmp"/ok.?.out)"
  [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -eq 2 ] || fail "not both roots ran once the process table was readable"
  [ "$(perl -ane 'push @e, [$F[1], 1], [$F[2], -1]; END { my ($n, $m) = (0, 0); for (sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @e) { $n += $_->[1]; $m = $n if $n > $m } print "$m\n" }' "$tmp/mem.starts.spans")" -eq 1 ] \
    || fail "two roots charged above the budget, in two pools, ran at once"
  pass "with no readable process table every run in every pool refuses naming it and starts no root; with it, the two pools take turns"
}

test_a_host_that_loses_its_process_table_stops_the_run_after_one_refusal() {
  local tmp rc out run starts refusals roots
  tmp=$(fm_test_tmproot fm-lint-census-lost)
  mkdir -p "$tmp/bin" "$tmp/deny" "$tmp/repo"
  roots=()
  for run in 1 2 3 4 5 6; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/r$run.sh"
    roots+=("$tmp/r$run.sh")
  done
  fm_lint_write_memory_shellcheck "$tmp/bin" 48 "$tmp/mem.starts"
  cp -R "$ROOT/bin" "$tmp/repo/bin"
  rm -f "$tmp/repo/bin/fm-proc-info.py"
  # ps answers until the first root has started, then fails for good, and the
  # lint copy has no fm-proc-info.py: the table is readable when the run begins
  # and lost while it runs.
  cat > "$tmp/deny/ps" <<SH
#!/bin/sh
[ ! -e "$tmp/lost" ] || exit 1
exec "$FM_LINT_REAL_PS" "\$@"
SH
  chmod +x "$tmp/deny/ps"
  : > "$tmp/mem.starts"
  ( until [ -s "$tmp/mem.starts" ]; do sleep 0.1; done; : > "$tmp/lost" ) &
  rc=0
  out=$(env FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=8388608 \
    FM_TEST_MEM_HOLD=3 FM_TEST_GATE_POOL_PREFIX="$tmp/pool" PATH="$tmp/deny:$tmp/bin:$PATH" \
    "$tmp/repo/bin/fm-lint.sh" --jobs 2 "${roots[@]}" 2>&1) || rc=$?
  : > "$tmp/lost"
  [ "$rc" -ne 0 ] || fail "a run that lost its process table succeeded"$'\n'"$out"
  refusals=$(printf '%s\n' "$out" | grep -c 'host process table cannot be read' || true)
  [ "$refusals" -ge 1 ] || fail "the run did not name the lost process table"$'\n'"$out"
  [ "$refusals" -le 2 ] || fail "$refusals roots each refused for the lost process table; the workers kept scheduling roots"$'\n'"$out"
  starts=$(wc -l < "$tmp/mem.starts" | tr -d ' ')
  [ "$starts" -le 2 ] || fail "$starts of 6 roots started although the process table was lost after the first"
  pass "when the process table is lost during a run, at most one refusal per worker is printed and the other roots are never started"
}

# A run on a host whose process table cannot be read must fail once, in about 5 s,
# before it starts a root or takes a place in the shared queue, and another run in
# the same pool that can read the table must not wait for it.
test_an_unreadable_census_fails_one_run_once_and_does_not_delay_another_in_the_pool() {
  local tmp rc out run base t0 t1 deny_secs ok_secs alone_secs refusals roots pid_deny pid_ok
  tmp=$(fm_test_tmproot fm-lint-census-once)
  mkdir -p "$tmp/bin.deny" "$tmp/bin.ok" "$tmp/deny" "$tmp/repo"
  roots=()
  for run in 1 2 3 4 5 6; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/r$run.sh"
    roots+=("$tmp/r$run.sh")
  done
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/ok.sh"
  fm_lint_write_memory_shellcheck "$tmp/bin.deny" 48 "$tmp/deny.starts"
  fm_lint_write_memory_shellcheck "$tmp/bin.ok" 48 "$tmp/ok.starts"
  cp -R "$ROOT/bin" "$tmp/repo/bin"
  rm -f "$tmp/repo/bin/fm-proc-info.py"
  printf '#!/bin/sh\nexit 1\n' > "$tmp/deny/ps"
  chmod +x "$tmp/deny/ps"
  now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
  : > "$tmp/deny.starts"; : > "$tmp/ok.starts"
  # The reference: the readable run alone in its own pool.
  t0=$(now)
  env FM_LINT_SLOT_DIR="$tmp/pool.alone" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=8388608 \
    FM_TEST_MEM_HOLD=1 PATH="$tmp/bin.ok:$PATH" "$LINT" --jobs 1 "$tmp/ok.sh" > "$tmp/alone.out" 2>&1 \
    || fail "the readable run failed alone"$'\n'"$(cat "$tmp/alone.out")"
  t1=$(now)
  alone_secs=$(perl -e "printf '%.3f', $t1 - $t0")
  : > "$tmp/ok.starts"
  # Both runs share one pool. The unreadable run has six roots and two workers.
  t0=$(now)
  env FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=8388608 \
    FM_TEST_MEM_HOLD=1 PATH="$tmp/deny:$tmp/bin.deny:$PATH" \
    "$tmp/repo/bin/fm-lint.sh" --jobs 2 "${roots[@]}" > "$tmp/deny.out" 2>&1 &
  pid_deny=$!
  sleep 0.3
  env FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=8388608 \
    FM_TEST_MEM_HOLD=1 PATH="$tmp/bin.ok:$PATH" "$LINT" --jobs 1 "$tmp/ok.sh" > "$tmp/ok.out" 2>&1 &
  pid_ok=$!
  rc=0; wait "$pid_ok" || rc=$?
  t1=$(now)
  ok_secs=$(perl -e "printf '%.3f', $t1 - $t0")
  [ "$rc" -eq 0 ] || fail "the readable run sharing the pool failed (rc=$rc)"$'\n'"$(cat "$tmp/ok.out")"
  rc=0; wait "$pid_deny" || rc=$?
  t1=$(now)
  deny_secs=$(perl -e "printf '%.3f', $t1 - $t0")
  [ "$rc" -eq 2 ] || fail "the unreadable run exited $rc, not 2"$'\n'"$(cat "$tmp/deny.out")"
  refusals=$(grep -c 'host process table cannot be read' "$tmp/deny.out" || true)
  [ "$refusals" -eq 1 ] || fail "the unreadable run printed $refusals refusals, not one"$'\n'"$(cat "$tmp/deny.out")"
  [ ! -s "$tmp/deny.starts" ] || fail "a root started on the unreadable run: $(cat "$tmp/deny.starts")"
  perl -e 'exit(($ARGV[0] >= 4.5 && $ARGV[0] <= 12) ? 0 : 1)' "$deny_secs" \
    || fail "the unreadable run took $deny_secs s, not about 5 s (six roots at 5 s each would be 30 s)"
  perl -e 'exit(($ARGV[0] <= $ARGV[1] + 3) ? 0 : 1)' "$ok_secs" "$alone_secs" \
    || fail "the readable run took $ok_secs s beside the unreadable run, against $alone_secs s alone"
  [ "$(wc -l < "$tmp/ok.starts" | tr -d ' ')" -eq 1 ] || fail "the readable run did not start its root once"
  pass "an unreadable process table fails one run once in $deny_secs s with no root started, and a readable run in the same pool took $ok_secs s ($alone_secs s alone)"
}

# fm_lint_max_overlap <spans file>: the most stand-in analyses (lines of
# "<pid> <start> <end>") that held their memory at the same moment.
fm_lint_max_overlap() {
  perl -ane 'push @e, [$F[1], 1], [$F[2], -1]; END { my ($n, $m) = (0, 0); for (sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @e) { $n += $_->[1]; $m = $n if $n > $m } print "$m\n" }' "$1"
}

test_every_mode_takes_its_budget_from_the_same_host_wide_bound() {
  local tmp repo mode holder pid rc queued starts elapsed started_at
  local -a modes
  tmp=$(fm_test_tmproot fm-lint-modes)
  # Every run below uses one copy of the lint whose host-wide directory is the
  # test's own, so the holder's charge never reaches the host's real ledger.
  repo=$(fm_lint_isolated_copy "$tmp" modes)
  mkdir -p "$tmp/bin" "$tmp/retry-bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/b.sh"
  fm_lint_write_memory_shellcheck "$tmp/bin" 48 "$tmp/mem.starts"
  # A ShellCheck that dies of heap exhaustion while it follows sources, so the
  # run takes the memory retry, and otherwise is the stand-in analysis.
  cat > "$tmp/retry-bin/shellcheck" <<SH
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = --external-sources ]; then echo 'shellcheck: Heap exhausted;' >&2; exit 251; fi
done
exec "$tmp/bin/shellcheck" "\$@"
SH
  chmod +x "$tmp/retry-bin/shellcheck"
  cp "$tmp/bin/ps" "$tmp/retry-bin/ps"
  modes=(explicit fast partition retry)
  fm_lint_bounds_supported && modes+=(ci-bounds)
  # Every mode runs while another run, in the same pool, holds more than the
  # whole budget (its root is charged 8 GiB, the per-root watch bound). Each mode's first root must wait for
  # it (its queue time, taken from the roots log, is at least a second), and no
  # two stand-in analyses may hold their memory at once.
  for mode in "${modes[@]}"; do
    : > "$tmp/mem.starts"
    : > "$tmp/mem.starts.spans"
    mkdir -p "$tmp/home.$mode/.cache" "$tmp/home.holder.$mode/.cache"
    env HOME="$tmp/home.holder.$mode" XDG_CACHE_HOME="$tmp/home.holder.$mode/.cache" FM_HOME="$tmp/fm.holder.$mode" \
      FM_LINT_SLOT_DIR="$tmp/pool.$mode" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=8388608 \
      FM_TEST_MEM_HOLD=7 FM_TEST_GATE_POOL_PREFIX="$tmp/pool." PATH="$tmp/bin:$PATH" \
      "$repo/bin/fm-lint.sh" --jobs 1 "$tmp/a.sh" > "$tmp/holder.$mode.out" 2>&1 &
    holder=$!
    local deadline=$((SECONDS + 120))
    while [ ! -s "$tmp/mem.starts" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
    [ -s "$tmp/mem.starts" ] || fail "the run that holds the budget never started ($mode)"
    case "$mode" in
      explicit) set -- --jobs 1 "$tmp/b.sh" ;;
      fast) set -- --fast "$tmp/b.sh" ;;
      partition) set -- --partition 1of3 ;;
      retry) set -- "$tmp/b.sh" ;;
      ci-bounds) set -- "$tmp/b.sh" ;;
    esac
    local bin=$tmp/bin lint=$repo/bin/fm-lint.sh require=0 ci=${CI:-} gha=${GITHUB_ACTIONS:-}
    # --fast is local-only (CI refuses it), so that leg runs as a local run.
    [ "$mode" != fast ] || { ci=; gha=; }
    [ "$mode" != retry ] || bin=$tmp/retry-bin
    [ "$mode" != ci-bounds ] || require=1
    rc=0
    started_at=$SECONDS
    env HOME="$tmp/home.$mode" XDG_CACHE_HOME="$tmp/home.$mode/.cache" FM_HOME="$tmp/fm.$mode" \
      FM_LINT_SLOT_DIR="$tmp/pool.$mode" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=8388608 \
      FM_LINT_ROOT_MEMORY_KIB=33554432 FM_LINT_REQUIRE_BOUNDS="$require" FM_LINT_TELEMETRY="$tmp/$mode.tsv" \
      FM_TEST_MEM_HOLD=0.3 FM_TEST_GATE_POOL_PREFIX="$tmp/pool." PATH="$bin:$PATH" CI="$ci" GITHUB_ACTIONS="$gha" \
      "$lint" "$@" > "$tmp/$mode.out" 2>&1 || rc=$?
    wait "$holder" || fail "the run that holds the budget failed ($mode)"
    [ "$rc" -eq 0 ] || fail "the $mode run failed behind a run that holds the budget (rc=$rc)"$'\n'"$(cat "$tmp/$mode.out")"
    queued=$(awk -F '\t' '$1 == "end" { if ($17 + 0 > m) m = $17 + 0 } END { print m + 0 }' "$tmp/$mode.roots.tsv")
    elapsed=$((SECONDS - started_at))
    # The wait is a root's recorded queue time in the admission (the roots log's
    # wait_ms); the version probe has its own lane and never waits for the budget,
    # so elapsed time is not evidence of an admission wait.
    [ "$queued" -ge 1000 ] \
      || fail "$mode: no root recorded a wait for the budget that another run held (longest root queue $queued ms, run took $elapsed s)"$'\n'"$(cat "$tmp/$mode.roots.tsv")"
    [ "$(fm_lint_max_overlap "$tmp/mem.starts.spans")" -eq 1 ] \
      || fail "$mode: two stand-in analyses held their memory at once behind a charge above the budget"$'\n'"$(cat "$tmp/mem.starts.spans")"
  done
  pass "the explicit-path, --fast, --partition, memory-retry, and ${modes[4]:+CI-bounds }mode runs each wait behind a run that holds the host-wide budget, and never hold memory beside it"
}

test_the_roots_log_records_each_roots_queue_wait_in_wait_ms() {
  local tmp holder deadline waited gap
  tmp=$(fm_test_tmproot fm-lint-wait-ms)
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/b.sh"
  fm_lint_write_memory_shellcheck "$tmp/bin" 8 "$tmp/mem.starts"
  # A lone run's root does not wait: the last column of its end row is 0.
  FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_ROOT_RSS_KIB=8388608 FM_TEST_MEM_HOLD=0.2 FM_TEST_GATE_POOL_PREFIX="$tmp/pool" \
    FM_LINT_TELEMETRY="$tmp/lone.tsv" PATH="$tmp/bin:$PATH" "$LINT" --jobs 1 "$tmp/a.sh" > "$tmp/lone.out" 2>&1 \
    || fail "the lone run failed"$'\n'"$(cat "$tmp/lone.out")"
  waited=$(awk -F '\t' '$1 == "end" { print $17 }' "$tmp/lone.roots.tsv")
  [ "$waited" = 0 ] || fail "a root that did not wait recorded wait_ms '$waited', expected 0"$'\n'"$(cat "$tmp/lone.roots.tsv")"
  # A second run's root waits behind a holder charged above the whole budget:
  # its wait is recorded, not derived, and agrees with its start, end and duration.
  : > "$tmp/mem.starts"
  FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_ROOT_RSS_KIB=8388608 FM_TEST_MEM_HOLD=4 FM_TEST_GATE_POOL_PREFIX="$tmp/pool" \
    PATH="$tmp/bin:$PATH" "$LINT" --jobs 1 "$tmp/a.sh" > "$tmp/holder.out" 2>&1 &
  holder=$!
  deadline=$((SECONDS + 60))
  until [ -s "$tmp/mem.starts" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { kill "$holder" 2>/dev/null; fail "the holding run never started its root"; }
    sleep 0.1
  done
  FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_ROOT_RSS_KIB=8388608 FM_TEST_MEM_HOLD=0.2 FM_TEST_GATE_POOL_PREFIX="$tmp/pool" \
    FM_LINT_TELEMETRY="$tmp/wait.tsv" PATH="$tmp/bin:$PATH" "$LINT" --jobs 1 "$tmp/b.sh" > "$tmp/wait.out" 2>&1 \
    || { kill "$holder" 2>/dev/null; fail "the waiting run failed"$'\n'"$(cat "$tmp/wait.out")"; }
  wait "$holder" || fail "the holding run failed"$'\n'"$(cat "$tmp/holder.out")"
  waited=$(awk -F '\t' '$1 == "end" { print $17 }' "$tmp/wait.roots.tsv")
  case "$waited" in ''|*[!0-9]*) fail "the waiting root recorded no numeric wait_ms: '$waited'" ;; esac
  [ "$waited" -ge 1000 ] || fail "a root that queued behind a holder recorded wait_ms $waited, expected at least 1000"$'\n'"$(cat "$tmp/wait.roots.tsv")"
  gap=$(awk -F '\t' '$1 == "end" { print $7 - $6 - $8 - $17 }' "$tmp/wait.roots.tsv")
  [ "$gap" = 0 ] || fail "wait_ms disagrees with end minus start minus duration by $gap ms"$'\n'"$(cat "$tmp/wait.roots.tsv")"
  pass "the roots log records each root's queue wait in wait_ms: 0 for a root that did not wait, the queue time for one that did"
}

test_a_second_run_finds_the_budget_restored_and_repeats_the_first() {
  local tmp run rc out first first_rc second second_rc
  tmp=$(fm_test_tmproot fm-lint-second-run)
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/b.sh"
  fm_lint_write_memory_shellcheck "$tmp/bin" 48 "$tmp/mem.starts"
  for run in first second; do
    : > "$tmp/mem.starts"
    : > "$tmp/mem.starts.spans"
    # Where /usr/bin/time runs, the first run leaves each root a memory record that
    # lowers its charge in the second; this test is about the slots and tickets a
    # run leaves, so both runs start without records and charge each root the
    # worst case, above the budget.
    rm -rf "$tmp/pool/history"
    rc=0
    out=$(env FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=8388608 \
      FM_TEST_MEM_HOLD=0.5 FM_TEST_GATE_POOL_PREFIX="$tmp/pool" PATH="$tmp/bin:$PATH" \
      "$LINT" --jobs 2 "$tmp/a.sh" "$tmp/b.sh" 2>&1) || rc=$?
    [ "$(fm_lint_max_overlap "$tmp/mem.starts.spans")" -eq 1 ] || fail "the $run run held two roots at once, each charged above the budget"
    # The reservation record: no slot is held and no ticket waits.
    perl - "$tmp/pool" <<'PL' || fail "after the $run run the pool still shows a held slot or a waiting ticket"
use strict;
use warnings;
use Fcntl qw(:flock);
my $dir = shift;
opendir(my $d, $dir) or die "$dir: $!";
for my $name (readdir $d) {
    die "ticket $name remains\n" if $name =~ /\Aqueue\.[0-9]{20}\./;
    next unless $name =~ /\Aslot\.[0-9]+\z/;
    open(my $fh, '>>', "$dir/$name") or die "$name: $!";
    flock($fh, LOCK_EX | LOCK_NB) or die "$name is still held\n";
}
PL
    if [ "$run" = first ]; then first=$out; first_rc=$rc; else second=$out; second_rc=$rc; fi
  done
  [ "$first_rc" -eq "$second_rc" ] && [ "$first" = "$second" ] \
    || fail "the second run differs from the first (rc $first_rc/$second_rc)"$'\n'"$first"$'\n'"---"$'\n'"$second"
  pass "after a normal run the pool holds nothing, and a second run in the same environment stays inside the budget with the first run's exit status and diagnostics"
}

# fm_lint_child_of <parent-pid> <text>: the pid of a direct child of <parent-pid>
# whose command holds <text>, waiting up to 10 s.
fm_lint_child_of() {
  local deadline=$((SECONDS + 10)) pid
  while [ "$SECONDS" -lt "$deadline" ]; do
    pid=$(ps -axo pid=,ppid=,command= | awk -v parent="$1" -v want="$2" '$2 == parent && index($0, want) { print $1; exit }')
    [ -n "$pid" ] && { printf '%s\n' "$pid"; return 0; }
    sleep 0.1
  done
  return 1
}

# fm_lint_kill_tree <pid>...: ends each process this test started, and its children.
fm_lint_kill_tree() {
  local pid
  for pid in "$@"; do
    pkill -KILL -P "$pid" 2>/dev/null
    kill -KILL "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  done
  return 0
}

# fm_lint_write_table_filter <dir>: an fm-proc-info.py for a gate copied into
# <dir> whose ps is refused, so the gate reads the host through this helper. It
# calls the real helper (FM_TEST_REAL_HELPER) and keeps only this fixture's gates
# (FM_TEST_POOL_ROOT) and no process named shellcheck, as the ps shim does. The
# table row whose command holds FM_TEST_HIDDEN_MATCH takes FM_TEST_HIDDEN_FORM:
# drop removes it, so the census gives that process only its bare name, parent
# gives it its parent's command, and any other value is its command.
fm_lint_write_table_filter() {
  cat > "$1/fm-proc-info.py" <<'PY'
import json
import os
import subprocess
import sys

env = os.environ
output = subprocess.run([sys.executable, env["FM_TEST_REAL_HELPER"]] + sys.argv[1:],
                        stdout=subprocess.PIPE, text=True).stdout
if sys.argv[1] == "memory":
    print(json.dumps([row for row in json.loads(output) if row.get("comm") != "shellcheck"]))
    sys.exit(0)
rows = [line.split(None, 2) for line in output.splitlines()]
commands = {row[0]: row[2] for row in rows if len(row) == 3}
for row in rows:
    if len(row) != 3:
        continue
    pid, ppid, command = row
    if "fm-lint-cache.pl gate" in command and env["FM_TEST_POOL_ROOT"] not in command:
        continue
    if env["FM_TEST_HIDDEN_MATCH"] in command:
        form = env["FM_TEST_HIDDEN_FORM"]
        if form == "drop":
            continue
        command = commands.get(ppid, "") if form == "parent" else form
    print(pid, ppid, command)
PY
}

test_a_waiting_gate_reading_the_table_never_stops_a_younger_running_root() {
  local tmp waiter runner deadline helper form index=0 held hold
  local -a forms=(ps)
  command -v python3 >/dev/null 2>&1 || { pass "SKIP (python3 not resolved): a waiting gate's table read"; return; }
  tmp=$(fm_test_tmproot fm-lint-waiting-reader)
  mkdir -p "$tmp/refuse" "$tmp/hide" "$tmp/waiter" "$tmp/watcher"
  printf '#!/bin/sh\nexit 1\n' > "$tmp/refuse/ps"
  chmod +x "$tmp/refuse/ps"
  cp "$ROOT/bin/fm-lint-cache.pl" "$tmp/waiter/fm-lint-cache.pl"
  cp "$ROOT/bin/fm-lint-cache.pl" "$tmp/watcher/fm-lint-cache.pl"
  printf 'import time\ntime.sleep(600)\n' > "$tmp/waiter/fm-proc-info.py"
  fm_lint_write_table_filter "$tmp/watcher"
  fm_lint_hide_outside_shellcheck "$tmp/hide"
  # The older gate's turn reads the process table through the helper beside it,
  # because ps is refused, and that helper does not answer, so the gate waits
  # with that one child.
  PATH="$tmp/refuse:$PATH" FM_LINT_INTERNAL_HOST_RSS_KIB=1000000 \
    perl "$tmp/waiter/fm-lint-cache.pl" gate "$tmp/waiting-pool" 2 waiting "$tmp/waiting.wait" -- true &
  waiter=$!
  helper=$(fm_lint_child_of "$waiter" "$tmp/waiter/fm-proc-info.py table") \
    || { fm_lint_kill_tree "$waiter"; fail "the waiting gate never started its table read"; }
  sleep 1.2
  # A younger gate sees that helper in each form a process table can show it: its
  # full command from ps; and, where a gate with ps refused reads libproc, its bare
  # name, a parenthesized name, a zombie row or, before its exec, the gate's own
  # command. Its root of 80 MiB is over its 40000 KiB budget, and only a gate that
  # is not the oldest running gate holds its own root (it writes <peak file>.hold,
  # which the root's resident watch acts on), so that root must never be held.
  [ "$(uname)" != Darwin ] || forms+=(drop '(ps)' '<defunct>' '[ps] <defunct>' parent /usr/bin/true)
  for form in "${forms[@]}"; do
    index=$((index + 1))
    hold=3
    [ "$form" != /usr/bin/true ] || hold=60
    if [ "$form" = ps ]; then
      PATH="$tmp/hide:$PATH" FM_TEST_GATE_POOL_PREFIX="$tmp/" FM_LINT_INTERNAL_HOST_RSS_KIB=40000 FM_LINT_INTERNAL_ROOT_CAP_KIB=1024 \
        perl "$ROOT/bin/fm-lint-cache.pl" gate "$tmp/running-pool.$index" 2 running "$tmp/running.$index.wait" -- \
        perl -e '$x = "x" x (80 * 1048576); select(undef, undef, undef, $ARGV[0]); open(my $end, ">", $ARGV[1]); exit 0' "$hold" "$tmp/ended.$index" &
    else
      PATH="$tmp/refuse:$PATH" FM_LINT_INTERNAL_HOST_RSS_KIB=40000 FM_LINT_INTERNAL_ROOT_CAP_KIB=1024 \
        FM_TEST_REAL_HELPER="$ROOT/bin/fm-proc-info.py" FM_TEST_POOL_ROOT="$tmp/" \
        FM_TEST_HIDDEN_MATCH="$tmp/waiter/fm-proc-info.py table" FM_TEST_HIDDEN_FORM="$form" \
        perl "$tmp/watcher/fm-lint-cache.pl" gate "$tmp/running-pool.$index" 2 running "$tmp/running.$index.wait" -- \
        perl -e '$x = "x" x (80 * 1048576); select(undef, undef, undef, $ARGV[0]); open(my $end, ">", $ARGV[1]); exit 0' "$hold" "$tmp/ended.$index" &
    fi
    runner=$!
    if [ "$form" = /usr/bin/true ]; then
      # The control: the same reading, with the helper's row a started command,
      # names the waiting gate the oldest, so this root is held. Without this
      # hold, the passes above could come from a reading that never worked. This
      # root outlives the slowest reading and ends as soon as the hold is seen.
      held=0
      deadline=$((SECONDS + 45))
      while [ "$SECONDS" -lt "$deadline" ]; do
        if compgen -G "$tmp/running-pool.$index/slot.*.peak.hold" > /dev/null; then held=1; break; fi
        sleep 0.1
      done
      fm_lint_kill_tree "$runner"
      [ "$held" -eq 1 ] || { fm_lint_kill_tree "$waiter"; fail "a root under an older running gate was not held, so this test proved nothing"; }
      continue
    fi
    held=0
    deadline=$((SECONDS + 45))
    while [ ! -e "$tmp/ended.$index" ] && [ "$SECONDS" -lt "$deadline" ]; do
      if compgen -G "$tmp/running-pool.$index/slot.*.peak.hold" > /dev/null; then held=1; fi
      sleep 0.2
    done
    fm_lint_kill_tree "$runner"
    [ -e "$tmp/ended.$index" ] || { fm_lint_kill_tree "$waiter"; fail "a younger root over the budget did not finish while an older gate only waited on its table read (table form: $form)"; }
    [ "$held" -eq 0 ] || { fm_lint_kill_tree "$waiter"; fail "a younger root over the budget was held while an older gate only waited on its table read (table form: $form)"; }
    kill -0 "$helper" 2>/dev/null || fail "the older gate's table read ended before the younger root (table form: $form), so this test proved nothing"
  done
  fm_lint_kill_tree "$waiter"
  pass "a waiting gate whose only child is its own table read is not the oldest running gate in any form a table shows it (${forms[*]})"
}

# (RV-4) A queue head that waits on a full budget reads the process table at most
# every 0.5 s: a holder root fills the budget for 6 s, the waiter's reads are
# counted through a ps stub over 4 s, and the waiter runs once the holder ends.
test_the_queue_head_reads_the_process_table_at_most_twice_a_second() {
  local tmp reads before count holder waiter code
  tmp=$(fm_test_tmproot fm-lint-table-rate)
  mkdir -p "$tmp/ps"
  reads="$tmp/reads.log"
  : > "$reads"
  cat > "$tmp/ps/ps" <<'SH'
#!/bin/sh
if [ "$*" = '-axww -o pid=,ppid=,rss=,lstart=,command=' ]; then
  printf 'read\n' >> "$FM_TEST_READS"
  printf '%s 1 0 %s perl fm-lint-cache.pl gate %s 2 %s\n' "$PPID" "$(date '+%a %b %e %H:%M:%S %Y')" "$FM_TEST_POOL" "$FM_TEST_NAME"
  exit 0
fi
exit 1
SH
  chmod +x "$tmp/ps/ps"
  PATH="$tmp/ps:$PATH" FM_TEST_READS="$reads" FM_TEST_POOL="$tmp/pool" FM_TEST_NAME=holder \
    FM_LINT_INTERNAL_HOST_LOCK="$tmp/host.lock" FM_LINT_INTERNAL_HOST_RSS_KIB=1000 FM_LINT_INTERNAL_ROOT_CAP_KIB=900 \
    perl "$ROOT/bin/fm-lint-cache.pl" gate "$tmp/pool" 2 holder "$tmp/holder.wait" -- sleep 6 &
  holder=$!
  sleep 1
  PATH="$tmp/ps:$PATH" FM_TEST_READS="$reads" FM_TEST_POOL="$tmp/pool" FM_TEST_NAME=waiter \
    FM_LINT_INTERNAL_HOST_LOCK="$tmp/host.lock" FM_LINT_INTERNAL_HOST_RSS_KIB=1000 FM_LINT_INTERNAL_ROOT_CAP_KIB=900 \
    perl "$ROOT/bin/fm-lint-cache.pl" gate "$tmp/pool" 2 waiter "$tmp/waiter.wait" -- true &
  waiter=$!
  sleep 0.5
  before=$(wc -l < "$reads" | tr -d ' ')
  sleep 4
  count=$(( $(wc -l < "$reads" | tr -d ' ') - before ))
  code=0
  wait "$waiter" || code=$?
  wait "$holder" || fail "the holder root did not end cleanly"
  [ "$count" -ge 2 ] || fail "the waiting queue head read the process table $count times in 4 s, so it did not keep its reading current"
  [ "$count" -le 20 ] || fail "the waiting queue head read the process table $count times in 4 s, more than 5 times a second"
  [ "$code" -eq 0 ] || fail "the waiter did not run once the budget was free (exit $code)"
  pass "a queue head waiting on a full budget read the process table $count times in 4 s (at most 0.5 s apart) and ran once the budget was free"
}

test_growth_guard_never_stops_the_watch_reader() {
  local tmp py older younger deadline settle rows watch reader standin form
  local reader_seen reader_large reader_stopped standin_stopped
  [ "$(uname)" = Darwin ] || { pass "SKIP (not macOS): the resident watch's reader runs only on macOS"; return; }
  py=$(python3 -c 'import os, sys; print(os.path.realpath(sys.executable))' 2>/dev/null) \
    || { pass "SKIP (python3 not resolved): the resident watch's reader"; return; }
  tmp=$(fm_test_tmproot fm-lint-guard-reader)
  mkdir -p "$tmp/MacOS" "$tmp/hide" "$tmp/refuse" "$tmp/watcher"
  printf '#!/bin/sh\nexit 1\n' > "$tmp/refuse/ps"
  chmod +x "$tmp/refuse/ps"
  # In the full form the reader runs under an interpreter named Python, as the
  # Command Line Tools and python.org installs show it.
  ln -s "$py" "$tmp/MacOS/Python"
  cp "$ROOT/bin/fm-lint-cache.pl" "$tmp/watcher/fm-lint-cache.pl"
  fm_lint_write_table_filter "$tmp/watcher"
  fm_lint_hide_outside_shellcheck "$tmp/hide"
  PATH="$tmp/hide:$PATH" FM_TEST_GATE_POOL_PREFIX="$tmp/" FM_LINT_INTERNAL_HOST_RSS_KIB=1000000000 \
    perl "$ROOT/bin/fm-lint-cache.pl" gate "$tmp/older-pool" 2 older "$tmp/older.wait" -- perl -e 'sleep 120' &
  older=$!
  fm_lint_child_of "$older" "sleep 120" > /dev/null || { fm_lint_kill_tree "$older"; fail "the older gate never started its root"; }
  sleep 1.2
  # A younger gate is not the oldest and its watched root of 80 MiB is over its
  # 40000 KiB budget, so its guard stops that root. It must never stop the watch's
  # own reader, whether its table shows the reader's full command (from ps) or,
  # with ps refused, only its bare name (from libproc).
  for form in full bare; do
    if [ "$form" = full ]; then
      PATH="$tmp/hide:$PATH" FM_TEST_GATE_POOL_PREFIX="$tmp/" FM_LINT_INTERNAL_HOST_RSS_KIB=40000 FM_LINT_INTERNAL_ROOT_CAP_KIB=1024 \
        FM_LINT_INTERNAL_PYTHON="$tmp/MacOS/Python" \
        perl "$ROOT/bin/fm-lint-cache.pl" gate "$tmp/younger-pool.$form" 2 younger "$tmp/younger.$form.wait" -- \
        perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 8388608 "$tmp/rss.$form" -- \
        perl -e '$x = "x" x (80 * 1048576); sleep 60' &
    else
      PATH="$tmp/refuse:$PATH" FM_LINT_INTERNAL_HOST_RSS_KIB=40000 FM_LINT_INTERNAL_ROOT_CAP_KIB=1024 \
        FM_TEST_REAL_HELPER="$ROOT/bin/fm-proc-info.py" FM_TEST_POOL_ROOT="$tmp/" \
        FM_TEST_HIDDEN_MATCH="fm-proc-info.py rss-tree" FM_TEST_HIDDEN_FORM=drop \
        perl "$tmp/watcher/fm-lint-cache.pl" gate "$tmp/younger-pool.$form" 2 younger "$tmp/younger.$form.wait" -- \
        perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 8388608 "$tmp/rss.$form" -- \
        perl -e '$x = "x" x (80 * 1048576); sleep 60' &
    fi
    younger=$!
    reader_seen=0 reader_large=0 reader_stopped=0 standin_stopped=0 settle=
    deadline=$((SECONDS + 45))
    while [ "$SECONDS" -lt "$deadline" ]; do
      rows=$(ps -axo pid=,ppid=,stat=,rss=,command=)
      watch=$(printf '%s\n' "$rows" | awk -v parent="$younger" '$2 == parent && index($0, "fm-lint-cache.pl rsswatch") { print $1; exit }')
      reader=$(printf '%s\n' "$rows" | awk -v parent="${watch:-none}" '$2 == parent && index($0, "fm-proc-info.py rss-tree") { print $3, $4; exit }')
      standin=$(printf '%s\n' "$rows" | awk -v parent="${watch:-none}" '$2 == parent && index($0, "80 * 1048576") { print $3; exit }')
      if [ -n "$reader" ]; then
        reader_seen=1
        [ "${reader#* }" -lt 8192 ] || reader_large=1
        case "${reader%% *}" in *T*) reader_stopped=1 ;; esac
      fi
      case "$standin" in *T*) standin_stopped=1 ;; esac
      # Once the guard has stopped the root, watch the reader through later readings.
      if [ -z "$settle" ] && [ "$standin_stopped" -eq 1 ] && [ "$reader_large" -eq 1 ]; then settle=$((SECONDS + 5)); fi
      if [ -n "$settle" ] && [ "$SECONDS" -ge "$settle" ]; then break; fi
      sleep 0.1
    done
    kill -TERM "$younger" 2>/dev/null
    wait "$younger" 2>/dev/null
    [ "$reader_seen" -eq 1 ] || { fm_lint_kill_tree "$older"; fail "the resident watch's reader never appeared (form: $form), so this test proved nothing"; }
    [ "$reader_large" -eq 1 ] || { fm_lint_kill_tree "$older"; fail "the resident watch's reader held under 8192 KiB, below what the guard stops (form: $form), so this test proved nothing"; }
    [ "$standin_stopped" -eq 1 ] || { fm_lint_kill_tree "$older"; fail "the guard never stopped the root over the budget (form: $form), so this test proved nothing"; }
    [ "$reader_stopped" -eq 0 ] || { fm_lint_kill_tree "$older"; fail "the growth guard stopped the resident watch's reader (form: $form)"; }
    ! grep -q '^rss_reader_unavailable=' "$tmp/rss.$form" 2>/dev/null \
      || { fm_lint_kill_tree "$older"; fail "the resident watch lost its reader under the growth guard (form: $form): $(cat "$tmp/rss.$form")"; }
  done
  fm_lint_kill_tree "$older"
  pass "the growth guard stops a root over the budget but never the resident watch's reader, seen by its full command under an interpreter named Python or by its bare name"
}

test_a_wrapper_around_the_real_shellcheck_shares_the_host_wide_memory_bound() {
  local tmp rc out outside pid deadline real fixture mark
  pinned_ready || { pass "SKIP (ShellCheck $REQUIRED not resolved): wrapper around the real ShellCheck"; return; }
  tmp=$(fm_test_tmproot fm-lint-wrapper)
  mkdir -p "$tmp/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  real=$(command -v shellcheck)
  # shellcheck disable=SC2016 # ${1:-} and $@ expand in the generated stand-in.
  printf '#!/bin/sh\n[ "${1:-}" = --version ] || : > "%s/analysis.marker"\nexec "%s" "$@"\n' "$tmp" "$real" > "$tmp/bin/shellcheck"
  chmod +x "$tmp/bin/shellcheck"
  fm_lint_hide_outside_shellcheck "$tmp/bin"
  # Compliant: a one-line wrapper with no pool setting goes through the shared
  # host pool and leaves there the history record that only its own fixture path
  # can name; the test removes that record.
  fixture="$tmp/wrapped.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture"
  rc=0
  out=$(env -u FM_LINT_SLOT_DIR PATH="$tmp/bin:$PATH" TMPDIR="$tmp" \
    "$LINT" --jobs 1 --telemetry "$tmp/wrapper.tsv" "$fixture" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the wrapper run failed (rc=$rc)"$'\n'"$out"
  [ -e "$tmp/analysis.marker" ] || fail "the wrapper never ran the real analysis"
  mark="/var/tmp/firstmate-lint-$(id -u)/lint-slots/history/$(perl -MDigest::SHA=sha256_hex -e 'print sha256_hex($ARGV[0])' "full:$fixture")"
  [ -s "$mark" ] || fail "the wrapper run left no record in the host pool ($mark)"
  rm -f "$mark"
  # Harmful: the same wrapper pointed at its own pool, while a real ShellCheck
  # outside it holds more than the 4 MiB budget the private gate helper is given
  # here (no real ShellCheck holds the fixed 3.5 GiB), is not admitted although
  # its pool is empty, and runs once the outside one ends.
  rm -f "$tmp/analysis.marker"
  mkfifo "$tmp/hold"
  "$real" - < "$tmp/hold" > /dev/null 2>&1 &
  outside=$!
  exec 9> "$tmp/hold"
  sleep 2
  PATH="$tmp/bin:$PATH" FM_TEST_COUNTED_SHELLCHECK_PID="$outside" \
    fm_lint_gate_root 4096 "$tmp/own-pool" wrapper "$tmp/a.sh" -- "$tmp/bin/shellcheck" --norc -- "$tmp/a.sh" \
    > "$tmp/wrapper.out" 2>&1 9>&- &
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
    local $ENV{FM_LINT_INTERNAL_HOST_RSS_KIB} = 100000000;
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
# history records ("<peak KiB> <input bytes>"), or 0 when it records none.
fm_lint_max_recorded_peak() {
  local max=0 value bytes file
  for file in "$1"/history/*; do
    [ -f "$file" ] || continue
    read -r value bytes < "$file"
    [ -n "$bytes" ] || fail "history record $file names no input size"
    if [ "$value" -gt "$max" ]; then max=$value; fi
  done
  printf '%s\n' "$max"
}

test_memory_budget_bounds_the_aggregate_across_homes() {
  local tmp limit record budget baseline cold warm lone most starts root key bytes real first
  tmp=$(fm_test_tmproot fm-lint-memory-budget)
  mkdir -p "$tmp/bin"
  for root in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$root.sh"; done
  fm_lint_write_memory_shellcheck "$tmp/bin" 64 "$tmp/mem.starts"
  # The host-wide budget is the fixed 3670016 KiB. The per-root watch bound is
  # also the charge of a root with no record: 2000000 KiB here, so one unrecorded
  # root fits the budget and two do not. It sits far above one stand-in, so the
  # watch never ends one. A recorded peak of 1500000 KiB (seeded below) lets two
  # roots fit and not three.
  budget=3670016
  limit=2000000
  record=1500000
  # The control: charged a 256 MiB watch bound each, the same four runs from
  # four homes stack, eight roots at once on one count cap of nine.
  baseline=$(fm_lint_memory_runs "$tmp" "$tmp/bin" 4 FM_LINT_SLOT_DIR="$tmp/base" \
    FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=262144)
  read -r most starts <<<"$baseline"
  [ "$most" -ge 3 ] || fail "four runs charged 256 MiB per root peaked at only $most roots at once, so this test cannot show a bound: $baseline"
  # A pool with no records charges each root the watch bound until its first
  # copy ends: the first two roots never run together, each stand-in waits
  # after its admission before it allocates, and every root completes.
  cold=$(fm_lint_memory_runs "$tmp" "$tmp/bin" 4 FM_LINT_SLOT_DIR="$tmp/shared" FM_LINT_HOST_SLOTS=9 \
    FM_LINT_ROOT_RSS_KIB="$limit" FM_TEST_MEM_DELAY=0.5 FM_TEST_MEM_HOLD=1)
  read -r most starts <<<"$cold"
  [ "$starts" -eq 12 ] || fail "$starts of 12 roots completed in a pool with no records: $cold"
  first=$(sort -k2,2n "$tmp/mem.starts.spans" | awk 'NR == 1 { end = $3 } NR == 2 { print ($2 >= end - 0.05) ? "apart" : "overlap" }')
  [ "$first" = apart ] || fail "the first two roots of a pool with no records ran at once, though two roots charged $limit KiB do not fit $budget KiB: $cold"
  # The same four runs once every root is recorded at $record KiB: two run at
  # once, never three, although each allocates after admission.
  real=$(cd -P "$tmp" && pwd -P)
  mkdir -p "$tmp/shared/history"
  for root in a b c; do
    bytes=$(wc -c < "$tmp/$root.sh" | tr -d ' ')
    key=$(printf 'full:%s' "$real/$root.sh" | perl -MDigest::SHA=sha256_hex -ne 'print sha256_hex($_)')
    printf '%s %s\n' "$record" "$bytes" > "$tmp/shared/history/$key"
  done
  warm=$(fm_lint_memory_runs "$tmp" "$tmp/bin" 4 FM_LINT_SLOT_DIR="$tmp/shared" FM_LINT_HOST_SLOTS=9 \
    FM_LINT_ROOT_RSS_KIB="$limit" FM_TEST_MEM_DELAY=0.5 FM_TEST_MEM_HOLD=1.5)
  read -r most starts <<<"$warm"
  [ "$most" -eq 2 ] || fail "recorded roots ran $most at once, expected the two that fit the budget: $warm"
  [ "$starts" -eq 12 ] || fail "$starts of 12 recorded roots completed under the budget: $warm"
  # A lone run keeps its two workers once its roots are recorded. Each stand-in
  # holds its memory for eight seconds, so a second worker that starts seconds
  # late on a loaded host still overlaps the first; a gate that admits them one
  # at a time still leaves no overlap.
  lone=$(fm_lint_memory_runs "$tmp" "$tmp/bin" 1 FM_LINT_SLOT_DIR="$tmp/shared" FM_LINT_HOST_SLOTS=9 \
    FM_LINT_ROOT_RSS_KIB="$limit" FM_TEST_MEM_HOLD=8)
  read -r most starts <<<"$lone"
  [ "$most" -eq 2 ] || fail "a lone run with recorded roots peaked at $most stand-ins, expected its two workers: $lone"
  pass "four runs with four HOME values keep to the fixed memory budget with and without records, run two recorded roots at once, and finish all 12 roots (small charges: $baseline; no records: $cold; records: $warm)"
}

test_root_larger_than_the_budget_runs_alone_and_a_killed_run_frees_its_charge() {
  local tmp out first second pid_a pid_b deadline
  tmp=$(fm_test_tmproot fm-lint-memory-alone)
  mkdir -p "$tmp/bin"
  for root in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$root.sh"; done
  fm_lint_write_memory_shellcheck "$tmp/bin" 64 "$tmp/mem.starts"
  # A root charged more than the whole budget (the per-root watch bound at its
  # 8 GiB default): each root still runs, one at a time.
  out=$(fm_lint_memory_runs "$tmp" "$tmp/bin" 1 FM_LINT_SLOT_DIR="$tmp/alone" \
    FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=8388608)
  [ "$(printf '%s' "$out" | cut -d' ' -f1)" -eq 1 ] || fail "a root larger than the budget did not run alone: $out"
  [ "$(printf '%s' "$out" | cut -d' ' -f2)" -eq 3 ] || fail "a root larger than the budget did not complete every root: $out"
  # A run killed while it holds the only admissible charge (one root charged
  # 2000000 KiB fits the budget, two do not) frees it for the waiter.
  : > "$tmp/mem.starts"
  FM_TEST_MEM_HOLD=60 FM_LINT_SLOT_DIR="$tmp/kill" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=2000000 \
    PATH="$tmp/bin:$PATH" "$LINT" --jobs 1 "$tmp/a.sh" > "$tmp/kill.a.out" 2>&1 &
  pid_a=$!
  deadline=$((SECONDS + 20))
  until [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -ge 1 ]; do
    [ "$SECONDS" -lt "$deadline" ] || { kill "$pid_a" 2>/dev/null; fail "the first run never started its root"; }
    sleep 0.1
  done
  FM_TEST_MEM_HOLD=0.3 FM_LINT_SLOT_DIR="$tmp/kill" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=2000000 \
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
  second=$(FM_TEST_MEM_HOLD=0.2 FM_LINT_SLOT_DIR="$tmp/kill" FM_LINT_HOST_SLOTS=9 FM_LINT_ROOT_RSS_KIB=2000000 \
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
  PATH="$tmp/hide:$PATH" FM_TEST_GATE_POOL_PREFIX="$tmp/" perl - "$ROOT/bin/fm-lint-cache.pl" "$tmp" <<'PL' || fail "memory charge state regression failed"
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
# A gate's input size is 1000 bytes unless <env> names another; an undef value
# leaves that variable unset.
sub launch {
    my ($gate_script, $dir, $name, $env, $peak, $rss, $stderr) = @_;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        %ENV = (%ENV, FM_LINT_INTERNAL_ROOT_RSS_FILE => "$dir/rss.$name", FM_LINT_INTERNAL_ROOT_BYTES => 1000,
            FM_LINT_INTERNAL_HOST_RSS_KIB => 100000000,
            map { defined $env->{$_} ? ($_ => $env->{$_}) : () } keys %$env);
        delete $ENV{$_} for grep { !defined $env->{$_} } keys %$env;
        if (defined $stderr) { open(STDERR, '>', $stderr) or die "$!"; }
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
# A record "<peak KiB> <input bytes>", measured on 1000 bytes unless <bytes>
# names another input size; a <bytes> of '' writes the one-number format.
sub record {
    my ($dir, $key, $kib, $bytes) = @_;
    $bytes //= 1000;
    make_path("$dir/slots/history");
    open(my $fh, '>', history($dir, $key)) or die "$!";
    print {$fh} length $bytes ? "$kib $bytes\n" : "$kib\n";
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
    my $pid = launch($gate, $dir, 'stale', {FM_LINT_HOST_SLOTS => 2, FM_LINT_INTERNAL_HOST_RSS_KIB => 10});
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
    my %env = (FM_LINT_HOST_SLOTS => 2, FM_LINT_INTERNAL_HOST_RSS_KIB => 1050, FM_LINT_INTERNAL_ROOT_CAP_KIB => 1000,
        FM_LINT_INTERNAL_ROOT_KEY => 'small');
    my $pid = launch($gate, $dir, 'unknown', \%env);
    if (await("$dir/started.unknown", 1.5)) { kill 'KILL', $pid; die "a held slot with an unknown record was charged less than the worst case\n" }
    close $holder;
    await("$dir/started.unknown", 10) or do { kill 'KILL', $pid; die "the waiter stayed queued after the unknown holder ended\n" };
    release($dir, 'unknown', $pid);
}
# 3. Three roots recorded at 100000 KiB fit a 1500000 KiB budget when the table
# can be read.
for my $case (['readable', $gate, {}, 3]) {
    my ($label, $gate_script, $extra, $expected) = @$case;
    my $dir = "$tmp/$label";
    make_path("$dir/slots");
    record($dir, 'seeded', 100000);
    my %env = (FM_LINT_HOST_SLOTS => 9, FM_LINT_INTERNAL_HOST_RSS_KIB => 1500000, FM_LINT_INTERNAL_ROOT_CAP_KIB => 1000000,
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
# 3b. With no readable process table (ps fails and no libproc helper sits beside
# the gate) no root is admitted, not even in an empty pool with a record that
# fits: the gate retries for about 5 s, then names the table, ps and
# fm-proc-info.py, exits 2 and leaves no ticket.
{
    my $dir = "$tmp/unreadable";
    make_path("$dir/slots");
    record($dir, 'seeded', 100000);
    my %env = (FM_LINT_HOST_SLOTS => 9, FM_LINT_INTERNAL_HOST_RSS_KIB => 1500000, FM_LINT_INTERNAL_ROOT_CAP_KIB => 1000000,
        FM_LINT_INTERNAL_ROOT_KEY => 'seeded', PATH => "$tmp/shim:$ENV{PATH}");
    my $from = time();
    my $pid = launch("$tmp/lonely/fm-lint-cache.pl", $dir, 'blind', \%env, undef, undef, "$dir/stderr");
    my ($deadline, $reaped) = (time() + 30, 0);
    sleep 0.05 until ($reaped = waitpid($pid, WNOHANG)) == $pid || time() > $deadline;
    my ($status, $took) = ($?, time() - $from);
    if ($reaped != $pid) { kill 'KILL', $pid; waitpid($pid, 0); die "a gate with no readable table neither started nor refused\n" }
    die "a root started with no readable process table\n" if -e "$dir/started.blind";
    die "a gate with no readable table exited $status, expected 2\n" unless $status == 2 << 8;
    die "a gate with no readable table refused after $took s, before its about 5 s wait\n" if $took < 4.5;
    open(my $fh, '<', "$dir/stderr") or die "$!";
    my $said = do { local $/; <$fh> };
    die "the refusal did not name the process table, ps and fm-proc-info.py: $said\n"
        unless $said =~ /process table/ && $said =~ /\bps\b/ && $said =~ /fm-proc-info\.py/;
    opendir(my $listing, "$dir/slots") or die "$!";
    my @tickets = grep { /\Aqueue\.[0-9]/ } readdir $listing;
    die "a refused gate left a ticket: @tickets\n" if @tickets;
}
# 4. A held root is charged what it holds now when that exceeds its record (the
# watch's published peak), and a root's record is raised to its measured peak
# when it ends (the watch's peak, or /usr/bin/time's maximum resident size) and
# never lowered.
{
    my $dir = "$tmp/growth";
    make_path("$dir/slots");
    record($dir, $_, 1000) for qw(holder waiter);
    my %env = (FM_LINT_HOST_SLOTS => 9, FM_LINT_INTERNAL_HOST_RSS_KIB => 1000000, FM_LINT_INTERNAL_ROOT_CAP_KIB => 1000000);
    my $holder = launch($gate, $dir, 'holder', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'holder'}, 2000000);
    await("$dir/started.holder", 10) or do { kill 'KILL', $holder; die "the holder never started\n" };
    my $waiter = launch($gate, $dir, 'waiter', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'waiter'}, undef, 500);
    if (await("$dir/started.waiter", 1.5)) { kill 'KILL', $holder, $waiter; die "a holder past its record was charged only its record\n" }
    release($dir, 'holder', $holder);
    await("$dir/started.waiter", 10) or do { kill 'KILL', $waiter; die "the waiter stayed queued after the grown holder ended\n" };
    release($dir, 'waiter', $waiter);
    die "the watch's peak did not raise the record: " . recorded($dir, 'holder') . "\n" unless recorded($dir, 'holder') eq '2000000 1000';
    die "a lower peak lowered the record: " . recorded($dir, 'waiter') . "\n" unless recorded($dir, 'waiter') eq '1000 1000';
    my $lower = launch($gate, $dir, 'lower', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'holder'}, undef, 50);
    release($dir, 'lower', $lower);
    die "a lower peak lowered the record: " . recorded($dir, 'holder') . "\n" unless recorded($dir, 'holder') eq '2000000 1000';
    my $higher = launch($gate, $dir, 'higher', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'waiter'}, undef, 3000);
    release($dir, 'higher', $higher);
    die "the maximum resident size did not raise the record: " . recorded($dir, 'waiter') . "\n" unless recorded($dir, 'waiter') eq '3000 1000';
    # A record measured on another input is replaced, lower peak included, by
    # this peak and input; within 10 percent of that input it is again never
    # lowered and keeps its input size; with no input size nothing is written.
    my $moved = launch($gate, $dir, 'moved', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'holder', FM_LINT_INTERNAL_ROOT_BYTES => 2000}, undef, 50);
    release($dir, 'moved', $moved);
    die "a record for another input was not replaced: " . recorded($dir, 'holder') . "\n" unless recorded($dir, 'holder') eq '50 2000';
    my $drift = launch($gate, $dir, 'drift', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'holder', FM_LINT_INTERNAL_ROOT_BYTES => 2100}, undef, 40);
    release($dir, 'drift', $drift);
    die "a record within 10 percent was lowered or moved: " . recorded($dir, 'holder') . "\n" unless recorded($dir, 'holder') eq '50 2000';
    my $unsized = launch($gate, $dir, 'unsized', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'waiter', FM_LINT_INTERNAL_ROOT_BYTES => undef}, undef, 9000);
    release($dir, 'unsized', $unsized);
    die "an analysis with no input size changed the record: " . recorded($dir, 'waiter') . "\n" unless recorded($dir, 'waiter') eq '3000 1000';
}
# 5. A root with no record is charged the worst case: it waits beside a small
# held root that a recorded root joins.
{
    my $dir = "$tmp/fresh";
    make_path("$dir/slots");
    record($dir, $_, 1000) for qw(holder known);
    my %env = (FM_LINT_HOST_SLOTS => 9, FM_LINT_INTERNAL_HOST_RSS_KIB => 1000000, FM_LINT_INTERNAL_ROOT_CAP_KIB => 1000000);
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
    my $pid = launch($gate, $dir, 'narrow', {FM_LINT_HOST_SLOTS => 1, FM_LINT_INTERNAL_HOST_RSS_KIB => 1000000,
        FM_LINT_INTERNAL_ROOT_KEY => 'small'});
    if (await("$dir/started.narrow", 1.5)) { kill 'KILL', $pid; die "a run with a cap of one ignored a slot held beyond its cap\n" }
    close $holder;
    await("$dir/started.narrow", 10) or do { kill 'KILL', $pid; die "the narrow run stayed queued after the wide holder ended\n" };
    release($dir, 'narrow', $pid);
}
# 8. A record is trusted only for the input it was measured on. Beside a held
# root charged its 60000 KiB record times 1.10 plus 64 MiB (131536 KiB), under a
# budget that fits two such charges (270000 KiB) and not the worst case, a root whose input grew or shrank by 10 percent or
# more, whose record names no input size, or that has no input size is charged
# the worst case and waits; a root whose input is within 10 percent of its
# record's joins, so two roots with matching records run together.
{
    my $dir = "$tmp/input";
    make_path("$dir/slots");
    record($dir, $_, 60000) for qw(holder near grown shrunk unsized);
    record($dir, 'legacy', 60000, '');
    my %env = (FM_LINT_HOST_SLOTS => 9, FM_LINT_INTERNAL_HOST_RSS_KIB => 270000, FM_LINT_INTERNAL_ROOT_CAP_KIB => 1000000);
    my $holder = launch($gate, $dir, 'holder', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'holder'});
    await("$dir/started.holder", 10) or do { kill 'KILL', $holder; die "the recorded holder never started\n" };
    for my $case (['grown', 1100], ['shrunk', 900], ['legacy', 1000], ['unsized', undef]) {
        my ($key, $bytes) = @$case;
        my $pid = launch($gate, $dir, $key, {%env, FM_LINT_INTERNAL_ROOT_KEY => $key, FM_LINT_INTERNAL_ROOT_BYTES => $bytes});
        if (await("$dir/started.$key", 1.5)) { kill 'KILL', $holder, $pid; die "a $key root was charged a record that does not describe its input\n" }
        kill 'TERM', $pid;
        waitpid($pid, 0);
    }
    my $near = launch($gate, $dir, 'near', {%env, FM_LINT_INTERNAL_ROOT_KEY => 'near', FM_LINT_INTERNAL_ROOT_BYTES => 1099});
    await("$dir/started.near", 10) or do { kill 'KILL', $holder, $near; die "two roots with matching records did not run together\n" };
    release($dir, $_->[0], $_->[1]) for ['holder', $holder], ['near', $near];
}
PL
  pass "stale records are reclaimed, unknown records and a root with no record are charged the worst case, an unreadable table admits no root and refuses after about 5 s, a root past its record is charged its current peak, a record is trusted and only raised for an input within 10 percent and replaced for another, records change only after a complete analysis, and slots beyond a run's cap count"
}

test_fast_record_does_not_lower_the_full_charge() {
  local tmp limit record holder waiter starts deadline
  tmp=$(fm_test_tmproot fm-lint-memory-mode)
  mkdir -p "$tmp/bin"
  for root in a b; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$root.sh"; done
  fm_lint_write_memory_shellcheck "$tmp/bin" 1 "$tmp/mem.starts"
  limit=2000000
  # A --fast lint records the small peak of a.sh in fast mode only.
  CI='' GITHUB_ACTIONS='' FM_TEST_MEM_HOLD=0.1 FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_ROOT_RSS_KIB="$limit" PATH="$tmp/bin:$PATH" \
    "$LINT" --fast --jobs 1 "$tmp/a.sh" > "$tmp/fast.out" 2>&1 || fail "the fast seeding run failed"$'\n'"$(cat "$tmp/fast.out")"
  record=$(fm_lint_max_recorded_peak "$tmp/pool")
  { [ "$record" -gt 0 ] && [ $((record * 2)) -lt "$limit" ]; } \
    || fail "the fast run recorded a peak of $record KiB, expected above 0 and below half of $limit"
  # The fixed budget fits an unrecorded holder plus a.sh at its fast record, but
  # not two unrecorded roots (2000000 KiB each).
  : > "$tmp/mem.starts"
  FM_TEST_MEM_HOLD=60 FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_ROOT_RSS_KIB="$limit" \
    PATH="$tmp/bin:$PATH" "$LINT" --jobs 1 "$tmp/b.sh" > "$tmp/holder.out" 2>&1 &
  holder=$!
  deadline=$((SECONDS + 20))
  until [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -ge 1 ]; do
    [ "$SECONDS" -lt "$deadline" ] || { kill "$holder" 2>/dev/null; fail "the holding run never started its root"; }
    sleep 0.1
  done
  # A fast request of a.sh is charged its fast record and joins the holder.
  CI='' GITHUB_ACTIONS='' FM_TEST_MEM_HOLD=0.1 FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_ROOT_RSS_KIB="$limit" \
    PATH="$tmp/bin:$PATH" "$LINT" --fast --jobs 1 "$tmp/a.sh" > "$tmp/fast2.out" 2>&1 &
  waiter=$!
  deadline=$((SECONDS + 20))
  until [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -ge 2 ]; do
    [ "$SECONDS" -lt "$deadline" ] || { kill "$holder" "$waiter" 2>/dev/null; fail "a fast request was not charged its fast record"; }
    sleep 0.1
  done
  wait "$waiter" || { kill "$holder" 2>/dev/null; fail "the fast request failed beside the holder"$'\n'"$(cat "$tmp/fast2.out")"; }
  # A full request of a.sh has no full record, so it is charged the worst case and waits.
  FM_TEST_MEM_HOLD=0.1 FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_ROOT_RSS_KIB="$limit" \
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
  # The real ShellCheck with FM_LINT_SLOT_DIR unset: its pool is the live per-user
  # host pool, which no PATH entry, HOME, XDG_CACHE_HOME or FM_HOME can change.
  # Each run leaves a history record that
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
  local tmp mode
  local -a modes=(none)
  if fm_lint_bounds_supported; then modes+=(perl); fi
  tmp=$(fm_test_tmproot fm-lint-slot-inheritance)
  # The worker runs under a lint run's entry, in a copy whose host-wide directory
  # is the test's own.
  local repo
  repo=$(fm_lint_isolated_copy "$tmp" death)
  fm_lint_write_owner_stand_in "$tmp/owner" "$repo" "$(command -v python3)"
  # A worker takes its bound mechanism from its run's ledger entry, so each mode
  # runs under a run entry that names that mode.
  for mode in "${modes[@]}"; do
  FM_TEST_RUN_BOUNDED="$mode" FM_TEST_RUN_MEMORY_KIB=2097152 bash "$tmp/owner/fm-lint.sh" \
    perl - "$repo/bin/fm-lint.sh" "$repo/bin/fm-lint-cache.pl" "$tmp" "$mode" <<'PL' || fail "slot lifetime regression failed ($mode)"
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
for my $bounded ($bound_mechanism) {
    my $dir = "$tmp/$bounded";
    make_path("$dir/out");
    open(my $root, '>', "$dir/root.sh") or die "$!";
    print {$root} "#!/bin/bash\nexit 0\n";
    close $root;
    open(my $manifest, '>', "$dir/manifest") or die "$!";
    print {$manifest} "0\t$dir/root.sh\n";
    close $manifest;
    local %ENV = (%ENV, FM_LINT_INTERNAL => 1, 
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
  done
  pass "inherited slots prevent overlap after gate death and allow admission after watchdog cleanup"
}

test_queued_roots_use_high_resolution_timings() {
  local tmp bounded=none
  if fm_lint_bounds_supported; then bounded=perl; fi
  tmp=$(fm_test_tmproot fm-lint-slot-clock)
  # The worker runs under a lint run's entry, in a copy whose host-wide directory
  # is the test's own.
  local repo
  repo=$(fm_lint_isolated_copy "$tmp" clock)
  fm_lint_write_owner_stand_in "$tmp/owner" "$repo" "$(command -v python3)"
  FM_TEST_RUN_BOUNDED="$bounded" FM_TEST_RUN_MEMORY_KIB=2097152 bash "$tmp/owner/fm-lint.sh" \
    perl - "$repo/bin/fm-lint.sh" "$tmp" "$bounded" <<'PL' || fail "queued root clock regression failed"
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
        FM_LINT_INTERNAL => 1, 
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

test_the_analysis_process_sees_the_default_and_the_explicit_address_space_limit() {
  if ! fm_lint_bounds_supported; then
    pass "SKIP (host cannot enforce the bounded envelope): address-space limit observation"
    return
  fi
  local tmp fakebin seen ok
  tmp=$(fm_test_tmproot fm-lint-bound-observe)
  fakebin="$tmp/bin"
  mkdir -p "$fakebin"
  ok="$tmp/ok.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$ok"
  # A stand-in analysis that records the address-space limit its own process sees.
  cat > "$fakebin/shellcheck" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\\nversion: 0.11.0\\n'
  exit 0
fi
ulimit -v > "$tmp/limit.seen"
exit 0
SH
  chmod +x "$fakebin/shellcheck"
  fm_lint_hide_outside_shellcheck "$fakebin"
  # The default: 12 GiB (12582912 KiB) when FM_LINT_ROOT_MEMORY_KIB is omitted.
  PATH="$fakebin:$PATH" FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_SLOT_DIR="$tmp/slots.default" "$LINT" --jobs 1 "$ok" > "$tmp/default.out" 2>&1 \
    || fail "the bounded run with the default address-space limit failed"$'\n'"$(cat "$tmp/default.out")"
  seen=$(cat "$tmp/limit.seen")
  [ "$seen" = 12582912 ] || fail "the analysis process saw ulimit -v $seen, expected the 12582912 KiB default"
  # An explicit lower value is the limit the analysis process sees.
  rm -f "$tmp/limit.seen"
  PATH="$fakebin:$PATH" FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_ROOT_MEMORY_KIB=4194304 FM_LINT_SLOT_DIR="$tmp/slots.lower" "$LINT" --jobs 1 "$ok" > "$tmp/lower.out" 2>&1 \
    || fail "the bounded run with an explicit lower limit failed"$'\n'"$(cat "$tmp/lower.out")"
  seen=$(cat "$tmp/limit.seen")
  [ "$seen" = 4194304 ] || fail "the analysis process saw ulimit -v $seen, expected the explicit 4194304 KiB"
  pass "under the bounded envelope the analysis process sees the 12 GiB default and an explicit lower address-space limit"
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
# A shim reached again below itself refuses with status 99, so a real path that
# resolves back to a shim cannot recurse: the ps shim marks every call below it,
# and the python3 shim marks its own process (FM_TEST_RSS_SHIM_DEPTH=<pid>), which
# the interpreter it execs keeps, so that interpreter's children may still use the shims.
# Every entry appends its pid to FM_TEST_SHIM_TRACE when that is set. The ps
# shim logs how many processes each call listed to FM_TEST_PS_LOG; the python3 shim logs each
# call's arguments to FM_TEST_PY_LOG, fails at once under FM_TEST_PY_REFUSE=1,
# and with FM_TEST_PY_MEMORY set (resident and footprint KiB) answers each line a
# rss-tree reader is sent with the larger of the two as the reader's JSON reply,
# naming the root by its real identity (read once when the reader starts) and
# marked bound, instead of reading memory; with FM_TEST_PY_PLAN=<file> too,
# the Nth rss-tree reader started follows line N of <file>: stall answers its
# first line 8 s late, slow answers its first line 1 s late, slow-later answers
# its second line 8 s late (8 s is past a reply's 6 s and its 1 s retry), exit exits before any reply, and anything else (or
# no such line) answers at once. The python3 shim names itself as the
# interpreter lint resolves for the watch's readers.
fm_lint_write_rss_shims() {  # <dir>
  local guard
  guard=$(cat <<'SH'
#!/usr/bin/env bash
[ -z "${FM_TEST_SHIM_TRACE:-}" ] || printf '%s\n' "$$" >> "$FM_TEST_SHIM_TRACE"
if [ "${FM_TEST_RSS_SHIM_DEPTH:-}" = 1 ] || [ "${FM_TEST_RSS_SHIM_DEPTH:-}" = "$$" ]; then
  echo "rss shim: refused a call from inside a shim" >&2
  exit 99
fi
SH
)
  {
    printf '%s\n' "$guard"
    cat <<'SH'
export FM_TEST_RSS_SHIM_DEPTH=1
out=$("$FM_TEST_REAL_PS" "$@") || exit
printf '%s\n' "$out" | grep -c . >> "$FM_TEST_PS_LOG"
printf '%s\n' "$out"
SH
  } > "$1/ps"
  {
    printf '%s\n' "$guard"
    cat <<'SH'
export FM_TEST_RSS_SHIM_DEPTH=$$
if [ "$*" = "-c import sys; print(sys.executable)" ]; then
  printf '%s\n' "$0"
  exit 0
fi
printf '%s\n' "$*" >> "$FM_TEST_PY_LOG"
[ "${FM_TEST_PY_REFUSE:-0}" = 0 ] || exit 1
if [ -n "${FM_TEST_PY_MEMORY:-}" ] && [ "${2:-}" = rss-tree ]; then
  ident=$("$FM_TEST_REAL_PYTHON" -I -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("fp", sys.argv[1])
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)
print("%d,%d" % tuple(fp.process_identity(fp.kinfo(int(sys.argv[2])))))' "$1" "$3") || exit 1
  plan=
  [ -z "${FM_TEST_PY_PLAN:-}" ] || plan=$(sed -n "$(grep -c rss-tree "$FM_TEST_PY_LOG")p" "$FM_TEST_PY_PLAN")
  [ "$plan" != exit ] || exit 1
  line=0
  while read -r _; do
    line=$((line + 1))
    case "$plan:$line" in
      stall:1) sleep 8 ;;
      slow:1) sleep 1 ;;
      slow-later:2) sleep 8 ;;
    esac
    printf '{"rss_kib":%s,"members":[[%s,%s]],"uncounted":[],"bound":true}\n' "$(printf '%s\n' "$FM_TEST_PY_MEMORY" | awk '{ print ($1 > $2 ? $1 : $2) }')" "$3" "$ident"
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
  local tmp shims real_ps real_python refuse rc decoy_pid samples
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
  # The decoy is a process that is not the command's: it is started here, in a
  # process group of its own, holds 160 MiB, over the 100 MiB bound, and lives
  # while the command runs. The command is a short sleep.
  # Refusing every python call also refuses the watch's launch record: the root is
  # never started and the watch exits 96 (no table is ever read instead).
  for refuse in 0 1; do
    : > "$tmp/ps.log"
    : > "$tmp/py.log"
    rm -f "$tmp/rss" "$tmp/decoy.pid"
    perl -MPOSIX -e 'POSIX::setpgid(0, 0); open(my $fh, ">", $ARGV[0]); print {$fh} "$$\n"; close $fh; my $held = "x" x (160 * 1024 * 1024); sleep 30' "$tmp/decoy.pid" &
    local waited=0
    while [ ! -s "$tmp/decoy.pid" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
    decoy_pid=$(cat "$tmp/decoy.pid" 2>/dev/null || true)
    [ -n "$decoy_pid" ] || fail "the decoy did not start"
    rc=0
    fm_test_tree_leash env -u FM_TEST_RSS_SHIM_DEPTH PATH="$shims:$PATH" \
      FM_TEST_PY_REFUSE="$refuse" FM_TEST_REAL_PS="$real_ps" FM_TEST_REAL_PYTHON="$real_python" \
      FM_TEST_PS_LOG="$tmp/ps.log" FM_TEST_PY_LOG="$tmp/py.log" \
      perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 102400 "$tmp/rss" -- \
      sleep 3 > /dev/null 2>&1 || rc=$?
    kill -KILL "$decoy_pid" 2>/dev/null || true
    grep -q '^max_rss_kib=' "$tmp/rss" 2>/dev/null \
      && fail "the watch counted a process outside its command's tree (exit $rc, python refused=$refuse)"
    [ ! -s "$tmp/ps.log" ] || fail "the watch ran ps (python refused=$refuse)"
    if [ "$refuse" = 0 ]; then
      [ "$rc" -eq 0 ] || fail "the watch of a small command exited $rc"
      samples=$(sed -n 's/^rss_samples=//p' "$tmp/rss")
      [ "$(grep -c 'rss-tree' "$tmp/py.log")" -eq 1 ] \
        || fail "the watch did not start exactly one libproc reader"$'\n'"$(cat "$tmp/py.log")"
      case "$samples" in libproc:[1-9]*) ;; *) fail "the libproc samples were not recorded: $samples" ;; esac
    else
      { [ "$rc" -eq 96 ] && grep -q '^rss_launch_unrecorded=1$' "$tmp/rss"; } \
        || fail "a watch that could not read its root's start time did not refuse the launch (exit $rc): $(cat "$tmp/rss" 2>/dev/null)"
      [ "$(grep -c 'rss-tree' "$tmp/py.log")" -eq 0 ] \
        || fail "a reader started for a root that never launched"$'\n'"$(cat "$tmp/py.log")"
    fi
  done
  # A descendant of the command that leaves its process group is still the
  # command's own: the libproc reader counts it and ends the root.
  cat > "$tmp/leaver-parent.sh" <<'SH'
perl -MPOSIX -e 'POSIX::setpgid(0, 0); my $held = "x" x (160 * 1024 * 1024); sleep 30' &
echo "$!" > "$1"
sleep 3
SH
  : > "$tmp/py.log"
  rm -f "$tmp/rss" "$tmp/leaver.pid"
  rc=0
  fm_test_tree_leash env -u FM_TEST_RSS_SHIM_DEPTH PATH="$shims:$PATH" \
    FM_TEST_PY_REFUSE=0 FM_TEST_REAL_PS="$real_ps" FM_TEST_REAL_PYTHON="$real_python" \
    FM_TEST_PS_LOG="$tmp/ps.log" FM_TEST_PY_LOG="$tmp/py.log" \
    perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 102400 "$tmp/rss" -- \
    bash "$tmp/leaver-parent.sh" "$tmp/leaver.pid" > /dev/null 2>&1 || rc=$?
  decoy_pid=$(cat "$tmp/leaver.pid" 2>/dev/null || true)
  [ -z "$decoy_pid" ] || kill -KILL "$decoy_pid" 2>/dev/null || true
  [ -n "$decoy_pid" ] || fail "the group-leaving descendant did not start"
  grep -q '^max_rss_kib=' "$tmp/rss" \
    || fail "the watch did not count a descendant of its command that left the command's process group (exit $rc)"
  pass "the resident-memory watch samples only its command's own tree: an unrelated process is not counted, and a descendant that leaves the process group is"
}

# fm_lint_identity_of <pid>: "<start seconds>:<start microseconds>" of a live
# process, read through the helper the watch itself uses.
fm_lint_identity_of() {
  python3 -I -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("fp", sys.argv[1])
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)
print("%d:%d" % fp.process_identity(fp.kinfo(int(sys.argv[2]))))' "$ROOT/bin/fm-proc-info.py" "$1"
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
  [ "$(grep -c 'rss-tree' "$tmp/py.log")" -eq 1 ] \
    || fail "a reader started for an attempt that ended before its first tick"$'\n'"$(cat "$tmp/py.log")"
  pass "a root whose footprint crosses the bound while its resident size does not is ended and retried narrower"
}

# A reader that answers one tick past the deadline and its retry makes that tick a
# miss (no other source samples it); a new reader takes over and answers the next tick, so the miss
# is followed by a later tick and the root fails unmeasured (96): no narrower retry
# follows, and the run fails.
test_resident_watch_replaces_a_stalled_reader() {
  local tmp out samples
  tmp=$(fm_test_tmproot fm-lint-rss-stall)
  printf 'stall\n' > "$tmp/plan"
  if ! fm_lint_footprint_lint "$tmp" FM_TEST_PY_PLAN="$tmp/plan" FM_TEST_GROW_HOLD=22; then
    pass "SKIP (the resident-memory watch runs only on macOS): stalled reader check"
    return
  fi
  out=$(cat "$tmp/out")
  [ "$(cat "$tmp/rc")" -ne 0 ] || fail "a root with a stalled reply followed by later ticks passed"$'\n'"$out"
  assert_contains "$out" "reason=unmeasured" "the stalled tick did not fail the root as unmeasured"
  [ "$(cat "$tmp/flags.log")" = yes ] \
    || fail "an unmeasured root took a narrower retry"$'\n'"$(cat "$tmp/flags.log")"
  samples=$(awk -F '\t' '$1 == "end" && $3 ~ /footprint\.sh$/ { print $16 }' "$tmp/pass.roots.tsv")
  case "$samples" in libproc:[1-9]*,unmeasured) ;; *) fail "the stalled tick was not recorded as an unmeasured interval: $samples" ;; esac
  [ "$(grep -c 'rss-tree' "$tmp/py.log")" -eq 2 ] \
    || fail "the stalled reader was not replaced exactly once"$'\n'"$(cat "$tmp/py.log")"
  pass "a reader that misses one deadline is replaced, and the missed tick followed by a later one fails the root unmeasured with no narrower retry"
}

# A reader's first reply has the same 6 s as every reply, so a reader that starts
# slowly on a busy host still has its footprint used, with no miss.
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
  [ "$samples" = libproc:1 ] \
    || fail "a first reply 1 s late was not used as the footprint sample: $samples"
  [ "$(grep -c 'rss-tree' "$tmp/py.log")" -eq 1 ] \
    || fail "a reader whose first reply was 1 s late was replaced"$'\n'"$(cat "$tmp/py.log")"
  pass "a reader whose first reply is 1 s late keeps footprint in use"
}

# A later reply has the same 6 s and its one 1 s retry: one 8 s late is a miss
# for that tick, a new reader answers every tick after it, and the miss followed by later ticks
# fails the root unmeasured (96).
test_resident_watch_fails_a_root_whose_later_reply_was_late() {
  local tmp out samples
  tmp=$(fm_test_tmproot fm-lint-rss-slow-later)
  printf 'slow-later\n' > "$tmp/plan"
  if ! fm_lint_footprint_lint "$tmp" FM_TEST_PY_PLAN="$tmp/plan" FM_TEST_PY_MEMORY="1024 2048" FM_TEST_GROW_HOLD=22; then
    pass "SKIP (the resident-memory watch runs only on macOS): slow later reply check"
    return
  fi
  out=$(cat "$tmp/out")
  [ "$(cat "$tmp/rc")" -ne 0 ] || fail "a root with a late later reply followed by later ticks passed"$'\n'"$out"
  assert_contains "$out" "reason=unmeasured" "the late reply did not fail the root as unmeasured"
  [ "$(cat "$tmp/flags.log")" = yes ] \
    || fail "an unmeasured root took a narrower retry"$'\n'"$(cat "$tmp/flags.log")"
  samples=$(awk -F '\t' '$1 == "end" && $3 ~ /footprint\.sh$/ { print $16 }' "$tmp/pass.roots.tsv")
  case "$samples" in
    libproc:[1-9]*,unmeasured) ;;
    *) fail "the late later reply was not recorded as an unmeasured interval: $samples" ;;
  esac
  [ "$(grep -c 'rss-tree' "$tmp/py.log")" -eq 2 ] \
    || fail "the reader with a slow later reply was not replaced exactly once"$'\n'"$(cat "$tmp/py.log")"
  pass "a later reply 8 s late (past its 6 s and its 1 s retry) is a miss, and with later ticks it fails the root unmeasured"
}

# A replacement reader that exits before its first reply is one failed restart,
# not a reader that exited at start: the next replacement answers again. The two
# missed ticks were followed by later ones, so the root fails unmeasured (96).
test_resident_watch_retries_a_replacement_that_exits() {
  local tmp out samples
  tmp=$(fm_test_tmproot fm-lint-rss-replacement-exit)
  printf 'stall\nexit\n' > "$tmp/plan"
  if ! fm_lint_footprint_lint "$tmp" FM_TEST_PY_PLAN="$tmp/plan" FM_TEST_GROW_HOLD=24; then
    pass "SKIP (the resident-memory watch runs only on macOS): failed replacement check"
    return
  fi
  out=$(cat "$tmp/out")
  [ "$(cat "$tmp/rc")" -ne 0 ] || fail "a root with missed ticks followed by later ones passed"$'\n'"$out"
  assert_contains "$out" "reason=unmeasured" "the missed ticks did not fail the root as unmeasured"
  [ "$(cat "$tmp/flags.log")" = yes ] \
    || fail "an unmeasured root took a narrower retry"$'\n'"$(cat "$tmp/flags.log")"
  samples=$(awk -F '\t' '$1 == "end" && $3 ~ /footprint\.sh$/ { print $16 }' "$tmp/pass.roots.tsv")
  case "$samples" in libproc:[1-9]*,unmeasured) ;; *) fail "the failed replacement's ticks were not recorded as an unmeasured interval: $samples" ;; esac
  [ "$(grep -c 'rss-tree' "$tmp/py.log")" -eq 3 ] \
    || fail "the failed replacement was not replaced exactly once"$'\n'"$(cat "$tmp/py.log")"
  pass "a replacement reader that exits before replying is retried, and the missed ticks fail the root unmeasured"
}

# Three failed replacements in a row give the reader up for the rest of the
# root, with that reason recorded once in the roots log.
test_resident_watch_gives_up_after_three_failed_restarts() {
  local tmp out samples
  tmp=$(fm_test_tmproot fm-lint-rss-restarts-failed)
  printf 'stall\nexit\nexit\nexit\n' > "$tmp/plan"
  if ! fm_lint_footprint_lint "$tmp" FM_TEST_PY_PLAN="$tmp/plan" FM_TEST_GROW_HOLD=22; then
    pass "SKIP (the resident-memory watch runs only on macOS): restarts-failed check"
    return
  fi
  out=$(cat "$tmp/out")
  [ "$(cat "$tmp/rc")" -ne 0 ] || fail "a root no reader measured passed"$'\n'"$out"
  assert_contains "$out" "reason=unmeasured" "a root no reader measured was not failed as unmeasured"
  [ "$(cat "$tmp/flags.log")" = yes ] \
    || fail "a root no reader answered for was not left to its one attempt"$'\n'"$(cat "$tmp/flags.log")"
  samples=$(awk -F '\t' '$1 == "end" && $3 ~ /footprint\.sh$/ { print $16 }' "$tmp/pass.roots.tsv")
  case "$samples" in
    libproc:0,reader-unavailable:restarts-failed,unmeasured) ;;
    *) fail "three failed replacements did not give the reader up as restarts-failed: $samples" ;;
  esac
  [ "$(grep -c 'rss-tree' "$tmp/py.log")" -eq 4 ] \
    || fail "the watch did not stop starting readers after three failed replacements"$'\n'"$(cat "$tmp/py.log")"
  pass "three failed replacement readers in a row give the reader up as restarts-failed, and the root fails unmeasured"
}

test_a_per_root_limit_above_the_default_is_clamped_and_a_lower_one_is_kept() {
  local tmp out request limit rc
  tmp=$(fm_lint_slot_fixture fm-lint-slots-clamp)
  # A request of 9 GiB runs at the 8 GiB default, and the roots log and stderr name
  # both values; a request of 4 GiB runs at 4 GiB with no clamp line; an omitted
  # setting runs at the default with no clamp line. A number too long for shell
  # arithmetic is clamped too.
  for request in 9437184 99999999999999999999999 4194304 omitted; do
    if [ "$request" = omitted ]; then
      out=$(env -u FM_LINT_ROOT_RSS_KIB PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/pool.$request" \
        FM_LINT_TELEMETRY="$tmp/$request.tsv" "$LINT" "$tmp/a.sh" 2>&1) \
        || fail "a lint run with FM_LINT_ROOT_RSS_KIB omitted failed"$'\n'"$out"
    else
      out=$(env FM_LINT_ROOT_RSS_KIB="$request" PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/pool.$request" \
        FM_LINT_TELEMETRY="$tmp/$request.tsv" "$LINT" "$tmp/a.sh" 2>&1) \
        || fail "a lint run with FM_LINT_ROOT_RSS_KIB=$request failed"$'\n'"$out"
    fi
    limit=$(awk -F '\t' '$1 == "meta" && $2 == "root_rss_limit_kib" { print $3 }' "$tmp/$request.roots.tsv")
    case "$request" in
      4194304)
        [ "$limit" = 4194304 ] || fail "a request of 4 GiB ran at '$limit' KiB, not 4194304"
        assert_not_contains "$out" "per-root cap" "a request below the default printed a clamp line"
        ! grep -q $'^meta\troot_rss_requested_kib\t' "$tmp/$request.roots.tsv" \
          || fail "a request below the default logged a requested value"
        ;;
      omitted)
        [ "$limit" = 8388608 ] || fail "an omitted setting ran at '$limit' KiB, not the 8388608 default"
        assert_not_contains "$out" "per-root cap" "an omitted setting printed a clamp line"
        ! grep -q $'^meta\troot_rss_requested_kib\t' "$tmp/$request.roots.tsv" \
          || fail "an omitted setting logged a requested value"
        ;;
      *)
        [ "$limit" = 8388608 ] || fail "a request of $request KiB ran at '$limit' KiB, not clamped to 8388608"
        assert_contains "$out" "FM_LINT_ROOT_RSS_KIB=$request is above the 8388608 KiB per-root cap; the lint runs at 8388608 KiB" \
          "the clamp of $request was not named on stderr"
        assert_grep $'meta\troot_rss_requested_kib\t'"$request" "$tmp/$request.roots.tsv" \
          "the roots log did not record the requested value $request"
        ;;
    esac
  done
  out=$(env FM_LINT_ROOT_RSS_KIB=0x PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/pool.bad" "$LINT" "$tmp/a.sh" 2>&1) && rc=0 || rc=$?
  [ "${rc:-0}" -eq 2 ] || fail "an invalid FM_LINT_ROOT_RSS_KIB exited ${rc:-0}, not 2"
  pass "a per-root limit of 9 GiB runs at 8 GiB with both values logged, a very long number is clamped, 4 GiB and the omitted default run as set, and an invalid value still exits 2"
}

test_a_high_host_slot_count_does_not_raise_the_memory_limit() {
  local tmp control capped most starts
  tmp=$(fm_test_tmproot fm-lint-slots-high)
  mkdir -p "$tmp/bin"
  for root in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$root.sh"; done
  fm_lint_write_memory_shellcheck "$tmp/bin" 64 "$tmp/mem.starts"
  # The control: with FM_LINT_HOST_SLOTS=100 and small charges (256 MiB per root)
  # four runs from four homes run several roots at once, so the count cap is not
  # what holds the other case back.
  control=$(fm_lint_memory_runs "$tmp" "$tmp/bin" 4 FM_LINT_SLOT_DIR="$tmp/control" \
    FM_LINT_HOST_SLOTS=100 FM_LINT_ROOT_RSS_KIB=262144)
  read -r most starts <<<"$control"
  [ "$most" -ge 3 ] || fail "four runs with FM_LINT_HOST_SLOTS=100 and small charges peaked at only $most roots at once, so this test cannot show the memory limit: $control"
  # The same four runs with the default per-root charge, 8 GiB, above the whole
  # budget: FM_LINT_HOST_SLOTS=100 leaves each root alone in the pool and every
  # root completes. A completed root would leave a memory record (where
  # /usr/bin/time or the macOS watch measures it) that lowers the next run's charge
  # for the same root, so this pool's history path is a plain file and no record
  # forms: every root keeps the default charge.
  mkdir -p "$tmp/capped"
  : > "$tmp/capped/history"
  capped=$( unset FM_LINT_ROOT_RSS_KIB
    fm_lint_memory_runs "$tmp" "$tmp/bin" 4 FM_LINT_SLOT_DIR="$tmp/capped" FM_LINT_HOST_SLOTS=100 FM_TEST_MEM_HOLD=0.4 )
  read -r most starts <<<"$capped"
  [ "$most" -eq 1 ] || fail "four runs with FM_LINT_HOST_SLOTS=100 and the default per-root charge ran $most roots at once, expected one: $capped"
  [ "$starts" -eq 12 ] || fail "$starts of 12 roots completed with FM_LINT_HOST_SLOTS=100: $capped"
  pass "FM_LINT_HOST_SLOTS=100 does not raise the memory limit: four runs from four homes with the default charge run one root at a time and finish all 12 (small charges: $control; default charge: $capped)"
}

# The cap the watch holds is not shown by the roots log alone: the fake process
# helper answers every reading with a footprint the test chooses, so the cap the
# watch received shows in whether it ends the root. No memory is allocated. With
# the setting omitted the watch holds the 8 GiB default; a request of 9 GiB is
# clamped to it; a request of 4 GiB is held as asked. The roots log's applied
# value is corroborated by the same decision.
test_the_watch_receives_the_default_cap_and_the_clamped_request() {
  local tmp out n=0 spec request reading expect applied flags requested
  for spec in "omitted|9000000|ended|8388608" "omitted|8300000|left|8388608" \
    "9437184|9000000|ended|8388608" "9437184|8300000|left|8388608" \
    "4194304|4300000|ended|4194304" "4194304|4000000|left|4194304"; do
    n=$((n + 1))
    IFS='|' read -r request reading expect applied <<<"$spec"
    tmp=$(fm_test_tmproot "fm-lint-rss-sim-$n")
    requested=$request
    [ "$request" != omitted ] || requested=
    if ! fm_lint_footprint_lint "$tmp" FM_TEST_PY_MEMORY="1024 $reading" FM_LINT_ROOT_RSS_KIB="$requested" FM_TEST_GROW_HOLD=4; then
      pass "SKIP (the resident-memory watch runs only on macOS): simulated cap check"
      return
    fi
    out=$(cat "$tmp/out")
    [ "$(cat "$tmp/rc")" -eq 0 ] || fail "case $spec: the lint failed (exit $(cat "$tmp/rc"))"$'\n'"$out"
    flags=$(cat "$tmp/flags.log")
    case "$expect" in
      ended) [ "$flags" = "$(printf 'yes\nno')" ] || fail "case $spec: a simulated reading of $reading KiB did not end the root at the cap of $applied KiB"$'\n'"$flags" ;;
      left) [ "$flags" = yes ] || fail "case $spec: a simulated reading of $reading KiB below the cap of $applied KiB ended the root"$'\n'"$flags" ;;
    esac
    assert_grep $'meta\troot_rss_limit_kib\t'"$applied" "$tmp/pass.roots.tsv" "case $spec: the roots log did not show the applied limit $applied"
  done
  pass "the watch ends a simulated 9000000 KiB tree at the default cap and at a 9 GiB request clamped to it, leaves 8300000 KiB alone, and holds a 4 GiB request as asked, with the roots log's applied value matching each decision"
}

# fm_lint_write_tree_shellcheck <fakebin>: a stand-in whose memory sits in a tree.
# The root holds FM_TEST_TREE_MID_MB. Its child starts a grandchild that holds
# FM_TEST_TREE_ORPHAN_MB, then leaves after three seconds, so the grandchild is an
# orphan; the root then grows by FM_TEST_TREE_LATE_MB. Each part is under any cap
# the tests use alone; only the tree total is over it.
fm_lint_write_tree_shellcheck() {
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
  my ($mid, $orphan, $late, $orphan_pid_file) = @ARGV;
  my $held = "x" x ($mid * 1048576);
  my $kid = fork();
  if (!$kid) {
    my $grand = fork();
    if (!$grand) {
      if (open(my $fh, ">", $orphan_pid_file)) { print {$fh} "$$\n"; close $fh; }
      my $g = "x" x ($orphan * 1048576);
      sleep 40;
      exit 0;
    }
    sleep 3;
    exit 0;
  }
  waitpid($kid, 0);
  $held .= "x" x ($late * 1048576) if $late > 0;
  sleep 40;' "$FM_TEST_TREE_MID_MB" "$FM_TEST_TREE_ORPHAN_MB" "$FM_TEST_TREE_LATE_MB" "$FM_TEST_ORPHAN_PID_FILE"
SH
  chmod +x "$1/shellcheck"
}

# A root whose memory sits in descendants is ended at the cap: the child and the
# grandchild are read while the child lives, and the orphan the grandchild
# becomes is still read after the child is gone. Each part is under the cap
# alone, so only a reader that follows the whole tree ends it. The control has
# the same tree shape under the cap and is left alone.
test_resident_watch_ends_a_tree_whose_memory_sits_in_descendants_and_an_orphan() {
  local tmp fakebin fixture out rc flags_log started case_name late orphan_pid
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the resident-memory watch runs only on macOS): descendant tree check"
    return
  fi
  for case_name in over control; do
    tmp=$(fm_test_tmproot "fm-lint-rss-tree-$case_name")
    fakebin=$(fm_fakebin "$tmp")
    fixture="$tmp/tree.sh"
    flags_log="$tmp/flags.log"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture"
    fm_lint_write_tree_shellcheck "$fakebin"
    : > "$flags_log"
    late=40
    [ "$case_name" = over ] || late=0
    rc=0
    started=$SECONDS
    out=$(PATH="$fakebin:$PATH" FM_LINT_JOBS=1 FM_LINT_REQUIRE_BOUNDS=0 FM_LINT_ROOT_RSS_KIB=102400 \
      FM_TEST_FLAGS_LOG="$flags_log" FM_TEST_PID_FILE="$tmp/root.pid" FM_TEST_ORPHAN_PID_FILE="$tmp/orphan.pid" \
      FM_TEST_TREE_MID_MB=30 FM_TEST_TREE_ORPHAN_MB=40 FM_TEST_TREE_LATE_MB="$late" \
      "$LINT" --telemetry "$tmp/pass.tsv" "$fixture" 2>&1) || rc=$?
    orphan_pid=$(cat "$tmp/orphan.pid" 2>/dev/null || true)
    if [ "$case_name" = over ]; then
      [ "$rc" -eq 0 ] || fail "the tree over the cap did not pass its narrower retry (exit $rc)"$'\n'"$out"
      [ "$((SECONDS - started))" -lt 30 ] || fail "the tree over the cap was not ended: lint waited out the stand-in"
      [ "$(cat "$flags_log")" = "$(printf 'yes\nno')" ] \
        || fail "a tree whose memory sits in descendants and an orphan was not ended at the cap"$'\n'"$(cat "$flags_log")"
      assert_contains "$out" "hit the memory ceiling with --external-sources" "the end of the tree was not identified in the output"
    else
      # The control is left alone, so its stand-in sleeps 40 s: end it by hand.
      kill -KILL "$(cat "$tmp/root.pid" 2>/dev/null || echo 0)" 2>/dev/null || true
    fi
    [ -z "$orphan_pid" ] || ! kill -0 "$orphan_pid" 2>/dev/null || { kill -KILL "$orphan_pid" 2>/dev/null; fail "$case_name: the orphan $orphan_pid outlived the lint"; }
  done
  pass "a root whose memory sits in a child, a grandchild and the orphan it becomes is ended at the cap, and the same tree under the cap is left alone"
}

# No route sets a lint run's host-wide memory budget: the environment (the
# refused name, the old fixture name and the private helper name), a command-line
# flag, and a file in the local slot directory or in HOME are each tried. The
# run is refused or its budget stays the fixed value, and two roots recorded at
# 2 GiB each (4 GiB together, above the 3.5 GiB budget) never hold their memory
# at once under any of them.
test_no_route_sets_a_runs_budget() {
  local tmp rc out kib real key route run pid
  local -a pids
  tmp=$(fm_test_tmproot fm-lint-budget-routes)
  mkdir -p "$tmp/bin" "$tmp/home/.cache"
  for run in a b; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$run.sh"; done
  fm_lint_write_memory_shellcheck "$tmp/bin" 48 "$tmp/mem.starts"
  # A refused route: the run exits 2 and starts no analysis.
  : > "$tmp/mem.starts"
  rc=0
  out=$(env FM_LINT_HOST_RSS_KIB=1 PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/pool.env" "$LINT" "$tmp/a.sh" 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "FM_LINT_HOST_RSS_KIB was not refused (exit $rc)"$'\n'"$out"
  assert_contains "$out" FM_LINT_HOST_RSS_KIB "the refusal did not name FM_LINT_HOST_RSS_KIB"
  [ ! -s "$tmp/mem.starts" ] || fail "a refused route still started an analysis"
  # A flag route: the flag is refused, or the run's published budget stays the
  # fixed value (the lint knows no flag that sets it).
  for route in --host-rss-kib=1 --budget=1 --memory-budget=1 --host-budget=1; do
    rc=0
    out=$(env PATH="$tmp/bin:$PATH" FM_LINT_SLOT_DIR="$tmp/pool.flag" FM_LINT_TELEMETRY="$tmp/flag.tsv" FM_TEST_MEM_HOLD=0.2 \
      "$LINT" "$route" "$tmp/a.sh" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
      kib=$(awk -F '\t' '$1 == "meta" && $2 == "host_memory_budget_kib" { print $3 }' "$tmp/flag.roots.tsv")
      [ "$kib" = 3670016 ] || fail "the flag $route changed the published budget to '$kib' KiB"$'\n'"$out"
    fi
    rm -f "$tmp/flag.roots.tsv" "$tmp/flag.tsv"
  done
  # Routes that are ignored: the old fixture name, the private helper name, and
  # files in the places a run reads state from (the local slot directory, HOME).
  real=$(cd -P "$tmp" && pwd -P)
  mkdir -p "$tmp/pool.ignored/history"
  for run in a b; do
    key=$(printf 'full:%s' "$real/$run.sh" | perl -MDigest::SHA=sha256_hex -ne 'print sha256_hex($_)')
    printf '%s %s\n' 2097152 "$(wc -c < "$tmp/$run.sh" | tr -d ' ')" > "$tmp/pool.ignored/history/$key"
  done
  for route in host_rss_kib budget host-budget host_memory_budget_kib; do
    printf '100000000\n' > "$tmp/pool.ignored/$route"
    printf '100000000\n' > "$tmp/home/.cache/$route"
  done
  : > "$tmp/mem.starts"
  : > "$tmp/mem.starts.spans"
  pids=()
  for run in 1 2; do
    mkdir -p "$tmp/home.$run/.cache"
    env HOME="$tmp/home.$run" XDG_CACHE_HOME="$tmp/home.$run/.cache" FM_HOME="$tmp/fm.$run" \
      FM_LINT_SLOT_DIR="$tmp/pool.ignored" FM_LINT_HOST_SLOTS=9 FM_LINT_FIXTURE_HOST_RSS_KIB=100000000 \
      FM_LINT_INTERNAL_HOST_RSS_KIB=100000000 FM_LINT_ROOT_RSS_KIB=2000000 FM_TEST_MEM_HOLD=1.5 \
      FM_LINT_TELEMETRY="$tmp/ignored.$run.tsv" PATH="$tmp/bin:$PATH" \
      "$LINT" --jobs 1 "$tmp/a.sh" "$tmp/b.sh" > "$tmp/ignored.$run.out" 2>&1 &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || fail "a run with the ignored routes failed"$'\n'"$(cat "$tmp"/ignored.*.out)"
  done
  kib=$(awk -F '\t' '$1 == "meta" && $2 == "host_memory_budget_kib" { print $3 }' "$tmp/ignored.1.roots.tsv")
  [ "$kib" = 3670016 ] || fail "an ignored route changed the published budget to '$kib' KiB"
  [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -eq 4 ] || fail "not every root ran under the ignored routes"
  [ "$(fm_lint_max_overlap "$tmp/mem.starts.spans")" -eq 1 ] \
    || fail "two roots recorded at 2 GiB each held their memory at once: an ignored route raised the budget"$'\n'"$(cat "$tmp/mem.starts.spans")"
  pass "the refused name is refused, four flags are refused or leave the budget at 3670016 KiB, and the old fixture name, the private helper name and four budget files in the local slot directory and in HOME leave the budget at 3670016 KiB and keep two 2 GiB roots apart"
}

# The service order and the wait bound are recorded: four runs from four homes,
# the fourth arriving later, each selecting three roots charged more than the whole
# budget, so the roots are served one at a time. The bound is stated before the
# run: no root waits longer than every root ahead of it plus a margin of 3 s per
# root for admission. Every run is served and finishes, and the order is printed.
test_a_waiting_run_is_served_within_a_stated_wait_bound() {
  local tmp run root pid rc order bound_ms hold_ms=1000 margin_ms=3000 total=12 worst late
  local -a pids
  tmp=$(fm_test_tmproot fm-lint-wait-bound)
  mkdir -p "$tmp/bin"
  # Twelve distinct root files, so that no root has a recorded peak and every root
  # is charged the 8 GiB default, above the whole budget.
  for run in 1 2 3 4; do
    for root in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/r$run.$root.sh"; done
  done
  fm_lint_write_memory_shellcheck "$tmp/bin" 32 "$tmp/mem.starts"
  : > "$tmp/mem.starts"
  : > "$tmp/mem.starts.spans"
  bound_ms=$((total * (hold_ms + margin_ms)))
  pids=()
  for run in 1 2 3 4; do
    mkdir -p "$tmp/home.$run/.cache"
    if [ "$run" -eq 4 ]; then sleep 1.5; fi
    ( unset FM_LINT_ROOT_RSS_KIB
      env HOME="$tmp/home.$run" XDG_CACHE_HOME="$tmp/home.$run/.cache" FM_HOME="$tmp/fm.$run" \
        FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_HOST_SLOTS=9 FM_TEST_MEM_HOLD=1 FM_LINT_TELEMETRY="$tmp/run.$run.tsv" \
        PATH="$tmp/bin:$PATH" "$LINT" --jobs 2 "$tmp/r$run.a.sh" "$tmp/r$run.b.sh" "$tmp/r$run.c.sh" > "$tmp/run.$run.out" 2>&1 ) &
    pids+=("$!")
  done
  rc=0
  for pid in "${pids[@]}"; do wait "$pid" || rc=$?; done
  [ "$rc" -eq 0 ] || fail "a run failed while it waited (rc=$rc)"$'\n'"$(cat "$tmp"/run.?.out)"
  [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -eq "$total" ] || fail "not every one of the $total roots was served"
  [ "$(fm_lint_max_overlap "$tmp/mem.starts.spans")" -eq 1 ] || fail "two roots charged above the budget ran at once"
  worst=0
  for run in 1 2 3 4; do
    late=$(awk -F '\t' '$1 == "end" { if ($17 + 0 > m) m = $17 + 0 } END { print m + 0 }' "$tmp/run.$run.roots.tsv")
    [ "$late" -le "$bound_ms" ] || fail "run $run waited $late ms for a root, above the stated bound of $bound_ms ms"
    [ "$late" -le "$worst" ] || worst=$late
  done
  # The service order: every root of every run by the time it was admitted (its
  # request time plus its queue wait), relative to the first, in the order served.
  order=$(for run in 1 2 3 4; do
    awk -F '\t' -v run="$run" '$1 == "end" { printf "%s run%s:%s\n", $6 + $17, run, $3 }' "$tmp/run.$run.roots.tsv"
  done | sort -n | awk 'NR == 1 { first = $1 } { n = split($2, p, "/"); printf " %s+%dms", substr($2, 1, index($2, ":") - 1), $1 - first }')
  pass "four runs queued behind roots charged above the budget were all served, one root at a time, each root within the stated wait bound of $bound_ms ms (longest wait of a run's roots $worst ms; roots in the order served:$order)"
}

# A root charged more than the whole budget but at most R runs inside the admission
# and alone: two concurrent runs whose roots carry a recorded 5 GiB peak (so each is
# charged above the budget) never hold memory at once, each root completes, and the
# second run's roots wait. The stand-in itself allocates 32 MiB: this proves the
# handling of an oversized charge, not a root that actually holds more than the budget.
test_a_five_gib_root_runs_alone_inside_the_admission() {
  local tmp run real key root rc pid
  local -a pids
  tmp=$(fm_test_tmproot fm-lint-five-gib)
  mkdir -p "$tmp/bin" "$tmp/pool/history"
  for root in a b; do printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/$root.sh"; done
  fm_lint_write_memory_shellcheck "$tmp/bin" 32 "$tmp/mem.starts"
  real=$(cd -P "$tmp" && pwd -P)
  for root in a b; do
    key=$(printf 'full:%s' "$real/$root.sh" | perl -MDigest::SHA=sha256_hex -ne 'print sha256_hex($_)')
    printf '%s %s\n' 5242880 "$(wc -c < "$tmp/$root.sh" | tr -d ' ')" > "$tmp/pool/history/$key"
  done
  : > "$tmp/mem.starts"
  : > "$tmp/mem.starts.spans"
  pids=()
  for run in 1 2; do
    mkdir -p "$tmp/home.$run/.cache"
    ( unset FM_LINT_ROOT_RSS_KIB
      env HOME="$tmp/home.$run" XDG_CACHE_HOME="$tmp/home.$run/.cache" FM_HOME="$tmp/fm.$run" \
        FM_LINT_SLOT_DIR="$tmp/pool" FM_LINT_HOST_SLOTS=9 FM_TEST_MEM_HOLD=1.5 FM_LINT_TELEMETRY="$tmp/five.$run.tsv" \
        PATH="$tmp/bin:$PATH" "$LINT" --jobs 1 "$tmp/a.sh" "$tmp/b.sh" > "$tmp/five.$run.out" 2>&1 ) &
    pids+=("$!")
  done
  rc=0
  for pid in "${pids[@]}"; do wait "$pid" || rc=$?; done
  [ "$rc" -eq 0 ] || fail "a run with 5 GiB roots failed"$'\n'"$(cat "$tmp"/five.?.out)"
  [ "$(wc -l < "$tmp/mem.starts" | tr -d ' ')" -eq 4 ] || fail "not every 5 GiB root completed"
  [ "$(fm_lint_max_overlap "$tmp/mem.starts.spans")" -eq 1 ] || fail "two 5 GiB roots held their memory at once"$'\n'"$(cat "$tmp/mem.starts.spans")"
  [ "$(awk -F '\t' '$1 == "end" { if ($17 + 0 > m) m = $17 + 0 } END { print m + 0 }' "$tmp/five.1.roots.tsv" "$tmp/five.2.roots.tsv")" -ge 1000 ] \
    || fail "no 5 GiB root waited for another"
  pass "four roots charged from a recorded 5 GiB peak (above the 3.5 GiB budget, below R; each stand-in holds 32 MiB) from two runs complete one at a time inside the admission, with queue waits recorded"
}

# The directory that holds the host-wide budget state is part of the failed
# states: a copy of the lint whose host-wide directory is a plain file, or a
# symbolic link, refuses before any root starts, names the path and the fix, and
# starts no analysis. The copy differs from the shipped script only in that
# directory's path, so the test never touches the real host-wide state.
test_an_unusable_host_wide_budget_directory_refuses_before_any_root_starts() {
  local tmp rc out kind
  tmp=$(fm_test_tmproot fm-lint-host-dir)
  mkdir -p "$tmp/repo" "$tmp/bin" "$tmp/real"
  cp -R "$ROOT/bin" "$tmp/repo/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  fm_lint_write_memory_shellcheck "$tmp/bin" 1 "$tmp/mem.starts"
  for kind in file symlink; do
    : > "$tmp/mem.starts"
    rm -rf "$tmp/host.$kind"
    if [ "$kind" = file ]; then : > "$tmp/host.$kind"; else ln -s "$tmp/real" "$tmp/host.$kind"; fi
    perl -pi -e "s{^HOST_POOL_ROOT=.*\$}{HOST_POOL_ROOT=$tmp/host.$kind}" "$tmp/repo/bin/fm-lint.sh"
    grep -q "^HOST_POOL_ROOT=$tmp/host.$kind\$" "$tmp/repo/bin/fm-lint.sh" || fail "the copy's host-wide directory path was not replaced"
    rc=0
    out=$(env -u FM_LINT_SLOT_DIR PATH="$tmp/bin:$PATH" "$tmp/repo/bin/fm-lint.sh" "$tmp/a.sh" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "a host-wide directory that is a $kind exited $rc, expected 2"$'\n'"$out"
    assert_contains "$out" "$tmp/host.$kind" "the refusal did not name the unusable host-wide path ($kind)"
    assert_contains "$out" "host slot pool unusable" "the refusal did not say the pool is unusable ($kind)"
    assert_not_contains "$out" "running without the host-wide ShellCheck bound" "an unusable host-wide directory still ran unbounded ($kind)"
    [ ! -s "$tmp/mem.starts" ] || fail "an unusable host-wide directory ($kind) still started ShellCheck"
  done
  pass "a host-wide budget directory that is a plain file or a symbolic link is refused with its path named, before any root starts"
}

# --- Round 6 (outside review of 4c1247c8f): no test below sends a real signal. ---
# Every process a test starts ends on its own (a time limit or a release file);
# every send the watch or the gate makes goes through the identity helper, which
# the stub python records instead of sending (fm_lint_write_stub_python).

# fm_lint_fail_settled <message>: fail, after the test's release files exist and
# every background job of the test has ended on its own (each is bounded by a time
# limit or a release file), so the test library's cleanup finds no job to signal.
# A test names its release files in FM_LINT_RELEASE_FILES.
fm_lint_fail_settled() {
  local release
  for release in ${FM_LINT_RELEASE_FILES:-}; do : > "$release"; done
  wait 2>/dev/null || true
  fail "$@"
}

# fm_lint_isolated_copy <tmp> <label>: a small repository whose bin/fm-lint.sh has
# its host-wide directory (pool, host lock, ledger, probe lane) under <tmp>/<label>/host,
# so nothing the test does reaches the host's own /var/tmp directory. Prints the
# repository path.
fm_lint_isolated_copy() {
  local tmp=$1 label=$2 repo
  repo="$tmp/$label/repo"
  mkdir -p "$tmp/$label/host"
  fm_lint_small_repo "$repo"
  perl -pi -e "s{^HOST_POOL_ROOT=.*\$}{HOST_POOL_ROOT=$tmp/$label/host}" "$repo/bin/fm-lint.sh"
  grep -q "^HOST_POOL_ROOT=$tmp/$label/host\$" "$repo/bin/fm-lint.sh" || fm_lint_fail_settled "the copy's host-wide directory path was not replaced"
  printf '%s\n' "$repo"
}

# fm_lint_write_logging_shellcheck <dir> <starts log> [<version file>]: a script
# ShellCheck stand-in that appends every invocation's arguments to <starts log>,
# answers --version with the version in <version file> (0.11.0 without one), read
# when the probe starts and printed FM_TEST_PROBE_SECS seconds later, and otherwise prints one finding for the root and
# exits FM_TEST_ANALYSIS_RC (1 by default) after FM_TEST_ANALYSIS_SECS seconds.
fm_lint_write_logging_shellcheck() {
  local dir=$1 log=$2 version=${3:-}
  mkdir -p "$dir"
  cat > "$dir/shellcheck" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
if [ "\${1:-}" = --version ]; then
  v=0.11.0
  [ -z '$version' ] || v=\$(cat '$version')
  sleep "\${FM_TEST_PROBE_SECS:-0}"
  printf 'ShellCheck - shell script analysis tool\nversion: %s\n' "\$v"
  exit 0
fi
sleep "\${FM_TEST_ANALYSIS_SECS:-0}"
for a in "\$@"; do last=\$a; done
printf 'In %s line 1:\nSC9999 (warning): stand-in finding\n' "\$last"
exit "\${FM_TEST_ANALYSIS_RC:-1}"
SH
  chmod +x "$dir/shellcheck"
}

# fm_lint_hold_ledger_entry <ledger dir> <charge KiB> <release file> <ready file>:
# a background holder that writes a live ledger entry (its own pid, the charge, no
# peak file) and keeps its flock until <release file> exists (60 s at most), the
# way an admitted root holds its entry. It ends on its own.
fm_lint_hold_ledger_entry() {
  mkdir -p "$1"
  perl -MFcntl=:flock -MTime::HiRes=sleep,time -e '
    my ($dir, $charge, $release, $ready) = @ARGV;
    my $path = "$dir/entry.$$.1";
    open(my $fh, ">>", $path) or die "$!";
    flock($fh, LOCK_EX) or die "$!";
    truncate($fh, 0); syswrite($fh, "$$\t$charge\t$dir/none.peak\n");
    open(my $r, ">", $ready) or die "$!"; print {$r} "$path\n"; close $r;
    my $until = time() + 60;
    sleep 0.05 until -e $release || time() > $until;
    unlink $path;' "$@" &
}

# (F3) The ledger is read under the host lock, immediately before the decision.
# A copy of the gate helper pauses pool B's gate right after it has read the ledger
# (the anchor is the ledger read's return, present at every revision); while it is
# paused, pool A's gate tries to admit. Reading the ledger before the lock lets A
# admit and B then decide on its stale, empty reading: both run, their charges
# (A unrecorded, 256 MiB; B recorded, 174 MiB) together above the 300,000 KiB budget.
# Reading it under the lock makes A wait for B's decision, which then sees B's entry.
# Prints "<most at once> <starts> <ends> <A entry seen during the pause: yes|no>".
fm_lint_forced_ledger_schedule() {
  local tmp=$1 label=$2 budget=$3 copy a b pid_a pid_b waited seen=no bytes key rc=0
  copy="$tmp/$label/helper"
  mkdir -p "$copy" "$tmp/$label/pause"
  cp "$ROOT/bin/fm-lint-cache.pl" "$ROOT/bin/fm-proc-info.py" "$copy/"
  perl -0pi -e 's{\n(\s*)return \@live;\n}{\n$1if ((\$ENV{FM_TEST_PAUSE_RUN} // q()) eq \$run && !-e "\$ENV{FM_TEST_PAUSE_DIR}/paused") { open(my \$m, q(>), "\$ENV{FM_TEST_PAUSE_DIR}/paused"); close \$m; my \$until = Time::HiRes::time() + 8; Time::HiRes::sleep(0.02) until -e "\$ENV{FM_TEST_PAUSE_DIR}/go" || Time::HiRes::time() > \$until; }\n$1return \@live;\n}' "$copy/fm-lint-cache.pl"
  grep -q 'FM_TEST_PAUSE_RUN' "$copy/fm-lint-cache.pl" || fm_lint_fail_settled "the pause was not inserted after the ledger read"
  a="$tmp/$label.a.sh"
  b="$tmp/$label.b.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$a"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$b"
  bytes=$(wc -c < "$b" | tr -d ' ')
  key=$(printf 'full:%s' "$b" | perl -MDigest::SHA=sha256_hex -ne 'print sha256_hex($_)')
  mkdir -p "$tmp/$label/poolB/history"
  printf '102400 %s\n' "$bytes" > "$tmp/$label/poolB/history/$key"
  : > "$tmp/barrier.log"
  # B first: it pauses after reading the (empty) ledger.
  env FM_TEST_PAUSE_RUN="${label}b" FM_TEST_PAUSE_DIR="$tmp/$label/pause" FM_TEST_BARRIER=2 FM_TEST_BARRIER_SECS=4 \
    FM_TEST_MEM_MIB=100 FM_TEST_MEM_HOLD=2 PATH="$tmp/bin:$PATH" \
    FM_LINT_INTERNAL_HOST_RSS_KIB="$budget" FM_LINT_INTERNAL_ROOT_KEY="full:$b" FM_LINT_INTERNAL_ROOT_BYTES="$bytes" \
    FM_LINT_INTERNAL_ROOT_CAP_KIB=262144 FM_LINT_INTERNAL_HOST_LOCK="$tmp/$label/host.lock" FM_LINT_HOST_SLOTS=9 \
    perl "$copy/fm-lint-cache.pl" gate "$tmp/$label/poolB" 18 "${label}b" "$tmp/$label/b.wait" -- \
    "$tmp/bin/shellcheck" --norc -- "$b" > "$tmp/$label.b.out" 2>&1 &
  pid_b=$!
  waited=0
  while [ ! -e "$tmp/$label/pause/paused" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$tmp/$label/pause/paused" ] || fm_lint_fail_settled "pool B's gate never reached the ledger read ($label)"
  # A while B is paused.
  env FM_TEST_BARRIER=2 FM_TEST_BARRIER_SECS=4 FM_TEST_MEM_MIB=200 FM_TEST_MEM_HOLD=2 PATH="$tmp/bin:$PATH" \
    FM_LINT_INTERNAL_HOST_RSS_KIB="$budget" FM_LINT_INTERNAL_ROOT_KEY="full:$a" FM_LINT_INTERNAL_ROOT_BYTES="$(wc -c < "$a" | tr -d ' ')" \
    FM_LINT_INTERNAL_ROOT_CAP_KIB=262144 FM_LINT_INTERNAL_HOST_LOCK="$tmp/$label/host.lock" FM_LINT_HOST_SLOTS=9 \
    perl "$copy/fm-lint-cache.pl" gate "$tmp/$label/poolA" 18 "${label}a" "$tmp/$label/a.wait" -- \
    "$tmp/bin/shellcheck" --norc -- "$a" > "$tmp/$label.a.out" 2>&1 &
  pid_a=$!
  # Up to 3 s for A's admission to show in the ledger; then B goes on.
  waited=0
  while [ "$waited" -lt 30 ]; do
    if [ -n "$(find "$tmp/$label/host.lock.ledger" -name "entry.$pid_a.*" -print 2>/dev/null)" ]; then seen=yes; break; fi
    sleep 0.1
    waited=$((waited + 1))
  done
  : > "$tmp/$label/pause/go"
  wait "$pid_a" || rc=$?
  wait "$pid_b" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || fm_lint_fail_settled "a gate of the forced schedule failed ($label, rc=$rc)"$'\n'"$(cat "$tmp/$label".?.out)"
  printf '%s %s %s %s\n' \
    "$(perl -ane '$live++ if $F[0] eq "start"; $live-- if $F[0] eq "end"; $max = $live if $live > $max; END { print $max + 0 }' "$tmp/barrier.log")" \
    "$(grep -c '^start ' "$tmp/barrier.log")" "$(grep -c '^end ' "$tmp/barrier.log")" "$seen"
}

test_a_gate_reads_the_ledger_under_the_host_lock_so_a_root_admitted_meanwhile_counts() {
  local tmp most starts ends seen
  tmp=$(fm_test_tmproot fm-lint-forced-ledger)
  mkdir -p "$tmp/bin"
  fm_lint_write_barrier_shellcheck "$tmp/bin" 64 "$tmp/barrier.log"
  # Scale: the review's example is two roots of 8 GiB and 3,254 MiB charge against
  # a 3,584 MiB budget; here the same shape is 256 MiB and 174 MiB against 300,000 KiB.
  read -r most starts ends seen <<<"$(fm_lint_forced_ledger_schedule "$tmp" forced 300000)"
  { [ "$starts" -eq 2 ] && [ "$ends" -eq 2 ]; } || fm_lint_fail_settled "$starts starts and $ends ends: both roots must finish (a deadlock would also look like one at a time)"
  [ "$most" -eq 1 ] || fm_lint_fail_settled "$most roots ran at once: pool B decided on a ledger read before the host lock and missed the root pool A admitted meanwhile (A's entry seen during the pause: $seen)"
  [ "$seen" = no ] || fm_lint_fail_settled "pool A admitted a root while pool B held the host lock for its decision"
  # Control 1, legitimate sharing: with a budget that fits both charges the same
  # schedule runs both roots at once.
  read -r most starts ends seen <<<"$(fm_lint_forced_ledger_schedule "$tmp" fits 100000000)"
  { [ "$most" -eq 2 ] && [ "$starts" -eq 2 ] && [ "$ends" -eq 2 ]; } \
    || fm_lint_fail_settled "with a budget that fits both charges the roots did not share it ($most at once, $starts starts, $ends ends)"
  # Control 2, an oversized root runs alone: a budget below A's 256 MiB charge
  # still admits A when nothing else runs, and both roots finish.
  read -r most starts ends seen <<<"$(fm_lint_forced_ledger_schedule "$tmp" oversized 200000)"
  { [ "$most" -eq 1 ] && [ "$starts" -eq 2 ] && [ "$ends" -eq 2 ]; } \
    || fm_lint_fail_settled "with a root above the budget the roots did not each run alone and finish ($most at once, $starts starts, $ends ends)"
  wait 2>/dev/null || true
  pass "a gate reads the host ledger under the host lock: a root pool A tried to admit while pool B decided waited, both finished, one at a time; a budget that fits both runs them together; a root above the budget runs alone"
}

# (F3) A live ledger entry that cannot be opened is a charge the gate cannot
# account for: the gate refuses and names it, never skips it. The control: the
# same entry, readable, holds the budget (the root waits) and the root starts once
# the entry is released.
test_a_live_ledger_entry_that_cannot_be_opened_refuses_the_admission() {
  local tmp root entry rc=0 pid waited
  tmp=$(fm_test_tmproot fm-lint-unreadable-entry)
  FM_LINT_RELEASE_FILES="$tmp/release"
  mkdir -p "$tmp/bin"
  fm_lint_write_barrier_shellcheck "$tmp/bin" 8 "$tmp/barrier.log"
  root="$tmp/a.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root"
  : > "$tmp/barrier.log"
  fm_lint_hold_ledger_entry "$tmp/host.lock.ledger" 3000000 "$tmp/release" "$tmp/ready"
  waited=0
  while [ ! -s "$tmp/ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  entry=$(cat "$tmp/ready")
  chmod 000 "$entry"
  FM_TEST_MEM_HOLD=0.2 PATH="$tmp/bin:$PATH" fm_lint_gate_root 3100000 "$tmp/pool" unreadable "$root" -- \
    "$tmp/bin/shellcheck" --norc -- "$root" > "$tmp/unreadable.out" 2>&1 || rc=$?
  chmod 600 "$entry"
  [ "$rc" -eq 2 ] || { : > "$tmp/release"; fm_lint_fail_settled "a gate beside a live ledger entry it cannot open exited $rc, expected the refusal (2): $(cat "$tmp/unreadable.out")"; }
  [ ! -s "$tmp/barrier.log" ] || { : > "$tmp/release"; fm_lint_fail_settled "a gate admitted a root beside a live ledger entry it could not read"; }
  grep -qF "$entry" "$tmp/unreadable.out" || { : > "$tmp/release"; fm_lint_fail_settled "the refusal did not name the entry: $(cat "$tmp/unreadable.out")"; }
  # The control: readable, the same entry's 3,000,000 KiB charge keeps the 262,144
  # KiB root out of the 3,100,000 KiB budget until it is released.
  rc=0
  FM_TEST_MEM_HOLD=0.2 PATH="$tmp/bin:$PATH" fm_lint_gate_root 3100000 "$tmp/pool" readable "$root" -- \
    "$tmp/bin/shellcheck" --norc -- "$root" > "$tmp/readable.out" 2>&1 &
  pid=$!
  sleep 2
  [ ! -s "$tmp/barrier.log" ] || { : > "$tmp/release"; wait "$pid"; fm_lint_fail_settled "a root started beside a readable entry whose charge fills the budget"; }
  : > "$tmp/release"
  wait "$pid" || rc=$?
  [ "$rc" -eq 0 ] || fm_lint_fail_settled "the root did not start and finish once the entry was released (rc=$rc): $(cat "$tmp/readable.out")"
  [ "$(grep -c '^start ' "$tmp/barrier.log")" -eq 1 ] || fm_lint_fail_settled "the root did not start after the release"
  [ "$(cat "$tmp/pool.wait.readable")" -ge 1500 ] || fm_lint_fail_settled "the recorded wait $(cat "$tmp/pool.wait.readable") ms is shorter than the entry was held"
  wait 2>/dev/null || true
  pass "a live ledger entry the gate cannot open refuses the admission and names the entry; readable, its charge holds the budget and the root starts once it ends"
}

# A changed-mode run with no lint target leaves no run entry in the host ledger.
# The control: the run reached the ledger, so its entry was created and then removed.
test_a_run_with_no_changed_target_leaves_no_run_entry() {
  local tmp repo diff_file rc=0 entries
  tmp=$(fm_test_tmproot fm-lint-no-target-entry)
  repo=$(fm_lint_isolated_copy "$tmp" notarget)
  fm_lint_write_logging_shellcheck "$tmp/fake" "$tmp/starts.log"
  fm_lint_stub_git "$tmp/fake"
  diff_file="$tmp/diff.nul"
  : > "$diff_file"
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_GIT_BRANCH=feature \
      FM_TEST_GIT_DIFF_FILE="$diff_file" bash bin/fm-lint.sh > "$tmp/run.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] || fm_lint_fail_settled "a run with no changed target exited $rc: $(cat "$tmp/run.out")"
  grep -q 'no changed lint targets' "$tmp/run.out" || fm_lint_fail_settled "the run did not take the no-target path: $(cat "$tmp/run.out")"
  [ -d "$tmp/notarget/host/admission.lock.ledger" ] || fm_lint_fail_settled "the run did not reach the host ledger"
  entries=$(find "$tmp/notarget/host/admission.lock.ledger" -name 'run.*' -print)
  [ -z "$entries" ] || fm_lint_fail_settled "the no-target run left its run entry in the ledger: $entries"
  pass "a run with no changed lint target removes its run entry from the host ledger"
}

# fm_lint_write_owner_stand_in <dir> <repo> <stub python>: a script named
# fm-lint.sh (so it is recognised as a lint owner) that writes a run entry into the
# copy's host ledger the way bin/fm-lint.sh does, holds its flock on descriptor 9,
# and runs the rest of its arguments as its child with FM_LINT_INTERNAL_RUN_ENTRY
# set. The run entry names the given python and the bound mechanism and limits in
# FM_TEST_RUN_BOUNDED, FM_TEST_RUN_MEMORY_KIB and FM_TEST_RUN_RSS_KIB
# (none, 12582912 and 262144 by default).
fm_lint_write_owner_stand_in() {
  local dir=$1 repo=$2 python=$3 perl_bin
  perl_bin=$(command -v perl)
  mkdir -p "$dir"
  cat > "$dir/fm-lint.sh" <<SH
#!/usr/bin/env bash
ledger=\$(sed -n 's/^HOST_POOL_ROOT=//p' '$repo/bin/fm-lint.sh')/admission.lock.ledger
mkdir -p "\$ledger"
entry="\$ledger/run.\$\$.1"
printf '%s\t%s\t%s\t%s\t%s\t%s\n' "\$\$" '$perl_bin' '$python' "\${FM_TEST_RUN_BOUNDED:-none}" "\${FM_TEST_RUN_MEMORY_KIB:-12582912}" "\${FM_TEST_RUN_RSS_KIB:-262144}" > "\$entry"
exec 9>>"\$entry"
'$perl_bin' -MFcntl=:flock -e 'open(my \$fh, ">>&=", 9) or exit 1; flock(\$fh, LOCK_EX | LOCK_NB) or exit 1' || exit 9
rc=0
FM_LINT_INTERNAL_RUN_ENTRY="\$entry" "\$@" || rc=\$?
rm -f "\$entry"
exit "\$rc"
SH
  chmod +x "$dir/fm-lint.sh"
}

# (F10) The private modes that run a command they are handed (--internal-timed,
# --internal-root) start it only inside a root the host-wide admission admitted,
# for a live lint run, and take the perl that checks this from the run's entry:
# a caller-selected checker, an entry outside the host ledger, an entry in it whose
# named ancestor is not a gate, and an --internal-root limit that is not the run's
# are each refused with nothing started. The control: inside a gate, under a run
# entry, the mode runs its command.
test_the_private_modes_start_a_command_only_inside_an_admitted_root() {
  local tmp repo lint mode rc starts holder waited ledger forged real_python
  tmp=$(fm_test_tmproot fm-lint-private-modes)
  FM_LINT_RELEASE_FILES="$tmp/forged.release $tmp/notgate.release"
  repo=$(fm_lint_isolated_copy "$tmp" modes)
  lint="$repo/bin/fm-lint.sh"
  ledger="$tmp/modes/host/admission.lock.ledger"
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  mkdir -p "$tmp/bin" "$ledger"
  fm_lint_write_barrier_shellcheck "$tmp/bin" 8 "$tmp/barrier.log"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/a.sh"
  : > "$tmp/barrier.log"
  # (1) Called directly with the sentinel: refused, and the command never starts.
  for mode in timed root; do
    rc=0
    if [ "$mode" = timed ]; then
      env FM_LINT_INTERNAL=1 bash "$lint" --internal-timed 10 1 "$tmp/bin/shellcheck" --norc -- "$tmp/a.sh" > "$tmp/direct.$mode.out" 2>&1 || rc=$?
    else
      env FM_LINT_INTERNAL=1 bash "$lint" --internal-root "$tmp/direct.rss" 12582912 "$tmp/bin/shellcheck" --norc -- "$tmp/a.sh" > "$tmp/direct.$mode.out" 2>&1 || rc=$?
    fi
    [ "$rc" -eq 2 ] || fm_lint_fail_settled "--internal-$mode called directly exited $rc, expected the refusal (2): $(cat "$tmp/direct.$mode.out")"
    [ ! -s "$tmp/barrier.log" ] || fm_lint_fail_settled "--internal-$mode called directly started the supplied ShellCheck outside the admission"
  done
  # (2) A caller-selected checker: FM_LINT_PERL_BIN=/usr/bin/true would answer yes.
  rc=0
  env FM_LINT_INTERNAL=1 FM_LINT_PERL_BIN=/usr/bin/true FM_LINT_INTERNAL_ADMISSION=/nonexistent/x.ledger/entry.1.1 \
    bash "$lint" --internal-timed 10 1 "$tmp/bin/shellcheck" --norc -- "$tmp/a.sh" > "$tmp/checker.out" 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fm_lint_fail_settled "a caller-selected admission checker was obeyed (exit $rc): $(cat "$tmp/checker.out")"
  [ ! -s "$tmp/barrier.log" ] || fm_lint_fail_settled "a caller-selected admission checker started ShellCheck outside the admission"
  # (3) A fabricated entry outside the host ledger, live and naming this shell (an
  # ancestor of the caller).
  mkdir -p "$tmp/forged.ledger"
  forged="$tmp/forged.ledger/entry.$$.1"
  perl -MFcntl=:flock -MTime::HiRes=sleep,time -e 'open(my $fh, ">>", $ARGV[0]) or die; flock($fh, LOCK_EX) or die; truncate($fh, 0); syswrite($fh, "$ARGV[1]\t1\t/x\n"); my $u = time() + 30; sleep 0.05 until -e $ARGV[2] || time() > $u' \
    "$forged" "$$" "$tmp/forged.release" &
  holder=$!
  sleep 0.5
  rc=0
  env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_ADMISSION="$forged" \
    bash "$lint" --internal-timed 10 1 "$tmp/bin/shellcheck" --norc -- "$tmp/a.sh" > "$tmp/forged.out" 2>&1 || rc=$?
  : > "$tmp/forged.release"
  wait "$holder" 2>/dev/null || true
  [ "$rc" -eq 2 ] || fm_lint_fail_settled "a fabricated entry outside the host ledger admitted its caller (exit $rc): $(cat "$tmp/forged.out")"
  [ ! -s "$tmp/barrier.log" ] || fm_lint_fail_settled "a fabricated entry outside the host ledger started ShellCheck"
  # (4) Under a genuine run entry, an entry in the host ledger whose named ancestor
  # (the owner stand-in, a lint owner but not a gate) is not a gate.
  fm_lint_write_owner_stand_in "$tmp/owner" "$repo" "$real_python"
  rc=0
  bash "$tmp/owner/fm-lint.sh" bash -c '
    perl -MFcntl=:flock -MTime::HiRes=sleep,time -e '"'"'open(my $fh, ">>", $ARGV[0]) or die; flock($fh, LOCK_EX) or die; truncate($fh, 0); syswrite($fh, "$ARGV[1]\t1\t/x\n"); my $u = time() + 30; sleep 0.05 until -e $ARGV[2] || time() > $u'"'"' "$1/entry.$PPID.7" "$PPID" "$2" &
    sleep 0.5
    rc=0
    env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_ADMISSION="$1/entry.$PPID.7" bash "$3" --internal-timed 10 1 "$4" --norc -- "$5" > "$6" 2>&1 || rc=$?
    : > "$2"
    wait
    exit "$rc"' fm-test "$ledger" "$tmp/notgate.release" "$lint" "$tmp/bin/shellcheck" "$tmp/a.sh" "$tmp/notgate.out" || rc=$?
  [ "$rc" -eq 2 ] || fm_lint_fail_settled "a host-ledger entry whose named ancestor is not a gate admitted its caller (exit $rc): $(cat "$tmp/notgate.out")"
  [ ! -s "$tmp/barrier.log" ] || fm_lint_fail_settled "a host-ledger entry whose named ancestor is not a gate started ShellCheck"
  # (5) The control: inside a gate, under the run entry, --internal-timed runs its
  # command (its start is logged) and exits with the command's status.
  rc=0
  bash "$tmp/owner/fm-lint.sh" env FM_TEST_MEM_HOLD=0.3 PATH="$tmp/bin:$PATH" \
    FM_LINT_INTERNAL_HOST_RSS_KIB=100000000 FM_LINT_INTERNAL_ROOT_KEY="full:$tmp/a.sh" FM_LINT_INTERNAL_ROOT_CAP_KIB=262144 \
    FM_LINT_INTERNAL_HOST_LOCK="$tmp/modes/host/admission.lock" FM_LINT_HOST_SLOTS=9 \
    perl "$repo/bin/fm-lint-cache.pl" gate "$tmp/modes/host/lint-slots" 18 control "$tmp/control.wait" -- \
    env FM_LINT_INTERNAL=1 bash "$lint" --internal-timed 20 1 "$tmp/bin/shellcheck" --norc -- "$tmp/a.sh" > "$tmp/control.out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fm_lint_fail_settled "--internal-timed inside an admitted root under a run entry exited $rc, so the refusals above cannot be told from a broken mode: $(cat "$tmp/control.out")"
  starts=$(grep -c '^start ' "$tmp/barrier.log")
  [ "$starts" -eq 1 ] || fm_lint_fail_settled "--internal-timed inside an admitted root did not start its command ($starts starts)"
  # (6) --internal-root inside the same admission: a limit that is not the run's is
  # refused; the run's own limit passes the admission and reaches the limit step
  # (where ulimit -v cannot be applied, as on native macOS, that step exits 97; where
  # it can, the command runs).
  rc=0
  bash "$tmp/owner/fm-lint.sh" env FM_TEST_MEM_HOLD=0.3 PATH="$tmp/bin:$PATH" \
    FM_LINT_INTERNAL_HOST_RSS_KIB=100000000 FM_LINT_INTERNAL_ROOT_KEY="full:$tmp/a.sh" FM_LINT_INTERNAL_ROOT_CAP_KIB=262144 \
    FM_LINT_INTERNAL_HOST_LOCK="$tmp/modes/host/admission.lock" FM_LINT_HOST_SLOTS=9 \
    perl "$repo/bin/fm-lint-cache.pl" gate "$tmp/modes/host/lint-slots" 18 other "$tmp/other.wait" -- \
    env FM_LINT_INTERNAL=1 bash "$lint" --internal-root "$tmp/other.rss" 99999999 "$tmp/bin/shellcheck" --norc -- "$tmp/a.sh" > "$tmp/other.out" 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fm_lint_fail_settled "--internal-root with a limit that is not the run's exited $rc, expected the refusal: $(cat "$tmp/other.out")"
  [ "$(grep -c '^start ' "$tmp/barrier.log")" -eq "$starts" ] || fm_lint_fail_settled "--internal-root with a limit that is not the run's started ShellCheck"
  rc=0
  bash "$tmp/owner/fm-lint.sh" env FM_TEST_MEM_HOLD=0.3 PATH="$tmp/bin:$PATH" \
    FM_LINT_INTERNAL_HOST_RSS_KIB=100000000 FM_LINT_INTERNAL_ROOT_KEY="full:$tmp/a.sh" FM_LINT_INTERNAL_ROOT_CAP_KIB=262144 \
    FM_LINT_INTERNAL_HOST_LOCK="$tmp/modes/host/admission.lock" FM_LINT_HOST_SLOTS=9 \
    perl "$repo/bin/fm-lint-cache.pl" gate "$tmp/modes/host/lint-slots" 18 own "$tmp/own.wait" -- \
    env FM_LINT_INTERNAL=1 bash "$lint" --internal-root "$tmp/own.rss" 12582912 "$tmp/bin/shellcheck" --norc -- "$tmp/a.sh" > "$tmp/own.out" 2>&1 || rc=$?
  if ( ulimit -v 12582912 ) 2>/dev/null; then
    [ "$rc" -eq 0 ] && [ "$(grep -c '^start ' "$tmp/barrier.log")" -eq $((starts + 1)) ] \
      || fm_lint_fail_settled "--internal-root with the run's limit inside an admitted root did not run its command (exit $rc): $(cat "$tmp/own.out")"
  else
    [ "$rc" -eq 97 ] || fm_lint_fail_settled "--internal-root with the run's limit inside an admitted root exited $rc, expected 97 at the limit step on a host without ulimit -v: $(cat "$tmp/own.out")"
  fi
  wait 2>/dev/null || true
  pass "the private modes run a command only inside an admitted root of a live run: a direct call, a caller-selected checker, an entry outside the host ledger, a non-gate ancestor and a limit that is not the run's are refused with nothing started; inside a gate the mode runs"
}

# (F10) A worker started directly, without a live run's entry, starts nothing,
# whatever bounds the caller injects (an 8 GiB-plus resident limit, no limit with
# no bound mechanism, a checker that always answers yes). The control: the owner's
# own run, with the same values and a broken host lock and budget injected into its
# environment, analyzes its root: the run's entry and the script's constants decide,
# not the caller's environment.
test_a_worker_started_directly_takes_nothing_from_the_callers_environment() {
  local tmp repo case_name rc
  tmp=$(fm_test_tmproot fm-lint-direct-worker)
  repo=$(fm_lint_isolated_copy "$tmp" worker)
  fm_lint_write_logging_shellcheck "$tmp/fake" "$tmp/starts.log"
  mkdir -p "$tmp/w/out"
  printf '0\t%s\n' "$repo/bin/consumer.sh" > "$tmp/w/manifest"
  : > "$tmp/starts.log"
  for case_name in oversized omitted checker; do
    local -a extra=()
    case "$case_name" in
      oversized) extra=(FM_LINT_INTERNAL_BOUNDED=none FM_LINT_INTERNAL_RSS_KIB=99999999) ;;
      omitted) extra=(FM_LINT_INTERNAL_BOUNDED=none) ;;
      checker) extra=(FM_LINT_INTERNAL_BOUNDED=none FM_LINT_INTERNAL_RSS_KIB=262144 FM_LINT_PERL_BIN=/usr/bin/true) ;;
    esac
    rc=0
    ( cd "$repo" && env -u FM_LINT_INTERNAL_RSS_KIB FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_SLOT_DIR="$tmp/worker/host/lint-slots" \
        FM_LINT_INTERNAL_NCPU=18 FM_LINT_INTERNAL_RUN_ID="direct$case_name" FM_LINT_INTERNAL_MEMORY_KIB=12582912 \
        FM_LINT_INTERNAL_ROOT_SECS=20 FM_LINT_INTERNAL_GRACE=1 FM_LINT_HOST_SLOTS=9 FM_LINT_SHELLCHECK="$tmp/fake/shellcheck" \
        "${extra[@]}" bash "$repo/bin/fm-lint.sh" --internal-worker "$tmp/w/manifest" "$tmp/w/out" 0 > "$tmp/w/$case_name.out" 2>&1 ) || rc=$?
    [ "$rc" -eq 2 ] || fm_lint_fail_settled "a directly started worker ($case_name) exited $rc, expected the refusal (2): $(cat "$tmp/w/$case_name.out")"
    ! grep -q -- '-- ' "$tmp/starts.log" || fm_lint_fail_settled "a directly started worker ($case_name) started an analysis: $(cat "$tmp/starts.log")"
  done
  # The control.
  rc=0
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
      FM_LINT_INTERNAL_RSS_KIB=99999999 FM_LINT_INTERNAL_BOUNDED=none \
      FM_LINT_INTERNAL_HOST_LOCK=/nonexistent/lint/host.lock FM_LINT_INTERNAL_HOST_RSS_KIB=1 \
      bash bin/fm-lint.sh bin/consumer.sh > "$tmp/owner.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 1 ] || fm_lint_fail_settled "the owner's own run with injected values exited $rc, expected its finding (1): $(cat "$tmp/owner.out")"
  grep -q -- '-- bin/consumer.sh' "$tmp/starts.log" || fm_lint_fail_settled "the owner's own run started no analysis: $(cat "$tmp/starts.log")"
  wait 2>/dev/null || true
  pass "a worker started directly refuses (exit 2) and starts nothing for an oversized, omitted or self-checked bound; the owner's run with the same values injected analyzes its root under its own entry and constants"
}

# fm_lint_write_stub_python <dir> <real python>: a python3 stand-in. The one send
# in the root signal program (os.killpg) is replaced by a line in
# $FM_TEST_SIGNAL_LOG ("killpg <pgid> <signal number>"), never delivered; a program
# with any other kill call is refused (exit 3, nothing run). FM_TEST_SEND_FAIL=<NAME>
# makes that send fail for that signal (after it is logged). FM_TEST_IDENTITY=fail
# makes the start-time read of the watch's launch answer "unknown". The lint's
# resolution of python3 (sys.executable) answers with this stand-in.
# FM_TEST_READER=exit makes every libproc reader exit at once;
# FM_TEST_READER=dieafter:<n> makes the first reader (marked by $FM_TEST_READER_MARK)
# answer <n> requests and then exit, and later readers run normally;
# FM_TEST_READER=members makes every reader answer 300000 KiB naming the root (by
# its real identity) and the member $FM_TEST_MEMBER ("<pid>:<sec>:<usec>"), bound
# by the reader's own check (fm-proc-info.py bind_members) on the real process
# table; FM_TEST_READER=late:<n>:<secs> makes the first reader (marked by
# $FM_TEST_READER_MARK) answer its <n>th request <secs> late and the others at once,
# and later readers run normally; FM_TEST_READER=slow:<secs> makes every reader
# answer each request <secs> late; FM_TEST_READER=phantom:<ended|unreadable> makes
# every reader the real one, with one extra child of the root (a free pid) in each
# census: "ended" is in neither the kernel's table nor libproc when read (it ended
# after the census), "unreadable" is read by libproc but its identity read fails.
fm_lint_write_stub_python() {
  local dir=$1 real
  real=$("$2" -c 'import sys; print(sys.executable)') || fail "python3 cannot name its interpreter"
  mkdir -p "$dir"
  cat > "$dir/python3" <<PY
#!$real
import os, sys
REAL = "$real"
HERE = os.path.abspath(__file__)
args = sys.argv[1:]
if args[:2] == ["-c", "import sys; print(sys.executable)"]:
    print(HERE)
    sys.exit(0)
if "-c" in args:
    i = args.index("-c")
    program = args[i + 1]
    if os.environ.get("FM_TEST_IDENTITY") == "fail" and args[i + 3:i + 4] == ["identity"]:
        print("unknown")
        sys.exit(0)
    if "os.kill" in program:
        program = program.replace("os.killpg(pgid, number)", "_fm_test_send('killpg', pgid, number)")
        if "os.kill" in program:
            sys.stderr.write("stub python: a send it does not recognise; nothing was run\n")
            sys.exit(3)
        log = os.environ.get("FM_TEST_SIGNAL_LOG", os.path.join(os.path.dirname(HERE), "signals.log"))
        program = ("def _fm_test_send(kind, pid, number):\n"
                   "    open(%r, 'a').write('%%s %%d %%d\\\\n' %% (kind, pid, number))\n"
                   "    import signal as _s\n"
                   "    if %r and number == getattr(_s, 'SIG' + %r, None):\n"
                   "        raise PermissionError('stub: send fails')\n"
                   % (log, os.environ.get("FM_TEST_SEND_FAIL", ""), os.environ.get("FM_TEST_SEND_FAIL", ""))) + program
        args[i + 1] = program
    os.execv(REAL, [REAL] + args)
mode = os.environ.get("FM_TEST_READER", "")
if len(args) >= 3 and args[1] == "rss-tree":
    if mode == "exit":
        sys.exit(1)
    if mode == "members":
        import importlib.util
        spec = importlib.util.spec_from_file_location("fp", args[0])
        fp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fp)
        pid, sec, usec = (int(part) for part in os.environ["FM_TEST_MEMBER"].split(":"))
        root = int(args[2])
        ident = tuple(fp.process_identity(fp.kinfo(root)))
        for request in iter(sys.stdin.readline, ""):
            bound = fp.bind_members(root, {root: ident, pid: (sec, usec)}) is not None
            print('{"rss_kib":300000,"members":[[%d,%d,%d],[%d,%d,%d]],"uncounted":[],"bound":%s}'
                  % (root, ident[0], ident[1], pid, sec, usec, "true" if bound else "false"), flush=True)
        sys.exit(0)
    if mode.startswith("phantom:"):
        import importlib.util
        spec = importlib.util.spec_from_file_location("fp", args[0])
        fp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fp)
        root = int(args[2])
        real_kinfos, real_kinfo, real_memory = fp.kinfos, fp.kinfo, fp.memory
        phantom = 99999
        while phantom > 300:
            try:
                real_kinfo(phantom)
            except LookupError:
                break
            phantom -= 1
        record = bytearray(real_kinfo(root))
        fp.struct.pack_into("qq", record, fp.P_START, 1, 1)
        fp.struct.pack_into("i", record, fp.P_PID, phantom)
        fp.struct.pack_into("i", record, fp.E_PPID, root)
        record = bytes(record)
        def kinfos(*selector):
            yield from real_kinfos(*selector)
            yield record
        def kinfo(pid):
            if pid != phantom:
                return real_kinfo(pid)
            if mode == "phantom:unreadable":
                raise OSError("stub: identity read fails")
            raise LookupError(pid)
        def memory(pid):
            if pid != phantom:
                return real_memory(pid)
            if mode == "phantom:unreadable":
                return (1048576, 1048576)
            raise LookupError(pid)
        fp.kinfos, fp.kinfo, fp.memory = kinfos, kinfo, memory
        sys.exit(fp.main([args[0], "rss-tree", str(root)]))
    if mode.startswith("late:"):
        mark = os.environ["FM_TEST_READER_MARK"]
        if not os.path.exists(mark):
            open(mark, "w").close()
            import importlib.util, time
            spec = importlib.util.spec_from_file_location("fp", args[0])
            fp = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(fp)
            _, late, secs = mode.split(":")
            root, known, asked = int(args[2]), {}, 0
            for request in iter(sys.stdin.readline, ""):
                asked += 1
                if asked == int(late):
                    time.sleep(float(secs))
                try:
                    answer = fp.rss_tree(root, known, request)
                except Exception:
                    answer = "-"
                print(answer, flush=True)
            sys.exit(0)
    if mode.startswith("slow:"):
        import importlib.util, time
        spec = importlib.util.spec_from_file_location("fp", args[0])
        fp = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fp)
        root, known = int(args[2]), {}
        for request in iter(sys.stdin.readline, ""):
            time.sleep(float(mode.split(":")[1]))
            try:
                answer = fp.rss_tree(root, known, request)
            except Exception:
                answer = "-"
            try:
                print(answer, flush=True)
            except BrokenPipeError:
                os._exit(0)
        sys.exit(0)
    if mode.startswith("interrupt:"):
        # On the Nth request, signal the watch (SIGUSR1) twice while it waits,
        # 0.1 s apart, then answer 0.3 s after the request.
        mark = os.environ["FM_TEST_READER_MARK"]
        if not os.path.exists(mark):
            open(mark, "w").close()
            import importlib.util, signal, time
            spec = importlib.util.spec_from_file_location("fp", args[0])
            fp = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(fp)
            root, known, asked = int(args[2]), {}, 0
            for request in iter(sys.stdin.readline, ""):
                asked += 1
                if asked == int(mode.split(":")[1]):
                    for _ in range(2):
                        time.sleep(0.1)
                        os.kill(os.getppid(), signal.SIGUSR1)
                    time.sleep(0.1)
                try:
                    answer = fp.rss_tree(root, known, request)
                except Exception:
                    answer = "-"
                print(answer, flush=True)
            sys.exit(0)
    if mode.startswith("dieafter:"):
        mark = os.environ["FM_TEST_READER_MARK"]
        if not os.path.exists(mark):
            open(mark, "w").close()
            import importlib.util
            spec = importlib.util.spec_from_file_location("fp", args[0])
            fp = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(fp)
            root, known, answered = int(args[2]), {}, 0
            for request in iter(sys.stdin.readline, ""):
                if answered >= int(mode.split(":")[1]):
                    sys.exit(0)
                try:
                    answer = fp.rss_tree(root, known, request)
                except Exception:
                    answer = "-"
                print(answer, flush=True)
                answered += 1
            sys.exit(0)
os.execv(REAL, [REAL] + args)
PY
  chmod +x "$dir/python3"
}

fm_lint_live() {  # <pid>: 0 while the process exists (read through libproc; no signal is sent)
  python3 "$ROOT/bin/fm-proc-info.py" ppid "$1" > /dev/null 2>&1
}

# (Main 1885 rule O) No signal route takes a group from input. The former command
# line signal mode is gone: `signal KILL group:0` and a foreign group are refused
# before anything runs. fm_signal_root refuses without a launch record, before any
# process starts. The root signal program, given a fake process reader, sends only
# when the group leader still has exactly the recorded start time and still leads
# that group; group 0, another start time, another group and a gone leader are
# refused (its send is a recorder; nothing is delivered).
test_no_signal_route_takes_a_group_from_input() {
  local tmp real_python log out rc item program sub
  tmp=$(fm_test_tmproot fm-lint-rule-o)
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  log="$tmp/signals.log"
  : > "$log"
  for item in group:0 group:999999990 123:1:2 under:1:123; do
    rc=0
    FM_TEST_SIGNAL_LOG="$log" FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" \
      perl "$ROOT/bin/fm-lint-cache.pl" signal KILL "$item" > "$tmp/out" 2>&1 || rc=$?
    [ "$rc" -eq 255 ] && [ "$(cat "$tmp/out")" = "fm-lint-cache: invalid private invocation" ] \
      || fm_lint_fail_settled "the command line signal mode did not refuse '$item' with its usage error (exit $rc): $(cat "$tmp/out")"
  done
  [ ! -s "$log" ] || fm_lint_fail_settled "a refused item was sent: $(cat "$log")"
  printf '#!/bin/sh\n:\n' > "$tmp/root.sh"
  rc=0
  perl "$ROOT/bin/fm-lint-cache.pl" select "$tmp" "$tmp/root.sh" < /dev/null > "$tmp/ok.out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && [ ! -s "$tmp/ok.out" ] \
    || fm_lint_fail_settled "the same dispatcher did not accept a valid mode (exit $rc): $(cat "$tmp/ok.out")"
  sub=$(perl -0ne 'print $1 if /^(sub fm_signal_root \{\n.*?^\}\n)/ms' "$ROOT/bin/fm-lint-cache.pl")
  [ -n "$sub" ] || fm_lint_fail_settled "fm_signal_root is missing"
  out=$(FM_LINT_INTERNAL_PYTHON=/nonexistent perl -e 'use strict; use warnings; our $ROOT_SIGNAL_PY = ""; '"$sub"'
print join(",", fm_signal_root("KILL", undef), fm_signal_root("KILL", {pgid => 0, sec => 1, usec => 1}),
  fm_signal_root("KILL", {pgid => 1, sec => 1, usec => 1}), fm_signal_root("KILL", {pgid => "1 2", sec => 1, usec => 1}),
  fm_signal_root("HUP", {pgid => 4242, sec => 1, usec => 1})), "\n";' 2>&1)
  [ "$out" = refused,refused,refused,refused,refused ] || fm_lint_fail_settled "fm_signal_root did not refuse a missing or malformed launch record: $out"
  program=$(perl -0ne 'print $1 if /my \$ROOT_SIGNAL_PY = <<.PYTHON.;\n(.*?)\nPYTHON\n/s' "$ROOT/bin/fm-lint-cache.pl")
  [ -n "$program" ] || fm_lint_fail_settled "the root signal program is missing"
  out=$(python3 -I -c '
import os, sys, types
program = sys.argv[1]
sent = []
fake = types.ModuleType("fmproc")
fake.E_PGID = 0
LEADERS = {4242: (100, 7, 4242), 4343: (100, 7, 1)}
def kinfo(pid):
    if pid not in LEADERS:
        raise LookupError(pid)
    return LEADERS[pid]
fake.kinfo = kinfo
fake.process_identity = lambda record: record[:2]
import importlib.util, struct
importlib.util.spec_from_file_location = lambda *a: types.SimpleNamespace(loader=types.SimpleNamespace(exec_module=lambda m: m.__dict__.update(fake.__dict__)))
importlib.util.module_from_spec = lambda spec: types.ModuleType("fmproc")
struct.unpack_from = lambda fmt, record, offset: (record[2],)
os.path.exists = lambda path: False
os.killpg = lambda pgid, number: sent.append(pgid)
os.kill = lambda pid, number: sent.append(("kill", pid))
for argv in (["x", "-", "KILL", "0", "100", "7"], ["x", "-", "KILL", "4242", "100", "8"], ["x", "-", "KILL", "4343", "100", "7"],
             ["x", "-", "KILL", "4444", "100", "7"], ["x", "-", "KILL", "4242", "100", "7"]):
    sys.argv = argv
    try:
        exec(compile(program, "root-signal", "exec"), {"__name__": "__main__"})
    except SystemExit:
        pass
print("sent", sent)
' "$program" 2>&1)
  [ "$out" = "$(printf 'mismatch\nmismatch\nmismatch\ngone\nsent\nsent [4242]')" ] \
    || fm_lint_fail_settled "the root signal program did not send only to the recorded, unchanged group leader: $out"
  pass "no signal route takes a group from input: the command line mode is gone, a missing launch record is refused, and only the recorded, unchanged group leader's group is sent to (group 0, another start time, another group and a gone leader refused)"
}
# (Main 1885 item 2) The reader is the only source of a sample: with no reader
# (every reader exits at once) the watch never samples a process table, so a
# descendant that left the root's group and holds 160 MiB is not measured; the root
# is unmeasured (96), nothing is sent, and no peak is recorded. The stub records
# every send.
test_a_root_with_no_reader_is_unmeasured_and_never_sampled_from_a_table() {
  if [ "$(uname)" != Darwin ]; then
    wait 2>/dev/null || true
    pass "SKIP (the libproc helper table is macOS only): seconds-only member"
    return
  fi
  local tmp rc=0 pid real_python log
  tmp=$(fm_test_tmproot fm-lint-seconds-only)
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  log="$tmp/signals.log"
  : > "$log"
  # A descendant leaves the root's group and then holds 160 MiB against a 100 MiB
  # bound; it and the root end on their own. (The size is an argument: a constant
  # string repeat is built when perl compiles the program, before the fork.)
  cat > "$tmp/leaver-parent.sh" <<'SH'
perl -MPOSIX -MTime::HiRes=sleep -e 'my $mib = shift; sleep 1.6; POSIX::setpgid(0, 0); sleep 0.5; my $held = "x" x ($mib * 1024 * 1024); sleep 12' 160 &
echo "$!" > "$1"
sleep 9
SH
  FM_TEST_SIGNAL_LOG="$log" FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_READER=exit \
    perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 102400 "$tmp/rss" -- \
    bash "$tmp/leaver-parent.sh" "$tmp/leaver.pid" > "$tmp/err" 2>&1 || rc=$?
  pid=$(cat "$tmp/leaver.pid" 2>/dev/null || true)
  [ -n "$pid" ] || fm_lint_fail_settled "the group-leaving descendant did not start"
  grep -q '^rss_reader_unavailable=exited-at-start$' "$tmp/rss" || fm_lint_fail_settled "the test did not run with the reader down: $(cat "$tmp/rss")"
  { [ "$rc" -eq 96 ] && grep -q '^rss_unmeasured=1$' "$tmp/rss"; } || fm_lint_fail_settled "a root with no reader exited $rc, expected 96 unmeasured: $(cat "$tmp/err") $(cat "$tmp/rss")"
  ! grep -q '^max_rss_kib=' "$tmp/rss" || fm_lint_fail_settled "the watch recorded a peak with no reader (a table was sampled): $(cat "$tmp/rss")"
  grep -q '^rss_samples=libproc:0$' "$tmp/rss" || fm_lint_fail_settled "the watch counted a sample with no reader: $(cat "$tmp/rss")"
  [ ! -s "$log" ] || fm_lint_fail_settled "the watch sent a signal for a tree it never measured: $(cat "$log")"
  wait 2>/dev/null || true
  pass "with no reader the watch samples nothing else: the root is unmeasured (96), nothing is sent and no peak is recorded"
}

# (F11) A restarted reader starts with an empty set of members; the watch keeps
# every member it already knew that still runs. A descendant seen by the first
# reader leaves the group and is orphaned; the first reader then exits; after the
# restart the orphan holds 160 MiB against a 100 MiB bound. The watch must still
# count it and end the root's group; the orphan is never signalled, and since it
# outlives the root the root fails (96) and records it (sends recorded by the stub).
test_a_restarted_reader_keeps_a_member_that_left_the_group_and_was_orphaned() {
  if [ "$(uname)" != Darwin ]; then
    wait 2>/dev/null || true
    pass "SKIP (the libproc reader is macOS only): reader restart keeps members"
    return
  fi
  local tmp rc=0 orphan real_python log
  tmp=$(fm_test_tmproot fm-lint-reader-restart)
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  log="$tmp/signals.log"
  : > "$log"
  cat > "$tmp/root.sh" <<'SH'
perl -MPOSIX -MTime::HiRes=sleep -e '
  my ($pidfile, $mib) = @ARGV;
  POSIX::setsid();
  my $orphan = fork();
  if (!$orphan) {
    open(my $f, ">", $pidfile) or die; print {$f} "$$\n"; close $f;
    sleep 7.5;
    my $held = "x" x ($mib * 1024 * 1024);
    sleep 11;
    exit 0;
  }
  sleep 3.3;
  exit 0' "$1" 160 &
sleep 13
SH
  FM_TEST_SIGNAL_LOG="$log" FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_READER=dieafter:3 FM_TEST_READER_MARK="$tmp/reader.mark" \
    perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 102400 "$tmp/rss" -- bash "$tmp/root.sh" "$tmp/orphan.pid" > "$tmp/err" 2>&1 || rc=$?
  orphan=$(cat "$tmp/orphan.pid" 2>/dev/null || true)
  [ -n "$orphan" ] || fm_lint_fail_settled "the orphan did not start"
  [ -e "$tmp/reader.mark" ] || fm_lint_fail_settled "the first reader never started, so nothing was restarted"
  grep -q '^rss_samples=libproc:' "$tmp/rss" || fm_lint_fail_settled "no sample record: $(cat "$tmp/rss")"
  [ "$rc" -eq 96 ] || fm_lint_fail_settled "after its reader restarted the watch exited $rc, expected 96: $(cat "$tmp/err") $(cat "$tmp/rss")"
  grep -q '^killpg ' "$log" || fm_lint_fail_settled "the root's group was not ended over the bound: $(cat "$log") / $(cat "$tmp/rss")"
  ! grep -q " $orphan " "$log" || fm_lint_fail_settled "the watch signalled the orphan outside the root's group: $(cat "$log")"
  grep -q "^rss_escaped=.*$orphan" "$tmp/rss" || fm_lint_fail_settled "the counted orphan that outlived the root was not recorded: $(cat "$tmp/rss")"
  wait 2>/dev/null || true
  pass "a restarted reader does not lose a member that left the group and was orphaned: the watch counted it and ended the root's group over the bound, never signalled the orphan, and failed the root it outlived"
}

# (F11) A watch that loses every reader of its root's memory (libproc and the
# process table) lets that root finish but starts no further root of the run, and
# the run fails, naming the root it did not start.
test_a_watch_that_loses_every_reader_starts_no_further_root_and_fails_the_run() {
  if [ "$(uname)" != Darwin ]; then
    wait 2>/dev/null || true
    pass "SKIP (the resident watch runs on native macOS only): every reader lost"
    return
  fi
  local tmp repo real_python rc=0 real_ps
  tmp=$(fm_test_tmproot fm-lint-readers-lost)
  repo=$(fm_lint_isolated_copy "$tmp" lost)
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/fake" "$real_python"
  fm_lint_write_logging_shellcheck "$tmp/fake" "$tmp/starts.log"
  # Where ps works, the watch's own ps reading (the one with pgid) fails too.
  real_ps=$(command -v ps || true)
  printf '#!/bin/sh\ncase "$*" in *pgid=*) exit 1 ;; esac\n[ -n "%s" ] && exec "%s" "$@"\nexit 1\n' "$real_ps" "$real_ps" > "$tmp/fake/ps"
  chmod +x "$tmp/fake/ps"
  : > "$tmp/starts.log"
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_JOBS=1 \
      FM_TEST_READER=exit FM_TEST_ANALYSIS_SECS=5 FM_TEST_ANALYSIS_RC=0 \
      FM_TEST_SIGNAL_LOG="$tmp/signals.log" bash bin/fm-lint.sh bin/consumer.sh bin/library.sh > "$tmp/out" 2>&1 ) || rc=$?
  [ "$rc" -ne 0 ] || fm_lint_fail_settled "a run whose watch lost every reader exited 0 with a root not analyzed: $(cat "$tmp/out")"
  [ "$(grep -c -- '-- bin/' "$tmp/starts.log")" -eq 1 ] || fm_lint_fail_settled "the run started another root after its watch lost every reader: $(cat "$tmp/starts.log")"
  grep -q 'not started' "$tmp/out" || fm_lint_fail_settled "the run did not name the root it did not start: $(cat "$tmp/out")"
  wait 2>/dev/null || true
  pass "a watch that loses every reader lets its root finish, starts no further root, and the run fails naming the root not started"
}

# fm_lint_native_launcher <fakebin> <starts log> <version file>: a compiled
# ShellCheck launcher (not a script) whose --version answer comes from <version
# file>, read every run, the way a launcher's delegate can change without the
# launcher's own bytes changing. Returns 1 when the host has no C compiler.
fm_lint_native_launcher() {
  local fakebin=$1 log=$2 version=$3 src
  command -v cc >/dev/null 2>&1 || return 1
  mkdir -p "$fakebin"
  src="$fakebin/launcher.c"
  cat > "$src" <<C
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  FILE *f = fopen("$log", "a");
  if (f) { for (int i = 1; i < argc; i++) fprintf(f, "%s%s", i > 1 ? " " : "", argv[i]); fprintf(f, "\n"); fclose(f); }
  if (argc > 1 && strcmp(argv[1], "--version") == 0) {
    char v[64] = "unknown";
    FILE *d = fopen("$version", "r");
    if (d) { if (fscanf(d, "%63s", v) != 1) strcpy(v, "unknown"); fclose(d); }
    printf("ShellCheck - shell script analysis tool\nversion: %s\n", v);
    return 0;
  }
  return 0;
}
C
  cc -o "$fakebin/shellcheck" "$src" 2>/dev/null || return 1
  rm -f "$src"
}

# (F12) A compiled launcher is probed every run, like a script: its delegate's
# current version decides the strict policy, with the launcher's bytes unchanged.
test_a_compiled_launcher_is_probed_every_run_and_its_delegates_version_decides() {
  local tmp repo rc
  tmp=$(fm_test_tmproot fm-lint-native-launcher)
  repo=$(fm_lint_isolated_copy "$tmp" launcher)
  printf '0.11.0\n' > "$tmp/delegate.version"
  fm_lint_native_launcher "$tmp/fake" "$tmp/starts.log" "$tmp/delegate.version" \
    || { pass "SKIP (no C compiler for a compiled launcher): native launcher probed every run"; return; }
  rc=0
  # FM_LINT_STRICT_VERSION=1 sets the strict version policy on every host; --strict-version
  # also refuses off macOS (exit 2) before the probe.
  ( cd "$repo" && PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
      FM_LINT_STRICT_VERSION=1 bash bin/fm-lint.sh bin/consumer.sh > "$tmp/first.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] || fm_lint_fail_settled "a launcher whose delegate reports the pinned version was rejected ($rc): $(cat "$tmp/first.out")"
  printf '0.10.0\n' > "$tmp/delegate.version"
  rc=0
  ( cd "$repo" && PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
      FM_LINT_STRICT_VERSION=1 bash bin/fm-lint.sh bin/consumer.sh > "$tmp/second.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 1 ] || fm_lint_fail_settled "a compiled launcher whose delegate changed to 0.10.0 passed the strict version policy ($rc): $(cat "$tmp/second.out")"
  grep -q 'found 0.10.0' "$tmp/second.out" || fm_lint_fail_settled "the refusal did not name the delegate's current version: $(cat "$tmp/second.out")"
  printf '0.11.0\n' > "$tmp/delegate.version"
  rc=0
  ( cd "$repo" && PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
      FM_LINT_STRICT_VERSION=1 bash bin/fm-lint.sh bin/consumer.sh > "$tmp/third.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] || fm_lint_fail_settled "a corrected delegate was rejected ($rc): $(cat "$tmp/third.out")"
  [ "$(grep -c -- '^--version$' "$tmp/starts.log")" -eq 3 ] || fm_lint_fail_settled "the launcher was not probed on each of its three runs: $(cat "$tmp/starts.log")"
  wait 2>/dev/null || true
  pass "a compiled launcher is probed every run: its delegate's change to 0.10.0 is refused under the strict policy and the corrected delegate accepted, with the launcher's bytes unchanged"
}

# The version probe waits only for its own lane (another probe), never behind
# roots holding the budget, and the wait is recorded (probe_wait_ms).
test_the_version_probe_waits_only_for_its_own_lane() {
  local tmp repo rc=0 run lane waited probe_wait
  tmp=$(fm_test_tmproot fm-lint-probe-lane)
  FM_LINT_RELEASE_FILES="$tmp/lane.release"
  repo=$(fm_lint_isolated_copy "$tmp" lane)
  fm_lint_write_logging_shellcheck "$tmp/fake" "$tmp/starts.log"
  lane="$tmp/lane/host/admission.lock.probe"
  perl -MFcntl=:flock -MTime::HiRes=sleep,time -e 'open(my $fh, ">>", $ARGV[0]) or die; flock($fh, LOCK_EX) or die; open(my $r, ">", $ARGV[1]) or die; close $r; my $u = time() + 30; sleep 0.05 until -e $ARGV[2] || time() > $u' \
    "$lane" "$tmp/lane.ready" "$tmp/lane.release" &
  waited=0
  while [ ! -e "$tmp/lane.ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  : > "$tmp/starts.log"
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_ANALYSIS_RC=0 \
      FM_LINT_TELEMETRY="$tmp/t.tsv" bash bin/fm-lint.sh bin/consumer.sh > "$tmp/out" 2>&1 ) &
  run=$!
  # The run needs about a second to reach the lane (its census first); the lane is
  # held 4 s from the run's start, so the run waits for it at least a second.
  sleep 4
  [ ! -s "$tmp/starts.log" ] || { : > "$tmp/lane.release"; wait "$run"; fm_lint_fail_settled "ShellCheck started while the probe lane was held: $(cat "$tmp/starts.log")"; }
  : > "$tmp/lane.release"
  wait "$run" || rc=$?
  [ "$rc" -eq 0 ] || fm_lint_fail_settled "the run failed after the lane was released ($rc): $(cat "$tmp/out")"
  probe_wait=$(awk -F '\t' '$1 == "meta" && $2 == "probe_wait_ms" { print $3 }' "$tmp/t.roots.tsv")
  [ -n "$probe_wait" ] && [ "$probe_wait" -ge 1000 ] || fm_lint_fail_settled "the probe's recorded lane wait is ${probe_wait:-missing} ms, though the lane was held for 4 s after the run began"
  wait 2>/dev/null || true
  pass "the version probe waited for its held lane ($probe_wait ms recorded) and started nothing meanwhile"
}

# (Main 1846 F1, F5) Each reader reply is bound to the processes it measured: a reply
# that names the bystander's pid with another start time (a member that ended, whose
# pid was reused) is unknown, so the root runs unmeasured (96) and nothing is sent.
# The control: named with its true start time, the bystander is counted, the root's
# group is ended over the bound, the bystander is never signalled, and since it
# outlives the root the root fails (96) and records it. Every send is recorded by the
# stub, none delivered.
test_the_watch_never_ends_an_unrelated_process_that_holds_a_members_old_pid() {
  if [ "$(uname)" != Darwin ]; then
    wait 2>/dev/null || true
    pass "SKIP (the libproc identity reader is macOS only): reused member pid"
    return
  fi
  local tmp bystander identity sec usec rc real_python label log
  tmp=$(fm_test_tmproot fm-lint-reused-pid)
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  for label in reused control; do
    sleep 10 > /dev/null 2>&1 &
    bystander=$!
    identity=$(fm_lint_identity_of "$bystander") || fm_lint_fail_settled "could not read the bystander's start time"
    sec=${identity%%:*}
    usec=${identity##*:}
    # The reader names the bystander's pid with a start time of 100 s earlier
    # (a member that ended, whose pid was reused: "reused"), or with the
    # bystander's own start time ("control").
    [ "$label" = reused ] && sec=$((sec - 100))
    log="$tmp/signals.$label"
    : > "$log"
    rm -f "$tmp/rss.$label"
    rc=0
    FM_TEST_SIGNAL_LOG="$log" FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_READER=members FM_TEST_MEMBER="$bystander:$sec:$usec" \
      perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 102400 "$tmp/rss.$label" -- sleep 3 > "$tmp/err.$label" 2>&1 || rc=$?
    [ "$rc" -eq 96 ] || fm_lint_fail_settled "the watch exited $rc ($label), expected 96: $(cat "$tmp/err.$label")"
    ! grep -q " $bystander " "$log" || fm_lint_fail_settled "the watch signalled the bystander ($label): $(cat "$log")"
    if [ "$label" = reused ]; then
      grep -q '^rss_unmeasured=1$' "$tmp/rss.$label" || fm_lint_fail_settled "a reply naming a reused pid was counted: $(cat "$tmp/rss.$label")"
      [ ! -s "$log" ] || fm_lint_fail_settled "the watch ended a root over a reply it could not bind: $(cat "$log")"
    else
      grep -q '^killpg ' "$log" || fm_lint_fail_settled "the root's group was not ended over the bound (recorded): $(cat "$log")"
      grep -q "^rss_escaped=.*$bystander" "$tmp/rss.$label" || fm_lint_fail_settled "the counted bystander that outlived the root was not recorded: $(cat "$tmp/rss.$label")"
    fi
  done
  wait 2>/dev/null || true
  pass "a reply naming a reused pid is unknown and the root fails unmeasured with nothing sent; with the true identity the member is counted, only the root's group is ended, and the member that outlives it fails the root (sends recorded by the stub, none delivered)"
}

# (F7) Two runs at once, each against a pool whose slot file cannot be opened,
# both refuse and start nothing (an unbounded fallback would run both analyses
# beside each other). The control: with the slot file usable again both runs
# analyze their root and leave no ticket or live ledger entry behind.
test_concurrent_runs_against_an_unusable_slot_both_refuse_and_then_both_run() {
  local tmp repo rc1=0 rc2=0 run1 run2 left
  tmp=$(fm_test_tmproot fm-lint-concurrent-failed-slot)
  repo=$(fm_lint_isolated_copy "$tmp" failed)
  fm_lint_write_logging_shellcheck "$tmp/fake" "$tmp/starts.log"
  mkdir -p "$tmp/pool"
  : > "$tmp/pool/slot.0"
  chmod 000 "$tmp/pool/slot.0"
  : > "$tmp/starts.log"
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_SLOT_DIR="$tmp/pool" \
      FM_TEST_ANALYSIS_RC=0 FM_TEST_ANALYSIS_SECS=1 bash bin/fm-lint.sh bin/consumer.sh > "$tmp/run1.out" 2>&1 ) &
  run1=$!
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_SLOT_DIR="$tmp/pool" \
      FM_TEST_ANALYSIS_RC=0 FM_TEST_ANALYSIS_SECS=1 bash bin/fm-lint.sh bin/library.sh > "$tmp/run2.out" 2>&1 ) &
  run2=$!
  wait "$run1" || rc1=$?
  wait "$run2" || rc2=$?
  chmod 600 "$tmp/pool/slot.0"
  [ "$rc1" -ne 0 ] && [ "$rc2" -ne 0 ] || fm_lint_fail_settled "concurrent runs against an unusable slot file exited $rc1 and $rc2; both must refuse: $(cat "$tmp/run1.out" "$tmp/run2.out")"
  ! grep -q -- '-- bin/' "$tmp/starts.log" || fm_lint_fail_settled "a run against an unusable slot file started an analysis: $(cat "$tmp/starts.log")"
  if ! { grep -q "$tmp/pool/slot.0" "$tmp/run1.out" && grep -q "$tmp/pool/slot.0" "$tmp/run2.out"; }; then
    fm_lint_fail_settled "a refusal did not name the unusable slot file: $(cat "$tmp/run1.out" "$tmp/run2.out")"
  fi
  # The control.
  rc1=0; rc2=0
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_SLOT_DIR="$tmp/pool" \
      FM_TEST_ANALYSIS_RC=0 FM_TEST_ANALYSIS_SECS=1 bash bin/fm-lint.sh bin/consumer.sh > "$tmp/run3.out" 2>&1 ) &
  run1=$!
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_SLOT_DIR="$tmp/pool" \
      FM_TEST_ANALYSIS_RC=0 FM_TEST_ANALYSIS_SECS=1 bash bin/fm-lint.sh bin/library.sh > "$tmp/run4.out" 2>&1 ) &
  run2=$!
  wait "$run1" || rc1=$?
  wait "$run2" || rc2=$?
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] || fm_lint_fail_settled "with the slot file usable the runs exited $rc1 and $rc2: $(cat "$tmp/run3.out" "$tmp/run4.out")"
  [ "$(grep -c -- '-- bin/' "$tmp/starts.log")" -eq 2 ] || fm_lint_fail_settled "with the slot file usable the two roots were not both analyzed: $(cat "$tmp/starts.log")"
  left=$(find "$tmp/pool" -name 'queue.0*' -print)
  [ -z "$left" ] || fm_lint_fail_settled "the runs left tickets behind: $left"
  wait 2>/dev/null || true
  pass "two concurrent runs against an unusable slot file both refuse naming it and start nothing; with it usable both analyze their root and leave no ticket"
}

# (Main 1770 (6)) A run never takes a version from a probe that started before it
# began waiting: run 1's probe reads 0.11.0 and is still running when the delegate
# changes to 0.10.0 and run 2 (strict) arrives; run 2 must probe again and refuse
# 0.10.0. The control: run 1 reports its own probe's 0.11.0.
test_a_run_never_takes_a_version_from_a_probe_that_started_before_it_waited() {
  local tmp repo rc1=0 rc2=0 run1 waited
  tmp=$(fm_test_tmproot fm-lint-probe-fresh)
  repo=$(fm_lint_isolated_copy "$tmp" fresh)
  printf '0.11.0\n' > "$tmp/delegate.version"
  fm_lint_write_logging_shellcheck "$tmp/fake" "$tmp/starts.log" "$tmp/delegate.version"
  : > "$tmp/starts.log"
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_ANALYSIS_RC=0 FM_TEST_PROBE_SECS=4 \
      bash bin/fm-lint.sh bin/consumer.sh > "$tmp/run1.out" 2>&1 ) &
  run1=$!
  waited=0
  while ! grep -q -- '^--version$' "$tmp/starts.log" && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  grep -q -- '^--version$' "$tmp/starts.log" || fm_lint_fail_settled "run 1's probe never started"
  printf '0.10.0\n' > "$tmp/delegate.version"
  # FM_LINT_STRICT_VERSION=1 sets the strict version policy on every host; --strict-version
  # also refuses off macOS (exit 2) before the probe.
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_ANALYSIS_RC=0 \
      FM_LINT_STRICT_VERSION=1 bash bin/fm-lint.sh bin/library.sh > "$tmp/run2.out" 2>&1 ) || rc2=$?
  wait "$run1" || rc1=$?
  [ "$rc2" -eq 1 ] || fm_lint_fail_settled "a strict run that began waiting during another run's probe exited $rc2 on that probe's older version: $(cat "$tmp/run2.out")"
  grep -q 'found 0.10.0' "$tmp/run2.out" || fm_lint_fail_settled "the strict run did not name the delegate's version when it waited: $(cat "$tmp/run2.out")"
  [ "$(grep -c -- '^--version$' "$tmp/starts.log")" -eq 2 ] || fm_lint_fail_settled "the strict run did not probe again: $(cat "$tmp/starts.log")"
  if ! { [ "$rc1" -eq 0 ] && grep -q 'ShellCheck 0.11.0 (pinned 0.11.0)' "$tmp/run1.out"; }; then
    fm_lint_fail_settled "run 1 did not report its own probe's version ($rc1): $(cat "$tmp/run1.out")"
  fi
  wait 2>/dev/null || true
  pass "a run that began waiting during another run's probe probed again and refused the delegate's 0.10.0 under the strict policy; the earlier run reported its own probe's 0.11.0"
}

# (Main 1775 N1) Every run probes its own ShellCheck. Two runs of one wrapper whose
# delegate depends on HOME queue for the probe lane; each must get its own delegate's
# version: the strict run whose HOME selects 0.10.0 refuses, the other passes. The
# control: two runs with the same HOME both pass, each with its own probe.
fm_lint_home_wrapper() {  # <fakebin> <starts log>
  mkdir -p "$1"
  cat > "$1/shellcheck" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$HOME" "\$*" >> '$2'
if [ "\${1:-}" = --version ]; then
  case "\$HOME" in *old*) v=0.10.0 ;; *) v=0.11.0 ;; esac
  printf 'ShellCheck - shell script analysis tool\nversion: %s\n' "\$v"
  exit 0
fi
exit 0
EOF
  chmod +x "$1/shellcheck"
}

test_runs_with_different_delegates_each_probe_their_own_shellcheck() {
  local tmp repo lane waited run_a rc_a=0 rc_b=0 label home_b want_b
  tmp=$(fm_test_tmproot fm-lint-own-probe)
  FM_LINT_RELEASE_FILES="$tmp/lane.release.different $tmp/lane.release.same"
  repo=$(fm_lint_isolated_copy "$tmp" own)
  fm_lint_home_wrapper "$tmp/fake" "$tmp/starts.log"
  lane="$tmp/own/host/admission.lock.probe"
  for label in different same; do
    if [ "$label" = different ]; then home_b="$tmp/home.old"; want_b=1; else home_b="$tmp/home.new2"; want_b=0; fi
    mkdir -p "$tmp/home.new" "$home_b"
    rm -f "$tmp/lane.ready"
    perl -MFcntl=:flock -MTime::HiRes=sleep,time -e 'open(my $fh, ">>", $ARGV[0]) or die; flock($fh, LOCK_EX) or die; open(my $r, ">", $ARGV[1]) or die; close $r; my $u = time() + 30; sleep 0.05 until -e $ARGV[2] || time() > $u' \
      "$lane" "$tmp/lane.ready" "$tmp/lane.release.$label" &
    waited=0
    while [ ! -e "$tmp/lane.ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
    : > "$tmp/starts.log"
    rc_a=0; rc_b=0
    # FM_LINT_STRICT_VERSION=1 sets the strict version policy on every host; --strict-version
    # also refuses off macOS (exit 2) before the probe.
    ( cd "$repo" && env HOME="$tmp/home.new" PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
        FM_LINT_STRICT_VERSION=1 bash bin/fm-lint.sh bin/consumer.sh > "$tmp/$label.a.out" 2>&1 ) &
    run_a=$!
    sleep 0.5
    ( cd "$repo" && env HOME="$home_b" PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
        FM_LINT_STRICT_VERSION=1 bash bin/fm-lint.sh bin/library.sh > "$tmp/$label.b.out" 2>&1 ) &
    sleep 2
    : > "$tmp/lane.release.$label"
    wait "$run_a" || rc_a=$?
    wait "$!" || rc_b=$?
    wait 2>/dev/null || true
    [ "$rc_a" -eq 0 ] || fm_lint_fail_settled "$label: the run whose delegate is the pinned 0.11.0 exited $rc_a: $(cat "$tmp/$label.a.out")"
    [ "$rc_b" -eq "$want_b" ] || fm_lint_fail_settled "$label: the second run exited $rc_b, expected $want_b for its own delegate: $(cat "$tmp/$label.b.out")"
    [ "$(grep -c -- ' --version$' "$tmp/starts.log")" -eq 2 ] || fm_lint_fail_settled "$label: the two runs did not each probe their own ShellCheck: $(cat "$tmp/starts.log")"
  done
  grep -q 'found 0.10.0' "$tmp/different.b.out" || fm_lint_fail_settled "the strict refusal did not name the run's own delegate version: $(cat "$tmp/different.b.out")"
  wait 2>/dev/null || true
  pass "two queued runs of one wrapper each probed their own delegate: the strict run whose HOME selects 0.10.0 refused, the 0.11.0 run passed; with one HOME both passed, each on its own probe"
}

# (Main 1775 N2) The probe is the lane holder's direct child and the run waits for
# it on its own time bound: a probe that closes its output at once and then runs past
# the bound still makes its run report blocked, a run waiting for the lane reports
# blocked and starts nothing, and both finish once the probe exits. Nothing is ended.
# The copy's bound is 1 s.
test_a_probe_past_its_bound_is_waited_for_and_reported_even_after_closing_its_output() {
  local tmp repo rc1=0 rc2=0 run1 run2 waited
  tmp=$(fm_test_tmproot fm-lint-probe-overdue)
  FM_LINT_RELEASE_FILES="$tmp/release"
  repo=$(fm_lint_isolated_copy "$tmp" overdue)
  perl -pi -e 's{^PROBE_BOUND_SECONDS=.*$}{PROBE_BOUND_SECONDS=1}' "$repo/bin/fm-lint.sh"
  grep -q '^PROBE_BOUND_SECONDS=1$' "$repo/bin/fm-lint.sh" || printf 'note: this copy has no probe bound to shorten\n'
  mkdir -p "$tmp/fake"
  # The first --version prints its version, closes its output and then runs until
  # the release file exists (20 s at most); later ones answer at once.
  cat > "$tmp/fake/shellcheck" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$tmp/starts.log'
if [ "\${1:-}" = --version ]; then
  printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'
  if [ ! -e '$tmp/first' ]; then
    : > '$tmp/first'
    exec >/dev/null
    perl -MTime::HiRes=sleep,time -e 'my \$u = time() + 20; sleep 0.05 until -e \$ARGV[0] || time() > \$u' '$tmp/release'
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$tmp/fake/shellcheck"
  : > "$tmp/starts.log"
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
      bash bin/fm-lint.sh bin/consumer.sh > "$tmp/run1.out" 2>&1 ) &
  run1=$!
  waited=0
  while [ ! -e "$tmp/first" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
      bash bin/fm-lint.sh bin/library.sh > "$tmp/run2.out" 2>&1 ) &
  run2=$!
  # Run 2 needs about a second to reach the lane, then waits past the 1 s bound.
  sleep 4.5
  grep -q 'blocked: the version probe (pid [0-9]*) has run more than 1 s' "$tmp/run1.out" \
    || fm_lint_fail_settled "a run whose probe closed its output and ran past the bound did not report it was blocked: $(cat "$tmp/run1.out")"
  grep -q 'blocked: the version probe lane' "$tmp/run2.out" || fm_lint_fail_settled "a run waiting past the bound did not report it was blocked: $(cat "$tmp/run2.out")"
  [ "$(grep -c -- '^--version$' "$tmp/starts.log")" -eq 1 ] || fm_lint_fail_settled "a second probe started while the first probe still ran: $(cat "$tmp/starts.log")"
  : > "$tmp/release"
  wait "$run1" || rc1=$?
  wait "$run2" || rc2=$?
  [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] || fm_lint_fail_settled "the runs did not finish once the probe exited ($rc1, $rc2): $(cat "$tmp/run1.out" "$tmp/run2.out")"
  wait 2>/dev/null || true
  pass "a probe that closed its output and ran past its bound was waited for: its run and the waiting run reported blocked, no second probe started, and both finished once it exited; nothing was ended"
}

# (Main 1775 N3) Outside macOS without the enforced envelope the per-root resident
# cap and the 64 MiB probe lane are not enforced: a strict run refuses before any
# ShellCheck starts and says so. The control: a non-strict run there warns that the
# caps are not enforced and goes on to probe the version (on this macOS host the
# roots that follow cannot run as on Linux: the Linux /usr/bin/time options do not
# exist here, so the control stops its assertions at the probe). (The host is made to
# report Linux by a uname stand-in; the copy's host-wide directory is the test's own.)
test_strict_mode_refuses_where_the_caps_are_not_enforced() {
  local tmp repo rc
  tmp=$(fm_test_tmproot fm-lint-unenforced)
  repo=$(fm_lint_isolated_copy "$tmp" linux)
  fm_lint_write_logging_shellcheck "$tmp/fake" "$tmp/starts.log"
  # shellcheck disable=SC2016 # single quotes intended: this writes a literal script
  printf '#!/bin/sh\ncase "${1:-}" in -m) echo x86_64 ;; *) echo Linux ;; esac\n' > "$tmp/fake/uname"
  chmod +x "$tmp/fake/uname"
  : > "$tmp/starts.log"
  rc=0
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_REQUIRE_BOUNDS=0 \
      bash bin/fm-lint.sh --strict-version bin/consumer.sh > "$tmp/strict.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 2 ] || fm_lint_fail_settled "a strict run where the caps are not enforced exited $rc, expected the refusal (2): $(cat "$tmp/strict.out")"
  grep -q 'strict mode refuses on Linux' "$tmp/strict.out" || fm_lint_fail_settled "the refusal did not say why: $(cat "$tmp/strict.out")"
  [ ! -s "$tmp/starts.log" ] || fm_lint_fail_settled "the refused strict run started ShellCheck: $(cat "$tmp/starts.log")"
  rc=0
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_REQUIRE_BOUNDS=0 FM_TEST_ANALYSIS_RC=0 \
      bash bin/fm-lint.sh bin/consumer.sh > "$tmp/plain.out" 2>&1 ) || rc=$?
  if ! { [ "$rc" -ne 2 ] && ! grep -q 'strict mode refuses' "$tmp/plain.out"; }; then
    fm_lint_fail_settled "the non-strict run there was refused ($rc): $(cat "$tmp/plain.out")"
  fi
  grep -q 'are not enforced' "$tmp/plain.out" || fm_lint_fail_settled "the non-strict run did not warn that the caps are not enforced: $(cat "$tmp/plain.out")"
  grep -q -- '^--version$' "$tmp/starts.log" || fm_lint_fail_settled "the non-strict run did not go on to probe the version: $(cat "$tmp/starts.log")"
  # An FM_LINT_STRICT_VERSION=1 inherited from the environment still refuses a
  # ShellCheck that differs from the pin (the version guard, as on the base), but is
  # not the off-macOS memory-cap refusal, which keys only on --strict-version.
  printf '0.10.0\n' > "$tmp/version"
  fm_lint_write_logging_shellcheck "$tmp/fake" "$tmp/starts.log" "$tmp/version"
  rc=0
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_REQUIRE_BOUNDS=0 FM_LINT_STRICT_VERSION=1 \
      bash bin/fm-lint.sh bin/consumer.sh > "$tmp/inherited.out" 2>&1 ) || rc=$?
  ! grep -q 'strict mode refuses' "$tmp/inherited.out" \
    || fm_lint_fail_settled "an inherited FM_LINT_STRICT_VERSION took the memory-cap refusal: $(cat "$tmp/inherited.out")"
  if ! { [ "$rc" -eq 1 ] && grep -q 'ShellCheck 0.11.0 required for CI parity, found 0.10.0' "$tmp/inherited.out"; }; then
    fm_lint_fail_settled "an inherited FM_LINT_STRICT_VERSION=1 did not refuse a mismatched version ($rc): $(cat "$tmp/inherited.out")"
  fi
  # Under the enforced envelope, on a host that can apply it, a strict run is refused
  # by the real CLI before any ShellCheck starts.
  if fm_lint_bounds_supported; then
    : > "$tmp/starts.log"
    rc=0
    ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_REQUIRE_BOUNDS=1 \
        bash bin/fm-lint.sh --strict-version bin/consumer.sh > "$tmp/envelope.out" 2>&1 ) || rc=$?
    if ! { [ "$rc" -eq 2 ] && grep -q 'strict mode refuses on Linux' "$tmp/envelope.out"; }; then
      fm_lint_fail_settled "a strict run under the enforced envelope on Linux was not refused ($rc): $(cat "$tmp/envelope.out")"
    fi
    [ ! -s "$tmp/starts.log" ] || fm_lint_fail_settled "the refused strict run under the enforced envelope started ShellCheck: $(cat "$tmp/starts.log")"
  else
    printf '# SKIP (host cannot enforce the bounded envelope): the strict refusal under FM_LINT_REQUIRE_BOUNDS=1\n'
  fi
  pass "where the resident cap and the probe lane are not enforced a strict run refuses before any ShellCheck starts and names why, also under the enforced envelope; a non-strict run warns and goes on; an inherited FM_LINT_STRICT_VERSION=1 refuses a mismatched version but not on memory caps"
}

# (Main 1775 N4) A root whose watch lost every reader fails: the run exits nonzero and
# no reusable success is recorded for it, also when it is the run's only root. A root
# already waiting at the gate of the same run (two workers, one slot) is not admitted.
test_a_root_whose_readers_are_lost_fails_and_no_queued_root_is_admitted() {
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the resident watch runs on native macOS only): reader loss fails the root"
    return
  fi
  local tmp repo real_python real_ps rc=0
  tmp=$(fm_test_tmproot fm-lint-reader-loss)
  repo=$(fm_lint_isolated_copy "$tmp" loss)
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/fake" "$real_python"
  fm_lint_write_logging_shellcheck "$tmp/fake" "$tmp/starts.log"
  real_ps=$(command -v ps || true)
  printf '#!/bin/sh\ncase "$*" in *pgid=*) exit 1 ;; esac\n[ -n "%s" ] && exec "%s" "$@"\nexit 1\n' "$real_ps" "$real_ps" > "$tmp/fake/ps"
  chmod +x "$tmp/fake/ps"
  # (1) The only root: a compiled stand-in that exits 0 itself, but ran unmeasured.
  mkdir -p "$tmp/native"
  fm_lint_native_version_stub "$tmp/native" "$tmp/starts.log" 0.11.0 || { pass "SKIP (no C compiler for a native ShellCheck stand-in): reader loss fails the root"; return; }
  : > "$tmp/starts.log"
  ( cd "$repo" && env PATH="$tmp/native:$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
      FM_TEST_READER=exit FM_TEST_ANALYSIS_SECS=5 FM_TEST_ANALYSIS_RC=0 \
      FM_TEST_SIGNAL_LOG="$tmp/signals.log" bash bin/fm-lint.sh bin/consumer.sh > "$tmp/only.out" 2>&1 ) || rc=$?
  [ "$rc" -ne 0 ] || fm_lint_fail_settled "a run whose only root ran unmeasured exited 0: $(cat "$tmp/only.out")"
  grep -q 'reason=unmeasured' "$tmp/only.out" || fm_lint_fail_settled "the run did not name the unmeasured root: $(cat "$tmp/only.out")"
  # (2) Two workers, one slot: the second root waits at the gate while the first
  # runs unmeasured, and is then not admitted.
  : > "$tmp/starts.log"
  rc=0
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_HOST_SLOTS=1 \
      FM_TEST_READER=exit FM_TEST_ANALYSIS_SECS=5 FM_TEST_ANALYSIS_RC=0 \
      FM_TEST_SIGNAL_LOG="$tmp/signals.log" bash bin/fm-lint.sh --jobs 2 bin/consumer.sh bin/library.sh > "$tmp/queued.out" 2>&1 ) || rc=$?
  [ "$rc" -ne 0 ] || fm_lint_fail_settled "a run with an unmeasured root exited 0: $(cat "$tmp/queued.out")"
  [ "$(grep -c -- '-- bin/' "$tmp/starts.log")" -eq 1 ] || fm_lint_fail_settled "a root waiting at the gate was admitted after the run's watch lost every reader: $(cat "$tmp/starts.log")"
  grep -q 'admits no new root' "$tmp/queued.out" || fm_lint_fail_settled "the gate did not say why it admitted no root: $(cat "$tmp/queued.out")"
  pass "a root that ran unmeasured fails the run and records no success, also as the only root; a root already waiting at the gate is not admitted"
}

# (Main 1775 N4) A reply that names a member whose pid now belongs to a process that
# started in the same second but not at the same instant (a replacement) is unknown,
# so the root's group is not ended for it and the root ends unmeasured (96). Every
# reply names the member with a start time 1 microsecond off. The control: named
# with its true start time, the process is counted and the root's group is ended
# over the bound; the process, outside that group, is never signalled and outlives
# the root, so the root fails (96) and records it (sends recorded).
test_a_same_second_replacement_is_not_counted_against_the_root() {
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the libproc identity reader is macOS only): same-second replacement"
    return
  fi
  local tmp real_python big identity sec usec label rc log
  tmp=$(fm_test_tmproot fm-lint-same-second)
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  for label in replacement control; do
    perl -e 'my $mib = shift; my $held = "x" x ($mib * 1024 * 1024); sleep 12' 160 > /dev/null 2>&1 &
    big=$!
    sleep 0.5
    identity=$(fm_lint_identity_of "$big") || fm_lint_fail_settled "could not read the start time of the large process"
    sec=${identity%%:*}
    usec=${identity##*:}
    [ "$label" = replacement ] && usec=$(( usec == 999999 ? usec - 1 : usec + 1 ))
    log="$tmp/signals.$label"
    : > "$log"
    rc=0
    FM_TEST_SIGNAL_LOG="$log" FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_READER=members \
      FM_TEST_MEMBER="$big:$sec:$usec" \
      perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 102400 "$tmp/rss.$label" -- sleep 6 > "$tmp/err.$label" 2>&1 || rc=$?
    wait "$big" 2>/dev/null || true
    if [ "$label" = replacement ]; then
      [ "$rc" -ne 98 ] || fm_lint_fail_settled "the watch ended the root over a same-second replacement it counted as its member: $(cat "$tmp/err.$label") / $(cat "$log")"
      ! grep -q '^killpg ' "$log" || fm_lint_fail_settled "the root's group was signalled over a same-second replacement: $(cat "$log")"
      # Main 1775/1791: the replacement makes the tree unknown, so the root ends
      # unmeasured (96), never quietly passed.
      if ! { [ "$rc" -eq 96 ] && grep -q '^rss_unmeasured=1$' "$tmp/rss.$label"; }; then
        fm_lint_fail_settled "a same-second replacement did not make the tree unknown (exit $rc): $(cat "$tmp/rss.$label")"
      fi
    else
      [ "$rc" -eq 96 ] || fm_lint_fail_settled "the watch did not count a member with its true start time, or did not fail the root it outlived ($rc): $(cat "$tmp/err.$label")"
      grep -q '^killpg ' "$log" || fm_lint_fail_settled "the root's group over the bound was not ended (recorded): $(cat "$log")"
      ! grep -q " $big " "$log" || fm_lint_fail_settled "the watch signalled the member outside the root's group: $(cat "$log")"
      grep -q "^rss_escaped=.*$big" "$tmp/rss.$label" || fm_lint_fail_settled "the member that outlived the root was not recorded: $(cat "$tmp/rss.$label")"
    fi
  done
  pass "a same-second replacement of a known member is not counted, so the root is not ended for it; the member with its true start time is counted, the root's group ended over the bound, and the member it never signals fails the root (sends recorded, none delivered)"
}

# (F5, Main 1846 F5, Main 1885 item 4) A counted descendant that left the process
# group is never signalled. Over the bound the watch ends the root's group, and the
# descendant, which outlives it, fails the root (96, rss_escaped=<pid>). Under the
# bound the same survivor of a normally ending root fails it too, with nothing sent.
# The control: a descendant that ends before its root is a completed tree, and the
# root passes. Every send is recorded by the stub, none delivered; the processes
# end on their own.
test_a_descendant_that_left_the_group_and_outlives_the_root_fails_it_unsignalled() {
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the libproc tree reader is macOS only): group-leaving descendant termination"
    return
  fi
  local tmp rc pid real_python label mib
  tmp=$(fm_test_tmproot fm-lint-leaver-kill)
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  cat > "$tmp/leaver-parent.sh" <<'SH'
perl -MPOSIX -e 'my ($mib, $secs) = @ARGV; POSIX::setpgid(0, 0); my $held = "x" x ($mib * 1024 * 1024); sleep $secs' "$2" "$3" &
echo "$!" > "$1"
sleep 5
SH
  for label in over under ended; do
    case "$label" in over) mib=160 secs=10 ;; under) mib=8 secs=10 ;; ended) mib=8 secs=2 ;; esac
    : > "$tmp/signals.$label"
    rc=0
    FM_TEST_SIGNAL_LOG="$tmp/signals.$label" FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" \
      perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 102400 "$tmp/rss.$label" -- \
      bash "$tmp/leaver-parent.sh" "$tmp/leaver.$label.pid" "$mib" "$secs" > "$tmp/err.$label" 2>&1 || rc=$?
    pid=$(cat "$tmp/leaver.$label.pid" 2>/dev/null || true)
    [ -n "$pid" ] || fm_lint_fail_settled "the group-leaving descendant did not start ($label)"
    if [ "$label" = over ]; then
      [ "$rc" -eq 96 ] || fm_lint_fail_settled "the watch exited $rc, expected 96 for a root over its bound whose counted descendant outlived it: $(cat "$tmp/err.$label")"
      grep -q '^killpg ' "$tmp/signals.over" || fm_lint_fail_settled "the root's group over the bound was not ended (recorded): $(cat "$tmp/signals.over")"
      ! grep -q " $pid " "$tmp/signals.over" || fm_lint_fail_settled "the watch signalled the descendant outside the root's group: $(cat "$tmp/signals.over")"
      grep -q "^rss_escaped=.*$pid" "$tmp/rss.over" || fm_lint_fail_settled "the descendant that outlived the root was not recorded: $(cat "$tmp/rss.over")"
    elif [ "$label" = under ]; then
      [ "$rc" -eq 96 ] || fm_lint_fail_settled "a normally ending root whose counted descendant outlived it exited $rc, expected 96: $(cat "$tmp/err.$label")"
      grep -q "^rss_escaped=.*$pid" "$tmp/rss.under" || fm_lint_fail_settled "the survivor of a normally ending root was not recorded: $(cat "$tmp/rss.under")"
      [ ! -s "$tmp/signals.under" ] || fm_lint_fail_settled "the watch signalled a tree under the bound: $(cat "$tmp/signals.under")"
    else
      [ "$rc" -eq 0 ] || fm_lint_fail_settled "a completed tree under the bound exited $rc: $(cat "$tmp/err.$label")"
      ! grep -q '^rss_escaped=' "$tmp/rss.ended" || fm_lint_fail_settled "a descendant that ended before its root was recorded as a survivor: $(cat "$tmp/rss.ended")"
      [ ! -s "$tmp/signals.ended" ] || fm_lint_fail_settled "the watch signalled a completed tree: $(cat "$tmp/signals.ended")"
    fi
  done
  wait 2>/dev/null || true
  pass "over the bound the watch ends only the root's group, never the counted descendant that left it; a survivor fails the root after an over-cap end and after a normal end alike, with nothing sent to it; a completed tree passes (sends recorded, none delivered)"
}

# (Main 1791 item 1, Main 3904) The rss-tree reader's own reply, as the watch asks
# for it ("bind <pid>:<sec>:<usec> ..."), on a fake process table: root 100042 (its
# own group), its child 100043, and member 100050, which the watch knows by identity
# and which sits outside the root's tree. Each scenario changes what the census
# lists, what a later identity read answers (another identity, ended, unreadable)
# and whether libproc reads the memory (160 MiB each). Prints
# "bound=<true|false|absent> members=<pids> kib=<n>".
fm_lint_fake_reader() {  # <scenario>
  local program
  program=$(cat <<'PY'
import importlib.util, json, os, struct, sys
spec = importlib.util.spec_from_file_location("fp", sys.argv[1])
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)
scenario = sys.argv[2]
ROOT, CHILD, KNOWN = 100042, 100043, 100050
def record(pid, ppid, sec, usec, stat=2, flag=0):
    data = bytearray(fp.KINFO_SIZE)
    struct.pack_into("qq", data, fp.P_START, sec, usec)
    struct.pack_into("i", data, fp.P_PID, pid)
    struct.pack_into("i", data, fp.P_FLAG, flag)
    data[fp.P_STAT] = stat
    struct.pack_into("i", data, fp.E_PPID, ppid)
    struct.pack_into("i", data, fp.E_PGID, KNOWN if pid == KNOWN else ROOT)
    struct.pack_into("I", data, fp.E_UID, os.geteuid())
    return bytes(data)
census = {ROOT: record(ROOT, 1, 100, 1), CHILD: record(CHILD, ROOT, 200, 1)}
request = "bind"
if scenario.startswith("known-"):
    census[KNOWN] = record(KNOWN, 1, 300, 2 if scenario == "known-same-second" else 1)
    request = "bind %d:100:1 %d:300:1" % (ROOT, KNOWN)
if scenario == "known-ended":
    del census[KNOWN]
later = dict(census)   # what a later identity read answers; absent: not in the table
readable = set(census)  # pids whose memory libproc reads
ends = set()            # pids that end right after their memory read
if scenario == "known-replaced":
    later[KNOWN] = record(KNOWN, 1, 300, 2)
elif scenario == "known-unreadable":
    later[KNOWN] = None
elif scenario == "child-ended":
    ends.add(CHILD)
elif scenario == "child-recycled":
    later[CHILD] = record(CHILD, ROOT, 200, 2)
elif scenario == "child-unreadable":
    later[CHILD] = None
elif scenario == "child-libproc-only":
    del later[CHILD]
elif scenario == "root-zombie":
    later[ROOT] = record(ROOT, 1, 100, 1, stat=fp.SZOMB)
elif scenario == "root-exiting":
    later[ROOT] = record(ROOT, 1, 100, 1, flag=fp.P_WEXIT)
elif scenario == "root-gone":
    del later[ROOT]
elif scenario == "plain":
    request = ""
ended = set()
def kinfo(pid):
    if pid in ended or pid not in later:
        raise LookupError(pid)
    if later[pid] is None:
        raise OSError("unreadable")
    return later[pid]
def memory(pid):
    if pid in ended or pid not in readable:
        raise LookupError(pid)
    if pid in ends:
        ended.add(pid)
    return (160 << 20, 160 << 20)
fp.kinfos = lambda *selector: iter(list(census.values()))
fp.kinfo, fp.memory = kinfo, memory
reply = json.loads(fp.rss_tree(ROOT, {}, request + "\n"))
print("bound=%s members=%s kib=%s" % (str(reply.get("bound", "absent")).lower(),
      ",".join(str(member[0]) for member in sorted(reply["members"])), reply["rss_kib"]))
PY
)
  python3 -I -B -c "$program" "$ROOT/bin/fm-proc-info.py" "$1"
}

# A member the watch knows by identity outside the root's tree is counted only when
# the census lists it with exactly that identity and the read after the census
# agrees. A replacement between the reads, a same-second replacement and a member
# whose identity read fails are not bound; a member in neither the table nor
# libproc has ended and is dropped. A request with no "bind" (fm-proc-budget's) gets
# the reply it always had.
test_the_exact_member_reader_counts_only_an_unchanged_identity() {
  local out
  out=$(fm_lint_fake_reader known-replaced)
  [ "$out" = "bound=false members=100042,100043,100050 kib=491520" ] || fail "a replacement between the census and the identity read was bound: '$out'"
  out=$(fm_lint_fake_reader known-same-second)
  [ "$out" = "bound=false members=100042,100043 kib=327680" ] || fail "a same-second replacement of a known member was bound: '$out'"
  out=$(fm_lint_fake_reader known-unreadable)
  [ "$out" = "bound=false members=100042,100043,100050 kib=491520" ] || fail "a known member whose identity read fails was bound: '$out'"
  out=$(fm_lint_fake_reader known-ended)
  [ "$out" = "bound=true members=100042,100043 kib=327680" ] || fail "a known member in neither the table nor libproc was not dropped as ended: '$out'"
  out=$(fm_lint_fake_reader known-unchanged)
  [ "$out" = "bound=true members=100042,100043,100050 kib=491520" ] || fail "an unchanged known member was not counted: '$out'"
  out=$(fm_lint_fake_reader plain)
  [ "$out" = "bound=absent members=100042,100043 kib=327680" ] || fail "a plain request did not get the unbound reply it always had: '$out'"
  pass "the reader counts a known member only with its recorded identity; a replacement between reads, a same-second replacement and a failed identity read are not bound; an ended member is dropped; a plain request is unchanged"
}

# (Main 1791 item 2) The probe lane is a record naming the probe by its exact
# identity; it frees only when that process has provably ended. A record left by a
# run whose helper died, naming a probe that still runs (a test-owned process that
# ends on its own after 8 s), holds the lane: the next run reports blocked, starts no
# probe, and probes once that process has ended. The control: a record naming a
# process that has ended frees the lane at once. The copy's bound is 1 s.
test_a_probe_lane_left_by_a_dead_run_stays_held_until_its_probe_ends() {
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the libproc identity reader is macOS only): probe lane record"
    return
  fi
  local tmp repo holder identity rc=0 probe_wait short short_id waited
  tmp=$(fm_test_tmproot fm-lint-probe-record)
  repo=$(fm_lint_isolated_copy "$tmp" record)
  perl -pi -e 's{^PROBE_BOUND_SECONDS=.*$}{PROBE_BOUND_SECONDS=1}' "$repo/bin/fm-lint.sh"
  fm_lint_write_logging_shellcheck "$tmp/fake" "$tmp/starts.log"
  sleep 8 > /dev/null 2>&1 &
  holder=$!
  identity=$(fm_lint_identity_of "$holder") || fm_lint_fail_settled "could not read the start time of the stand-in probe"
  printf '999999\t%s\t%s\t%s\t0\n' "$holder" "${identity%%:*}" "${identity##*:}" > "$tmp/record/host/admission.lock.probe.holder"
  : > "$tmp/starts.log"
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_ANALYSIS_RC=0 \
      FM_LINT_TELEMETRY="$tmp/held.tsv" bash bin/fm-lint.sh bin/consumer.sh > "$tmp/held.out" 2>&1 ) &
  # The run needs a second or more to reach the lane (its census first, longer under
  # load) and then waits past the 1 s bound: look for its report for up to 6 s.
  waited=0
  while ! grep -q 'blocked: the version probe lane' "$tmp/held.out" && [ "$waited" -lt 60 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ ! -s "$tmp/starts.log" ] || fm_lint_fail_settled "a probe started while the lane record named a probe that still runs: $(cat "$tmp/starts.log")"
  grep -q 'blocked: the version probe lane' "$tmp/held.out" || fm_lint_fail_settled "the waiting run did not report it was blocked: $(cat "$tmp/held.out")"
  wait "$!" || rc=$?
  [ "$rc" -eq 0 ] || fm_lint_fail_settled "the run did not finish once the recorded probe ended ($rc): $(cat "$tmp/held.out")"
  probe_wait=$(awk -F '\t' '$1 == "meta" && $2 == "probe_wait_ms" { print $3 }' "$tmp/held.roots.tsv")
  [ -n "$probe_wait" ] && [ "$probe_wait" -ge 2000 ] || fm_lint_fail_settled "the run recorded a lane wait of ${probe_wait:-none} ms"
  wait 2>/dev/null || true
  # The control: a record naming a process that has ended.
  sleep 0.1 > /dev/null 2>&1 &
  short=$!
  short_id=$(fm_lint_identity_of "$short") || short_id=1:1
  wait "$short" 2>/dev/null || true
  printf '999999\t%s\t%s\t%s\t0\n' "$short" "${short_id%%:*}" "${short_id##*:}" > "$tmp/record/host/admission.lock.probe.holder"
  rc=0
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_ANALYSIS_RC=0 \
      FM_LINT_TELEMETRY="$tmp/free.tsv" bash bin/fm-lint.sh bin/consumer.sh > "$tmp/free.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] || fm_lint_fail_settled "a record naming an ended probe did not free the lane ($rc): $(cat "$tmp/free.out")"
  probe_wait=$(awk -F '\t' '$1 == "meta" && $2 == "probe_wait_ms" { print $3 }' "$tmp/free.roots.tsv")
  [ -n "$probe_wait" ] && [ "$probe_wait" -lt 1000 ] || fm_lint_fail_settled "a record naming an ended probe still made the run wait ${probe_wait:-none} ms"
  [ ! -e "$tmp/record/host/admission.lock.probe.holder" ] || fm_lint_fail_settled "the lane record was not removed after the probe ended"
  pass "a lane record naming a probe that still runs held the lane after its run had gone: the next run reported blocked, waited, and probed once it ended; a record naming an ended probe freed the lane at once"
}

# (Main 1791 item 4, Main 1862) A launcher whose delegate changes between runs of one
# version: every run is analysed (no result is reused), so delegate B's finding is
# reported after delegate A passed, and back on A the run is analysed again.
test_a_launcher_switching_delegates_is_analysed_every_run() {
  local tmp repo rc
  tmp=$(fm_test_tmproot fm-lint-delegate-switch)
  repo=$(fm_lint_isolated_copy "$tmp" delegate)
  mkdir -p "$tmp/fake"
  printf 'A\n' > "$tmp/delegate.choice"
  cat > "$tmp/fake/shellcheck" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$(cat '$tmp/delegate.choice')" "\$*" >> '$tmp/starts.log'
if [ "\${1:-}" = --version ]; then printf 'ShellCheck - shell script analysis tool\nversion: 0.11.0\n'; exit 0; fi
if [ "\$(cat '$tmp/delegate.choice')" = B ]; then
  for a in "\$@"; do last=\$a; done
  printf 'In %s line 1:\nSC9998 (warning): delegate B finding\n' "\$last"
  exit 1
fi
exit 0
EOF
  chmod +x "$tmp/fake/shellcheck"
  rc=0
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
      bash bin/fm-lint.sh bin/consumer.sh > "$tmp/a.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] || fail "delegate A's run failed ($rc): $(cat "$tmp/a.out")"
  printf 'B\n' > "$tmp/delegate.choice"
  rc=0
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
      bash bin/fm-lint.sh bin/consumer.sh > "$tmp/b.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 1 ] || fail "delegate B's run did not report its finding (exit $rc): $(cat "$tmp/b.out")"
  grep -q 'SC9998' "$tmp/b.out" || fail "delegate B's finding was not reported: $(cat "$tmp/b.out")"
  printf 'A\n' > "$tmp/delegate.choice"
  : > "$tmp/starts.log"
  ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' \
      bash bin/fm-lint.sh bin/consumer.sh > "$tmp/a2.out" 2>&1 ) || fail "delegate A's second run failed: $(cat "$tmp/a2.out")"
  grep -v -- '--version' "$tmp/starts.log" | grep -q '^A .*bin/consumer[.]sh' || fail "delegate A's second run was not analysed: $(cat "$tmp/starts.log")"
  pass "after delegate A passed, delegate B of the same version was analysed and its finding reported, and back on A the run was analysed again"
}
# (Main 1791 item 5) A watch that cannot write the run's stop mark (its directory is
# made read-only while the first root runs unmeasured) still stops the run: the root
# fails, the worker cannot mark it either and stops, and the root waiting at the gate
# (two workers, one slot) is refused because the mark location cannot be checked. The
# control: with readers healthy, the same run analyzes both roots.
test_a_stop_mark_that_cannot_be_written_still_admits_no_new_root() {
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the resident watch runs on native macOS only): stop mark failure"
    return
  fi
  local tmp repo real_python real_ps rc=0 run waited tmproot
  tmp=$(fm_test_tmproot fm-lint-mark-failure)
  repo=$(fm_lint_isolated_copy "$tmp" mark)
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/fake" "$real_python"
  mkdir -p "$tmp/native" "$tmp/tmpdir"
  fm_lint_native_version_stub "$tmp/native" "$tmp/starts.log" 0.11.0 || { pass "SKIP (no C compiler for a native ShellCheck stand-in): stop mark failure"; return; }
  real_ps=$(command -v ps || true)
  printf '#!/bin/sh\ncase "$*" in *pgid=*) exit 1 ;; esac\n[ -n "%s" ] && exec "%s" "$@"\nexit 1\n' "$real_ps" "$real_ps" > "$tmp/fake/ps"
  chmod +x "$tmp/fake/ps"
  : > "$tmp/starts.log"
  ( cd "$repo" && env TMPDIR="$tmp/tmpdir" PATH="$tmp/native:$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_HOST_SLOTS=1 \
      FM_TEST_READER=exit FM_TEST_ANALYSIS_SECS=6 FM_TEST_SIGNAL_LOG="$tmp/signals.log" \
      bash bin/fm-lint.sh --jobs 2 bin/consumer.sh bin/library.sh > "$tmp/out" 2>&1 ) &
  run=$!
  waited=0
  while ! grep -q -- '-- bin/' "$tmp/starts.log" && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  tmproot=$(find "$tmp/tmpdir" -maxdepth 1 -name 'fm-lint.*' -type d | head -1)
  [ -n "$tmproot" ] || fm_lint_fail_settled "the run's temporary directory was not found"
  chmod 555 "$tmproot"
  wait "$run" || rc=$?
  chmod 755 "$tmproot"
  [ "$rc" -ne 0 ] || fm_lint_fail_settled "a run whose stop mark could not be written exited 0: $(cat "$tmp/out")"
  [ "$(grep -c -- '-- bin/' "$tmp/starts.log")" -eq 1 ] || fm_lint_fail_settled "a second root was admitted although the run could not be marked to stop: $(cat "$tmp/starts.log")"
  grep -q 'could not mark the run' "$tmp/out" || fm_lint_fail_settled "the failed stop mark was not said: $(cat "$tmp/out")"
  # The control: readers healthy, both roots analyzed.
  : > "$tmp/starts.log"
  rc=0
  ( cd "$repo" && env TMPDIR="$tmp/tmpdir" PATH="$tmp/native:$PATH" CI='' GITHUB_ACTIONS='' FM_LINT_HOST_SLOTS=1 \
      bash bin/fm-lint.sh --jobs 2 bin/consumer.sh bin/library.sh > "$tmp/control.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] && [ "$(grep -c -- '-- bin/' "$tmp/starts.log")" -eq 2 ] || fm_lint_fail_settled "with readers healthy the run did not analyze both roots ($rc): $(cat "$tmp/control.out")"
  pass "a stop mark that could not be written still stopped the run: the unmeasured root failed, no second root was admitted, and the failure was said; with readers healthy both roots ran"
}

# (Main 1806 item 1, Main 3904) Descendants: the reader binds a child only with the
# identity the census listed it under. Child 100043 now holds another identity (a
# recycled pid), its identity read fails, or the kernel table no longer lists it
# while libproc still reads it: not bound. The child ended after its memory read
# (in neither the table nor libproc): dropped, and the reply is bound. The control:
# the unchanged child is counted.
test_the_exact_member_reader_adopts_a_child_only_with_its_listed_identity() {
  local out scenario
  for scenario in child-recycled child-unreadable child-libproc-only; do
    out=$(fm_lint_fake_reader "$scenario")
    [ "${out%% *}" = bound=false ] || fail "a child that is not provably the listed process was bound ($scenario): '$out'"
  done
  out=$(fm_lint_fake_reader child-ended)
  [ "$out" = "bound=true members=100042 kib=327680" ] || fail "a child that ended after the census was not dropped from a bound reply: '$out'"
  out=$(fm_lint_fake_reader known-unchanged)
  [ "$out" = "bound=true members=100042,100043,100050 kib=491520" ] || fail "an unchanged child was not counted: '$out'"
  pass "the reader binds a child only with its listed identity; a recycled, unreadable or table-less child is not bound; an ended child is dropped; an unchanged child is counted"
}

# (Main 1806 item 2) An empty or damaged lane record holds the lane: the next run
# reports blocked and starts no probe; once the damaged record is removed (the repair
# the message names) the run probes. The copy's bound is 1 s.
test_an_empty_or_damaged_lane_record_holds_the_lane() {
  local tmp repo kind rc waited run
  tmp=$(fm_test_tmproot fm-lint-lane-damaged)
  repo=$(fm_lint_isolated_copy "$tmp" damaged)
  perl -pi -e 's{^PROBE_BOUND_SECONDS=.*$}{PROBE_BOUND_SECONDS=1}' "$repo/bin/fm-lint.sh"
  fm_lint_write_logging_shellcheck "$tmp/fake" "$tmp/starts.log"
  for kind in empty damaged; do
    if [ "$kind" = empty ]; then : > "$tmp/damaged/host/admission.lock.probe.holder"; else printf 'not a record\n' > "$tmp/damaged/host/admission.lock.probe.holder"; fi
    : > "$tmp/starts.log"
    rc=0
    ( cd "$repo" && env PATH="$tmp/fake:$PATH" CI='' GITHUB_ACTIONS='' FM_TEST_ANALYSIS_RC=0 \
        bash bin/fm-lint.sh bin/consumer.sh > "$tmp/$kind.out" 2>&1 ) &
    run=$!
    waited=0
    while ! grep -q 'blocked: the version probe lane' "$tmp/$kind.out" && [ "$waited" -lt 60 ]; do sleep 0.1; waited=$((waited + 1)); done
    if [ -s "$tmp/starts.log" ] || ! grep -q 'blocked: the version probe lane' "$tmp/$kind.out"; then
      rm -f "$tmp/damaged/host/admission.lock.probe.holder"
      wait "$run" 2>/dev/null || true
      fail "an $kind lane record did not hold the lane (probe started: $(cat "$tmp/starts.log"); output: $(cat "$tmp/$kind.out"))"
    fi
    rm -f "$tmp/damaged/host/admission.lock.probe.holder"
    wait "$run" || rc=$?
    [ "$rc" -eq 0 ] || fail "the run did not probe and finish once the $kind record was removed ($rc): $(cat "$tmp/$kind.out")"
  done
  pass "an empty or a damaged lane record holds the lane (the run reports blocked and starts no probe); once removed, the run probes and finishes"
}

# (Main 1806 item 3, Main 1846 F2) Positive proof: a new root is admitted only while
# every watched running root's measurement record names a successful sample at most
# 5 s old. A live ledger entry for a watched root keeps a new root out while its
# record is absent (not yet sampled), empty, invalidated ("failed ...") or names a
# sample 60 s old, whatever the file's own time; once it names a fresh sample the
# root is admitted. The control: beside a fresh sample the root is admitted at once.
test_a_stale_measurement_record_admits_no_new_root() {
  local tmp root pid waited state
  tmp=$(fm_test_tmproot fm-lint-stale-health)
  FM_LINT_RELEASE_FILES="$tmp/release"
  mkdir -p "$tmp/bin" "$tmp/host.lock.ledger"
  fm_lint_write_barrier_shellcheck "$tmp/bin" 8 "$tmp/barrier.log"
  root="$tmp/a.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root"
  perl -MFcntl=:flock -MTime::HiRes=sleep,time -e '
    my ($dir, $peak, $release, $ready) = @ARGV;
    my $path = "$dir/entry.$$.1";
    open(my $fh, ">>", $path) or die; flock($fh, LOCK_EX) or die;
    truncate($fh, 0); syswrite($fh, "$$\t65536\t$peak\t1\n");
    open(my $r, ">", $ready) or die; close $r;
    my $u = time() + 120; sleep 0.05 until -e $release || time() > $u; unlink $path;' \
    "$tmp/host.lock.ledger" "$tmp/peak" "$tmp/release" "$tmp/ready" &
  waited=0
  while [ ! -e "$tmp/ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  sample_at() { perl -MTime::HiRes=time -e 'printf "sample %.6f\n", time() - $ARGV[0]' "$1"; }
  for state in absent empty failed old; do
    : > "$tmp/barrier.log"
    rm -f "$tmp/peak.health"
    case "$state" in
      empty) : > "$tmp/peak.health" ;;
      failed) printf 'failed a sample was missed\n' > "$tmp/peak.health" ;;
      old) sample_at 60 > "$tmp/peak.health" ;;
    esac
    FM_TEST_MEM_HOLD=0.2 PATH="$tmp/bin:$PATH" fm_lint_gate_root 100000000 "$tmp/pool" "$state" "$root" -- \
      "$tmp/bin/shellcheck" --norc -- "$root" > "$tmp/$state.out" 2>&1 &
    pid=$!
    sleep 3
    [ ! -s "$tmp/barrier.log" ] || fm_lint_fail_settled "a root was admitted beside a watched root whose measurement record is $state"
    sample_at 0 > "$tmp/peak.health"
    wait "$pid" || fm_lint_fail_settled "the root failed once the record named a fresh sample ($state): $(cat "$tmp/$state.out")"
    [ "$(grep -c '^start ' "$tmp/barrier.log")" -eq 1 ] || fm_lint_fail_settled "the root did not start once the record named a fresh sample ($state)"
    [ "$(cat "$tmp/pool.wait.$state")" -ge 2500 ] || fm_lint_fail_settled "the recorded wait $(cat "$tmp/pool.wait.$state") ms is shorter than the record stayed $state"
  done
  # The control: a fresh sample admits at once.
  : > "$tmp/barrier.log"
  sample_at 0 > "$tmp/peak.health"
  FM_TEST_MEM_HOLD=0.2 PATH="$tmp/bin:$PATH" fm_lint_gate_root 100000000 "$tmp/pool" fresh "$root" -- \
    "$tmp/bin/shellcheck" --norc -- "$root" > "$tmp/fresh.out" 2>&1 || fm_lint_fail_settled "the root beside a fresh sample failed: $(cat "$tmp/fresh.out")"
  [ "$(cat "$tmp/pool.wait.fresh")" -lt 1000 ] || fm_lint_fail_settled "a root beside a fresh sample waited $(cat "$tmp/pool.wait.fresh") ms"
  : > "$tmp/release"
  wait 2>/dev/null || true
  pass "a watched running root whose record is absent, empty, invalidated or names an old sample keeps every new root out; once it names a fresh sample the root is admitted; beside a fresh sample it is admitted at once"
}

# (Main 1806 item 4, Main 1846 F3) Reader loss wins over an over-cap end. Every
# reader fails (loss): the root is never measured and exits 96. A short loss: the
# first reader answers once and exits, a new reader then answers every tick and the
# root grows past the bound: still 96, not 98, so no memory retry can follow.
# The control: with a reader throughout, the same growth ends with 98.
test_reader_loss_followed_by_an_over_cap_reading_still_fails_unmeasured() {
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the resident watch runs on native macOS only): reader loss then over-cap"
    return
  fi
  local tmp real_python rc label reader
  tmp=$(fm_test_tmproot fm-lint-loss-then-over)
  real_python=$(command -v python3) || fail "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  cat > "$tmp/root.sh" <<'SH'
perl -e 'my $mib = shift; sleep 6; my $held = "x" x ($mib * 1024 * 1024); sleep 3' 160
SH
  for label in loss short control; do
    rc=0
    case "$label" in loss) reader='exit' ;; short) reader='dieafter:1' ;; control) reader='' ;; esac
    FM_TEST_SIGNAL_LOG="$tmp/signals.$label" FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_READER="$reader" \
      FM_TEST_READER_MARK="$tmp/mark.$label" \
      perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 102400 "$tmp/rss.$label" -- bash "$tmp/root.sh" > "$tmp/err.$label" 2>&1 || rc=$?
    if [ "$label" != control ]; then
      [ "$rc" -eq 96 ] || fail "a root unmeasured for its first ticks ($label) and later over the bound exited $rc, expected 96: $(cat "$tmp/err.$label") $(cat "$tmp/rss.$label")"
      grep -q '^rss_unmeasured=1$' "$tmp/rss.$label" || fail "the unmeasured interval was not recorded: $(cat "$tmp/rss.$label")"
    else
      [ "$rc" -eq 98 ] || fail "the control over the bound exited $rc, expected 98: $(cat "$tmp/err.$label")"
    fi
  done
  pass "a root unmeasured for an interval, long or short, and later over the bound exits 96 (unmeasured), not 98; measured throughout, the same growth exits 98"
}

# (Main 2421 RV-2, Main 3923) Every reply has 6 s, and a late reply is read once
# more in the same tick (1 s) before it is a miss, so a reply is late only after 7 s.
# The first reader answers one request late: its first at 3.4 s or its third at
# 3.4 s (inside the 6 s), or its third at 6.5 s (after the 6 s read, inside the 1 s
# retry); in each the root runs to its own result (0), measured throughout, with
# that reply used. Answered 7.5 s late, the read and its retry both miss
# (rss_miss=late, about 7000 ms waited), and the root exits 96 (unmeasured).
test_a_late_reply_is_retried_once_in_the_same_tick() {
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the resident watch runs on native macOS only): late reply retried once"
    return
  fi
  local tmp real_python rc label request delay hold latency waited
  tmp=$(fm_test_tmproot fm-lint-late-retry)
  real_python=$(command -v python3) || fail "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  for label in first later retried missed; do
    rc=0
    case "$label" in
      first) request=1 delay=3.4 hold=8 ;;
      later) request=3 delay=3.4 hold=10 ;;
      retried) request=3 delay=6.5 hold=13 ;;
      missed) request=3 delay=7.5 hold=18 ;;
    esac
    FM_TEST_SIGNAL_LOG="$tmp/signals.$label" FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_READER="late:$request:$delay" \
      FM_TEST_READER_MARK="$tmp/mark.$label" \
      perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 8388608 "$tmp/rss.$label" -- sleep "$hold" > "$tmp/err.$label" 2>&1 || rc=$?
    [ -e "$tmp/mark.$label" ] || fail "the late reader never ran ($label): $(cat "$tmp/err.$label")"
    if [ "$label" != missed ]; then
      [ "$rc" -eq 0 ] || fail "a root whose reply was $delay s late ($label) exited $rc, expected 0: $(cat "$tmp/err.$label") $(cat "$tmp/rss.$label" 2>/dev/null)"
      ! grep -q '^rss_unmeasured=1$' "$tmp/rss.$label" 2>/dev/null || fail "a reply $delay s late ($label) was recorded as unmeasured: $(cat "$tmp/rss.$label")"
      ! grep -q '^rss_miss=late,' "$tmp/rss.$label" || fail "a reply $delay s late ($label) was recorded as a late miss: $(cat "$tmp/rss.$label")"
      latency=$(sed -n 's/^rss_longest_reply_ms=//p' "$tmp/rss.$label")
      [ "${latency:-0}" -ge "${delay%.*}000" ] || fail "the $delay s reply ($label) was not the one used: longest reply ${latency:-none} ms"
    else
      waited=$(sed -n 's/^rss_miss=late,wait_ms=\([0-9]*\),.*/\1/p' "$tmp/rss.$label" | head -n 1)
      [ "${waited:-0}" -ge 6900 ] || fail "the 7.5 s reply was not a late miss after about 7 s: $(cat "$tmp/rss.$label" 2>/dev/null)"

      [ "$rc" -eq 96 ] || fail "a root whose read and retry both missed exited $rc, expected 96: $(cat "$tmp/err.$label") $(cat "$tmp/rss.$label" 2>/dev/null)"
      grep -q '^rss_unmeasured=1$' "$tmp/rss.$label" || fail "the missed tick was not recorded as unmeasured: $(cat "$tmp/rss.$label")"
    fi
  done
  pass "a first or later reply 3.4 s late is a sample, one 6.5 s late is good on the same-tick retry, each keeping the root to its own result (0); a reply 7.5 s late is a late miss after about 7 s and ends the root with 96 (unmeasured)"
}

# (Main 3511) A signal that interrupts a reply wait (EINTR) waits again for the time
# left and does not spend the retry. The watch runs with a USR1 handler that logs
# each signal; the reader signals it twice while it waits for its second reply,
# then answers 0.3 s after the request, inside the 6 s wait. No tick is a miss
# and the root runs to its own result (0). Without the deadline, the first
# interrupt spent the retry and the second made the tick a miss (96).
test_an_interrupted_reply_wait_with_a_reply_in_time_is_no_miss() {
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the resident watch runs on native macOS only): interrupted reply wait"
    return
  fi
  local tmp real_python rc=0 latency
  tmp=$(fm_test_tmproot fm-lint-interrupted-wait)
  real_python=$(command -v python3) || fail "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  mkdir -p "$tmp/lib"
  cat > "$tmp/lib/FmTestInterrupt.pm" <<'PERL'
package FmTestInterrupt;
$SIG{USR1} = sub {
    if (open(my $log, '>>', $ENV{FM_TEST_INTERRUPT_LOG})) { print {$log} "interrupted\n"; close $log; }
};
1;
PERL
  FM_TEST_SIGNAL_LOG="$tmp/signals" FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_READER="interrupt:2" \
    FM_TEST_READER_MARK="$tmp/mark" FM_TEST_INTERRUPT_LOG="$tmp/interrupts" \
    perl -I"$tmp/lib" -MFmTestInterrupt "$ROOT/bin/fm-lint-cache.pl" rsswatch 8388608 "$tmp/rss" -- sleep 5 \
    > "$tmp/err" 2>&1 || rc=$?
  [ -e "$tmp/mark" ] || fail "the interrupting reader never ran: $(cat "$tmp/err")"
  [ "$(grep -c '^interrupted$' "$tmp/interrupts" 2>/dev/null)" = 2 ] \
    || fail "the watch did not receive both interrupts: $(cat "$tmp/interrupts" 2>/dev/null) $(cat "$tmp/err")"
  [ "$rc" -eq 0 ] || fail "a root whose reply wait was interrupted, with the reply in time, exited $rc, expected 0: $(cat "$tmp/err") $(cat "$tmp/rss" 2>/dev/null)"
  # A miss on the root's own last tick (its exit) is exempt and may be recorded;
  # no tick that was interrupted may be a miss.
  ! grep -Eq '^rss_miss=.*interrupted=[1-9]' "$tmp/rss" || fail "an interrupted reply wait with the reply in time was recorded as a miss: $(cat "$tmp/rss")"
  ! grep -q '^rss_unmeasured=1$' "$tmp/rss" || fail "an interrupted reply wait with the reply in time was recorded as unmeasured: $(cat "$tmp/rss")"
  grep -Eq '^rss_samples=libproc:[2-9]' "$tmp/rss" || fail "the watch did not sample the root through the interrupted tick: $(cat "$tmp/rss")"
  latency=$(sed -n 's/^rss_longest_reply_ms=//p' "$tmp/rss")
  [ "${latency:-0}" -ge 250 ] || fail "the interrupted reply (0.3 s) was not the one waited for: longest reply ${latency:-none} ms"
  pass "a reply wait interrupted twice, with the reply in time, is no miss: the root runs to its own result (0), measured throughout"
}

# (Main 3904) The real reader runs with one extra child of the root in each census,
# a free pid (FM_TEST_READER=phantom:<label>). "ended": the child is in neither the
# kernel's table nor libproc when the reader reads it again (it ended after the
# census), so it holds no memory. "unreadable": libproc reads its memory but its
# identity read fails (a live member that cannot be read).
fm_lint_phantom_watch() {  # <tmp> <ended|unreadable>: the watch's exit status
  local rc=0
  FM_TEST_SIGNAL_LOG="$1/signals.$2" FM_LINT_INTERNAL_PYTHON="$1/stub/python3" FM_TEST_READER="phantom:$2" \
    perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 8388608 "$1/rss.$2" -- sleep 4 > "$1/err.$2" 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# A member that ended between the census and its identity read is dropped, and the
# tick is a sample, not a miss: the root runs to its own result (0), sampled through
# its run. Before Main 3904 each such tick was unbound and the root exited 96.
test_a_member_that_ended_after_the_census_is_a_sample_not_a_miss() {
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the resident watch runs on native macOS only): member ended after the census"
    return
  fi
  local tmp real_python rc
  tmp=$(fm_test_tmproot fm-lint-member-ended)
  real_python=$(command -v python3) || fail "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  rc=$(fm_lint_phantom_watch "$tmp" ended)
  [ "$rc" -eq 0 ] || fail "a root whose member ended after the census exited $rc, expected 0: $(cat "$tmp/err.ended") $(cat "$tmp/rss.ended" 2>/dev/null)"
  ! grep -q '^rss_unmeasured=1$' "$tmp/rss.ended" || fail "a member that ended after the census made the root unmeasured: $(cat "$tmp/rss.ended")"
  grep -Eq '^rss_samples=libproc:[2-9]' "$tmp/rss.ended" || fail "the watch did not sample the root whose member ended: $(cat "$tmp/rss.ended")"
  # A miss on the root's own last tick (its exit) is exempt and may be recorded.
  [ "$(grep -c '^rss_miss=' "$tmp/rss.ended")" -le 1 ] || fail "ticks with a member that ended after the census were misses: $(cat "$tmp/rss.ended")"
  pass "a member that ended between the census and its identity read is dropped and the tick is a sample: the root runs to its own result (0)"
}

# A live member whose identity cannot be read is still a miss: every tick is
# unbound, nothing is sampled, and the root exits 96 (unmeasured).
test_a_live_member_that_cannot_be_read_is_still_a_miss() {
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the resident watch runs on native macOS only): unreadable live member"
    return
  fi
  local tmp real_python rc
  tmp=$(fm_test_tmproot fm-lint-member-unreadable)
  real_python=$(command -v python3) || fail "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  rc=$(fm_lint_phantom_watch "$tmp" unreadable)
  [ "$rc" -eq 96 ] || fail "a root with a live member that cannot be read exited $rc, expected 96: $(cat "$tmp/err.unreadable") $(cat "$tmp/rss.unreadable" 2>/dev/null)"
  grep -q '^rss_unmeasured=1$' "$tmp/rss.unreadable" || fail "the unbound ticks were not recorded as unmeasured: $(cat "$tmp/rss.unreadable")"
  grep -q '^rss_miss=unbound,' "$tmp/rss.unreadable" || fail "the misses were not recorded as unbound: $(cat "$tmp/rss.unreadable")"
  grep -q '^rss_samples=libproc:0$' "$tmp/rss.unreadable" || fail "a tick with an unreadable live member was sampled: $(cat "$tmp/rss.unreadable")"
  pass "a live member whose identity cannot be read is a miss on every tick, and the root exits 96 (unmeasured)"
}

# (Main 2981, Main 2988, Main 3923) On a loaded host each reader reply comes late, so
# a tick that meets the root's own exit (a zombie, refused by the reply check and
# retried) outlasts the 1 s timer and the next tick ran before the watch could reap
# the root: a clean root ended 96. Each tick now reaps an exited root first. The
# root is shaped as bin/fm-lint.sh runs it (/usr/bin/time around the analysis),
# every reader reply is 1.5 s late (FM_TEST_READER=slow:1.5, so ticks run back to
# back), and the root keeps its own exit status, 0 or 3.
test_a_root_exit_under_slow_checks_keeps_its_own_status() {
  if [ "$(uname)" != Darwin ]; then
    pass "SKIP (the resident watch runs on native macOS only): root exit under slow checks"
    return
  fi
  local tmp real_python rc want
  tmp=$(fm_test_tmproot fm-lint-slow-exit)
  real_python=$(command -v python3) || fail "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  for want in 0 3; do
    rc=0
    FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_READER=slow:1.5 \
      perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 8388608 "$tmp/rss.$want" -- \
      /usr/bin/time -lp -o "$tmp/rss.$want" perl -e 'sleep 8; exit $ARGV[0]' "$want" > "$tmp/err.$want" 2>&1 || rc=$?
    [ "$rc" -eq "$want" ] || fail "a root that exited $want under 1.5 s slow replies ended $rc: $(cat "$tmp/err.$want") $(cat "$tmp/rss.$want" 2>/dev/null)"
    ! grep -q '^rss_unmeasured=1$' "$tmp/rss.$want" || fail "a root's own exit under slow replies was recorded as unmeasured: $(cat "$tmp/rss.$want")"
    grep -Eq '^rss_samples=libproc:[1-9]' "$tmp/rss.$want" || fail "the watch took no sample of the root: $(cat "$tmp/rss.$want")"
  done
  pass "under 1.5 s slow reader replies a root's own exit is reaped, not sampled as misses: it ends with its own status (0, and 3), measured and not unmeasured"
}

# (Main 1806 item 5, Main 1862) A compiled launcher that runs delegate A or B (one
# version, chosen by a file): every run is analysed, so after A passed B's finding is
# reported, and back on A the run is analysed again.
fm_lint_compiled_launcher_with_delegates() {  # <dir> <choice file>; 1 without cc
  local dir=$1 choice=$2 name
  command -v cc >/dev/null 2>&1 || return 1
  mkdir -p "$dir"
  for name in a b; do
    cat > "$dir/delegate-$name.c" <<C
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--version") == 0) { usleep(150000); printf("ShellCheck - shell script analysis tool\\nversion: 0.11.0\\n"); return 0; }
  if ("$name"[0] == 'b') { printf("In %s line 1:\\nSC9997 (warning): delegate B finding\\n", argv[argc - 1]); return 1; }
  return 0;
}
C
    cc -o "$dir/delegate-$name" "$dir/delegate-$name.c" 2>/dev/null || return 1
  done
  cat > "$dir/launcher.c" <<C
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
  char which[8] = "a", path[4096];
  FILE *f = fopen("$choice", "r");
  if (f) { if (fscanf(f, "%7s", which) != 1) strcpy(which, "a"); fclose(f); }
  snprintf(path, sizeof path, "$dir/delegate-%s", which);
  argv[0] = path;
  execv(path, argv);
  return 127;
}
C
  mkdir -p "$dir/bin"
  cc -o "$dir/bin/shellcheck" "$dir/launcher.c" 2>/dev/null || return 1
}

test_a_compiled_launcher_switching_delegates_is_analysed_every_run() {
  local tmp repo rc
  tmp=$(fm_test_tmproot fm-lint-compiled-delegates)
  repo=$(fm_lint_isolated_copy "$tmp" compiled)
  printf 'a\n' > "$tmp/choice"
  fm_lint_compiled_launcher_with_delegates "$tmp/c" "$tmp/choice" || { pass "SKIP (no C compiler): compiled launcher delegates"; return; }
  rc=0
  ( cd "$repo" && env PATH="$tmp/c/bin:$PATH" CI='' GITHUB_ACTIONS='' \
      bash bin/fm-lint.sh bin/consumer.sh > "$tmp/a1.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] || fail "delegate A's first run failed ($rc): $(cat "$tmp/a1.out")"
  printf 'b\n' > "$tmp/choice"
  rc=0
  ( cd "$repo" && env PATH="$tmp/c/bin:$PATH" CI='' GITHUB_ACTIONS='' \
      bash bin/fm-lint.sh bin/consumer.sh > "$tmp/b.out" 2>&1 ) || rc=$?
  [ "$rc" -eq 1 ] || fail "delegate B's run through the unchanged launcher did not report its finding (exit $rc): $(cat "$tmp/b.out")"
  grep -q 'SC9997' "$tmp/b.out" || fail "delegate B's finding was not reported: $(cat "$tmp/b.out")"
  printf 'a\n' > "$tmp/choice"
  ( cd "$repo" && env PATH="$tmp/c/bin:$PATH" CI='' GITHUB_ACTIONS='' \
      bash bin/fm-lint.sh bin/consumer.sh > "$tmp/a2.out" 2>&1 ) || fail "delegate A's second run failed: $(cat "$tmp/a2.out")"
  pass "a compiled launcher switched to delegate B reported B's finding, and every run, back on A included, was analysed"
}
# fm_lint_source_sub <name>: the text of sub <name> in bin/fm-lint-cache.pl.
fm_lint_source_sub() {
  perl -0ne 'BEGIN { $name = shift } print $1 if /^(sub \Q$name\E \{\n.*?^\}\n)/ms' "$1" "$ROOT/bin/fm-lint-cache.pl"
}

# (Main 1846 F3, Main 1885) The watch's tick and exit rules on synthetic ticks: a
# miss followed by any later tick is unmeasured, a miss on the last tick alone is
# not; 96 (unmeasured, a survivor, a failed publication, a lost signal or record)
# comes before 98.
test_the_watch_tick_and_exit_rules_hold_on_synthetic_ticks() {
  local subs out
  subs="$(fm_lint_source_sub fm_watch_unmeasured)$(fm_lint_source_sub fm_watch_exit)"
  [ -n "$subs" ] || fail "fm_watch_unmeasured or fm_watch_exit is missing"
  out=$(perl -e 'use strict; use warnings; '"$subs"'
print join(",", map { fm_watch_unmeasured(split / /, $_) } ("m s", "s m s s", "m m", "s s m", "s s", "")), "\n";
print join(",", fm_watch_exit(unmeasured => 1, status => 0), fm_watch_exit(unmeasured => 1, over => 1),
  fm_watch_exit(warned => 1, over => 1), fm_watch_exit(escaped => 1, status => 0), fm_watch_exit(unpublished => 1),
  fm_watch_exit(lost => 1, over => 1), fm_watch_exit(over => 1), fm_watch_exit(signal => 15), fm_watch_exit(status => 256),
  fm_watch_exit(status => 0)), "\n";' 2>&1)
  [ "$out" = "$(printf '1,1,1,0,0,0\n96,96,96,96,96,96,98,143,1,0')" ] || fail "the watch's tick or exit rule changed: $out"
  pass "a miss followed by a later tick is unmeasured and a last-tick miss is not; 96 comes before 98 for every unmeasured, survivor, publication or lost-signal end"
}

# (Main 1846 F2, Main 1885 item 3) The measurement record: only a sample at most 5 s
# old is proof; a published sample is read back; an invalidated record is not proof
# at once; a publication into a directory that takes no file fails, and the record
# is then invalidated in place; a record that cannot be invalidated at all (file and
# directory unwritable) is reported, which the watch answers by keeping the host
# admission lock (its header).
test_the_measurement_record_rules_hold_on_synthetic_records() {
  local subs tmp out
  subs="$(fm_lint_source_sub fm_health_publish)$(fm_lint_source_sub fm_health_invalidate)$(fm_lint_source_sub fm_health_fresh)"
  [ -n "$subs" ] || fail "a measurement record sub is missing"
  tmp=$(fm_test_tmproot fm-lint-record-rules)
  out=$(perl -e 'use strict; use warnings; '"$subs"'
my ($dir) = @ARGV;
my $path = "$dir/slot.1.peak.health";
my $now = time;
sub write_record { open(my $fh, ">", $path) or die; print {$fh} @_; close $fh; }
my @r;
push @r, fm_health_fresh($path, $now);
write_record(""); push @r, fm_health_fresh($path, $now);
write_record("failed a sample was missed\n"); push @r, fm_health_fresh($path, $now);
write_record(sprintf("sample %.6f\n", $now - 6)); push @r, fm_health_fresh($path, $now);
write_record(sprintf("sample %.6f\n", $now + 5)); push @r, fm_health_fresh($path, $now);
write_record(sprintf("sample %.6f\n", $now - 1)); push @r, fm_health_fresh($path, $now);
print join(",", @r), "\n";
unlink $path;
print join(",", fm_health_publish($path, $now), fm_health_fresh($path, $now), fm_health_invalidate($path, "a sample was missed"), fm_health_fresh($path, $now)), "\n";
write_record(sprintf("sample %.6f\n", $now));
chmod 0500, $dir;
my @f = (fm_health_publish($path, $now), fm_health_invalidate($path, "the sample could not be published"), fm_health_fresh($path, $now));
chmod 0700, $dir;
write_record(sprintf("sample %.6f\n", $now));
chmod 0400, $path; chmod 0500, $dir;
push @f, fm_health_invalidate($path, "x"), fm_health_fresh($path, $now);
chmod 0700, $dir; chmod 0600, $path;
print join(",", @f), "\n";' "$tmp" 2>&1)
  [ "$(printf '%s\n' "$out" | head -n 2)" = "$(printf '0,0,0,0,0,1\n1,1,1,0')" ] || fail "a measurement record rule changed: $out"
  if [ "$(id -u)" -eq 0 ]; then pass "SKIP (a read-only directory still takes files as root): the record that cannot be invalidated"; return; fi
  [ "$out" = "$(printf '0,0,0,0,0,1\n1,1,1,0\n0,1,0,0,1')" ] || fail "a measurement record rule changed: $out"
  pass "only a fresh sample is proof; a published sample is read back and invalidated at once; a failed publication is invalidated in place; a record that cannot be invalidated is reported (and stays fresh, which the watch answers with the host lock)"
}

# (Main 1846 F1, Main 1885 item 2, Main 3904) The reply check, run in the reader on
# a fake process table: a root that is a zombie, exiting or gone makes the reply
# unbound; an unchanged tree is bound.
test_the_reply_check_binds_members_and_refuses_a_zombie_root() {
  local out scenario
  for scenario in root-zombie root-exiting root-gone; do
    out=$(fm_lint_fake_reader "$scenario")
    [ "${out%% *}" = bound=false ] || fail "a reply whose root is not live was bound ($scenario): '$out'"
  done
  out=$(fm_lint_fake_reader bound)
  [ "$out" = "bound=true members=100042,100043 kib=327680" ] || fail "an unchanged tree was not bound: '$out'"
  pass "a reply is bound only when its root is neither a zombie, exiting nor gone and its members keep their identities"
}

# (Main 1885 item 4) A hold is counted only on a sent STOP; a CONT that is not sent
# keeps the root held, is tried once more, and then the root's group is ended and
# the root fails (96, rss_cont_failed=1). The control: a STOP that is never sent
# leaves the root unheld, no CONT is sent, and the root passes. Sends are recorded
# by the stub, never delivered.
test_a_failed_resume_ends_the_held_root_and_fails_it() {
  if [ "$(uname)" != Darwin ]; then pass "SKIP (the resident watch runs on native macOS only): failed resume"; return; fi
  local tmp real_python label rc pid waited stop cont kill_number
  tmp=$(fm_test_tmproot fm-lint-failed-resume)
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  stop=$(kill -l STOP); cont=$(kill -l CONT); kill_number=$(kill -l KILL)
  for label in cont stop; do
    : > "$tmp/signals.$label"
    : > "$tmp/peak.$label.hold"
    rc=0
    FM_TEST_SIGNAL_LOG="$tmp/signals.$label" FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_SEND_FAIL="$([ "$label" = cont ] && echo CONT || echo STOP)" \
      FM_LINT_INTERNAL_SLOT_PEAK_FILE="$tmp/peak.$label" \
      perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 8388608 "$tmp/rss.$label" -- sleep 7 > "$tmp/err.$label" 2>&1 &
    pid=$!
    waited=0
    while ! grep -q "^killpg [0-9]* $stop\$" "$tmp/signals.$label" && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
    rm -f "$tmp/peak.$label.hold"
    wait "$pid" || rc=$?
    if [ "$label" = cont ]; then
      { [ "$rc" -eq 96 ] && grep -q '^rss_cont_failed=1$' "$tmp/rss.cont"; } \
        || fm_lint_fail_settled "a root whose resume failed twice exited $rc, expected 96 with rss_cont_failed: $(cat "$tmp/err.cont") $(cat "$tmp/rss.cont")"
      [ "$(grep -c "^killpg [0-9]* $cont\$" "$tmp/signals.cont")" -eq 2 ] || fm_lint_fail_settled "a failed resume was not tried exactly twice: $(cat "$tmp/signals.cont")"
      grep -q "^killpg [0-9]* $kill_number\$" "$tmp/signals.cont" || fm_lint_fail_settled "the root left held was not ended: $(cat "$tmp/signals.cont")"
    else
      [ "$rc" -eq 0 ] || fm_lint_fail_settled "a root whose hold was never sent exited $rc: $(cat "$tmp/err.stop")"
      ! grep -q "^killpg [0-9]* $cont\$" "$tmp/signals.stop" || fm_lint_fail_settled "a root never held was sent a resume: $(cat "$tmp/signals.stop")"
    fi
  done
  pass "a failed resume keeps the root held, is retried once, then ends the root, which fails (96); a hold that was never sent is not counted and needs no resume"
}

# (Main 1885 rule O) A watch that cannot record its root's start time never lets the
# root execute: it exits 96 with rss_launch_unrecorded=1 and the command never ran.
test_a_root_whose_start_time_cannot_be_recorded_never_runs() {
  if [ "$(uname)" != Darwin ]; then pass "SKIP (the resident watch runs on native macOS only): launch record"; return; fi
  local tmp real_python rc=0
  tmp=$(fm_test_tmproot fm-lint-launch-record)
  real_python=$(command -v python3) || fail "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_IDENTITY=fail FM_TEST_SIGNAL_LOG="$tmp/signals.log" \
    perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 8388608 "$tmp/rss" -- touch "$tmp/ran" > "$tmp/err" 2>&1 || rc=$?
  { [ "$rc" -eq 96 ] && grep -q '^rss_launch_unrecorded=1$' "$tmp/rss"; } || fail "a watch without its root's start time exited $rc: $(cat "$tmp/err")"
  [ ! -e "$tmp/ran" ] || fail "the root executed before its start time was recorded"
  [ ! -s "$tmp/signals.log" ] || fail "a signal was sent without a launch record: $(cat "$tmp/signals.log")"
  rc=0
  FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_SIGNAL_LOG="$tmp/signals.log" \
    perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 8388608 "$tmp/rss.control" -- touch "$tmp/ran" > "$tmp/err.control" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && [ -e "$tmp/ran" ] || fail "the control watch with a readable start time did not run its root ($rc): $(cat "$tmp/err.control")"
  pass "a root whose start time cannot be recorded never executes (96); with the record the same root runs"
}

# (Main 1885 item 3) A live host-ledger entry that cannot be read as an entry names
# no root, charge or record: it is never charged at the requester's worst case and
# refuses every admission while it is held, and the gate says so; once its holder
# ends, the root is admitted.
test_a_live_malformed_ledger_entry_admits_no_root() {
  local tmp root pid waited
  tmp=$(fm_test_tmproot fm-lint-malformed-entry)
  FM_LINT_RELEASE_FILES="$tmp/release"
  mkdir -p "$tmp/bin" "$tmp/host.lock.ledger"
  fm_lint_write_barrier_shellcheck "$tmp/bin" 8 "$tmp/barrier.log"
  root="$tmp/a.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$root"
  : > "$tmp/barrier.log"
  perl -MFcntl=:flock -MTime::HiRes=sleep,time -e '
    my ($dir, $release, $ready) = @ARGV;
    my $path = "$dir/entry.$$.1";
    open(my $fh, ">>", $path) or die; flock($fh, LOCK_EX) or die;
    truncate($fh, 0); syswrite($fh, "not an entry\n");
    open(my $r, ">", $ready) or die; close $r;
    my $u = time() + 60; sleep 0.05 until -e $release || time() > $u; unlink $path;' \
    "$tmp/host.lock.ledger" "$tmp/release" "$tmp/ready" &
  waited=0
  while [ ! -e "$tmp/ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  FM_TEST_MEM_HOLD=0.2 PATH="$tmp/bin:$PATH" fm_lint_gate_root 100000000 "$tmp/pool" malformed "$root" -- \
    "$tmp/bin/shellcheck" --norc -- "$root" > "$tmp/malformed.out" 2>&1 &
  pid=$!
  sleep 3
  [ ! -s "$tmp/barrier.log" ] || fm_lint_fail_settled "a root was admitted beside a live ledger entry that cannot be read"
  grep -q 'cannot be read as an entry' "$tmp/malformed.out" || fm_lint_fail_settled "the gate did not name the unreadable entry: $(cat "$tmp/malformed.out")"
  : > "$tmp/release"
  wait "$pid" || fm_lint_fail_settled "the root failed once the entry was freed: $(cat "$tmp/malformed.out")"
  [ "$(grep -c '^start ' "$tmp/barrier.log")" -eq 1 ] || fm_lint_fail_settled "the root did not start once the entry was freed"
  wait 2>/dev/null || true
  pass "a live ledger entry that cannot be read refuses every admission and is named; once freed, the root is admitted"
}

# (Main 1885 item 3) A measurement record that cannot be invalidated (its file and
# directory made unwritable after the first samples, then a missed sample): the
# watch keeps the host admission lock, so no gate anywhere can decide, ends its
# root (recorded, not delivered) and fails it (96, rss_invalidation_failed=1), and
# releases the lock only after the root is reaped.
test_a_record_that_cannot_be_invalidated_keeps_the_host_lock_until_the_root_ends() {
  if [ "$(uname)" != Darwin ]; then pass "SKIP (the resident watch runs on native macOS only): invalidation failure"; return; fi
  if [ "$(id -u)" -eq 0 ]; then pass "SKIP (a read-only directory still takes files as root): invalidation failure"; return; fi
  local tmp real_python rc=0 pid waited held_during held_after kill_number
  tmp=$(fm_test_tmproot fm-lint-invalidation-failure)
  real_python=$(command -v python3) || fm_lint_fail_settled "python3 is not on PATH"
  fm_lint_write_stub_python "$tmp/stub" "$real_python"
  kill_number=$(kill -l KILL)
  mkdir -p "$tmp/rec"
  : > "$tmp/host.lock"
  FM_TEST_SIGNAL_LOG="$tmp/signals.log" FM_LINT_INTERNAL_PYTHON="$tmp/stub/python3" FM_TEST_READER=dieafter:2 FM_TEST_READER_MARK="$tmp/mark" \
    FM_LINT_INTERNAL_SLOT_PEAK_FILE="$tmp/rec/peak" FM_LINT_INTERNAL_HOST_LOCK="$tmp/host.lock" \
    perl "$ROOT/bin/fm-lint-cache.pl" rsswatch 8388608 "$tmp/rss" -- sleep 9 > "$tmp/err" 2>&1 &
  pid=$!
  waited=0
  while ! grep -q '^sample ' "$tmp/rec/peak.health" 2>/dev/null && [ "$waited" -lt 100 ]; do sleep 0.05; waited=$((waited + 1)); done
  chmod 0400 "$tmp/rec/peak.health"; chmod 0500 "$tmp/rec"
  waited=0
  while ! grep -q 'keeps the host admission lock' "$tmp/err" && [ "$waited" -lt 150 ]; do sleep 0.1; waited=$((waited + 1)); done
  held_during=0
  perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' "$tmp/host.lock" || held_during=$?
  chmod 0700 "$tmp/rec"; chmod 0600 "$tmp/rec/peak.health"
  wait "$pid" || rc=$?
  held_after=0
  perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 2; exit(flock($f, LOCK_EX | LOCK_NB) ? 0 : 1)' "$tmp/host.lock" || held_after=$?
  [ "$held_during" -eq 1 ] || fm_lint_fail_settled "the host admission lock was free while the record could not be invalidated ($held_during): $(cat "$tmp/err")"
  { [ "$rc" -eq 96 ] && grep -q '^rss_invalidation_failed=1$' "$tmp/rss"; } || fm_lint_fail_settled "the root exited $rc, expected 96 with rss_invalidation_failed: $(cat "$tmp/err") $(cat "$tmp/rss")"
  grep -q "^killpg [0-9]* $kill_number\$" "$tmp/signals.log" || fm_lint_fail_settled "the root was not ended: $(cat "$tmp/signals.log")"
  [ "$held_after" -eq 0 ] || fm_lint_fail_settled "the host admission lock stayed held after the root was reaped"
  pass "a record that cannot be invalidated keeps the host admission lock until its root is reaped; the root is ended and fails (96)"
}

fm_lint_test_cases=(
test_the_watch_tick_and_exit_rules_hold_on_synthetic_ticks
test_the_measurement_record_rules_hold_on_synthetic_records
test_the_reply_check_binds_members_and_refuses_a_zombie_root
test_a_failed_resume_ends_the_held_root_and_fails_it
test_a_root_whose_start_time_cannot_be_recorded_never_runs
test_a_live_malformed_ledger_entry_admits_no_root
test_a_record_that_cannot_be_invalidated_keeps_the_host_lock_until_the_root_ends
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
test_runs_with_different_delegates_each_probe_their_own_shellcheck
test_a_compiled_launcher_is_probed_every_run_and_its_delegates_version_decides
test_a_wrapper_around_shellcheck_is_probed_every_run_and_its_current_version_decides
test_slot_pool_cannot_be_disabled_and_refuses_bad_settings
test_host_budget_default_is_one_number_stated_by_both_docs
test_a_per_root_limit_above_the_default_is_clamped_and_a_lower_one_is_kept
test_the_watch_receives_the_default_cap_and_the_clamped_request
test_no_route_sets_a_runs_budget
test_slot_file_failures_refuse_and_never_run_unbounded
test_concurrent_runs_against_an_unusable_slot_both_refuse_and_then_both_run
test_an_unusable_host_wide_budget_directory_refuses_before_any_root_starts
test_growing_roots_are_held_to_the_budget_across_pools
test_simultaneous_growth_after_admission_is_brought_back_within_the_allowance
test_the_stated_bound_holds_under_trusted_records_and_growth_beyond_the_charge
test_two_pools_charge_one_host_wide_ledger_so_the_budget_holds_across_them
test_a_gate_reads_the_ledger_under_the_host_lock_so_a_root_admitted_meanwhile_counts
test_a_live_ledger_entry_that_cannot_be_opened_refuses_the_admission
test_a_run_with_no_changed_target_leaves_no_run_entry
test_the_private_modes_start_a_command_only_inside_an_admitted_root
test_a_worker_started_directly_takes_nothing_from_the_callers_environment
test_the_roots_log_keeps_the_time_reading_and_the_watch_peak_in_separate_columns
test_an_unreadable_host_census_never_starts_a_root_in_any_pool
test_a_host_that_loses_its_process_table_stops_the_run_after_one_refusal
test_an_unreadable_census_fails_one_run_once_and_does_not_delay_another_in_the_pool
test_the_version_probe_waits_only_for_its_own_lane
test_a_run_never_takes_a_version_from_a_probe_that_started_before_it_waited
test_a_probe_past_its_bound_is_waited_for_and_reported_even_after_closing_its_output
test_strict_mode_refuses_where_the_caps_are_not_enforced
test_every_mode_takes_its_budget_from_the_same_host_wide_bound
test_a_second_run_finds_the_budget_restored_and_repeats_the_first
test_the_roots_log_records_each_roots_queue_wait_in_wait_ms
test_a_waiting_gate_reading_the_table_never_stops_a_younger_running_root
test_the_queue_head_reads_the_process_table_at_most_twice_a_second
test_growth_guard_never_stops_the_watch_reader
test_a_wrapper_around_the_real_shellcheck_shares_the_host_wide_memory_bound
test_memory_budget_bounds_the_aggregate_across_homes
test_a_high_host_slot_count_does_not_raise_the_memory_limit
test_a_five_gib_root_runs_alone_inside_the_admission
test_a_waiting_run_is_served_within_a_stated_wait_bound
test_root_larger_than_the_budget_runs_alone_and_a_killed_run_frees_its_charge
test_memory_charge_survives_unknown_records_and_an_unreadable_table
test_fast_record_does_not_lower_the_full_charge
test_default_pool_is_one_directory_for_every_home
test_slot_survives_gate_death
test_queued_roots_use_high_resolution_timings
test_worker_trees_stop_on_signal
test_root_deadline_names_the_root_and_reaps_the_tree
test_root_memory_limit_reports_a_named_death
test_the_analysis_process_sees_the_default_and_the_explicit_address_space_limit
test_memory_failure_retries_without_external_sources
test_unbounded_root_over_resident_bound_is_ended_and_retried_narrower
test_unbounded_root_under_resident_bound_is_untouched
test_resident_watch_ends_its_command_when_its_owner_dies
test_rss_shim_that_resolves_to_itself_is_refused
test_resident_watch_reads_only_its_own_tree
test_resident_watch_bounds_footprint_beyond_resident
test_resident_watch_ends_a_tree_whose_memory_sits_in_descendants_and_an_orphan
test_a_descendant_that_left_the_group_and_outlives_the_root_fails_it_unsignalled
test_no_signal_route_takes_a_group_from_input
test_the_watch_never_ends_an_unrelated_process_that_holds_a_members_old_pid
test_a_root_with_no_reader_is_unmeasured_and_never_sampled_from_a_table
test_a_restarted_reader_keeps_a_member_that_left_the_group_and_was_orphaned
test_a_watch_that_loses_every_reader_starts_no_further_root_and_fails_the_run
test_a_root_whose_readers_are_lost_fails_and_no_queued_root_is_admitted
test_a_same_second_replacement_is_not_counted_against_the_root
test_the_exact_member_reader_counts_only_an_unchanged_identity
test_a_probe_lane_left_by_a_dead_run_stays_held_until_its_probe_ends
test_a_launcher_switching_delegates_is_analysed_every_run
test_a_stop_mark_that_cannot_be_written_still_admits_no_new_root
test_the_exact_member_reader_adopts_a_child_only_with_its_listed_identity
test_an_empty_or_damaged_lane_record_holds_the_lane
test_a_stale_measurement_record_admits_no_new_root
test_reader_loss_followed_by_an_over_cap_reading_still_fails_unmeasured
test_a_late_reply_is_retried_once_in_the_same_tick
test_an_interrupted_reply_wait_with_a_reply_in_time_is_no_miss
test_a_member_that_ended_after_the_census_is_a_sample_not_a_miss
test_a_live_member_that_cannot_be_read_is_still_a_miss
test_a_root_exit_under_slow_checks_keeps_its_own_status
test_a_compiled_launcher_switching_delegates_is_analysed_every_run
test_resident_watch_replaces_a_stalled_reader
test_resident_watch_waits_for_a_slow_first_reply
test_resident_watch_fails_a_root_whose_later_reply_was_late
test_resident_watch_retries_a_replacement_that_exits
test_resident_watch_gives_up_after_three_failed_restarts
)
fm_lint_run "$@"
