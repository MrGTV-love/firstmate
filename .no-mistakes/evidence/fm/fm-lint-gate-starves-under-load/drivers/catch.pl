# catch.pl <pid> <slot-dir> <seconds>: SIGSTOP <pid> repeatedly until the stop
# lands while it owns <slot-dir>/admission.lock; exit 0 leaving it stopped.
use strict; use warnings; use Fcntl qw(:flock); use Time::HiRes qw(time sleep);
my ($pid, $dir, $secs) = @ARGV; my $deadline = time + $secs; my $tries = 0;
open(my $lock, '>>', "$dir/admission.lock") or die "$!";
while (time < $deadline) {
    kill 'STOP', $pid; $tries++;
    sleep 0.002;
    if (!flock($lock, LOCK_EX | LOCK_NB)) { print "caught after $tries tries\n"; exit 0; }
    flock($lock, LOCK_UN); kill 'CONT', $pid; sleep 0.013;
}
kill 'CONT', $pid; print "not caught after $tries tries\n"; exit 1;
