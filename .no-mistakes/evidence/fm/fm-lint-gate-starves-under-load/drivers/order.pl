#!/usr/bin/env perl
# order.pl <marker> <out> <stopfile>: log each newly started ShellCheck (pid,
# fixture root) in start order, plus the peak number running at once.
use strict; use warnings; use Time::HiRes qw(time sleep);
my ($marker, $out, $stop) = @ARGV;
open(my $log, '>', $out) or die $!; select((select($log), $|=1)[0]);
my (%seen, $max); my $t0 = time; $max = 0;
until (-e $stop) {
    my $n = 0;
    for (`ps -axww -o pid=,command=`) {
        next unless m{\A\s*([0-9]+)\s+\S*/shellcheck\s.*\Q$marker\E(\S+)};
        $n++;
        printf {$log} "%.2f\tstart\t%s\n", time - $t0, $2 unless $seen{$1}++;
    }
    $max = $n if $n > $max;
    sleep 0.05;
}
print {$log} "MAX\t$max\n";
