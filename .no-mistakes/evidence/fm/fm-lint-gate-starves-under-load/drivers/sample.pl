#!/usr/bin/env perl
# sample.pl <marker> <out> <stopfile>: every 100 ms, count live ShellCheck
# processes whose argv names <marker>; log time, count, 1-min load.
use strict; use warnings; use Time::HiRes qw(time sleep);
my ($marker, $out, $stop) = @ARGV;
open(my $log, '>', $out) or die $!; select((select($log), $|=1)[0]);
my $t0 = time; my $max = 0;
until (-e $stop) {
    my $n = 0;
    for (`ps -axww -o command=`) { $n++ if m{\A\S*/shellcheck\s} && index($_, $marker) >= 0; }
    my ($load) = `sysctl -n vm.loadavg` =~ /([0-9.]+)/;
    $max = $n if $n > $max;
    printf {$log} "%.2f\t%d\t%s\n", time - $t0, $n, $load;
    sleep 0.1;
}
printf {$log} "MAX\t%d\n", $max;
