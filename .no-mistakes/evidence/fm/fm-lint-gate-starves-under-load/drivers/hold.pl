# hold.pl <slot-file> <release-file>: hold the slot flock until <release-file> exists.
use strict; use warnings; use Fcntl qw(:flock); use Time::HiRes qw(sleep);
my ($slot, $release) = @ARGV;
open(my $fh, '>>', $slot) or die "$!"; flock($fh, LOCK_EX) or die "$!";
truncate($fh, 0); syswrite($fh, "holder\t0\n");
print "held\n"; $| = 1;
sleep 0.05 until -e $release;
