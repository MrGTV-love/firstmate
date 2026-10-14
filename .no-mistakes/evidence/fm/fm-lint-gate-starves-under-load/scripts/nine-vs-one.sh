#!/usr/bin/env bash
# nine-vs-one.sh <gate-script> <scen> <style head|mid>
# Real gate, two slots. Run "nine" has 9 looping workers; run "one" has 1.
# Each admitted command records request/admit times and holds its slot 1.5 s.
set -u
gate=$1 scen=$2 style=$3
mkdir -p "$scen"; : > "$scen/log"
export FM_LINT_HOST_SLOTS=2
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
worker() {  # <run> <iterations>
  local run=$1 n=$2 id=$3 i req
  for ((i=0;i<n;i++)); do
    req=$(now)
    if [ "$style" = head ]; then
      perl "$gate" gate "$scen/slots" 18 "$run" "$scen/wait.$run.$id.$i" -- \
        perl -MTime::HiRes=time,sleep -e 'open(my $f, ">>", $ARGV[0]) or die; printf {$f} "%s\t%s\t%.3f\n", $ARGV[1], $ARGV[2], time; close $f; sleep 1.5' "$scen/log" "$run" "$req"
    else
      perl "$gate" gate "$scen/slots" 18 "$scen/wait.$run.$id.$i" -- \
        perl -MTime::HiRes=time,sleep -e 'open(my $f, ">>", $ARGV[0]) or die; printf {$f} "%s\t%s\t%.3f\n", $ARGV[1], $ARGV[2], time; close $f; sleep 1.5' "$scen/log" "$run" "$req"
    fi
  done
}
for w in 1 2 3 4 5 6 7 8 9; do worker nine 3 $w & done
sleep 1
worker one 6 0 &
wait
# For each "one" request: nine admissions between its request and admission.
perl -e '
open(my $f, "<", $ARGV[0]) or die; my @r = map { chomp; [split /\t/] } <$f>;
my @nine = map { $_->[2] } grep { $_->[0] eq "nine" } @r; my $worst = 0; my $sum = 0;
for my $o (grep { $_->[0] eq "one" } @r) { my $n = grep { $_ > $o->[1] && $_ < $o->[2] } @nine; $worst = $n if $n > $worst; $sum += $n;
  printf "one request at +%.1f s admitted after %.1f s; nine admissions while it waited: %d\n", $o->[1]-$r[0][2], $o->[2]-$o->[1], $n }
printf "worst=%d total_nine_overtakes=%d\n", $worst, $sum;' "$scen/log"
