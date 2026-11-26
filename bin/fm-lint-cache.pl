#!/usr/bin/env perl
# fm-lint-cache.pl - private dependency selection, analysis runner, and host-slot gate for fm-lint.sh.
# Usage: perl fm-lint-cache.pl select <root> <NUL-separated changes on stdin>
#        perl fm-lint-cache.pl check <root> <shellcheck> <args> -- <file>
#             [--execute <command...>]
# ShellCheck retains source-aware extended analysis. Every check is analysed: no
# result is reused, because no sampled reading can prove which ShellCheck a
# launcher runs, and a reused success could hide a diagnostic.
# --execute wraps the analysis with the gate/watchdog/time command supplied by
# fm-lint.sh. The analysis runs with FM_LINT_INTERNAL_ROOT_BYTES set to the size
# of the root file plus every file its source closure follows.
#
use Cwd qw(abs_path);
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock F_SETFD);
use File::Path qw(make_path);
use File::Basename qw(dirname basename);

# Signalling (rule O, Main 1885). A signal goes only to the process group the watch
# itself created for its root and recorded at launch: the root's pid, which leads
# that group, and the root's exact start time, read before the root executes
# anything. fm_signal_root takes only that launch record, never a group from
# input; group 0 and 1 are refused. In one python step it reads the group leader
# again and sends only when the leader still has exactly the recorded start time
# and still leads that group, so no other process's group is ever signalled, also
# after the root is reaped and its pid reused. It returns "sent", "gone" (no such
# process), "mismatch" (another process, or another group: nothing sent),
# "unreadable" (nothing sent) or "refused" (no launch record). There is no command
# line route to it. Three own-child signals stay by pid: the gate and the check mode
# forward TERM to their own unreaped child, as on the base; the watch ends its own
# reader with KILL, which this change keeps but narrows (the base killed the reader
# at once when it stopped it; now only a reader still running 2 s after its input
# closed is killed).
my $ROOT_SIGNAL_PY = <<'PYTHON';
import importlib.util, os, signal, struct, sys
LINUX = os.path.exists("/proc/self/stat")
def leader(pgid):
    # (exact start identity, the group it leads); LookupError when there is none.
    if LINUX:
        try:
            with open("/proc/%d/stat" % pgid) as handle:
                fields = handle.read().rsplit(")", 1)[1].split()
        except FileNotFoundError:
            raise LookupError(pgid)
        return (int(fields[19]), 0), int(fields[2])
    spec = importlib.util.spec_from_file_location("fmproc", sys.argv[1])
    fp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fp)
    record = fp.kinfo(pgid)
    return tuple(fp.process_identity(record)), struct.unpack_from("i", record, fp.E_PGID)[0]
try:
    number = getattr(signal, "SIG" + sys.argv[2])
    pgid, recorded = int(sys.argv[3]), (int(sys.argv[4]), int(sys.argv[5]))
    if pgid <= 1:
        print("mismatch")
        sys.exit(0)
    try:
        identity, group = leader(pgid)
    except LookupError:
        print("gone")
        sys.exit(0)
    if identity != recorded or group != pgid:
        print("mismatch")
        sys.exit(0)
    try:
        os.killpg(pgid, number)
    except ProcessLookupError:
        print("gone")
        sys.exit(0)
    print("sent")
except SystemExit:
    raise
except Exception:
    print("unreadable")
PYTHON
sub fm_signal_root {
    my ($name, $launch) = @_;
    return 'refused' unless ref $launch eq 'HASH' && ($name // '') =~ /\A(?:TERM|KILL|STOP|CONT)\z/
        && ($launch->{pgid} // '') =~ /\A[0-9]+\z/ && $launch->{pgid} > 1
        && ($launch->{sec} // '') =~ /\A[0-9]+\z/ && ($launch->{usec} // '') =~ /\A[0-9]+\z/;
    my $python = $ENV{FM_LINT_INTERNAL_PYTHON} || 'python3';
    no warnings 'exec';
    open(my $py, '-|', $python, '-I', '-c', $ROOT_SIGNAL_PY, $launch->{helper} // '', $name, @{$launch}{qw(pgid sec usec)})
        or return 'unreadable';
    my $answer = <$py> // '';
    close $py;
    return $answer =~ /\A(sent|gone|mismatch|unreadable)\n\z/ ? $1 : 'unreadable';
}

# The state of one process, for the probe lane: perl runs
#   python -I -c $PROCESS_STATE_PY <fm-proc-info.py> identity <pid>
# which prints "<sec> <usec>" (its exact start time: libproc's seconds and
# microseconds on macOS, /proc's start time in clock ticks and 0 on Linux) or
# "unknown"; and ... state <pid> <sec> <usec>, which prints "alive" when that pid
# still has exactly that start time, "ended" when the pid is no longer in the process
# table or now holds another start time, and "unknown" for anything it cannot read.
# A root's watch ticks once a second; each tick is "s" (a sample) or "m" (a miss
# while the root still ran). The root ran unmeasured for an interval when any miss
# is followed by a later tick; only a miss on the very last tick (the root's own
# exit, which no reader can measure) is exempt.
sub fm_watch_unmeasured {
    my @ticks = @_;
    return (grep { $ticks[$_] eq 'm' } 0 .. $#ticks - 1) ? 1 : 0;
}
# The watch's exit status: unmeasured, a survivor, or a lost signal (96) comes
# before an over-cap end (98).
sub fm_watch_exit {
    my (%end) = @_;
    return 96 if $end{warned} || $end{unmeasured} || $end{escaped} || $end{lost};
    return 98 if $end{over};
    return 128 + $end{signal} if $end{signal};
    my $status = $end{status} // 0;
    return ($status & 127) ? 128 + ($status & 127) : $status >> 8;
}

my $PROCESS_STATE_PY = <<'PYTHON';
import importlib.util, os, struct, sys
LINUX = os.path.exists("/proc/self/stat")
if not LINUX:
    spec = importlib.util.spec_from_file_location("fmproc", sys.argv[1])
    fp = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fp)
def identity(pid):
    # A zombie has ended: it is reported as gone.
    if LINUX:
        try:
            with open("/proc/%d/stat" % pid) as handle:
                fields = handle.read().rsplit(")", 1)[1].split()
        except FileNotFoundError:
            raise LookupError(pid)
        if fields[0] == "Z":
            raise LookupError(pid)
        return int(fields[19]), 0
    record = fp.kinfo(pid)
    if record[fp.P_STAT] == fp.SZOMB:
        raise LookupError(pid)
    return tuple(fp.process_identity(record))
def present(pid):
    if LINUX:
        try:
            with open("/proc/%d/stat" % pid) as handle:
                return handle.read().rsplit(")", 1)[1].split()[0] != "Z"
        except OSError:
            return False
    for record in fp.kinfos():
        if struct.unpack_from("i", record, fp.P_PID)[0] == pid:
            return record[fp.P_STAT] != fp.SZOMB
    return False
try:
    mode, pid = sys.argv[2], int(sys.argv[3])
    if mode == "identity":
        print("%d %d" % identity(pid))
        sys.exit(0)
    try:
        now = identity(pid)
    except LookupError:
        print("unknown" if present(pid) else "ended")
        sys.exit(0)
    if sys.argv[5] == "-":
        # Known only to the second: a process with that second may be it.
        print("alive" if now[0] == int(sys.argv[4]) else "ended")
    else:
        print("alive" if tuple(now) == (int(sys.argv[4]), int(sys.argv[5])) else "ended")
except SystemExit:
    raise
except Exception:
    print("unknown")
PYTHON

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

# Private mode: perl fm-lint-cache.pl probe <host lock> <wait-file> <bound-seconds> -- <command...>
# The version probe's lane in the host-wide budget. bin/fm-lint.sh keeps a fixed
# share of the budget for it (its PROBE_RESERVE_KIB) and gives the roots' admission
# the rest, so a probe never waits behind roots holding the budget and a run whose
# roots are all skipped reserves nothing in the roots' budget. Every run probes
# its own ShellCheck: no run takes another run's answer.
# One probe runs at a time on the host. The lane is a record, <host lock>.probe.holder,
# naming the probe process by its exact identity (pid and start time), read and
# written only under the flock of <host lock>.probe, which is held for those few
# steps alone. The lane is free only when the record is absent or the process it
# names has provably ended: its pid is no longer in the process table, or that pid
# now holds another start time. A process the record names that still runs, or
# whose identity cannot be read, holds the lane, whether or not the run that started
# it is still alive; a record that is empty, cannot be read or cannot be parsed holds
# it too. Only an absent record is a free lane. So the death of a
# probe's run, or of any descriptor, never frees the lane while its probe runs.
# The probe is this process's direct child: it is forked, waits until its identity
# is recorded, and only then executes the command; if this process dies first the
# child exits without executing anything. This process waits for it on one timer,
# whether or not it holds its output open, and removes the record (under the flock)
# once it has reaped that child. Nothing ends a probe: a probe still running after
# <bound-seconds>, and every run that has waited longer than that for the lane, say
# on stderr once that they are blocked, naming the record, and keep waiting. The
# time spent waiting for the lane is written in milliseconds to <wait-file>. A lane
# whose record cannot be written names its path and exits 2 without running the
# command.
if (($ARGV[0] // '') eq 'probe') {
    require POSIX;
    require Time::HiRes;
    my (undef, $host_lock, $wait_file, $bound, $dashes, @command) = @ARGV;
    die "fm-lint-probe: invalid private invocation\n"
        unless defined $dashes && $dashes eq '--' && @command && length($host_lock // '') && ($bound // '') =~ /\A[1-9][0-9]*\z/;
    my $refuse = sub {
        my ($path, $why) = @_;
        print STDERR "fm-lint: version probe lane unusable at $path ($why); the host-wide ShellCheck memory bound cannot be enforced, "
            . "so the probe was not started. Make that path writable, or remove it if it is damaged.\n";
        exit 2;
    };
    my %signal_number = (HUP => 1, INT => 2, TERM => 15);
    my ($caught, $child);
    for my $name (keys %signal_number) { $SIG{$name} = sub { $caught = $name; }; }
    my $helper = dirname(abs_path($0)) . '/fm-proc-info.py';
    my $python = $ENV{FM_LINT_INTERNAL_PYTHON} || 'python3';
    # The state of a recorded process: "alive" (that pid still has that start time),
    # "ended" (the pid is gone, or holds another start time) or "unknown".
    my $state = sub {
        my ($pid, $sec, $usec) = @_;
        no warnings 'exec';
        open(my $py, '-|', $python, '-I', '-c', $PROCESS_STATE_PY, $helper, 'state', $pid, $sec, $usec) or return 'unknown';
        my $answer = <$py> // '';
        close $py;
        return $answer =~ /\A(alive|ended)\n\z/ ? $1 : 'unknown';
    };
    my $identity = sub {
        my ($pid) = @_;
        no warnings 'exec';
        open(my $py, '-|', $python, '-I', '-c', $PROCESS_STATE_PY, $helper, 'identity', $pid) or return;
        my $answer = <$py> // '';
        close $py;
        return $answer =~ /\A([0-9]+) ([0-9]+)\n\z/ ? ($1, $2) : ();
    };
    my $arrived = Time::HiRes::time();
    my $lane_path = "$host_lock.probe";
    my $holder_path = "$host_lock.probe.holder";
    open(my $lane, '>>', $lane_path) or $refuse->($lane_path, $!);
    my ($reported, $go_write, $record);
    while (1) {
        exit 128 + $signal_number{$caught} if $caught;
        my $why;
        if (flock($lane, LOCK_EX | LOCK_NB)) {
            # Free only when the record is genuinely absent; an empty, damaged or
            # unreadable record holds the lane.
            $record = undef;
            my $absent;
            if (open(my $fh, '<', $holder_path)) {
                local $/;
                $record = <$fh>;
                $why = "its record $holder_path cannot be read ($!)" unless defined $record && close $fh;
                $why //= "its record $holder_path is empty" if defined $record && $record eq '';
            } elsif ($!{ENOENT}) {
                $absent = 1;
            } else {
                $why = "its record $holder_path cannot be read ($!)";
            }
            my $free = !defined $why && $absent;
            if (!defined $why && !$free) {
                if (($record // '') =~ /\A([0-9]+)\t([0-9]+)\t([0-9]+)\t([0-9]+)\t[0-9.]+\n\z/) {
                    my $answer = $state->($2, $3, $4);
                    $free = $answer eq 'ended';
                    $why = $answer eq 'alive' ? "its probe (pid $2, started by pid $1) still runs"
                        : "the identity of its probe (pid $2) cannot be read" unless $free;
                } else {
                    $why = "its record $holder_path cannot be parsed";
                }
            }
            if ($free) {
                pipe(my $go_read, $go_write) or die "fm-lint-probe: pipe: $!\n";
                pipe(my $from_probe, my $to_caller) or die "fm-lint-probe: pipe: $!\n";
                $child = fork();
                die "fm-lint-probe: fork: $!\n" unless defined $child;
                if (!$child) {
                    close $go_write;
                    close $from_probe;
                    my $byte = '';
                    sysread($go_read, $byte, 1);
                    POSIX::_exit(127) unless $byte eq 'g';
                    open(STDOUT, '>&', $to_caller) or POSIX::_exit(127);
                    exec {$command[0]} @command;
                    warn "fm-lint-probe: exec $command[0]: $!\n";
                    POSIX::_exit(127);
                }
                close $go_read;
                close $to_caller;
                my @id = $identity->($child);
                my ($staged, $fh) = ("$holder_path.tmp.$$");
                $record = sprintf "%d\t%d\t%s\t%s\t%.6f\n", $$, $child, @id ? @id : ('', ''), Time::HiRes::time();
                unless (@id && open($fh, '>', $staged) && print({$fh} $record) && close($fh) && rename($staged, $holder_path)) {
                    my $err = @id ? "$!" : "the probe's identity cannot be read";
                    unlink $staged;
                    close $go_write;
                    waitpid($child, 0);
                    $refuse->($holder_path, $err);
                }
                flock($lane, LOCK_UN);
                if (open(my $wf, '>', $wait_file)) { printf {$wf} "%d\n", (Time::HiRes::time() - $arrived) * 1000; close $wf; }
                syswrite($go_write, 'g');
                close $go_write;
                # Read the probe's output and wait for the probe itself on one timer,
                # so the bound is judged whether or not it closed its output early.
                my ($output, $eof, $over, $status) = ('', 0, 0);
                my $ready = '';
                vec($ready, fileno($from_probe), 1) = 1;
                my $started = Time::HiRes::time();
                while (1) {
                    if (!$eof) {
                        my $n = select(my $readable = $ready, undef, undef, 0.1);
                        if ($n > 0) {
                            my $got = sysread($from_probe, $output, 65536, length $output);
                            $eof = 1 if defined $got && $got == 0 || !defined $got && !$!{EINTR};
                        }
                    } else {
                        Time::HiRes::sleep(0.1);
                    }
                    my $reaped = waitpid($child, POSIX::WNOHANG());
                    if ($reaped == $child) {
                        $status = $?;
                        while (!$eof && select(my $readable = $ready, undef, undef, 0) > 0) {
                            my $got = sysread($from_probe, $output, 65536, length $output);
                            $eof = 1 unless defined $got && $got > 0;
                        }
                        last;
                    }
                    if ($reaped == -1 && !$!{EINTR}) { $status = 127 << 8; last; }
                    if (!$over && Time::HiRes::time() - $started > $bound) {
                        printf STDERR "fm-lint: blocked: the version probe (pid %d) has run more than %d s and keeps the lane %s; "
                            . "this run waits for it to end; nothing is ended\n", $child, $bound, $holder_path;
                        $over = 1;
                    }
                }
                close $from_probe;
                # The child is reaped: the record names a process proven ended.
                if (flock($lane, LOCK_EX)) {
                    my $now = '';
                    if (open(my $fh, '<', $holder_path)) { local $/; $now = <$fh> // ''; close $fh; }
                    unlink $holder_path if $now eq $record;
                    flock($lane, LOCK_UN);
                }
                print $output;
                exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
            }
            flock($lane, LOCK_UN);
        } else {
            $!{EWOULDBLOCK} || $!{EAGAIN} || $!{EINTR} or $refuse->($lane_path, $!);
            $why = 'another run is reading or writing its record';
        }
        if (!$reported && Time::HiRes::time() - $arrived > $bound) {
            printf STDERR "fm-lint: blocked: the version probe lane %s has been held for more than %d s (%s); "
                . "this run waits until that probe has provably ended; nothing is ended\n", $holder_path, $bound, $why;
            $reported = 1;
        }
        Time::HiRes::sleep(0.1);
    }
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
# only if those charges plus the request's own charge fit the budget, or nothing
# is held, so a root larger than the budget runs alone. Only governed roots count:
# this pool's held slots and the host ledger's live entries. Memory no ledger
# entry governs (another caller's ShellCheck, a lint from a checkout without the
# ledger) never blocks a turn; that residual belongs to the host memory guard
# (bin/fm-mem-guard.sh), which reads host pressure when a run is admitted. A held
# slot is charged the worst case when its record names no charge. Admission
# needs a readable table: while neither ps nor fm-proc-info.py answers, the
# request whose turn it is retries, and after about 5 s it names the table on
# stderr and exits 2 without starting its command. A request waiting for its turn
# reads the table at most every 0.5 s, before it takes the host lock, and reuses
# that reading until the next read (a failed read is never reused); the ledger and
# the slot charges are read fresh
# on every pass under the host lock, and the decision is taken under that lock.
# When the analysis
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
# produces a success that an analysis would have produced.
if (($ARGV[0] // '') eq 'gate' || ($ARGV[0] // '') eq 'census') {
    require POSIX;
    require Time::HiRes;
    my ($gate_mode, $slot_dir, $ncpu, $run, $wait_file, $dashes, @command) = @ARGV;
    die "fm-lint-gate: invalid private invocation\n"
        unless defined $dashes && $dashes eq '--' && @command && ($ncpu // '') =~ /\A[1-9][0-9]*\z/
            && ($run // '') =~ /\A[A-Za-z0-9_-]{1,64}\z/;
    # The growth guard holds a root only by asking its resident watch, which owns
    # the root's process group, to stop and resume that group: the gate writes
    # <peak file>.hold and removes it to resume. The gate itself sends no signal to
    # any process but its own unreaped child.
    my ($child, $caught, $hold_path, $reaped_status);
    my $resume = sub { unlink $hold_path if defined $hold_path; };
    my %signal_number = (HUP => 1, INT => 2, TERM => 15);
    for my $name (keys %signal_number) {
        $SIG{$name} = sub { $caught = $name; $resume->(); kill 'TERM', $child if $child && !defined $reaped_status; };
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
    # Every lint gate on the host, whatever pool it uses, and the processes below
    # it: the table reduced to { gate pid => [process set, start, running] }.
    # Which of them are governed (named by a ledger entry) is the caller's
    # question. A gate's own table and
    # owner reads (ps, fm-proc-info.py table or memory, also seen as a bare or
    # parenthesized command name, a <defunct> row or, before their exec, the
    # gate's own command) are not in its set, so a gate runs only once its
    # command has started.
    my $host_view = sub {
        my ($table) = @_;
        my %children;
        push @{$children{$table->{$_}[0]}}, $_ for keys %$table;
        my %gates;
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
        }
        return \%gates;
    };
    my ($table, $table_at);
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
    my ($blocked_at, $checked_at, $bypass, $census_from, $host, $queued, $malformed_said);
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
    # The gate pids the ledger governs, read only by name (entry.<gate pid>.<ticket>)
    # for the growth guard: nothing is opened, locked or removed, and no reading
    # refuses. A name whose pid is not a live gate in the table is ignored there.
    # A ledger directory that cannot be listed governs no other gate: the guard
    # then counts its own root alone, and says so once on stderr naming the path.
    my $ledger_unlisted_said;
    my $governed_gates = sub {
        my $listing;
        unless (opendir($listing, $ledger_dir)) {
            print STDERR "fm-lint-gate: the growth guard cannot list the host ledger $ledger_dir ($!); "
                . "it counts only its own root until the ledger can be read again\n" unless $ledger_unlisted_said++;
            return;
        }
        my @pids = map { /\Aentry\.([0-9]+)\.[0-9]+\z/ ? $1 + 0 : () } readdir $listing;
        closedir $listing;
        return @pids;
    };
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
            # A live entry this gate cannot read as an entry names no root, no charge
            # and no record: it is never charged at this request's worst case; it
            # refuses every admission until its holder ends (the admission below).
            else { push @live, [undef, undef, undef, undef, $path]; }
        }
        return @live;
    };
    # A run whose resident watch lost every reader of a root's memory, or whose
    # census failed, marked FM_LINT_INTERNAL_ABORT_FILE: its gates admit no new root,
    # checked while waiting and again under the host lock before admitting.
    my $abort_file = $ENV{FM_LINT_INTERNAL_ABORT_FILE} // '';
    # Stopped: the mark exists, or its directory is not a writable directory, so a
    # mark the run needed could not have been written there (refuse on doubt).
    my $aborted = sub {
        return 0 unless length $abort_file;
        my $dir = dirname($abort_file);
        return -e $abort_file || !(-d $dir && -w _);
    };
    # A refused root never started: its time queued here is recorded as its wait,
    # so fm-lint.sh does not count it as analysis time.
    my $refuse_aborted = sub {
        unlink($ticket_path) if $ticket_path;
        if (open(my $fh, '>', $wait_file)) {
            printf {$fh} "%d\n", $waited_from && $queued ? (Time::HiRes::time() - $waited_from) * 1000 : 0;
            close $fh;
        }
        my $why = '';
        if (open(my $mark, '<', $abort_file)) { $why = <$mark> // ''; close $mark; }
        chomp $why;
        $why = 'its stop mark ' . $abort_file . ' cannot be checked or written: ' . dirname($abort_file) . ' is not a writable directory'
            if !length $why && !-e $abort_file;
        print STDERR "fm-lint: this run admits no new root: " . (length $why ? $why : 'it was marked to stop') . "\n";
        exit 2;
    };
    $waited_from = Time::HiRes::time();
    ACQUIRE: while (!$slot && !$caught) {
        $refuse_aborted->() if $aborted->();
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
                # My turn. The memory budget decides, from the ledger read under the
                # host-wide admission lock and a table at most 0.5 s old (see the
                # header) (FM_LINT_INTERNAL_HOST_LOCK), which an admitted gate keeps until
                # its command has started, so no two pools admit on one reading. A
                # gate that cannot take that lock waits; nothing decides without
                # it. The budget counts the held roots and the new root; a root
                # takes its turn alone only when no root is held. Memory no ledger
                # entry governs never blocks a turn. Without a table nothing is
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
                # continues or dies). The ledger is read after the lock is taken,
                # immediately before the decision, so a root another pool admitted
                # while this gate waited is read at its charge; the table is read
                # again only when its last reading is 0.5 s old or more, before the
                # lock is taken, so a table read that does not answer never holds
                # the host lock and stops every other gate's decision.
                if (!$table || Time::HiRes::time() - $table_at >= 0.5) {
                    $table = $process_table->();
                    $table_at = Time::HiRes::time() if $table;
                }
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
                    if (!$table) {
                        $census_from //= $now;
                        if ($now - $census_from >= 5) {
                            unlink($ticket_path);
                            $refuse_census->();
                        }
                    } else {
                        undef $census_from;
                        # A new root is admitted when its charge and every held root's
                        # charge (never below what that root holds now) fit the budget;
                        # no wait for a watch sample. A
                        # live ledger entry that cannot be read as an entry refuses
                        # admission: its root, charge and record are unknown.
                        my @malformed = map { $_->[4] } grep { defined $_->[4] } @unnamed;
                        if (@malformed && !$malformed_said++) {
                            print STDERR "fm-lint: host ledger entry " . join(', ', @malformed) . " is held by a live process but cannot be read as an entry; "
                                . "no root is admitted on this host until it is freed\n";
                        }
                        $fits = !@malformed && (!@host_charges
                            || $charged->($table, @host_charges) + $charge_kib <= $budget_kib);
                    }
                }
                if ($fits && $aborted->()) { flock($host, LOCK_UN); $refuse_aborted->(); }
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
    # analysis follows that the walk does not see). While the running governed
    # roots (this gate's and every gate the host ledger names, in any pool) hold
    # more than the budget, this gate holds its root unless it belongs to the
    # oldest running governed gate, and releases it as soon as the total fits
    # again or its gate becomes the oldest. Memory no ledger entry governs
    # (another caller's ShellCheck, a lint from a checkout without the ledger) is
    # neither counted nor ever the reason a root is held, and an ungoverned gate is
    # never the oldest; the host memory guard (bin/fm-mem-guard.sh) owns that
    # residual when it admits a run. The hold is <peak file>.hold: the root's resident
    # watch, which owns the root's process group, stops that group while the file
    # exists and resumes it when the file is gone. Only the group is signalled,
    # by the process that created it and has not reaped its leader; no process of
    # the root is signalled by its pid. A root without a resident watch (outside macOS, or
    # under the enforced envelope) is not held. A stopped root keeps what it holds
    # but cannot grow further, and the oldest running governed gate is never held,
    # so every root finishes. No polling guard can remove what roots grow inside one
    # reading interval (up to 2 s at or below 60 percent of the budget, 0.5 s above
    # it).
    $hold_path = length($peak_file // '') ? "$peak_file.hold" : undef;
    my ($guard_busy, $poll) = (0, 0.5);
    my $guard = sub {
        return if $caught || $guard_busy || defined $reaped_status;
        # A table read slower than the guard's interval leaves the next tick
        # pending, so ticks follow each other and the main flow's waitpid and exit
        # wait behind them. As the watch's tick does, the guard first reaps an
        # ended command, and it reads no table once its command has ended.
        my $gone = waitpid($child, POSIX::WNOHANG());
        $reaped_status = $? if $gone == $child;
        return if $gone != 0;
        $guard_busy = 1;
        my $table = $process_table->();
        my $view = $table && $host_view->($table);
        my $mine = $view && $view->{$$};
        # The running governed gates: this one and every running gate the ledger
        # names; their trees are the total the budget is judged on.
        my %governed = map { $_ => 1 } $$, ($mine ? $governed_gates->() : ());
        my @running = grep { $governed{$_} && $view->{$_}[2] } keys %{$view // {}};
        my (%member, $total);
        $member{$_} = 1 for map { keys %{$view->{$_}[0]} } @running;
        $total += $table->{$_}[1] for keys %member;
        $total //= 0;
        my $next = $mine && $total * 5 > $budget_kib * 3 ? 0.5 : 2;
        Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), $next, $next) if $next != $poll;
        $poll = $next;
        if (!$mine) { $guard_busy = 0; return; }
        my ($oldest) = sort { $view->{$a}[1] <=> $view->{$b}[1] || $a <=> $b } @running;
        my $over = $total > $budget_kib;
        if ($over && (!defined $oldest || $oldest != $$)) {
            if (defined $hold_path && !-e $hold_path && open(my $hold, '>', $hold_path)) { close $hold; }
        } else {
            $resume->();
        }
        $guard_busy = 0;
    };
    $SIG{ALRM} = sub { local ($?, $!); $guard->() };
    Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), $poll, $poll);
    my $reaped;
    while (!defined $reaped_status && ($reaped = waitpid($child, 0)) == -1 && $!{EINTR}) { }
    my $status = defined $reaped_status ? $reaped_status : $reaped == $child ? $? : 127 << 8;
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
# has no other memory bound on a root. It runs the command in a process group of
# its own and samples once a second that command's process tree: the command, its
# descendants in any group or session, and each process the reader has seen in the
# tree that was later orphaned, so a memory-holding grandchild cannot leave the
# count by outliving its parent. Each sample is the larger of the tree's resident
# size and its physical footprint, read by a long-lived libproc reader
# (fm-proc-info.py rss-tree) started at the first tick, under the interpreter
# fm-lint.sh resolved once (FM_LINT_INTERNAL_PYTHON, else python3). A reader's first
# reply may take 2 s; each later reply has 0.5 s. A reply that is late, or that
# cannot be bound to the processes it measured, is read once more in the same tick:
# a late reply is given 1 s more, an unbound one a new request with 1 s; no tick
# has more than that one retry, and no older sample is reused. Each wait has a
# deadline: a signal that interrupts it (EINTR) waits again for the time left and
# does not spend the retry.
# The reader is the only source of a sample. A tick whose reply (after that retry)
# is late, malformed or cannot be bound to the processes it measured is a miss, never a
# zero and never a guess from another table: the reply is discarded and a new
# reader starts for the next tick. A replacement that cannot start, or fails before
# it replies, is one failed restart; the reader is given up for the rest of the
# command (every later tick a miss) when libproc cannot read the command, the
# command's first reader exits before its first reply, or three restarts in a row
# fail; a good reply resets that count. The reason is appended to <rss-file> once
# as rss_reader_unavailable=<reason>.
# Binding a reply: the reader lists the tree in one census and then reads each
# member's memory by pid, so right after those reads, in the same process (no tick
# starts a process), it reads every member again by pid and marks the reply bound
# or not. A member whose pid is in neither the kernel's process table nor libproc
# has ended and is dropped (it holds no memory). A member whose identity differs
# from the census's or that cannot be read, a reply that is not bound or names no
# root, and one whose root is a zombie or exiting (its memory is no longer read)
# are misses. Each request names every member the watch knows by exact identity;
# the reader keeps each one that still runs, with its descendants, and counts it,
# and one whose pid the census lists with another identity is a miss.
# Crossing the limit ends the root's group with KILL, records the peak sampled as
# max_rss_kib=<KiB> in <rss-file>, names the bound on stderr, and exits 98, which
# fm-lint.sh reports as a memory failure so the root takes its narrower retry.
# Every end appends rss_samples=libproc:<n> and watch_peak_kib=<KiB>, then, as
# measurement only, one rss_miss=<late|unbound|malformed|unavailable>,wait_ms=<n>,
# interrupted=<n> per missed tick (its branch, reply wait and interrupted waits),
# rss_ticks=<n>, rss_longest_tick_ms=<n> and rss_longest_reply_ms=<n>; fm-lint.sh
# prints each rss_miss record and the run's longest reply and tick on stderr. Each new
# peak is written to FM_LINT_INTERNAL_SLOT_PEAK_FILE when the gate names one, so
# the gate's admission charges it.
# Any miss while the root runs that is followed by a later tick makes the root exit
# 96 (fm_watch_unmeasured); only a miss on its very last tick is exempt. Each tick
# first reaps an exited root (keeping its exit status), so slow ticks that follow
# each other cannot hold an exited root unreaped and sample its exit as misses. Three misses
# in a row also write FM_LINT_INTERNAL_ABORT_FILE so the run's gates admit no
# further root. 96 comes before 98, so no unmeasured root is retried or recorded as
# a success.
# When that unmeasured interval is the root's only failure, the end also writes
# rss_rerun_alone=1 (never for three misses in a row, a reader given up, a
# reading over the cap, an owner's signal, a survivor or a lost signal); the watch still exits 96,
# and fm-lint.sh decides whether the root runs once more alone.
# Signalling follows rule O (fm_signal_root): the watch records its root's exact
# start time before the root executes anything (the root waits on a pipe until the
# record exists; a root whose start time cannot be read never executes and the
# watch exits 96 with rss_launch_unrecorded=1), and every signal goes only to that
# root's group after the leader is proven unchanged. TERM or KILL end the root's
# group; STOP and CONT hold it while the gate's growth guard asks (<peak file>.hold).
# Every result is acted on: a STOP that is not sent leaves the root unheld (tried
# again next tick); a CONT that is not sent keeps the root held and is tried once
# more, then the root's group is ended and the root fails (96, rss_cont_failed=1);
# a TERM that is not sent brings the KILL forward; a KILL that is neither sent nor
# finds the group gone fails the root (96, rss_kill_failed=1). No process of the
# root is ever signalled by its pid (the watch's own reader is the one exception,
# ended by KILL when it has not exited 2 s after its input closed). After every end, a normal success included, each process
# the watch counted that still runs (or cannot be proven ended) is a survivor: the
# root fails (96), the run admits no further root, and <rss-file> records
# rss_escaped=<pids>; survivors are never signalled.
# A signal to the watch, or the loss of its parent, ends the root's group within
# about one tick (about 6 s if the command ignores TERM); the watch sits in a group
# of its own, out of reach of its owner's group sweep.
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
    my ($to_reader, $from_reader, $reader_pid, $reader_fresh, $reader_down);
    my ($reader_failures, $libproc_samples) = (0, 0);
    # Measurement only: this tick's miss branch, reply wait (s) and interrupted
    # waits; the misses' records; ticks, longest tick (s), longest reply latency (s).
    my ($miss_branch, $tick_wait, $tick_interrupts, @miss_records) = ('', 0, 0);
    my ($tick_count, $longest_tick, $longest_reply) = (0, 0, 0);
    my %known;    # pid => [start seconds, start microseconds], every member counted
    my ($child_reaped, $reaped_status);
    # A reader exits when its input closes; only a reader still running 2 s later,
    # the watch's own unreaped child, is ended by a signal (as on the base).
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
        $reader_fresh = $first && $reader_pid ? 1 : 0;
        return if $reader_pid;
        $reader_down = $first ? 'exited-at-start' : ++$reader_failures > 3 ? 'restarts-failed' : undef;
    };
    # KiB of the root's tree as the reader measured it (the larger of footprint and
    # resident size), with each member the watch knows by exact identity, or undef
    # (a miss) when the reader cannot give a bound reply. Each request names those
    # identities ("bind <pid>:<sec>:<usec> ..."), and the reader binds its reply in
    # the same process (fm-proc-info.py bind_members), so a tick starts no process.
    # Every reply, a new reader's first and each later one, has 6 s; a late or
    # unconfirmed reply is read once more in the same tick (the retry), which waits
    # at most 1 s: a late reply gets 1 s more, an unconfirmed one a new request with
    # 1 s; a retry that also misses is the tick's miss. So a reply is late (an
    # rss_miss=late record, wait_ms about 7000) only after 7 s (Main 3923: about
    # twice the worst late reply measured on a loaded host, 3347 ms).
    my $tree_rss;
    $tree_rss = sub {
        my ($root_pid, $retry) = @_;
        $start_reader->($root_pid) unless $reader_pid || $reader_down;
        $miss_branch = 'unavailable';
        return undef unless $reader_pid;
        local $SIG{PIPE} = 'IGNORE';
        my ($answer, $ready) = ('', '');
        vec($ready, fileno($from_reader), 1) = 1;
        my $gone = !syswrite($to_reader, join(' ', 'bind', map { "$_:$known{$_}[0]:$known{$_}[1]" } sort { $a <=> $b } keys %known) . "\n");
        my $asked = Time::HiRes::time();
        my $wait = $retry ? 1 : 6;
        while (1) {
            # Each wait has a deadline: a signal that interrupts it (EINTR) waits
            # again for the time left and does not spend the retry.
            my $began = Time::HiRes::time();
            my $deadline = $began + $wait;
            while (!$gone && $answer !~ /\n/) {
                my $left = $deadline - Time::HiRes::time();
                last if $left <= 0;
                my $ready_count = select(my $readable = $ready, undef, undef, $left);
                if ($ready_count < 0 && $!{EINTR}) { $tick_interrupts++; next; }
                last if $ready_count <= 0;
                $gone = !sysread($from_reader, $answer, 64, length $answer);
            }
            $tick_wait += Time::HiRes::time() - $began;
            last if $gone || $answer =~ /\n/ || $retry++;
            $wait = 1;
        }
        if ($answer =~ /\n/) {
            my $latency = Time::HiRes::time() - $asked;
            $longest_reply = $latency if $latency > $longest_reply;
        }
        if ($answer =~ /\A\{"rss_kib":([0-9]+),[^\n]*\}\n\z/) {
            my $kib = $1 + 0;
            ($reader_failures, $reader_fresh) = (0, 0);
            my $named = eval { require JSON::PP; JSON::PP::decode_json($answer)->{members} };
            my %reply;
            %reply = map { ($_->[0] + 0 => [$_->[1] + 0, $_->[2] + 0]) } @$named
                if ref $named eq 'ARRAY' && @$named
                    && !grep { ref $_ ne 'ARRAY' || @$_ < 3 || grep { !defined $_ || !/\A[0-9]+\z/ } @$_[0, 1, 2] } @$named;
            # The reader bound the reply ("bound":true): it read every member again
            # after its census and memory reads, dropped each that had ended, and
            # kept each identity this request named that still runs, with its
            # descendants (so a restarted reader keeps a member that left the tree).
            # Any other reply is a miss.
            $miss_branch = 'unbound';
            return $retry ? undef : $tree_rss->($root_pid, 1)
                unless $reply{$root_pid} && $answer =~ /,"bound":true\}\n\z/;
            %known = %reply;
            $libproc_samples++;
            return $kib;
        }
        $miss_branch = !$gone && $answer !~ /\n/ ? 'late' : 'malformed';
        my $fresh = $reader_fresh;
        $stop_reader->();
        $reader_down = $answer eq "-\n" || $answer =~ /\A\{"rss_kib":null,/ ? 'libproc-unreadable'
            : $gone && $fresh ? 'exited-at-start'
            : ++$reader_failures > 3 ? 'restarts-failed' : undef;
        $start_reader->($root_pid) unless $reader_down;
        return undef;
    };
    my ($child, $launch, $caught, $term_at, $over, $warned, $mark_failed, $unmeasured, @ticks, $held,
        $escaped, $cont_failures, $cont_failed, $kill_failed, $hold_said);
    my $lock_path = $ENV{FM_LINT_INTERNAL_HOST_LOCK} // '';
    # A hold on the host admission lock; undef when there is none or it cannot be
    # taken.
    my $take_host = sub {
        my $lock;
        return length $lock_path && open($lock, '>>', $lock_path) && flock($lock, LOCK_EX) ? $lock : undef;
    };
    # The run's stop mark (FM_LINT_INTERNAL_ABORT_FILE) is written under the host
    # lock, so no gate admits between this mark and its own check; a mark that
    # cannot be written is said, and the root still fails (the worker then marks
    # the run itself).
    my $mark_run = sub {
        my ($text) = @_;
        my $abort = $ENV{FM_LINT_INTERNAL_ABORT_FILE} // '';
        return unless length $abort;
        my $lock = $take_host->();
        my ($mark, $published);
        if ($lock || !length $lock_path) {
            $published = open($mark, '>>', $abort) && print({$mark} "$text\n") && close($mark);
        }
        my $why = $!;
        close $lock if $lock;
        return if $published;
        warn "fm-lint: resident-memory watch could not mark the run at $abort ($why); the root fails and the worker stops the run\n";
        $mark_failed = 1;
    };
    # End the root's group (rule O). A KILL that is neither sent nor finds the group
    # gone fails the root.
    my $end_tree = sub {
        return if !$launch || $child_reaped;
        my $result = fm_signal_root('KILL', $launch);
        return if $result eq 'sent' || $result eq 'gone';
        warn "fm-lint: resident-memory watch could not end its root's group ($result); the root fails\n" unless $kill_failed++;
    };
    my ($peak, $misses) = (0, 0);
    my %signal_number = (HUP => 1, INT => 2, TERM => 15);
    # TERM to the root's group; one that is not sent brings the KILL forward.
    my $term_root = sub {
        return if !$launch || $child_reaped;
        my $result = fm_signal_root('TERM', $launch);
        $term_at = Time::HiRes::time() - 5 unless $result eq 'sent' || $result eq 'gone';
    };
    for my $name (keys %signal_number) {
        $SIG{$name} = sub {
            $caught = $name;
            $term_at //= Time::HiRes::time();
            $term_root->();
        };
    }
    # Perl restarts waitpid after a handled signal, so the sampling runs in the
    # timer's handler while the main flow blocks in waitpid.
    my $busy;
    my $sample = sub {
        if (!$caught && getppid() != $owner) {
            $caught = 'TERM';
            $term_at = Time::HiRes::time();
            $term_root->();
        }
        $end_tree->() if $caught && Time::HiRes::time() - $term_at >= 5;
        return if $caught || $over || $cont_failed;
        # The gate's growth guard holds the root through <peak file>.hold: stop the
        # root's group while it exists, resume it when it is gone. Held only on a
        # sent STOP; a CONT that is not sent keeps it held and is tried once more,
        # then the root is ended and fails.
        if (length $peak_file && !$child_reaped) {
            my $want = -e "$peak_file.hold";
            if ($want && !$held) {
                my $result = fm_signal_root('STOP', $launch);
                if ($result eq 'sent') { $held = 1; }
                elsif (!$hold_said++) { warn "fm-lint: resident-memory watch could not hold its root's group ($result); it tries again next tick\n"; }
            } elsif (!$want && $held) {
                my $result = fm_signal_root('CONT', $launch);
                if ($result eq 'sent') {
                    ($held, $cont_failures) = (0, 0);
                } elsif (++$cont_failures >= 2) {
                    $cont_failed = 1;
                    warn "fm-lint: resident-memory watch could not resume its held root's group twice ($result); it ends the root, which fails (status 96)\n";
                    $end_tree->();
                    $mark_run->("the resident-memory watch could not resume a held root");
                    return;
                }
            }
        }
        # Reap an exited root here: the main flow's waitpid cannot run while ticks
        # follow each other, and the exit would otherwise be sampled as misses.
        if (!$child_reaped) {
            my $gone = waitpid($child, POSIX::WNOHANG());
            if ($gone == $child) { ($child_reaped, $reaped_status) = (1, $?); return; }
            return if $gone == -1 && $!{ECHILD};
        }
        ($miss_branch, $tick_wait, $tick_interrupts) = ('', 0, 0);
        my $rss = $tree_rss->($child);
        if (!defined $rss) {
            return if $child_reaped;
            push @miss_records, sprintf("rss_miss=%s,wait_ms=%d,interrupted=%d\n",
                $miss_branch, $tick_wait * 1000, $tick_interrupts);
            # A miss in the root's last tick can be its own exit (a zombie no reader
            # measures); a miss followed by any later tick is an unmeasured interval
            # (fm_watch_unmeasured, judged once the root is reaped).
            push @ticks, 'm';
            return if ++$misses < 3 || $warned;
            $mark_run->("the resident-memory watch lost every reader of a running root's memory");
            warn "fm-lint: resident-memory watch cannot sample this root (no reader answers); the root fails (status 96), and the run admits no further root\n";
            $warned = 1;
            return;
        }
        $misses = 0;
        push @ticks, 's';
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
        return if $busy || !$launch;
        $busy = 1;
        my $began = Time::HiRes::time();
        $sample->();
        my $took = Time::HiRes::time() - $began;
        $tick_count++;
        $longest_tick = $took if $took > $longest_tick;
        $busy = 0;
    };
    # Launch: the root waits on a pipe until its exact start time is recorded.
    pipe(my $go_read, my $go_write) or die "fm-lint-rsswatch: pipe: $!\n";
    $child = fork();
    die "fm-lint-rsswatch: fork: $!\n" unless defined $child;
    if (!$child) {
        close $go_write;
        POSIX::setpgid(0, 0);
        my $go = '';
        1 while !defined sysread($go_read, $go, 1) && $!{EINTR};
        POSIX::_exit(127) unless $go eq 'g';
        exec {$command[0]} @command;
        warn "fm-lint-rsswatch: exec $command[0]: $!\n";
        POSIX::_exit(127);
    }
    close $go_read;
    POSIX::setpgid($child, $child);
    my $identity = '';
    if (-r $helper) {
        no warnings 'exec';
        if (open(my $py, '-|', $python, '-I', '-c', $PROCESS_STATE_PY, $helper, 'identity', $child)) {
            $identity = <$py> // '';
            close $py;
        }
    }
    unless ($identity =~ /\A([0-9]+) ([0-9]+)\n\z/) {
        close $go_write;
        waitpid($child, 0);
        warn "fm-lint: resident-memory watch could not record its root's start time, so the root was not started (status 96)\n";
        if (open(my $fh, '>>', $rss_file)) { print {$fh} "rss_launch_unrecorded=1\nrss_unmeasured=1\n"; close $fh; }
        exit 96;
    }
    $launch = { pgid => $child, sec => $1 + 0, usec => $2 + 0, helper => $helper };
    syswrite($go_write, 'g');
    close $go_write;
    $term_root->() if $caught;
    Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), 1, 1);
    my $reaped = $child_reaped ? $child : waitpid($child, 0);
    $reaped = $child if $child_reaped;
    $child_reaped = 1 if $reaped == $child;
    $unmeasured = fm_watch_unmeasured(@ticks);
    my $status = $reaped == $child ? ($reaped_status // $?) : 127 << 8;
    Time::HiRes::setitimer(Time::HiRes::ITIMER_REAL(), 0, 0);
    $stop_reader->();
    # After every end, a normal success included: each process the watch counted
    # that still runs (or cannot be proven ended) is a survivor. Survivors are never
    # signalled; the root fails (96) and the run admits no further root. Processes
    # of the root's group ended with it get up to about 1 s to be proven ended.
    my @escaped;
    for my $pid (sort { $a <=> $b } grep { $_ != $$ && $_ != $child } keys %known) {
        my ($sec, $usec) = @{$known{$pid}};
        no warnings 'exec';
        my $answer = '';
        for (1 .. 10) {
            if (open(my $py, '-|', $python, '-I', '-c', $PROCESS_STATE_PY, $helper, 'state', $pid, $sec, $usec)) {
                $answer = <$py> // '';
                close $py;
            }
            last if $answer eq "ended\n";
            Time::HiRes::sleep(0.1);
        }
        push @escaped, $pid unless $answer eq "ended\n";
    }
    if (@escaped) {
        $escaped = 1;
        warn "fm-lint: resident-memory watch: counted process(es) " . join(',', @escaped)
            . " still run (or cannot be proven ended) after the root ended; they are never signalled, so the root fails and the run admits no further root\n";
        $mark_run->("a root's counted process outlived it");
    }
    if (open(my $fh, '>>', $rss_file)) {
        printf {$fh} "rss_samples=libproc:%d\n", $libproc_samples;
        print {$fh} "rss_reader_unavailable=$reader_down\n" if $reader_down;
        printf {$fh} "watch_peak_kib=%d\n", $peak if $peak;
        print {$fh} 'rss_escaped=' . join(',', @escaped) . "\n" if @escaped;
        print {$fh} "rss_cont_failed=1\n" if $cont_failed;
        print {$fh} "rss_kill_failed=1\n" if $kill_failed;
        print {$fh} "rss_unmeasured=1\n" if $warned || $unmeasured;
        # A root whose only failure is an unmeasured interval (a missed tick that a
        # later tick follows), with its readers still up, never seen over its cap
        # (a reading over the cap is a real measurement, Main 4351), never signalled
        # by its owner and with every counted process proven ended, may be run once
        # more alone (fm-lint.sh). Every other failure of the root leaves this line
        # out and stays final.
        print {$fh} "rss_rerun_alone=1\n" if $unmeasured && !$warned && !@escaped && !$cont_failed
            && !$kill_failed && !$over && !$caught && !$reader_down && !$mark_failed;
        print {$fh} "rss_mark_failed=1\n" if $mark_failed;
        print {$fh} @miss_records;
        printf {$fh} "rss_ticks=%d\nrss_longest_tick_ms=%d\nrss_longest_reply_ms=%d\n",
            $tick_count, $longest_tick * 1000, $longest_reply * 1000;
        close $fh;
    }
    exit fm_watch_exit(warned => $warned, unmeasured => $unmeasured, escaped => $escaped,
        lost => ($cont_failed || $kill_failed) ? 1 : 0,
        over => $over, signal => $caught ? $signal_number{$caught} : 0, status => $status);
}

my ($mode, $root, @args) = @ARGV;
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
# A per-invocation sidecar records that the root was analysed, for the roots log.
sub duration_outcome {
    my ($outcome) = @_;
    return unless defined $ENV{FM_LINT_CACHE_RESULT_FILE};
    if (open(my $fh, '>', $ENV{FM_LINT_CACHE_RESULT_FILE})) {
        print {$fh} "$outcome\n";
        close $fh;
    } else {
        warn "fm-lint: cannot record the analysis outcome: $!\n";
    }
}
duration_outcome('analyzed');
@execute = ($tool, @args) unless @execute;
# The input the analysis reads, for the gate's memory record: the root file plus
# every file its source closure follows.
{
    my (%seen, $bytes);
    closure($path, \%seen);
    $bytes += (-s $_ || 0) for keys %seen;
    $ENV{FM_LINT_INTERNAL_ROOT_BYTES} = $bytes;
}
# Forward cancellation to the analysis runner.
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
exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
