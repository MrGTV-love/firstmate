#!/usr/bin/perl
# sampler.pl <out> <stopfile> <pattern>: every 0.2 s, sum RSS (KiB) of processes whose command contains <pattern>,
# and separately of other processes named shellcheck; print "time count kib real_count real_kib".
use strict; use warnings; use Time::HiRes qw(time sleep);
my ($out,$stop,$pat)=@ARGV; open(my $o,'>',$out) or die; select((select($o),$|=1)[0]);
print {$o} "# t_epoch standin_count standin_rss_kib other_shellcheck_count other_shellcheck_rss_kib\n";
while (!-e $stop) { my ($n,$k,$rn,$rk)=(0,0,0,0);
  for (`/bin/ps -axww -o pid=,rss=,command=`) { next unless /^\s*(\d+)\s+(\d+)\s+(.*)$/; my ($p,$r,$c)=($1,$2,$3);
    next if $p==$$; next if $c =~ /--version/;
    if ($c =~ m{^\S*perl\S* \Q$pat\E}) { $n++; $k+=$r; next }
    my ($n0)=split ' ',$c; $n0 =~ s{.*/}{}; if ($n0 eq 'shellcheck') { $rn++; $rk+=$r } }
  printf {$o} "%.2f %d %d %d %d\n", time(), $n,$k,$rn,$rk; sleep 0.2; }
