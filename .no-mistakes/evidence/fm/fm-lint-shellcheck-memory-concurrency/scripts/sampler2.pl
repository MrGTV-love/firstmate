#!/usr/bin/perl
# sampler2.pl <out> <stopfile> <tag>: every 0.2 s, sum RSS KiB of processes named shellcheck whose command
# contains <tag> (this run's roots), and separately all other processes named shellcheck on the host.
use strict; use warnings; use Time::HiRes qw(time sleep);
my ($out,$stop,$tag)=@ARGV; open(my $o,'>',$out) or die; select((select($o),$|=1)[0]);
print {$o} "# t_epoch mine_count mine_rss_kib other_shellcheck_count other_shellcheck_rss_kib\n";
while (!-e $stop) { my ($n,$k,$rn,$rk)=(0,0,0,0);
  for (`/bin/ps -axww -o pid=,rss=,command=`) { next unless /^\s*(\d+)\s+(\d+)\s+(.*)$/; my ($p,$r,$c)=($1,$2,$3);
    my ($n0)=split ' ',$c; $n0 =~ s{.*/}{}; next unless $n0 eq 'shellcheck'; next if $c =~ /--version/;
    if (index($c,$tag)>=0) { $n++; $k+=$r } else { $rn++; $rk+=$r } }
  printf {$o} "%.2f %d %d %d %d\n", time(), $n,$k,$rn,$rk; sleep 0.2; }
