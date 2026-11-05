#!/usr/bin/env perl
use strict; use warnings; use Time::HiRes qw(time);
BEGIN { if (($ARGV[0] // '') eq '--version') { print "ShellCheck - shell script analysis tool\nversion: 0.11.0\n"; exit 0; }
  select(undef,undef,undef,$ENV{SIM_DELAY} // 0); }
my $mib = $ENV{SIM_MIB} // 200;
my $block = 'x' x ($mib * 1048576);
my $t0 = time();
select(undef,undef,undef,$ENV{SIM_HOLD} // 3);
open(my $l,'>>',$ENV{SIM_LOG}) or die; printf {$l} "%d %.3f %.3f %s\n", $$, $t0, time(), $ARGV[-1]; close $l;
exit(length($block) ? 0 : 1);
