#!/usr/bin/env perl
# psampler.pl <slot-dir> <out-tsv> <stop-file>: every 0.5 s, count gate processes
# for this slot dir and how many are admitted (have a running child command).
use strict; use warnings;
use Time::HiRes qw(time sleep);
my ($dir, $out, $stop) = @ARGV;
open(my $log, '>', $out) or die "$!";
select((select($log), $| = 1)[0]);
my $t0 = time(); my ($peak, $peakwait) = (0, 0);
print {$log} "#t\tgates\tadmitted\tadmitted_by_run\n";
until (-e $stop) {
    my (%cmd, %kids);
    open(my $ps, '-|', 'ps', '-ww', '-A', '-o', 'pid=,ppid=,command=') or die;
    while (<$ps>) { chomp; my ($pid, $ppid, $c) = /\A\s*(\d+)\s+(\d+)\s+(.*)\z/ or next; $cmd{$pid} = $c; push @{$kids{$ppid}}, $pid; }
    close $ps;
    my ($g, $a, %byrun) = (0, 0);
    for my $pid (keys %cmd) {
        next unless $cmd{$pid} =~ /\A\S*perl\S* \S*fm-lint-cache\.pl gate \Q$dir\E (\d+) (\S+)/;
        my $run = $2; $run = 'base' if $run =~ m{/};
        $g++;
        if ($kids{$pid}) { $a++; $byrun{$run}++; }
    }
    $peak = $a if $a > $peak; my $w = $g - $a; $peakwait = $w if $w > $peakwait;
    printf {$log} "%.1f\t%d\t%d\t%s\n", time() - $t0, $g, $a, join(',', map { "$_=$byrun{$_}" } sort keys %byrun);
    sleep 0.5;
}
print {$log} "#peak_admitted\t$peak\tpeak_waiting\t$peakwait\n";
