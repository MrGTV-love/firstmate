#!/usr/bin/env perl
# sampler.pl <slot-dir> <out-tsv> <stop-file>: polls host slot occupancy every 50 ms.
use strict; use warnings;
use Fcntl qw(:flock);
use Time::HiRes qw(time sleep);
my ($dir, $out, $stop) = @ARGV;
open(my $log, '>', $out) or die "$!";
select((select($log), $| = 1)[0]);
my %cur; my $peak = 0; my $t0 = time();
print {$log} "#t\tevent\tslot\trun\tticket\toccupied\n";
until (-e $stop) {
    my %now;
    for my $path (glob "\Q$dir\E/slot.*") {
        open(my $fh, '>>', $path) or next;
        if (flock($fh, LOCK_EX | LOCK_NB)) { flock($fh, LOCK_UN); close $fh; next; }
        close $fh;
        open(my $r, '<', $path) or next;
        my $line = <$r> // ''; chomp $line;
        my ($slot) = $path =~ /slot\.(\d+)\z/;
        $now{$slot} = $line;
    }
    my $occ = keys %now;
    $peak = $occ if $occ > $peak;
    for my $s (sort { $a <=> $b } keys %now) {
        next if exists $cur{$s} && $cur{$s} eq $now{$s};
        my ($run, $tk) = split /\t/, $now{$s};
        printf {$log} "%.3f\tadmit\t%s\t%s\t%s\t%d\n", time() - $t0, $s, $run // '-', $tk // '-', $occ;
    }
    for my $s (keys %cur) { printf {$log} "%.3f\trelease\t%s\t-\t-\t%d\n", time() - $t0, $s, $occ unless exists $now{$s}; }
    %cur = %now;
    sleep 0.05;
}
print {$log} "#peak\t$peak\n";
