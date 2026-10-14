# bwait.pl <scen>: for each B root, count A admissions inside B's queue wait window.
use strict; use warnings;
my $s = shift;
my (@a, @b);
for my $run (qw(A B)) {
    open(my $fh, '<', "$s/$run.roots.tsv") or die "$s/$run.roots.tsv: $!";
    while (<$fh>) { chomp; my @f = split /\t/; next unless $f[0] eq 'end';
        my ($start, $end, $dur) = @f[5, 6, 7]; my $admit = $end - $dur;
        if ($run eq 'A') { push @a, $admit } else { push @b, [$f[2], $start, $admit] } }
}
my $worst = 0;
for my $r (sort { $a->[1] <=> $b->[1] } @b) {
    my $n = grep { $_ > $r->[1] && $_ < $r->[2] - 50 } @a;
    $worst = $n if $n > $worst;
    printf "B root %-50s waited %6.1f s; A admissions during that wait: %d\n", $r->[0], ($r->[2]-$r->[1])/1000, $n;
}
print "worst_A_admissions_during_one_B_wait=$worst\n";
