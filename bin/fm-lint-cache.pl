#!/usr/bin/env perl
# fm-lint-cache.pl - private dependency selection, success cache, and host-slot gate for fm-lint.sh.
# Usage: perl fm-lint-cache.pl select <root> <NUL-separated changes on stdin>
#        perl fm-lint-cache.pl check <cache-dir|off> <root> <shellcheck> <args> -- <file>
#             [--execute <cold-command...>]
# ShellCheck retains source-aware extended analysis; only identical successful checks
# are reused. Cache-key flock serializes identical misses before host admission.
# --execute wraps a cold analysis with the gate/watchdog/time command supplied
# by fm-lint.sh; the analysis identity remains the ShellCheck binary and args.
# A cold analysis runs with FM_LINT_INTERNAL_ROOT_BYTES set to the size of the
# root file plus every file its source closure follows.
#
use Cwd qw(abs_path);
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock F_SETFD);
use File::Path qw(make_path);
use File::Basename qw(dirname basename);

# Signalling by process identity. A process is named by its pid and the exact
# time it started (the kernel's start seconds and microseconds), never by its pid
# alone: a pid is reused once its process ends, and a signal to a reused pid ends
# an unrelated process. Every signal the watch and the gate send to a process other
# than their own unreaped child goes through fm_signal_items, in one python process
# that reads the identity and sends in the same step, through the one send() below.
# An item is one of:
#   <pid>:<sec>:<usec>  sent only when the live process has exactly that start time
#                       (seconds and microseconds); a usec of "-" (an identity taken
#                       from ps or a table, which prints whole seconds) is never
#                       exact, so nothing is sent and the pid is reported inexact;
#   under:<ancestor>:<pid>  sent only when <pid> is now a descendant of <ancestor>
#                       (the gate's own tree); the exact start time read in that
#                       step is reported, so a later signal can name it exactly;
#   group:<pgid>        the process group of the caller's own unreaped child, whose
#                       pid cannot be reused before the caller reaps it.
# Each result line is "<sent|gone|mismatch|unreadable|inexact> <pid> [<sec> <usec>]".
# The residual is the few microseconds between that read and that send, which no
# portable call closes.
my $IDENTITY_SIGNAL_PY = <<'PYTHON';
import importlib.util, os, signal, struct, sys
spec = importlib.util.spec_from_file_location("fmproc", sys.argv[1])
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)
number = getattr(signal, "SIG" + sys.argv[2])
def send(pid, group):
    if group:
        os.killpg(pid, number)
    else:
        os.kill(pid, number)
def descends(pid, ancestor):
    for _ in range(80):
        if pid == ancestor:
            return True
        if pid <= 1:
            return False
        pid = struct.unpack_from("i", fp.kinfo(pid), fp.E_PPID)[0]
    return False
for item in sys.argv[3:]:
    parts = item.split(":")
    pid = int(parts[1] if parts[0] == "group" else parts[2] if parts[0] == "under" else parts[0])
    try:
        if parts[0] == "group":
            send(pid, True)
            print("sent", pid)
            continue
        if parts[0] == "under":
            identity = fp.process_identity(fp.kinfo(pid))
            if not descends(pid, int(parts[1])):
                print("mismatch", pid)
                continue
            send(pid, False)
            print("sent", pid, identity[0], identity[1])
            continue
        if parts[2] == "-":
            print("inexact", pid)
            continue
        identity = fp.process_identity(fp.kinfo(pid))
        if identity[0] != int(parts[1]) or identity[1] != int(parts[2]):
            print("mismatch", pid)
            continue
        send(pid, False)
        print("sent", pid)
    except (LookupError, ProcessLookupError):
        print("gone", pid)
    except Exception:
        print("unreadable", pid)
PYTHON
sub fm_signal_items {
    my ($name, @items) = @_;
    my %result = (gone => [], mismatch => [], unreadable => [], inexact => [], sent => [], identity => {});
    return \%result unless @items;
    my $helper = dirname(abs_path($0)) . '/fm-proc-info.py';
    my $python = $ENV{FM_LINT_INTERNAL_PYTHON} || 'python3';
    my %seen;
    if (-r $helper && open(my $py, '-|', $python, '-I', '-c', $IDENTITY_SIGNAL_PY, $helper, $name, @items)) {
        while (my $line = <$py>) {
            next unless $line =~ /\A(gone|mismatch|unreadable|inexact|sent) ([0-9]+)(?: ([0-9]+) ([0-9]+))?\n\z/;
            push @{$result{$1}}, $2 + 0;
            $result{identity}{$2 + 0} = [$3 + 0, $4 + 0] if defined $3;
            $seen{$2 + 0} = 1;
        }
        close $py;
    }
    # A process the helper did not answer for is unreadable: nothing is sent to it.
    push @{$result{unreadable}}, grep { !$seen{$_} } map { /(?:\A|:)([0-9]+)(?::[0-9]+:(?:[0-9]+|-))?\z/ ? $1 + 0 : () } @items;
    return \%result;
}
sub fm_signal_by_identity {
    my ($name, @members) = @_;
    return fm_signal_items($name, map { sprintf '%d:%d:%s', $_->[0], $_->[1], defined $_->[2] ? $_->[2] : '-' } @members);
}
# Private mode: perl fm-lint-cache.pl signal <HUP|INT|TERM|KILL|CONT|STOP> <item>...
# prints "<sent|gone|mismatch|unreadable|inexact> <pid>" for each and exits 0 (the
# watch's and the gate's identity check, reachable by a test).
if (($ARGV[0] // '') eq 'signal') {
    my (undef, $name, @items) = @ARGV;
    die "fm-lint-signal: invalid private invocation\n"
        unless ($name // '') =~ /\A(?:HUP|INT|TERM|KILL|CONT|STOP)\z/ && @items
            && !grep { !/\A(?:[0-9]+:[0-9]+:(?:[0-9]+|-)|under:[0-9]+:[0-9]+)\z/ } @items;
    my $result = fm_signal_items($name, @items);
    for my $kind (qw(sent gone mismatch unreadable inexact)) {
        for my $pid (@{$result->{$kind}}) {
            my $exact = $result->{identity}{$pid};
            print "$kind $pid", ($kind eq 'sent' && $exact ? " @$exact" : ''), "\n";
        }
    }
    exit 0;
}

# Process facts for the admission checks below: the parent of a pid, and its
# command line, from ps or, where ps is refused, from fm-proc-info.py.
sub fm_process_fact {
    my ($field, $pid) = @_;
    my $helper = dirname(abs_path($0)) . '/fm-proc-info.py';
    my $python = $ENV{FM_LINT_INTERNAL_PYTHON} || 'python3';
    no warnings 'exec';
    if (open(my $ps, '-|', 'ps', '-o', ($field eq 'ppid' ? 'ppid=' : 'command='), '-p', $pid)) {
        my $text = do { local $/; <$ps> } // '';
        close $ps;
        $text =~ s/\s+\z//;
        $text =~ s/\A\s+//;
        return $text if length $text && ($field ne 'ppid' || $text =~ /\A[0-9]+\z/);
    }
    if (-r $helper && open(my $py, '-|', $python, $helper, ($field eq 'ppid' ? 'ppid' : 'args'), $pid)) {
        my $text = do { local $/; <$py> } // '';
        close $py;
        $text =~ s/\s+\z//;
        return $text if length $text && ($field ne 'ppid' || $text =~ /\A[0-9]+\z/);
    }
    return undef;
}
# Whether <pid> is an ancestor of this process (its parent, its parent's parent...).
sub fm_is_ancestor {
    my ($target) = @_;
    my $pid = getppid();
    for (1 .. 80) {
        return 1 if $pid == $target;
        last unless $pid > 1;
        $pid = fm_process_fact('ppid', $pid) // last;
    }
    return 0;
}
# Whether <entry> is a file directly in <ledger dir> named <prefix>.<pid>.<n>, its
# flock is held (its owner is alive), its first field is that pid, the pid is an
# ancestor of this process and its command matches <pattern>. Returns the pid, or
# undef.
sub fm_live_ledger_owner {
    my ($ledger_dir, $entry, $prefix, $pattern) = @_;
    return undef unless defined $ledger_dir && length $ledger_dir && defined $entry;
    my $dir = abs_path($ledger_dir) // return undef;
    return undef unless $entry =~ m{\A(.*)/\Q$prefix\E\.([0-9]+)\.[0-9]+\z} && !-l $entry && -f $entry;
    my ($parent, $pid) = ($1, $2 + 0);
    return undef unless (abs_path($parent) // '') eq $dir;
    open(my $fh, '>>', $entry) or return undef;
    return undef if flock($fh, LOCK_EX | LOCK_NB);   # free: its owner has ended
    open(my $record, '<', $entry) or return undef;
    my $line = <$record> // '';
    close $record;
    return undef unless $line =~ /\A([0-9]+)\t/ && $1 + 0 == $pid;
    return undef unless fm_is_ancestor($pid);
    my $command = fm_process_fact('command', $pid) // return undef;
    return $command =~ $pattern ? $pid : undef;
}
# Private mode: perl fm-lint-cache.pl admitted <host ledger dir> <gate entry>. Exit 0
# only when the entry is one a gate wrote directly in that host ledger (the
# directory bin/fm-lint.sh names from its own constant, never any other *.ledger
# directory), its flock is held (its root is running), and the pid it names is an
# ancestor of the caller that runs this script's gate mode, so a command that
# bin/fm-lint.sh's private modes (--internal-timed, --internal-root) are about to run
# is inside an admitted root. Anything else exits 1 and starts nothing.
if (($ARGV[0] // '') eq 'admitted') {
    my (undef, $ledger_dir, $entry) = @ARGV;
    exit(defined fm_live_ledger_owner($ledger_dir, $entry, 'entry', qr{\A\S*perl\S*\s+(?:-\S+\s+)*\S*fm-lint-cache\.pl\s+gate\s}) ? 0 : 1);
}
# Private mode: perl fm-lint-cache.pl admitted-run <host ledger dir> <run entry>.
# Exit 0 only when the entry is a lint run's entry directly in that host ledger,
# its flock is held (the run is alive), and the pid it names is an ancestor of the
# caller that runs bin/fm-lint.sh.
if (($ARGV[0] // '') eq 'admitted-run') {
    my (undef, $ledger_dir, $entry) = @ARGV;
    exit(defined fm_live_ledger_owner($ledger_dir, $entry, 'run', qr{\A\S*(?:bash|sh)\S*\s+(?:-\S+\s+)*\S*fm-lint\.sh(?:\s|\z)}) ? 0 : 1);
}

# Private mode: perl fm-lint-cache.pl probe <host lock> <key> <wait-file> -- <command...>
# The version probe's lane in the host-wide budget. bin/fm-lint.sh keeps a fixed
# share of the budget for it (its PROBE_RESERVE_KIB) and gives the roots' admission
# the rest, so a probe never waits behind roots holding the budget and a run whose
# roots are all cache hits reserves nothing in the roots' budget. One probe runs at
# a time on the host: the lane is the flock of <host lock>.probe, and the command
# (a ShellCheck --version that bin/fm-lint.sh has wrapped in its memory bound) runs
# only while it is held. A probe that waited for the lane first looks in
# <host lock>.probe.d/<key> (<key> names the ShellCheck file and its bytes): a
# version written there by a probe that ended after this one began waiting is
# printed as its own result and nothing is started, so runs whose probes overlap
# share one. Otherwise the command runs, its output is passed through, and a
# version it prints with exit 0 is written there with its end time. A version is
# never taken from a probe that ended before this one began waiting. The time spent
# waiting for the lane is written in milliseconds to <wait-file>. A lane that cannot
# be used names its path and exits 2 without starting the command.
if (($ARGV[0] // '') eq 'probe') {
    require POSIX;
    require Time::HiRes;
    my (undef, $host_lock, $key, $wait_file, $dashes, @command) = @ARGV;
    die "fm-lint-probe: invalid private invocation\n"
        unless defined $dashes && $dashes eq '--' && @command && length($host_lock // '') && ($key // '') =~ /\A[0-9a-z]{1,64}\z/;
    my $refuse = sub {
        my ($path, $why) = @_;
        print STDERR "fm-lint: version probe lane unusable at $path ($why); the host-wide ShellCheck memory bound cannot be enforced, "
            . "so the probe was not started. Make that path writable, or remove it if it is damaged.\n";
        exit 2;
    };
    my %signal_number = (HUP => 1, INT => 2, TERM => 15);
    my ($caught, $child);
    for my $name (keys %signal_number) { $SIG{$name} = sub { $caught = $name; kill 'TERM', $child if $child; }; }
    my $arrived = Time::HiRes::time();
    my $lane_path = "$host_lock.probe";
    open(my $lane, '>>', $lane_path) or $refuse->($lane_path, $!);
    until (flock($lane, LOCK_EX | LOCK_NB)) {
        $!{EWOULDBLOCK} || $!{EAGAIN} || $!{EINTR} or $refuse->($lane_path, $!);
        exit 128 + $signal_number{$caught} if $caught;
        Time::HiRes::sleep(0.02);
    }
    if (open(my $fh, '>', $wait_file)) { printf {$fh} "%d\n", (Time::HiRes::time() - $arrived) * 1000; close $fh; }
    my $results = "$host_lock.probe.d";
    eval { make_path($results, {mode => 0700}); 1 } or $refuse->($results, $@);
    -d $results && -w _ or $refuse->($results, 'not a writable directory');
    my $result = "$results/$key";
    if (open(my $fh, '<', $result)) {
        my $line = <$fh> // '';
        close $fh;
        if ($line =~ /\A([0-9]+(?:\.[0-9]+)?)\t([0-9A-Za-z.+-]+)\n\z/ && $1 >= $arrived) {
            print "version: $2\n";
            exit 0;
        }
    }
    pipe(my $from_probe, my $to_caller) or die "fm-lint-probe: pipe: $!\n";
    $child = fork();
    die "fm-lint-probe: fork: $!\n" unless defined $child;
    if (!$child) {
        close $from_probe;
        open(STDOUT, '>&', $to_caller) or POSIX::_exit(127);
        exec {$command[0]} @command;
        warn "fm-lint-probe: exec $command[0]: $!\n";
        POSIX::_exit(127);
    }
    close $to_caller;
    kill 'TERM', $child if $caught;
    my $output = do { local $/; <$from_probe> } // '';
    close $from_probe;
    my $reaped;
    while (($reaped = waitpid($child, 0)) == -1 && $!{EINTR}) { }
    my $status = $reaped == $child ? $? : 127 << 8;
    print $output;
    my $rc = ($status & 127) ? 128 + ($status & 127) : $status >> 8;
    if ($rc == 0 && $output =~ /^version:\s*([0-9A-Za-z.+-]+)\s*$/m) {
        my ($staged, $version, $fh) = ("$result.tmp.$$", $1);
        if (open($fh, '>', $staged) && printf({$fh} "%.6f\t%s\n", Time::HiRes::time(), $version) && close($fh)) {
            rename($staged, $result) or unlink $staged;
        } else {
            unlink $staged;
        }
    }
    exit $rc;
}

# Private gate protocol; bin/fm-lint.sh's header owns the public pool controls.
# Usage: perl fm-lint-cache.pl gate <slot-dir> <ncpu> <run-id> <wait-file> -- <command...>
# Commands inherit the flock descriptor across exec, so killing the gate cannot
# release capacity while a protected descendant still holds it; the kernel
# releases the slot when the last inherited descriptor closes.
# Live requests take a ticket under admission.lock; a request's flock is its
# liveness proof, so a killed waiter cannot strand the queue. Capacity is the
# CPU-derived cap and a resident-memory budget in bytes; host load never shrinks
# either, so unrelated machine load cannot starve lint. Service is shared per
# run, not per worker: an admitted request records its run, ticket and gate pid
# in its slot file, and a free slot goes to the waiting run holding the fewest
# slots, then the run served least recently, then the oldest ticket. Within a
# run, tickets stay FIFO, so every waiting run and request makes progress. A head
# ticket whose owner has been stopped for a second is skipped; one ps call, made
# without admission.lock so a slow ps cannot keep the next root out, checks every
# waiting owner, and only after a free slot has stayed unclaimed for that second.
# A waiter that has been unable to take admission.lock for a second looks,
# at most once a second, for a stopped gate on this slot directory; if one exists,
# its owner may hold the lock, so the waiter scans without the lock. Slot flocks
# alone enforce the capacity count.
# The memory budget is checked only by the request whose turn it is, under
# admission.lock (or without it on the stopped-gate path above), and always under
# the host lock, never without it. The request is
# charged the recorded peak of its root times 1.10 plus 64 MiB, at most the
# per-root worst case (FM_LINT_INTERNAL_ROOT_KEY, kept in
# history/<sha256 of the key> as "<peak KiB> <input bytes>") only when its input
# now (FM_LINT_INTERNAL_ROOT_BYTES, the root file plus every file the analysis
# follows, from check mode below) is more than 90 and less than 110 percent of
# the input that peak was measured on; otherwise (no record, a record in another
# format, no input size, an input outside that band) it is charged the per-root
# worst case (FM_LINT_INTERNAL_ROOT_CAP_KIB). Every held slot is charged the larger of the charge its record names
# and what its root holds now: its gate's whole process tree in one read of the
# live process table, and the peak the macOS watch publishes beside the slot
# (slot.<n>.peak, through FM_LINT_INTERNAL_SLOT_PEAK_FILE). The turn is taken
# only if those charges, plus the current resident size outside the held roots
# (the running lint trees of other pools and every other process named
# shellcheck, from another caller or a wrapper script around the real
# ShellCheck), plus the request's own charge fit the budget, or nothing is held
# and nothing runs outside, so a root larger than the budget runs alone. A held
# slot is charged the worst case when its record names no charge. Admission
# needs a readable table: while neither ps nor fm-proc-info.py answers, the
# request whose turn it is retries, and after about 5 s it names the table on
# stderr and exits 2 without starting its command. When the analysis
# completes (no signal reached the gate, and it exited 0, 1, 98 or 251), the
# gate takes the larger of the watch's peak and the maximum resident size in
# FM_LINT_INTERNAL_ROOT_RSS_FILE: a record whose input is in the band above is
# raised to it and keeps its input size, and is never lowered; any other record
# is replaced by that peak and this input size. Any other end, or no input
# size, leaves the record alone. Every slot.<n> file in the
# directory counts toward the budget, beyond this run's count cap too.
# A pool that cannot be used (directory, lock, ticket, slot or queue file) never
# lets the analysis run unbounded: the gate names the path and the fix on stderr
# and exits 2.
# Admission retains the slot.* protocol so in-flight older gates remain bounded;
# their records name no charge and are charged the worst case.
# One host-wide ledger: every admitted gate, in every pool, writes an entry in
# <host lock path>.ledger/ (named by the one host lock, never by a pool directory)
# holding its gate pid, its charge and the path of its peak file, under the host
# lock that decides the admission, and keeps the entry's flock through its command
# (the descriptor is inherited like the slot's), so an entry is live exactly while
# some process of that root holds it. An admission in any pool reads every live
# entry, not only its own pool's slots, so a root just admitted in another pool is
# charged what its record names, not what it holds in the instant of the reading;
# an entry whose flock is free belongs to an ended root and is removed.
# The high-resolution wait is written in milliseconds to <wait-file> before
# launch so the caller can account for queue time separately.
# The census (perl fm-lint-cache.pl census <same arguments>) is a mode of its own,
# chosen by its argument and never by the environment: it reads the host process
# table, as an admission would, and exits 0 when the table can be read, else waits
# about 5 s and refuses as a root would. It never runs its command, so it never
# produces a success that an analysis would have produced. The gate refuses to run
# when FM_LINT_INTERNAL_CENSUS_ONLY, the census's former environment switch, is set:
# an inherited switch must never turn an analysis into a no-op that exits 0.
if (($ARGV[0] // '') eq 'gate' || ($ARGV[0] // '') eq 'census') {
    require POSIX;
    require Time::HiRes;
    my ($gate_mode, $slot_dir, $ncpu, $run, $wait_file, $dashes, @command) = @ARGV;
    die "fm-lint-gate: invalid private invocation\n"
        unless defined $dashes && $dashes eq '--' && @command && ($ncpu // '') =~ /\A[1-9][0-9]*\z/
            && ($run // '') =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    if ($gate_mode eq 'gate' && length($ENV{FM_LINT_INTERNAL_CENSUS_ONLY} // '')) {
        print STDERR "fm-lint: FM_LINT_INTERNAL_CENSUS_ONLY is set in this analysis's environment; it is not an input "
            . "to an analysis (the census is its own mode), so this analysis was not started. Unset it and run the lint again.\n";
        exit 2;
    }
    # %paused: each process the growth guard stopped, by pid, with the exact start
    # time read when it was stopped; it is resumed only by that exact identity.
    my ($child, $caught, %paused);
    my $resume = sub {
        fm_signal_by_identity('CONT', map { [$_, @{$paused{$_}}] } sort { $a <=> $b } keys %paused);
        %paused = ();
    };
    my %signal_number = (HUP => 1, INT => 2, TERM => 15);
    for my $name (keys %signal_number) {
        $SIG{$name} = sub { $caught = $name; $resume->() if %paused; kill 'TERM', $child if $child; };
    }
    my $cap = ($ENV{FM_LINT_HOST_SLOTS} // '') =~ /\A[1-9][0-9]*\z/ ? $ENV{FM_LINT_HOST_SLOTS} + 0
        : ($ncpu >> 1) > 2 ? ($ncpu >> 1) : 2;
    # Memory budget (KiB) for every ShellCheck the pool admits, and the per-root
    # worst case charged without a trusted record. bin/fm-lint.sh validates
    # the budget override and owns the documented defaults.
    my $positive = sub { ($_[0] // '') =~ /\A[1-9][0-9]*\z/ ? $_[0] + 0 : $_[1] };
    # The budget has one owner and one default: bin/fm-lint.sh always passes it.
    my $budget_kib = ($ENV{FM_LINT_INTERNAL_HOST_RSS_KIB} // '') =~ /\A[1-9][0-9]*\z/ ? $ENV{FM_LINT_INTERNAL_HOST_RSS_KIB} + 0
        : die "fm-lint-gate: invalid private invocation: FM_LINT_INTERNAL_HOST_RSS_KIB is the host-wide budget in KiB and bin/fm-lint.sh sets it\n";
    my $worst_kib = $positive->($ENV{FM_LINT_INTERNAL_ROOT_CAP_KIB}, 8388608);
    my $root_key = $ENV{FM_LINT_INTERNAL_ROOT_KEY} // '';
    my $history_path = length $root_key ? "$slot_dir/history/" . sha256_hex($root_key) : undef;
    my $root_bytes = ($ENV{FM_LINT_INTERNAL_ROOT_BYTES} // '') =~ /\A[0-9]+\z/ ? $ENV{FM_LINT_INTERNAL_ROOT_BYTES} + 0 : undef;
    my $read_kib = sub {
        open(my $fh, '<', $_[0]) or return 0;
        my $line = <$fh> // '';
        return $line =~ /\A([0-9]+)\n\z/ ? $1 + 0 : 0;
    };
    # The record's peak when it was measured on an input within 10 percent of
    # this one, else undef.
    my $in_band = sub { my ($line) = @_; ($line // '') =~ /\A([0-9]+) ([0-9]+)\n\z/
        && defined $root_bytes && $root_bytes * 10 > $2 * 9 && $root_bytes * 10 < $2 * 11 ? $1 + 0 : undef };
    my $max = sub { $_[0] > $_[1] ? $_[0] : $_[1] };
    my $min = sub { $_[0] < $_[1] ? $_[0] : $_[1] };
    my $refuse = sub {
        my ($path, $why) = @_;
        $why = 'unknown error' unless defined $why && length $why;
        $why =~ s/\s+\z//;
        print STDERR "fm-lint: host slot pool unusable at $path ($why); the host-wide ShellCheck memory bound cannot be enforced, "
            . "so this analysis was not started. Make that path writable, or remove it if it is damaged.\n";
        exit 2;
    };
    my $stopped_owners = sub {
        my %stopped;
        no warnings 'exec';
        open(my $ps, '-|', 'ps', '-o', 'pid=,stat=', '-p', join(',', @_)) or return %stopped;
        while (my $line = <$ps>) { $stopped{$1} = 1 if $line =~ /\A\s*([0-9]+)\s+T/; }
        close $ps;
        return %stopped;
    };
    # One read of the live process table: { pid => [ppid, resident KiB, name,
    # command, start seconds] }, or undef when no source answers. ps first, then
    # libproc through fm-proc-info.py for a sandbox that refuses ps. The start is
    # the absolute start (lstart) every reader sees alike, so all gates agree on
    # which running gate is the oldest.
    require Time::Piece;
    my %start_of;
    my $start = sub {
        my ($text) = @_;
        $text =~ s/\s+/ /g;
        return $start_of{$text} //= eval { Time::Piece->strptime($text, '%a %b %e %H:%M:%S %Y')->epoch } // 0;
    };
    my $process_table = sub {
        my %table;
        {
            no warnings 'exec';
            local $ENV{LC_ALL} = 'C';
            if (open(my $ps, '-|', 'ps', '-axww', '-o', 'pid=,ppid=,rss=,lstart=,command=')) {
                while (my $line = <$ps>) {
                    next unless $line =~ /\A\s*([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+(\S+\s+\S+\s+[0-9]+\s+[0-9:]+\s+[0-9]+)\s+(.*?)\s*\z/s;
                    my ($pid, $ppid, $rss, $started, $command) = ($1, $2, $3, $4, $5);
                    my $name = (split ' ', $command)[0] // '';
                    $name =~ s{.*/}{};
                    $table{$pid} = [$ppid, $rss + 0, $name, $command, $start->($started)];
                }
                close $ps;
            }
        }
        return \%table if $table{$$};
        %table = ();
        my $helper = dirname(abs_path($0)) . '/fm-proc-info.py';
        if (-r $helper) {
            no warnings 'exec';
            my $python = $ENV{FM_LINT_INTERNAL_PYTHON} || 'python3';
            my %command;
            if (open(my $py, '-|', $python, $helper, 'table', 'pid,ppid,command')) {
                while (my $line = <$py>) { $command{$1} = $3 if $line =~ /\A\s*([0-9]+)\s+([0-9]+)\s+(.*?)\s*\z/s; }
                close $py;
            }
            if (open(my $py, '-|', $python, $helper, 'memory')) {
                local $/;
                my $json = <$py>;
                close $py;
                require JSON::PP;
                my $rows = eval { JSON::PP::decode_json($json // '') };
                for my $row (ref $rows eq 'ARRAY' ? @$rows : ()) {
                    next unless ref $row eq 'HASH' && defined $row->{pid} && defined $row->{ppid}
                        && defined $row->{rss_bytes};
                    $table{$row->{pid}} = [$row->{ppid}, int($row->{rss_bytes} / 1024), $row->{comm} // '',
                        $command{$row->{pid}} // ($row->{comm} // ''), $start->($row->{started} // '')];
                }
            }
        }
        return $table{$$} ? \%table : undef;
    };
    # The refusal for a host whose process table cannot be read by either route.
    # It also marks the run (FM_LINT_INTERNAL_ABORT_FILE) so the lint's workers
    # start no further root: each would wait the same 5 s and fail the same way.
    my $refuse_census = sub {
        my $abort = $ENV{FM_LINT_INTERNAL_ABORT_FILE} // '';
        if (length $abort && open(my $mark, '>>', $abort)) { close $mark; }
        print STDERR "fm-lint: the host process table cannot be read: ps failed, and so did fm-proc-info.py "
            . "(table and memory) beside fm-lint-cache.pl; the host-wide ShellCheck memory bound cannot be "
            . "enforced, so this analysis was not started. Let this user run ps, or keep bin/fm-proc-info.py "
            . "beside bin/fm-lint-cache.pl with a python3 that can run it.\n";
        exit 2;
    };
    # Census mode, run once by bin/fm-lint.sh before any root starts: succeeds when
    # the table can be read, else waits about 5 s and refuses as a root would.
    if ($gate_mode eq 'census') {
        my $began = Time::HiRes::time();
        while (!$process_table->()) {
            $refuse_census->() if Time::HiRes::time() - $began >= 5;
            Time::HiRes::sleep(0.5);
        }
        exit 0;
    }
    # KiB charged for the held slots, each [gate pid, charge, watch peak file]
    # with undef for what its record does not name: the larger of its charge and
    # what it holds now (its gate's whole process tree, or the watch's peak), and
    # at least the worst case without a charge.
    my $charged = sub {
        my ($table, @held) = @_;
        my %children;
        push @{$children{$table->{$_}[0]}}, $_ for keys %$table;
        my $total = 0;
        for my $entry (@held) {
            my ($pid, $charge, $peak_file) = @$entry;
            my $sum = $read_kib->($peak_file);
            if (defined $pid) {
                my ($tree, @queue, %seen) = (0, $pid);
                while (defined(my $member = shift @queue)) {
                    next if $seen{$member}++ || !$table->{$member};
                    $tree += $table->{$member}[1];
                    push @queue, @{$children{$member} // []};
                }
                $sum = $max->($sum, $tree);
            }
            $charge = $worst_kib unless defined $charge;
            $total += $max->($charge, $sum);
        }
        return $total;
    };
    # Every lint gate on the host, whatever pool it uses, the processes below
    # it, and every other process named shellcheck: the table reduced to
    # { total => KiB in all of them, gates => { gate pid => [process set, start,
    #   running] }, named => KiB of processes named shellcheck in no gate's tree }.
    # total counts only gates that are running. A gate's own table and
    # owner reads (ps, fm-proc-info.py table or memory, also seen as a bare or
    # parenthesized command name, a <defunct> row or, before their exec, the
    # gate's own command) are not in its set, so a gate runs only once its
    # command has started.
    my $host_view = sub {
        my ($table) = @_;
        my %children;
        push @{$children{$table->{$_}[0]}}, $_ for keys %$table;
        my (%gates, %in_tree, %running);
        for my $pid (keys %$table) {
            # A gate is a perl running this script's gate mode; a process that only
            # carries those words later in its arguments (check, timeout) is not one.
            next unless ($table->{$pid}[3] // '') =~ m{\A\S*perl\S*\s+(?:-\S+\s+)*\S*fm-lint-cache\.pl\s+gate\s};
            my $own_command = $table->{$pid}[3] // '';
            my (@queue, %set) = grep {
                my $command = $table->{$_}[3] // '';
                $command ne $own_command && $command !~ m{\A(?:\S*/)?ps\s|\A\S*sh\s+\S*/ps\s|\A\S*(?i:python)\S*\s+(?:-\S+\s+)*\S*fm-proc-info\.py\s+(?:table|memory)\b|\A\(?\S*(?i:python)\S*\)?\z|\A\(\S+\)\z|\A(?:\[\S+\]\s+)?<defunct>\z}
            } @{$children{$pid} // []};
            $set{$pid} = 1;
            while (defined(my $member = shift @queue)) {
                next if $set{$member}++ || !$table->{$member};
                push @queue, @{$children{$member} // []};
            }
            # A gate that has not started its command holds nothing: waiting
            # gates must not count each other, or none would ever be admitted.
            my $started = keys(%set) > 1;
            $gates{$pid} = [\%set, $table->{$pid}[4], $started];
            $in_tree{$_} = 1 for keys %set;
            $running{$_} = 1 for $started ? keys %set : ();
        }
        my ($total, $named) = (0, 0);
        $total += $table->{$_}[1] for keys %running;
        for my $pid (keys %$table) {
            next if $in_tree{$pid} || $table->{$pid}[2] ne 'shellcheck';
            $named += $table->{$pid}[1];
        }
        return {total => $total + $named, named => $named, gates => \%gates};
    };
    # KiB resident in lint trees of other pools and in processes named
    # shellcheck outside every gate: memory this pool does not hold.
    my $foreign = sub {
        my ($table, @held) = @_;
        my $view = $host_view->($table);
        my %own;
        for my $entry (@held) {
            my ($pid) = @$entry;
            $own{$_} = 1 for defined $pid && $view->{gates}{$pid} ? keys %{$view->{gates}{$pid}[0]} : ();
        }
        my $total = $view->{named};
        for my $gate (keys %{$view->{gates}}) {
            next if $gate == $$ || $own{$gate} || !$view->{gates}{$gate}[2];
            for my $pid (keys %{$view->{gates}{$gate}[0]}) { $total += $table->{$pid}[1] unless $own{$pid}; }
        }
        return $total;
    };
    my $table;
    # Whether a stopped gate other than this one has <needle> in its command.
    my $stopped_gate = sub {
        my ($needle) = @_;
        no warnings 'exec';
        open(my $ps, '-|', 'ps', '-axww', '-o', 'pid=,stat=,command=') or return 0;
        my $found = 0;
        while (my $line = <$ps>) {
            next unless $line =~ /\A\s*([0-9]+)\s+T\S*\s+(.*)\z/s && $1 != $$;
            $found = 1 if index($2, $needle) >= 0;
        }
        close $ps;
        return $found;
    };
    my ($slot, $slot_path, $peak_file, $charge_kib, $waited_from, $ticket, $ticket_path, $ticket_number, $coordinator);
    my ($blocked_at, $checked_at, $bypass, $census_from, $host, $queued);
    my ($passed, $passed_at, %stopped);
    eval { make_path($slot_dir, {mode => 0700}); 1 } or $refuse->($slot_dir, $@);
    -d $slot_dir && -w _ or $refuse->($slot_dir, 'not a writable directory');
    open($coordinator, '>>', "$slot_dir/admission.lock") or $refuse->("$slot_dir/admission.lock", $!);
    # One host lock, always: bin/fm-lint.sh names it, and a gate with none would
    # admit on a reading no other pool shares.
    my $host_lock = $ENV{FM_LINT_INTERNAL_HOST_LOCK} // '';
    length $host_lock
        or die "fm-lint-gate: invalid private invocation: FM_LINT_INTERNAL_HOST_LOCK is the host-wide admission lock and bin/fm-lint.sh sets it\n";
    open($host, '>>', $host_lock) or $refuse->($host_lock, $!);
    my $ledger_dir = "$host_lock.ledger";
    eval { make_path($ledger_dir, {mode => 0700}); 1 } or $refuse->($ledger_dir, $@);
    -d $ledger_dir && -w _ or $refuse->($ledger_dir, 'not a writable directory');
    my ($ledger_fh, $ledger_path);
    # Every live ledger entry as [gate pid, charge KiB, peak file], and the ended
    # ones removed. An empty entry is one being written by an admitting gate that
    # has not yet filled it: it counts at the worst case for 5 s and is then
    # removed. It is called only while this gate holds the host lock, so no other
    # gate admits, writes or removes an entry between this reading and the
    # decision taken on it. An entry that cannot be opened or read is a ledger
    # this gate cannot account for: it refuses and names the entry, never skips it.
    my $ledger_entries = sub {
        my @live;
        opendir(my $listing, $ledger_dir) or $refuse->($ledger_dir, $!);
        my @names = grep { /\Aentry\.[0-9]+\.[0-9]+\z/ } readdir $listing;
        closedir $listing;
        for my $name (sort @names) {
            my $path = "$ledger_dir/$name";
            my $fh;
            unless (open($fh, '>>', $path)) { next if $!{ENOENT}; $refuse->($path, $!); }
            my $free = flock($fh, LOCK_EX | LOCK_NB);
            if ($free) {
                my $age = Time::HiRes::time() - ((stat $path)[9] // 0);
                my $filled = -s $path;
                unlink $path if $filled || $age >= 5;
                push @live, [undef, undef, undef] if !$filled && $age < 5;
                close $fh;
                next;
            }
            $!{EWOULDBLOCK} || $!{EAGAIN} || $!{EINTR} or $refuse->($path, $!);
            close $fh;
            my $record;
            unless (open($record, '<', $path)) { next if $!{ENOENT}; $refuse->($path, $!); }
            my $line = <$record> // '';
            close $record;
            if ($line =~ /\A([0-9]+)\t([0-9]+)\t(.*)\n\z/) { push @live, [$1 + 0, $2 + 0, $3]; }
            else { push @live, [undef, undef, undef]; }
        }
        return @live;
    };
    $waited_from = Time::HiRes::time();
    ACQUIRE: while (!$slot && !$caught) {
        if (flock($coordinator, LOCK_EX | LOCK_NB)) {
            undef $blocked_at;
            undef $bypass;
        } else {
            $!{EWOULDBLOCK} || $!{EAGAIN} || $!{EINTR} or $refuse->("$slot_dir/admission.lock", $!);
            my $now = Time::HiRes::time();
            $blocked_at //= $now;
            if ($now - $blocked_at >= 1 && $now - ($checked_at // 0) >= 1) {
                $checked_at = $now;
                $bypass = $stopped_gate->(" gate $slot_dir ");
            }
            unless ($bypass) {
                $queued = 1;
                Time::HiRes::sleep(0.1);
                next;
            }
        }
        unless ($ticket) {
            my $sequence_path = "$slot_dir/queue.next";
            open(my $sequence, '+>>', $sequence_path) or $refuse->($sequence_path, $!);
            seek($sequence, 0, 0) or $refuse->($sequence_path, $!);
            my $number = <$sequence> // "0\n";
            $number =~ /\A[0-9]+\n\z/ or $refuse->($sequence_path, 'its counter is not a number');
            close $sequence;
            my $next;
            open($next, '>', "$sequence_path.tmp.$$")
                && print({$next} $number + 1, "\n") && close($next)
                && rename("$sequence_path.tmp.$$", $sequence_path)
                or $refuse->($sequence_path, $!);
            $ticket_number = $number + 1;
            $ticket_path = sprintf '%s/queue.%020d.%d.%s', $slot_dir, $ticket_number, $$, $run;
            open($ticket, '>>', $ticket_path) && flock($ticket, LOCK_EX | LOCK_NB)
                or $refuse->($ticket_path, $!);
        }
        my (@free, @slots, %indices, @check_owners);
        opendir(my $listing, $slot_dir) or $refuse->($slot_dir, $!);
        %indices = map { $_ => 1 } 0 .. $cap - 1, map { /\Aslot\.([0-9]+)\z/ ? $1 + 0 : () } readdir $listing;
        closedir $listing;
        for my $index (sort { $a <=> $b } keys %indices) {
            my $path = "$slot_dir/slot.$index";
            open(my $fh, '>>', $path) or $refuse->($path, $!);
            if (flock($fh, LOCK_EX | LOCK_NB)) {
                if ($index < $cap) { push @free, [$fh, $path]; } else { close $fh; }
                push @slots, [$path, 0];
                next;
            }
            my $busy = $!{EWOULDBLOCK} || $!{EAGAIN} || $!{EINTR};
            my $why = $!;
            close $fh;
            $busy or $refuse->($path, $why);
            push @slots, [$path, 1];
        }
        undef $passed unless @free;
        if (@free) {
            my (%held, %served, %oldest, %owners, @charges);
            for my $entry (@slots) {
                my $line = '';
                if (open(my $record, '<', $entry->[0])) { $line = <$record> // ''; }
                my @fields = $line =~ /\A([A-Za-z0-9_-]+)\t([0-9]+)(?:\t([0-9]+)(?:\t([0-9]+))?)?\n\z/;
                push @charges, [@fields[2, 3], "$entry->[0].peak"] if $entry->[1];
                next unless @fields;
                $held{$fields[0]}++ if $entry->[1];
                $served{$fields[0]} = $fields[1] if ($served{$fields[0]} // 0) < $fields[1];
            }
            opendir(my $queue, $slot_dir) or $refuse->($slot_dir, $!);
            my @requests = sort grep { /\Aqueue\.[0-9]{20}\.[0-9]+\.[A-Za-z0-9_-]+\z/ } readdir $queue;
            closedir $queue;
            for my $name (@requests) {
                my $path = "$slot_dir/$name";
                my ($owner, $owner_run) = $name =~ /\Aqueue\.[0-9]{20}\.([0-9]+)\.(.+)\z/;
                if ($path ne $ticket_path) {
                    open(my $request, '>>', $path) or $refuse->($path, $!);
                    if (flock($request, LOCK_EX | LOCK_NB)) {
                        unlink($path) or $!{ENOENT} or $refuse->($path, $!);
                        next;
                    }
                    $!{EWOULDBLOCK} || $!{EAGAIN} || $!{EINTR} or $refuse->($path, $!);
                    $owners{$owner} = 1;
                    next if $stopped{$owner};
                }
                $oldest{$owner_run} //= $path;
            }
            my ($next) = sort {
                ($held{$a} // 0) <=> ($held{$b} // 0)
                    || ($served{$a} // 0) <=> ($served{$b} // 0)
                    || $oldest{$a} cmp $oldest{$b}
            } keys %oldest;
            if (defined $next && $oldest{$next} eq $ticket_path) {
                # My turn. The memory budget decides, from the ledger and a table
                # read now under the host-wide admission lock
                # (FM_LINT_INTERNAL_HOST_LOCK), which an admitted gate keeps until
                # its command has started, so no two pools admit on one reading. A
                # gate that cannot take that lock waits; nothing decides without
                # it. The budget counts the held roots, the memory outside them and the
                # new root; a root takes its turn alone only when no held root
                # runs and nothing runs outside. Without a table nothing is
                # admitted, and after about 5 s without one the request is
                # refused.
                my $line = '';
                if ($history_path && open(my $record, '<', $history_path)) { $line = <$record> // ''; }
                # A trusted record's peak understates the next run by up to 8.5 percent
                # in this repository's measured runs, so the charge is the record
                # times 1.10 plus 64 MiB, never more than the per-root worst case.
                my $recorded = $in_band->($line);
                $charge_kib = $recorded ? $min->($worst_kib, int($recorded * 1.10 + 0.999) + 65536) : $worst_kib;
                my $now = Time::HiRes::time();
                my $fits;
                # The decision is taken only under the host lock: no path decides
                # without it, a stopped holder included (its lock is released when it
                # continues or dies). The ledger and the table are read after the lock
                # is taken, immediately before the decision, so a root another pool
                # admitted while this gate waited is read at its charge.
                my $held = flock($host, LOCK_EX | LOCK_NB);
                $held || $!{EWOULDBLOCK} || $!{EAGAIN} || $!{EINTR} or $refuse->($host_lock, $!);
                if ($held) {
                    # Every root admitted on this host, whatever its pool: this pool's
                    # held slots (older gates name no ledger entry) and the ledger's
                    # entries, one per gate pid.
                    my (%by_gate, @unnamed);
                    for my $held_root (@charges, $ledger_entries->()) {
                        if (defined $held_root->[0]) { $by_gate{$held_root->[0]} = $held_root; } else { push @unnamed, $held_root; }
                    }
                    my @host_charges = (values %by_gate, @unnamed);
                    $table = $process_table->();
                    if (!$table) {
                        $census_from //= $now;
                        if ($now - $census_from >= 5) {
                            unlink($ticket_path);
                            $refuse_census->();
                        }
                    } else {
                        undef $census_from;
                        my $outside = $foreign->($table, @host_charges);
                        $fits = !@host_charges && !$outside
                            || $charged->($table, @host_charges) + $outside + $charge_kib <= $budget_kib;
                    }
                }
                flock($host, LOCK_UN) if $held && !$fits;
                if ($fits) {
                    ($slot, $slot_path) = @{shift @free};
                    $peak_file = "$slot_path.peak";
                    unlink $peak_file;
                    truncate($slot, 0) && syswrite($slot, "$run\t$ticket_number\t$$\t$charge_kib\n")
                        or $refuse->($slot_path, $!);
                    # The ledger entry is written while the host lock is still held,
                    # so the next admission, in any pool, reads this root.
                    $ledger_path = sprintf '%s/entry.%d.%d', $ledger_dir, $$, $ticket_number;
                    open($ledger_fh, '>>', $ledger_path) && flock($ledger_fh, LOCK_EX | LOCK_NB)
                        && truncate($ledger_fh, 0) && syswrite($ledger_fh, "$$\t$charge_kib\t$peak_file\n")
                        or $refuse->($ledger_path, $!);
                }
            } elsif (defined $next) {
                my $now = Time::HiRes::time();
                if (($passed // '') ne $oldest{$next}) {
                    ($passed, $passed_at) = ($oldest{$next}, $now);
                } elsif ($now - $passed_at >= 1) {
                    @check_owners = sort keys %owners;
                }
            }
        }
        close $_->[0] for @free;
        if ($slot) {
            unlink($ticket_path);
            close $ticket;
            undef $ticket;
        }
        flock($coordinator, LOCK_UN);
        if (@check_owners) {
            %stopped = $stopped_owners->(@check_owners);
            $passed_at = Time::HiRes::time();
        }
        $queued = 1 unless $slot || $caught;
        Time::HiRes::sleep(0.1) unless $slot || $caught;
    }
    if ($ticket) { unlink($ticket_path); close $ticket; }
    close $coordinator if $coordinator;
    if ($slot && !defined fcntl($slot, F_SETFD, 0)) {
        my $why = $!;
        close $slot;
        $refuse->($slot_path, $why);
    }
    if ($ledger_fh && !defined fcntl($ledger_fh, F_SETFD, 0)) {
        my $why = $!;
        close $ledger_fh;
        $refuse->($ledger_path, $why);
    }
    if (open(my $fh, '>', $wait_file)) {
        # A root admitted on its first pass did not queue: it records 0, so the
        # roots log's wait_ms is the time a root spent queued, not the admission work.
        printf {$fh} "%d\n", $waited_from && $queued ? (Time::HiRes::time() - $waited_from) * 1000 : 0;
        close $fh;
    }
    exit 128 + $signal_number{$caught} if $caught;
    $ENV{FM_LINT_INTERNAL_SLOT_PEAK_FILE} = $peak_file;
    $ENV{FM_LINT_INTERNAL_ADMISSION} = $ledger_path;
    # The host lock is held until the command has replaced the child's image,
    # which closes the child's close-on-exec end of this pipe, so the next
    # decision in any pool reads this root as running.
    pipe(my $exec_read, my $exec_write) or die "fm-lint-gate: pipe: $!\n";
    $child = fork();
    die "fm-lint-gate: fork: $!\n" unless defined $child;
    if (!$child) {
        close $exec_read;
        exec {$command[0]} @command;
        warn "fm-lint-gate: exec $command[0]: $!\n";
        POSIX::_exit(127);
    }
    close $exec_write;
    1 while !defined sysread($exec_read, my $byte, 1) && $!{EINTR};
    close $exec_read;
    close $host if $host;
    kill 'TERM', $child if $caught;
    # Growth guard. Admission charges each root its record only when that
    # record was measured on this input, so the budget holds at every reading
    # for roots that stay within their records. The residual is a root that
    # grows beyond its record on an unchanged input (analysis noise, a file the
    # analysis follows that the walk does not see). While the lint trees of
    # every pool on the host, plus any other process named shellcheck, hold
    # more than the budget, this gate stops (SIGSTOP) the analysis processes of
    # its own tree unless it belongs to the oldest running gate, and resumes
    # them as soon as the total fits again or its gate becomes the oldest. A
    # stopped process keeps what it holds but cannot grow further, and the
    # oldest running gate is never stopped (unless processes named shellcheck
    # outside every gate alone hold the budget), so every root finishes. No
    # polling guard can remove what roots grow inside one reading interval (up
    # to 2 s at or below 60 percent of the budget, 0.5 s above it).
    # The guard stops a process only through fm_signal_items' under:<gate>:<pid>,
    # which sends nothing unless that pid is a descendant of this gate when the
    # signal is sent, and records the exact start time it read; it resumes only that
    # exact identity, so a pid reused by another process is neither stopped nor
    # continued.
    my ($guard_busy, $poll) = (0, 0.5);
    my $guard = sub {
        return if $caught || $guard_busy;
        $guard_busy = 1;
        my $table = $process_table->();
        delete @paused{grep { !$table->{$_} } keys %paused} if $table;
        my $view = $table && $host_view->($table);
        my $mine = $view && $view->{gates}{$$};
        my $next = $mine && $view->{total} * 5 > $budget_kib * 3 ? 0.5 : 2;
        Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), $next, $next) if $next != $poll;
        $poll = $next;
        if (!$mine) { $guard_busy = 0; return; }
        my ($oldest) = sort { $view->{gates}{$a}[1] <=> $view->{gates}{$b}[1] || $a <=> $b }
            grep { $view->{gates}{$_}[2] } keys %{$view->{gates}};
        my $over = $view->{total} > $budget_kib;
        if ($over && (!defined $oldest || $oldest != $$ || $view->{named} >= $budget_kib)) {
            my @stop;
            for my $pid (sort { $a <=> $b } keys %{$mine->[0]}) {
                next if $pid == $$ || $paused{$pid};
                my $row = $table->{$pid} or next;
                next if $row->[1] < 8192
                    || $row->[3] =~ m{\A\S*(?i:perl|bash|python)\S*\s+(?:-\S+\s+)*\S*(?:fm-lint-cache\.pl|fm-lint\.sh|fm-proc-info\.py)\b|\A\(?\S*(?i:python)\S*\)?\z};
                push @stop, "under:$$:$pid";
            }
            my $stopped = fm_signal_items('STOP', @stop);
            $paused{$_} = $stopped->{identity}{$_} for grep { $stopped->{identity}{$_} } @{$stopped->{sent}};
        } elsif (%paused) {
            $resume->();
        }
        $guard_busy = 0;
    };
    $SIG{ALRM} = sub { local ($?, $!); $guard->() };
    Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), $poll, $poll);
    my $reaped;
    while (($reaped = waitpid($child, 0)) == -1 && $!{EINTR}) { }
    my $status = $reaped == $child ? $? : 127 << 8;
    Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), 0, 0);
    $resume->();
    # Raise the root's record to this complete analysis's measured peak (the
    # watch's peak of resident size and footprint, and /usr/bin/time's maximum
    # resident size) when it describes this input, else replace it with that
    # peak and this input's size.
    my $code = ($status & 127) ? -1 : $status >> 8;
    if ($history_path && defined $root_bytes && !$caught && grep { $code == $_ } 0, 1, 98, 251) {
        my $peak = $read_kib->($peak_file);
        my $rss_file = $ENV{FM_LINT_INTERNAL_ROOT_RSS_FILE} // '';
        if (length $rss_file && open(my $fh, '<', $rss_file)) {
            while (my $line = <$fh>) {
                $peak = $max->($peak, $1) if $line =~ /\Amax_rss_kib=([0-9]+)\s*\z/;
                $peak = $max->($peak, int($1 / 1024)) if $line =~ /\A\s*([0-9]+)\s+maximum resident set size/;
            }
            close $fh;
        }
        my $history;
        if ($peak && !(eval { make_path(dirname($history_path), {mode => 0700}); 1 }
            && open($history, '+>>', $history_path) && flock($history, LOCK_EX)
            && seek($history, 0, 0)
            && do {
                my $old = <$history> // '';
                my $kept = $in_band->($old);
                defined $kept && $kept >= $peak
                    || truncate($history, 0)
                        && syswrite($history, defined $kept ? "$peak " . (split ' ', $old)[1] . "\n" : "$peak $root_bytes\n");
            })) {
            warn "fm-lint: cannot record the $peak KiB memory peak of $root_key at $history_path ($!); "
                . "its record was not raised\n";
        }
        close $history if $history;
    }
    exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
}

# Private resident-memory watch. Usage: perl fm-lint-cache.pl rsswatch <limit-kib> <rss-file> -- <command...>
# fm-lint.sh runs this only on native macOS, which cannot apply ulimit -v and so
# has no other memory bound on a root. It runs the command in a process group
# of its own and samples once a second that command's process tree within that
# group, reading only the tree's own processes and never the whole host's: the
# command, its descendants in any group or session, and each process the reader
# has seen in the tree that was later orphaned (its parent left it to the init
# process), so a memory-holding grandchild cannot leave the count by outliving
# its parent. Each sample is the larger of the tree's resident size and its
# physical footprint, which also counts the compressed pages jetsam counts, both
# read by a long-lived libproc reader (fm-proc-info.py rss-tree) started at the
# first tick, so a command that ends sooner starts none. Each reader runs under the
# interpreter fm-lint.sh resolved once (FM_LINT_INTERNAL_PYTHON), or python3
# when that is unset. A reader's first reply may take 2 s, which covers its
# start-up; each later reply has 0.5 s. A tick whose reply is late or malformed
# is sampled by ps, which gives resident size alone; that reply is discarded
# and a new reader starts for the next tick. A replacement that cannot start,
# or that fails before it replies, is one failed restart, and the next tick
# tries again. The reader is given up for the rest
# of the command, with ps sampling every later tick, only when libproc cannot
# read the command, the command's first reader exits before its first reply,
# or three restarts in a row fail; a good reply resets that count. The reason
# is then appended to <rss-file> once as rss_reader_unavailable=<reason>. Crossing the limit ends the group with
# KILL, records the peak sampled as max_rss_kib=<KiB> in <rss-file> (the file
# /usr/bin/time would have written), names the bound on stderr, and exits 98,
# which fm-lint.sh reports as a memory failure so the root takes its narrower
# retry. Any other end passes the command's own status straight through.
# Every end appends to
# <rss-file> how many samples each source gave, as
# rss_samples=libproc:<n>,ps:<n>, for the roots log, and the peak the watch itself
# read as watch_peak_kib=<KiB> (the larger of the tree's resident size and
# footprint; /usr/bin/time's own figure is a different measurement and the roots log
# keeps the two in separate columns). Each new peak is also
# written to FM_LINT_INTERNAL_SLOT_PEAK_FILE when the host-slot gate names one,
# so the gate's admission charges it. A signal to the watch, or
# the loss of its parent, ends the group within about one tick (about 1 s, or
# about 6 s if the command ignores TERM) after the lint that started it ends;
# the watch itself sits in a group of its own, out of reach of its owner's
# group sweep. When every reader fails three ticks in a row (libproc and the
# process table), the watch warns once, writes FM_LINT_INTERNAL_ABORT_FILE so the
# run starts no further root, records rss_unmeasured=1 in <rss-file>, and goes on
# sampling each later tick. A process the memory reading does not name makes the
# tick a miss, never a zero.
# The watch never signals a process by its pid alone. It keeps, for each member
# of the tree, the pid and the exact time the process started, taken from the
# reader's reply (or, for a member first found by ps or the helper's table, the
# whole start second they print, which is never exact), and ends a member only
# through fm_signal_by_identity above, which sends nothing to a process whose start
# time differs, cannot be read or is known only to the second, and names it on
# stderr and in <rss-file> as rss_signal_skipped=<pid>:<mismatch|unreadable|inexact>.
# A restarted reader knows only the root's group and its descendants, so after
# each reply the watch looks up, in the process table, every member it already
# knew that the reply does not name, and keeps and counts each that still runs. The root's own process group
# is signalled as a group only while the watch has not yet reaped the root,
# because that pid cannot be reused until then. While the reader is down, each tick
# is sampled from the process table (ps, or the helper's table and memory when ps
# is refused): the root's group, every member the watch already knew whose start
# time still matches, and the descendants of all of them, so a descendant that
# left the group is still counted and ended.
if (($ARGV[0] // '') eq 'rsswatch') {
    require POSIX;
    require Time::HiRes;
    my (undef, $limit, $rss_file, $dashes, @command) = @ARGV;
    die "fm-lint-rsswatch: invalid private invocation\n"
        unless defined $dashes && $dashes eq '--' && @command && defined $rss_file
            && ($limit // '') =~ /\A[1-9][0-9]*\z/;
    my $helper = dirname(abs_path($0)) . '/fm-proc-info.py';
    my $peak_file = $ENV{FM_LINT_INTERNAL_SLOT_PEAK_FILE} // '';
    my $owner = getppid();
    # The watch keeps a process group of its own, apart from its owner's and
    # its command's, so an owner's group sweep cannot kill it before it has
    # ended the command's group (it notices the lost parent within a tick).
    POSIX::setpgid(0, 0);
    my $python = $ENV{FM_LINT_INTERNAL_PYTHON} || 'python3';
    my ($to_reader, $from_reader, $reader_pid, $reader_fresh, $reader_down, $reader_answered);
    my ($reader_failures, %samples) = (0, libproc => 0, ps => 0);
    my %known;    # pid => [start seconds, start microseconds or undef], every member seen
    my ($child_reaped, %skipped);
    # A reader exits when its input closes; only a reader still running 2 s later,
    # the watch's own unreaped child, is ended by a signal.
    my $stop_reader = sub {
        return unless $reader_pid;
        close $to_reader;
        close $from_reader;
        my $until = Time::HiRes::time() + 2;
        my $reaped = waitpid($reader_pid, POSIX::WNOHANG());
        while ($reaped == 0 && Time::HiRes::time() < $until) {
            Time::HiRes::sleep(0.02);
            $reaped = waitpid($reader_pid, POSIX::WNOHANG());
        }
        if ($reaped == 0) {
            kill 'KILL', $reader_pid;
            waitpid($reader_pid, 0);
        }
        undef $reader_pid;
    };
    # The reader stays in the watch's own group, so the bound never counts or
    # ends it, and it exits when the watch closes its input.
    my $start_reader = sub {
        my ($root_pid) = @_;
        require IPC::Open2;
        no warnings 'exec';
        my $first = !defined $reader_fresh;
        $reader_pid = -r $helper
            ? eval { IPC::Open2::open2($from_reader, $to_reader, $python, $helper, 'rss-tree', $root_pid) } : undef;
        ($reader_fresh, $reader_answered) = ($first && $reader_pid ? 1 : 0, 0);
        return if $reader_pid;
        $reader_down = $first ? 'exited-at-start' : ++$reader_failures > 3 ? 'restarts-failed' : undef;
    };
    # One read of the host's process table for the tick the reader cannot answer:
    # { pid => [ppid, pgid, resident KiB, start seconds] } from ps, or, where ps is
    # refused, from fm-proc-info.py (table for the ids and start, memory for the
    # sizes); undef when neither answers.
    my %month = (Jan => 0, Feb => 1, Mar => 2, Apr => 3, May => 4, Jun => 5, Jul => 6, Aug => 7, Sep => 8, Oct => 9, Nov => 10, Dec => 11);
    my $start_seconds = sub {
        my ($text) = @_;
        return undef unless ($text // '') =~ /\A\w{3}\s+(\w{3})\s+([0-9]+)\s+([0-9]+):([0-9]+):([0-9]+)\s+([0-9]{4})\z/ && exists $month{$1};
        return POSIX::mktime($5, $4, $3, $2, $month{$1}, $6 - 1900);
    };
    my $read_table = sub {
        my %table;
        {
            no warnings 'exec';
            local $ENV{LC_ALL} = 'C';
            if (open(my $ps, '-|', 'ps', '-axww', '-o', 'pid=,ppid=,pgid=,rss=,lstart=')) {
                while (my $line = <$ps>) {
                    next unless $line =~ /\A\s*([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+(\S+\s+\S+\s+[0-9]+\s+[0-9:]+\s+[0-9]+)\s*\z/;
                    my $started = $start_seconds->($5) // next;
                    $table{$1} = [$2 + 0, $3 + 0, $4 + 0, $started];
                }
                close $ps;
            }
        }
        return \%table if %table;
        return undef unless -r $helper;
        no warnings 'exec';
        my %rss;
        if (open(my $py, '-|', $python, $helper, 'memory')) {
            local $/;
            my $json = <$py>;
            close $py;
            require JSON::PP;
            my $rows = eval { JSON::PP::decode_json($json // '') };
            for my $row (ref $rows eq 'ARRAY' ? @$rows : ()) {
                $rss{$row->{pid}} = int($row->{rss_bytes} / 1024) if ref $row eq 'HASH' && defined $row->{pid} && defined $row->{rss_bytes};
            }
        }
        if (open(my $py, '-|', $python, $helper, 'table', 'pid,ppid,pgid,lstart')) {
            while (my $line = <$py>) {
                next unless $line =~ /\A\s*([0-9]+)\s+([0-9]+)\s+([0-9]+)\s+(\S+\s+\S+\s+[0-9]+\s+[0-9:]+\s+[0-9]+)\s*\z/;
                my $started = $start_seconds->($4) // next;
                # A process the memory reading did not name has no size: a sample
                # that needs it is a miss, never a zero.
                $table{$1} = [$2 + 0, $3 + 0, $rss{$1}, $started];
            }
            close $py;
        }
        return %table ? \%table : undef;
    };
    # KiB of the group leader <pid>, its live descendants and the members of its
    # tree orphaned since the reader saw them, the larger of footprint and
    # resident size, or undef when unreadable.
    my $tree_rss = sub {
        my ($root_pid) = @_;
        $start_reader->($root_pid) unless $reader_pid || $reader_down;
        if ($reader_pid) {
            local $SIG{PIPE} = 'IGNORE';
            my ($answer, $ready) = ('', '');
            vec($ready, fileno($from_reader), 1) = 1;
            my $gone = !syswrite($to_reader, "\n");
            my $wait = $reader_answered ? 0.5 : 2;
            while (!$gone && $answer !~ /\n/ && select(my $readable = $ready, undef, undef, $wait) > 0) {
                $gone = !sysread($from_reader, $answer, 64, length $answer);
            }
            if ($answer =~ /\A\{"rss_kib":([0-9]+),[^\n]*\}\n\z/) {
                my $kib = $1 + 0;
                ($reader_failures, $reader_fresh, $reader_answered) = (0, 0, 1);
                $samples{libproc}++;
                # The reader names every member of the tree it counted, including a
                # descendant that left the root's process group: those are the
                # processes this watch ends along with the group.
                my $named = eval { require JSON::PP; JSON::PP::decode_json($answer)->{members} };
                if (ref $named eq 'ARRAY') {
                    my %reply = map { ($_->[0] + 0 => [$_->[1] + 0, $_->[2] + 0]) }
                        grep { ref $_ eq 'ARRAY' && @$_ >= 3 && !grep { !defined $_ || !/\A[0-9]+\z/ } @$_[0, 1, 2] } @$named;
                    # A reader that was restarted knows only the root's group and its
                    # descendants; a member the watch already knew that left the group
                    # and was orphaned is not among them. Every known member the reply
                    # does not name is looked up in the process table: one that still
                    # runs with its start second is kept, with the exact start time
                    # the watch knew, and counted with its descendants (whose start
                    # times are whole seconds, so they are counted and recorded but
                    # never signalled). Without a table the tick is a miss.
                    my @missing = grep { !$reply{$_} } keys %known;
                    if (@missing) {
                        my $table = $read_table->() or return undef;
                        my %children;
                        push @{$children{$table->{$_}[0]}}, $_ for keys %$table;
                        my @queue = grep { $table->{$_} && $table->{$_}[3] == $known{$_}[0] } @missing;
                        my %extra;
                        while (defined(my $member = shift @queue)) {
                            next if $reply{$member} || $extra{$member}++ || !$table->{$member} || $member == $$;
                            push @queue, @{$children{$member} // []};
                        }
                        for my $pid (keys %extra) {
                            return undef unless defined $table->{$pid}[2];
                            $kib += $table->{$pid}[2];
                            $reply{$pid} = $known{$pid} && $known{$pid}[0] == $table->{$pid}[3] ? $known{$pid} : [$table->{$pid}[3], undef];
                        }
                    }
                    %known = %reply;
                }
                return $kib;
            }
            my $fresh = $reader_fresh;
            $stop_reader->();
            $reader_down = $answer eq "-\n" || $answer =~ /\A\{"rss_kib":null,/ ? 'libproc-unreadable'
                : $gone && $fresh ? 'exited-at-start'
                : ++$reader_failures > 3 ? 'restarts-failed' : undef;
            $start_reader->($root_pid) unless $reader_down;
        }
        # The reader is down for this tick: sample the process table and select the
        # tree by identity, not only the root's group.
        my $table = $read_table->();
        return undef unless $table && exists $table->{$root_pid};
        $samples{ps}++;
        my %children;
        push @{$children{$table->{$_}[0]}}, $_ for keys %$table;
        # The root's group (the root is not yet reaped while this runs, so its pid
        # and group are ours), every member known whose start time still matches,
        # and the descendants of all of them.
        my @queue = grep { $table->{$_}[1] == $root_pid } keys %$table;
        push @queue, grep { $table->{$_} && $table->{$_}[3] == $known{$_}[0] } keys %known;
        my %selected;
        while (defined(my $member = shift @queue)) {
            next if $selected{$member}++ || !$table->{$member} || $member == $$;
            push @queue, @{$children{$member} // []};
        }
        delete $selected{$$};
        my %next;
        for my $pid (keys %selected) {
            my $before = $known{$pid};
            $next{$pid} = [$table->{$pid}[3], $before && $before->[0] == $table->{$pid}[3] ? $before->[1] : undef];
        }
        %known = %next;
        my $total = 0;
        for my $pid (keys %selected) {
            return undef unless defined $table->{$pid}[2];
            $total += $table->{$pid}[2];
        }
        return $total;
    };
    my ($child, $caught, $term_at, $over, $warned);
    # End the whole counted tree: the root's process group, and every member known
    # by pid and start time, which also reaches a descendant that moved to another
    # group or was orphaned. The group is signalled as a group only until the root
    # is reaped (its pid cannot be reused before that); every other member only
    # through fm_signal_by_identity, which sends nothing to a pid whose process
    # started at another time, or whose start time cannot be read, and the watch
    # records it. The watch's own pid and the root's are never members to signal.
    my $end_tree = sub {
        fm_signal_items('KILL', "group:$child") if $child && !$child_reaped;
        my @members = map { [$_, @{$known{$_}}] } grep { $_ != $$ && $_ != ($child // 0) } sort { $a <=> $b } keys %known;
        my $result = fm_signal_by_identity('KILL', @members);
        for my $kind (qw(mismatch unreadable inexact)) {
            for my $pid (@{$result->{$kind}}) {
                next if $skipped{$pid};
                $skipped{$pid} = $kind;
                warn "fm-lint: resident-memory watch sent nothing to pid $pid: its start time $kind\n";
            }
        }
    };
    my ($peak, $misses) = (0, 0);
    my %signal_number = (HUP => 1, INT => 2, TERM => 15);
    for my $name (keys %signal_number) {
        $SIG{$name} = sub {
            $caught = $name;
            $term_at //= Time::HiRes::time();
            fm_signal_items('TERM', "group:$child") if $child && !$child_reaped;
        };
    }
    # Perl restarts waitpid after a handled signal, so the sampling runs in the
    # timer's handler while the main flow blocks in waitpid.
    my $busy;
    my $sample = sub {
        if (!$caught && getppid() != $owner) {
            $caught = 'TERM';
            $term_at = Time::HiRes::time();
            fm_signal_items('TERM', "group:$child") unless $child_reaped;
        }
        $end_tree->() if $caught && Time::HiRes::time() - $term_at >= 5;
        return if $caught || $over;
        my $rss = $tree_rss->($child);
        # A root that exits mid-sample is a zombie no sampler can read, so only
        # three misses in a row mean the sampler is failing.
        if (!defined $rss) {
            return if $child_reaped || !kill(0, $child);
            return if ++$misses < 3 || $warned;
            # Every reader failed three ticks in a row: this root runs unmeasured.
            # The run admits no new root (the abort mark its workers check), and the
            # loss is recorded on stderr and in <rss-file>.
            my $abort = $ENV{FM_LINT_INTERNAL_ABORT_FILE} // '';
            if (length $abort && open(my $mark, '>>', $abort)) {
                print {$mark} "the resident-memory watch lost every reader of a running root's memory (libproc and the process table)\n";
                close $mark;
            }
            warn "fm-lint: resident-memory watch cannot sample this root (no reader answers); the run starts no further root\n";
            $warned = 1;
            return;
        }
        $misses = 0;
        if ($rss > $peak) {
            $peak = $rss;
            if (length $peak_file) {
                my ($staged, $fh) = ("$peak_file.tmp.$$");
                open($fh, '>', $staged) && print({$fh} "$peak\n") && close($fh) && rename($staged, $peak_file)
                    or unlink $staged;
            }
        }
        return unless $rss > $limit;
        $over = 1;
        $end_tree->();
        if (open(my $fh, '>', $rss_file)) { printf {$fh} "max_rss_kib=%d\n", $peak; close $fh; }
        warn sprintf("fm-lint: root exceeded the %d KiB resident-memory bound (FM_LINT_ROOT_RSS_KIB) at %d KiB; ended\n", $limit, $peak);
    };
    $SIG{ALRM} = sub {
        local ($?, $!);
        return if $busy || !$child;
        $busy = 1;
        $sample->();
        $busy = 0;
    };
    $child = fork();
    die "fm-lint-rsswatch: fork: $!\n" unless defined $child;
    if (!$child) {
        POSIX::setpgid(0, 0);
        exec {$command[0]} @command;
        warn "fm-lint-rsswatch: exec $command[0]: $!\n";
        POSIX::_exit(127);
    }
    POSIX::setpgid($child, $child);
    fm_signal_items('TERM', "group:$child") if $caught;
    Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), 1, 1);
    my $reaped = waitpid($child, 0);
    $child_reaped = 1 if $reaped == $child;
    my $status = $reaped == $child ? $? : 127 << 8;
    Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), 0, 0);
    $end_tree->() if $over || $caught;
    $stop_reader->();
    if (open(my $fh, '>>', $rss_file)) {
        printf {$fh} "rss_samples=libproc:%d,ps:%d\n", @samples{qw(libproc ps)};
        print {$fh} "rss_reader_unavailable=$reader_down\n" if $reader_down;
        printf {$fh} "watch_peak_kib=%d\n", $peak if $peak;
        print {$fh} 'rss_signal_skipped=' . join(',', map { "$_:$skipped{$_}" } sort { $a <=> $b } keys %skipped) . "\n" if %skipped;
        print {$fh} "rss_unmeasured=1\n" if $warned;
        close $fh;
    }
    exit 98 if $over;
    exit 128 + $signal_number{$caught} if $caught;
    exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
}

my ($mode, $root, @args) = @ARGV;
my $cache;
if (defined $mode && $mode eq 'check') {
    $cache = $root;
    $root = shift @args;
}
die "fm-lint-cache: invalid private invocation\n" unless defined $root && ($mode eq 'select' || $mode eq 'check');
chdir $root or die "fm-lint-cache: chdir $root: $!\n";
my @inventory = sort map { glob $_ } qw(bin/*.sh bin/backends/*.sh tests/*.sh);
my @source_candidates = @inventory;
my (%text, %edges, %unknown);
sub contents {
    my ($path) = @_;
    return $text{$path} if exists $text{$path};
    open my $fh, '<', $path or return $text{$path} = undef;
    local $/;
    return $text{$path} = <$fh>;
}
sub identity_path {
    my ($path) = @_;
    my $absolute = abs_path($path);
    if (!defined $absolute) {
        my $parent = abs_path(dirname($path));
        $absolute = "$parent/" . basename($path) if defined $parent;
    }
    return $path unless defined $absolute;
    $absolute =~ s{^\Q$root\E/}{};
    return $absolute;
}
sub balanced_text {
    my ($body, $position, $open, $close, $subs) = @_;
    my $start = $$position;
    my $depth = 1;
    while ($$position < length $body) {
        my $char = substr($body, $$position, 1);
        if ($char eq $open) { $depth++; $$position++; next; }
        if ($char eq $close) {
            $$position++;
            return substr($body, $start, $$position - $start - 1) if --$depth == 0;
            next;
        }
        if ($char =~ /[\s;&|<>]/) { $$position++; next; }
        if ($char eq '#' && $open eq '(') {
            my $end = index($body, "\n", $$position);
            $$position = $end < 0 ? length($body) : $end;
            next;
        }
        my $before = $$position;
        my $word = shell_word($body, $position, {}, $close);
        push @$subs, @{$word->{subs}} if defined $subs;
        $$position++ if $$position == $before;
    }
    return substr($body, $start);
}
sub shell_word {
    my ($body, $position, $parameters, $stop, $literal) = @_;
    my ($value, $quote, @subs) = ('', '');
    my $raw_start = $$position;
    while ($$position < length $body) {
        my $char = substr($body, $$position, 1);
        last if !$quote && defined $stop && $char eq $stop;
        last if !$quote && $char =~ /[\s;&|<>()]/ && substr($body, $$position, 2) !~ /^[<>]\(/;
        if (!$quote && $char eq "'") {
            my $end = index($body, "'", $$position + 1);
            $end = length $body if $end < 0;
            $value .= substr($body, $$position + 1, $end - $$position - 1);
            $$position = $end < length($body) ? $end + 1 : $end;
            next;
        }
        if ($char eq '"') { $quote = $quote ? '' : '"'; $$position++; next; }
        if ($char eq '\\') {
            my $next = substr($body, $$position + 1, 1);
            $value .= '\\' if $quote && $next !~ /[\$`"\\\n]/;
            $value .= $next unless $next eq "\n";
            $$position += 2;
            next;
        }
        if (substr($body, $$position, 2) eq '$(' || (!$quote && substr($body, $$position, 2) =~ /^[<>]\(/)) {
            my $start = $$position;
            $$position += 2;
            my $program = balanced_text($body, $position, '(', ')');
            push @subs, $program unless $literal || $program =~ /^\(/;
            $value .= $literal ? substr($body, $start, $$position - $start) : "\x01";
            next;
        }
        if ($char eq '`') {
            my $start = $$position;
            $$position++;
            my $program = '';
            while ($$position < length $body) {
                my $part = substr($body, $$position++, 1);
                last if $part eq '`';
                if ($part eq '\\' && substr($body, $$position, 1) =~ /[\$`\\]/) {
                    $part = substr($body, $$position++, 1);
                }
                $program .= $part;
            }
            push @subs, $program unless $literal;
            $value .= $literal ? substr($body, $start, $$position - $start) : "\x01";
            next;
        }
        if ($char eq '$' && !$literal) {
            pos($body) = $$position;
            if ($body =~ /\G\$(?:\{([0-9]+)\}|([0-9]))/gc) {
                my $number = defined $1 ? $1 : $2;
                $$position = pos($body);
                $value .= exists $parameters->{$number} ? $parameters->{$number} : "\x01";
                next;
            }
            if ($body =~ /\G\$(?:[A-Za-z_]\w*|[?!#*@-])/gc) {
                $$position = pos($body);
                $value .= "\x01";
                next;
            }
            if (substr($body, $$position, 2) eq '${') {
                $$position += 2;
                balanced_text($body, $position, '{', '}', \@subs);
                $value .= "\x01";
                next;
            }
        }
        $value .= $char;
        $$position++;
    }
    return {value => $value, raw => substr($body, $raw_start, $$position - $raw_start), subs => \@subs};
}
sub source_dependency {
    my ($path, $word, $deps, $finite_backend) = @_;
    unless (defined $word) { $unknown{$path} = 1; return; }
    my $source = $word->{value};
    return if $source eq '/dev/null';
    if ($source =~ m{^\x01(/[^\x01\$`*?\[\\<>&|'"]+)\z}) {
        my $suffix = $1;
        $deps->{".$suffix"} = 1;
        $deps->{dirname($path) . $suffix} = 1;
        my ($base) = $source =~ m{([^/]+)$};
        $deps->{$_} = 1 for grep { m{(?:^|/)\Q$base\E$} } @source_candidates;
    } elsif ($source ne '' && $source !~ /[\x01\$`*?\[\\<>&|'"]/ && $source !~ /^-/) {
        $source =~ s{^\./}{};
        $deps->{$source} = 1;
    } else {
        return if $finite_backend && ($word->{raw} eq '"$adapter"' || $word->{raw} eq '$adapter');
        $unknown{$path} = 1;
    }
}
sub command_dependencies {
    my ($path, $words, $deps, $finite_backend, $stdin) = @_;
    my @words = @$words;
    while (@words) {
        my $raw = $words[0]{raw} // $words[0]{value};
        $raw =~ s/\\\n//g;
        last unless $raw =~ /^(?:if|then|elif|else|while|until|do|!|time)$/ || $raw =~ /^[A-Za-z_]\w*=/;
        my $prefix = shift @words;
        shift @words if $prefix->{value} eq 'time' && @words && $words[0]{value} eq '-p';
    }
    return unless @words;
    my $command = shift @words;
    if ($command->{value} =~ /^(?:builtin|command)$/ && @words && $words[0]{value} =~ /^(?:source|\.)$/) {
        $unknown{$path} = 1;
        shift @words;
        source_dependency($path, $words[0], $deps, $finite_backend);
    } elsif ($command->{value} =~ /^(?:source|\.)$/) {
        source_dependency($path, $words[0], $deps, $finite_backend);
    } else {
        while ($command->{value} =~ /^(?:exec|command|env)$/ && @words) {
            shift @words while @words && ($words[0]{value} =~ /^-/ || $words[0]{value} =~ /^[A-Za-z_]\w*=/);
            return unless @words;
            $command = shift @words;
        }
        return unless $command->{value} =~ m{(?:^|/)(?:bash|sh)$};
        my $stdin_mode = 0;
        while (@words && $words[0]{value} =~ /^[-+]/) {
            my $option = shift @words;
            if ($option->{value} eq '-') { $stdin_mode = 1; last; }
            last if $option->{value} eq '--';
            if ($option->{value} =~ /^-[A-Za-z]*c[A-Za-z]*$/) {
                my $payload = shift @words;
                return unless defined $payload;
                if ($payload->{value} =~ /\x01/) { $unknown{$path} = 1; return; }
                my %child_parameters;
                $child_parameters{$_} = $words[$_]{value} for 0 .. $#words;
                scan_program($path, $payload->{value}, $deps, $finite_backend, \%child_parameters);
                return;
            }
            $stdin_mode = 1 if $option->{value} =~ /^-[A-Za-z]*s[A-Za-z]*$/;
            shift @words if $option->{value} =~ /^(?:[-+][oO]|--rcfile|--init-file)$/;
        }
        if (!$stdin_mode && @words && $words[0]{value} eq '-') { $stdin_mode = 1; shift @words; }
        return unless defined $stdin && ($stdin_mode || !@words);
        my %child_parameters;
        $child_parameters{$_ + 1} = $words[$_]{value} for 0 .. $#words;
        $stdin->{parameters} = \%child_parameters;
    }
}
sub scan_program {
    my ($path, $body, $deps, $finite_backend, $parameters) = @_;
    my ($position, @words, @heredocs, @cases, $stdin);
    $position = 0;
    while ($position < length $body) {
        pos($body) = $position;
        if ($body =~ /\G(?:[ \t\r]+|\\\n)/gc) { $position = pos($body); next; }
        if ($body =~ /\G(#[^\n]*)/gc) {
            my $comment = $1;
            $position = pos($body);
            if ($comment =~ /^#\s*shellcheck\s+.*?\bsource=(?:"([^"]+)"|'([^']+)'|([^\s]+))/) {
                my $source = defined $1 ? $1 : defined $2 ? $2 : $3;
                $deps->{$source} = 1 unless $source eq '/dev/null';
            }
            $unknown{$path} = 1 if $comment =~ /^#\s*shellcheck\s+.*\bsource-path=/;
            next;
        }
        if (substr($body, $position, 2) eq '[[' || substr($body, $position, 2) eq '((') {
            my $close = substr($body, $position, 2) eq '[[' ? ']]' : '))';
            $position += 2;
            while ($position < length($body) && substr($body, $position, 2) ne $close) {
                if (substr($body, $position, 1) =~ /[\s;&|<>()]/) { $position++; next; }
                my $word = shell_word($body, \$position, $parameters);
                scan_program($path, $_, $deps, $finite_backend, $parameters) for @{$word->{subs}};
            }
            $position += 2;
            push @words, {value => 'test'};
            next;
        }
        if (substr($body, $position, 2) !~ /^[<>]\(/ && $body =~ /\G((?:[0-9]+)?(?:<<<|<<-|<<|>>|<&|>&|<>|>|<)|&>)/gc) {
            my $operator = $1;
            $position = pos($body);
            $position++ while substr($body, $position, 1) =~ /[ \t]/;
            my $heredoc = $operator =~ /^(?:[0-9]+)?<<-?$/;
            my $target = shell_word($body, \$position, $parameters, undef, $heredoc);
            scan_program($path, $_, $deps, $finite_backend, $parameters) for @{$target->{subs}};
            my $input = $operator =~ /^(?:0)?</;
            $stdin = undef if $input;
            if ($heredoc) {
                my $record = {
                    delimiter => $target->{value},
                    tabs => scalar($operator =~ /<<-/),
                    quoted => scalar($target->{raw} =~ /['"\\]/),
                };
                push @heredocs, $record;
                $stdin = $record if $input;
            }
            next;
        }
        if ($body =~ /\G([\n;(){}|&])/gc) {
            my $separator = $1;
            $position = pos($body);
            if (@cases && $cases[-1] eq 'pattern') {
                $cases[-1] = 'body' if $separator eq ')';
            } else {
                command_dependencies($path, \@words, $deps, $finite_backend, $stdin);
                $cases[-1] = 'pattern' if @cases && $separator eq ';' && substr($body, $position, 1) =~ /[;&]/;
            }
            @words = ();
            $stdin = undef;
            if ($separator eq "\n") {
                for my $heredoc (@heredocs) {
                    my $program = '';
                    while ($position < length $body) {
                        my $end = index($body, "\n", $position);
                        $end = length $body if $end < 0;
                        my $line = substr($body, $position, $end - $position);
                        $position = $end < length($body) ? $end + 1 : $end;
                        $line =~ s/^\t+// if $heredoc->{tabs};
                        last if $line eq $heredoc->{delimiter};
                        $program .= "$line\n" if exists $heredoc->{parameters};
                    }
                    if (exists $heredoc->{parameters}) {
                        my $child_parameters = $heredoc->{quoted} ? $heredoc->{parameters} : $parameters;
                        $unknown{$path} = 1 if !$heredoc->{quoted} && $program =~ /[\$`]/;
                        scan_program($path, $program, $deps, $finite_backend, $child_parameters);
                    }
                }
                @heredocs = ();
            }
            next;
        }
        my $word = shell_word($body, \$position, $parameters);
        scan_program($path, $_, $deps, $finite_backend, $parameters) for @{$word->{subs}};
        if (!@words && $word->{raw} eq 'case') { push @cases, 'header'; next; }
        if (@cases && $cases[-1] eq 'header') { $cases[-1] = 'pattern' if $word->{raw} eq 'in'; next; }
        if (@cases && $word->{raw} eq 'esac' && !@words) { pop @cases; next; }
        next if @cases && $cases[-1] eq 'pattern';
        push @words, $word;
    }
    command_dependencies($path, \@words, $deps, $finite_backend, $stdin);
}
sub dependencies {
    my ($path) = @_;
    return @{$edges{$path}} if exists $edges{$path};
    my $body = contents($path);
    my %deps;
    my $finite_backend = identity_path($path) eq 'bin/fm-backend.sh';
    if ($finite_backend) {
        $deps{"bin/backends/$_.sh"} = 1 for qw(tmux herdr zellij orca cmux);
    }
    if (defined $body) {
        scan_program($path, $body, \%deps, $finite_backend, {});
    }
    return @{$edges{$path} = [sort map { identity_path($_) } keys %deps]};
}
sub closure {
    my ($path, $seen) = @_;
    return if $seen->{$path}++;
    closure($_, $seen) for dependencies($path);
}
if ($mode eq 'select') {
    local $/ = "\0";
    my %changed;
    while (<STDIN>) { chomp; s{^\./}{}; $changed{$_} = 1; }
    push @source_candidates, keys %changed;
    my $policy_changed = grep { $changed{$_} } qw(bin/fm-lint.sh bin/fm-lint-cache.pl);
    my (%selected, %closures, %inputs);
    for my $path (@inventory) {
        my %seen;
        closure($path, \%seen);
        $closures{$path} = \%seen;
        $inputs{$_} = 1 for keys %seen;
    }
    my $source_changed = grep { $inputs{$_} || /\.sh\z/ } keys %changed;
    for my $path (@inventory) {
        my $seen = $closures{$path};
        $selected{$path} = 1 if $policy_changed || $changed{$path}
            || (grep { $changed{$_} } keys %$seen)
            || ($source_changed && (grep { $unknown{$_} } keys %$seen));
    }
    print "$_\0" for grep { $selected{$_} } @inventory;
    exit 0;
}
my $tool = shift @args;
my @execute;
for my $index (0 .. $#args) {
    next unless $args[$index] eq '--';
    my $marker = $index + 2; # The root operand follows the analysis delimiter.
    next unless $marker <= $#args && $args[$marker] eq '--execute';
    @execute = splice @args, $marker;
    shift @execute;
    die "fm-lint-cache: missing execution command\n" unless @execute;
    last;
}
my $path = $args[-1];
die "fm-lint-cache: missing analysis command\n" unless defined $path && defined $tool;
$path = identity_path($path);
sub fingerprint {
    %text = (); %edges = (); %unknown = ();
    return undef unless defined contents($tool);
    my %seen;
    closure($path, \%seen);
    return undef if grep { $unknown{$_} } keys %seen;
    my @key_args = map { my $arg = $_; $arg =~ s{^\Q$root\E/}{}; $arg } @args;
    my @parts = ('fm-lint-cache-v1', $^O, @key_args);
    $seen{$_} = 1 for ($tool, 'bin/fm-lint.sh', 'bin/fm-lint-cache.pl');
    for my $name (sort keys %seen) {
        my $body = contents($name);
        push @parts, $name eq $tool ? 'shellcheck-binary' : $name,
            defined $body ? sha256_hex($body) : 'missing';
    }
    return sha256_hex(join "\0", @parts);
}
# Per-invocation sidecars distinguish reused successes from cold analysis and
# account for key-lock queue time outside the analysis watchdog and retry budget.
my $key_wait_ms = 0;
sub duration_outcome {
    my ($outcome) = @_;
    return unless defined $ENV{FM_LINT_CACHE_RESULT_FILE};
    if (open(my $fh, '>', $ENV{FM_LINT_CACHE_RESULT_FILE})) {
        print {$fh} "$outcome\n";
        close $fh;
    } else {
        warn "fm-lint: cannot record cache outcome: $!\n";
    }
    return if $key_wait_ms <= 0;
    if (open(my $fh, '>', "$ENV{FM_LINT_CACHE_RESULT_FILE}.wait")) {
        print {$fh} "$key_wait_ms\n";
        close $fh;
    } else {
        warn "fm-lint: cannot record cache queue time: $!\n";
    }
}
my $key = $cache eq 'off' ? undef : fingerprint();
my ($lock, $passed);
if (defined $key) {
    # An unavailable cache is an optimization failure, not a lint failure.
    require Time::HiRes;
    if (eval { make_path($cache, {mode => 0700}); 1 }
        && open($lock, '>>', "$cache/$key.lock")
        && do {
            my $started = Time::HiRes::time();
            my $got = flock($lock, LOCK_EX);
            my $error = 0 + $!;
            $key_wait_ms = int((Time::HiRes::time() - $started) * 1000);
            $! = $error;
            $got;
        }) {
        $passed = "$cache/$key.passed";
        my $locked_key = fingerprint();
        if (!defined $locked_key || $locked_key ne $key) {
            close $lock;
            undef $key;
        }
        if (defined $key && open(my $fh, '<', $passed)) {
            my $record = <$fh>;
            close $fh;
            if (defined $record && $record eq "$key\n") {
                duration_outcome('cache-hit');
                print STDERR "fm-lint: cache hit $path\n";
                exit 0;
            }
        }
    } else {
        warn "fm-lint: cache unavailable; checking $path\n";
        undef $key;
    }
}
duration_outcome('analyzed');
@execute = ($tool, @args) unless @execute;
# The input a cold analysis reads, for the gate's memory record: the root file
# plus every file its source closure follows, whatever the cache setting.
{
    my (%seen, $bytes);
    closure($path, \%seen);
    $bytes += (-s $_ || 0) for keys %seen;
    $ENV{FM_LINT_INTERNAL_ROOT_BYTES} = $bytes;
}
# Cache lookup and identical-miss serialization precede slot admission. Forward
# cancellation to the cold runner, retaining the key lock until it is reaped.
my ($child, $caught);
for my $name (qw(HUP INT TERM)) {
    $SIG{$name} = sub { $caught = $name; kill 'TERM', $child if $child; };
}
$child = fork();
die "fm-lint-cache: fork: $!\n" unless defined $child;
if (!$child) {
    exec {$execute[0]} @execute;
    warn "fm-lint-cache: exec $execute[0]: $!\n";
    require POSIX;
    POSIX::_exit(127);
}
kill 'TERM', $child if $caught;
my $reaped;
while (($reaped = waitpid($child, 0)) == -1 && $!{EINTR}) { }
my $status = $reaped == $child ? $? : 127 << 8;
my $rc = ($status & 127) ? 128 + ($status & 127) : $status >> 8;
if ($rc == 0 && defined $key) {
    my $after = fingerprint();
    if (defined $after && $after eq $key && open(my $fh, '>', $passed)) {
        print {$fh} "$key\n";
        close $fh;
    }
}
exit $rc;
