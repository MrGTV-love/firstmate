#!/usr/bin/env perl
# Best-effort shared-lock timing implementation for fm-wake-lib.sh.
# start OWNER LOCK STATE publishes a monotonic acquisition observation and a
# diagnostic receipt. release OWNER STATE COMMAND appends
# one JSONL observation with O_APPEND and a nonblocking flock. Busy or failed
# recording never waits for another writer or fails the releasing caller.
# Perl and these core modules are already part of Firstmate's runtime.
use strict;
use warnings;
use Encode qw(decode FB_CROAK);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_APPEND O_NONBLOCK LOCK_EX LOCK_NB);
use Time::HiRes qw(time clock_gettime CLOCK_MONOTONIC);
my $mode = shift @ARGV // '';
sub read_text {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}
sub write_text {
    my ($path, $text) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die "$path: $!";
    print {$fh} $text or die "$path: $!";
    close $fh or die "$path: $!";
}
my $ok = eval {
    @ARGV = map { decode('UTF-8', $_, FB_CROAK) } @ARGV;
    if ($mode eq 'start') {
        my ($owner, $lock, $state) = @ARGV;
        require Cwd;
        require File::Basename;
        my $directory = Cwd::abs_path(File::Basename::dirname($lock))
            // die "lock parent directory missing";
        $lock = $directory . '/' . File::Basename::basename($lock);
        # Only numeric clocks belong in this private start record. Lock and
        # owner are already in the diagnostic receipt; PID/command are read at
        # release so handoff reports the final holder. No JSON module is needed
        # while acquiring.
        write_text("$owner/hold-start", sprintf("%.6f %.0f\n",
            clock_gettime(CLOCK_MONOTONIC) * 1000, int(time * 1000)));
        my $monitor = "$state/.lock-monitor";
        mkdir $monitor unless -d $monitor;
        # These are diagnostic IDs, not lock ownership tokens. Exclusive
        # creation prevents overwrite; a serial handles helper-PID reuse while
        # an older observation remains. Avoid File::Temp's initialization on
        # every acquisition in the hot lock path.
        my ($fh, $receipt);
        my $serial = 0;
        while (1) {
            $receipt = "$monitor/hold.$$." . $serial++;
            last if sysopen($fh, $receipt, O_WRONLY | O_CREAT | O_EXCL, 0600);
            die "$receipt: $!" unless $!{EEXIST};
        }
        binmode $fh, ':encoding(UTF-8)';
        my $published = eval {
            print {$fh} "$lock\n$owner\n" or die $!;
            close $fh or die $!;
            write_text("$owner/monitor-record", "$receipt\n");
            1;
        };
        if (!$published) { unlink $receipt; die "receipt publication failed"; }
    } elsif ($mode eq 'release') {
        my ($owner, $state, $command) = @ARGV;
        my $now = clock_gettime(CLOCK_MONOTONIC) * 1000;
        my $released_at_ms = int(time * 1000);
        my ($started_ms, $acquired_at_ms) = read_text("$owner/hold-start")
            =~ /\A([0-9]+(?:\.[0-9]+)?) ([0-9]+)\n\z/;
        die "invalid start clocks" unless defined $acquired_at_ms;
        my $receipt = read_text("$owner/monitor-record");
        chomp $receipt;
        my ($lock, $recorded_owner) = split(/\n/, read_text($receipt), 3);
        die "receipt owner changed" unless defined $recorded_owner && $recorded_owner eq $owner;
        my $duration = $now - $started_ms;
        my $data = {lock => $lock, pid => 0 + read_text("$owner/pid"), command => $command,
            acquired_at_ms => 0 + $acquired_at_ms, released_at_ms => $released_at_ms,
            duration_ms => 0 + sprintf('%.3f', $duration > 0 ? $duration : 0)};
        # A receipt alone cannot establish that its waiter is still live.
        # Preserve unknown rather than turn a stale receipt into a live count.
        $data->{waiters} = 0;
        if (opendir my $directory, "$state/.lock-monitor") {
            for my $name (readdir $directory) {
                next unless $name =~ /^wait\./;
                my $text = eval { read_text("$state/.lock-monitor/$name") };
                my @fields = defined $text ? split(/\n/, $text) : ();
                if (@fields < 2 || $fields[1] eq $data->{lock}) {
                    $data->{waiters} = undef;
                    last;
                }
            }
            closedir $directory;
        } else { $data->{waiters} = undef; }
        require JSON::PP;
        my $json = JSON::PP->new->utf8->canonical;
        sysopen my $ledger, "$state/.lock-holds.jsonl",
            O_WRONLY | O_CREAT | O_APPEND | O_NONBLOCK, 0600 or die $!;
        flock($ledger, LOCK_EX | LOCK_NB) or die $!;
        my $row = $json->encode($data) . "\n";
        syswrite($ledger, $row) == length($row) or die $!;
        close $ledger;
    } else { die "unknown mode"; }
    1;
};
# The shell warns about unavailable start receipts, but never refuses an
# acquired lock. Release telemetry is silent and cannot change its result.
exit($ok || $mode eq 'release' ? 0 : 1);
