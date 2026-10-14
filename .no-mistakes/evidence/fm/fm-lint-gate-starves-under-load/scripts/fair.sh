#!/usr/bin/env bash
# fair.sh <impl-root> <scen-dir> <cap> <rootsA-file> <rootsB-file>
# Starts run A (--jobs 2), waits until A has a queued ticket, then run B (--jobs 1).
set -u
impl=$1 scen=$2 cap=$3; ra=(); rb=()
while IFS= read -r l; do ra+=("$l"); done < "$4"
while IFS= read -r l; do rb+=("$l"); done < "$5"
mkdir -p "$scen"
common=(env XDG_CACHE_HOME="$scen/xdg" FM_DURATION_FILE=off FM_LINT_CACHE_DIR=off FM_LINT_SLOT_DIR="$scen/slots" FM_LINT_HOST_SLOTS="$cap")
"${common[@]}" "$impl/bin/fm-lint.sh" --jobs 2 --telemetry "$scen/A.tsv" "${ra[@]}" > "$scen/A.out" 2>&1 &
pa=$!
perl -e 'my $d=time+120; until (grep { -e } glob("$ARGV[0]/queue.0*")) { exit 1 if time>$d; select(undef,undef,undef,0.05) }' "$scen/slots" || echo "A never queued"
sleep 1
bstart=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
"${common[@]}" "$impl/bin/fm-lint.sh" --jobs 1 --telemetry "$scen/B.tsv" "${rb[@]}" > "$scen/B.out" 2>&1 &
pb=$!
wait $pa; ra_rc=$?; wait $pb; rb_rc=$?
printf 'A_rc=%s B_rc=%s B_started_ms=%s\n' "$ra_rc" "$rb_rc" "$bstart" > "$scen/result.txt"
# admission timeline: admit_ms = end - analysis duration
{ awk -F'\t' '$1=="end"{print $7-$8"\tA\t"$3}' "$scen/A.roots.tsv"; awk -F'\t' '$1=="end"{print $7-$8"\tB\t"$3}' "$scen/B.roots.tsv"; } | sort -n > "$scen/admissions.tsv"
perl -e '
my ($bstart, $f) = @ARGV; open(my $fh, "<", $f) or die; my @rows = map { chomp; [split /\t/] } <$fh>;
my $btotal = grep { $_->[1] eq "B" } @rows; my $bseen = 0; my $gap = 0; my $maxgap = 0; my $seq = "";
for my $r (@rows) { next if $r->[0] < $bstart; last if $bseen == $btotal; $seq .= $r->[1];
  if ($r->[1] eq "B") { $maxgap = $gap if $gap > $maxgap; $gap = 0; $bseen++ } else { $gap++ } }
my $a = () = $seq =~ /A/g; my $b = () = $seq =~ /B/g;
printf "sequence_after_B_arrives=%s A_turns=%d B_turns=%d max_A_turns_between_B=%d\n", $seq, $a, $b, $maxgap;' "$bstart" "$scen/admissions.tsv" >> "$scen/result.txt"
awk -F'\t' '$1=="end"{w=($7-$6)-$8; t+=w; if(w>m)m=w} END{printf "B_sum_wait_s=%.1f B_max_wait_s=%.1f\n", t/1000, m/1000}' "$scen/B.roots.tsv" >> "$scen/result.txt"
cat "$scen/result.txt"
