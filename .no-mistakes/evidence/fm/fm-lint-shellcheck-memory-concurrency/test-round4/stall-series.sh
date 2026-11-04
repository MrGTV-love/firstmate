#!/usr/bin/env bash
# Head and pre-fix controls in the same window. Same driver and rule as round 3.
R=$1 WT=$2 LAB=$3
gap(){ perl -ane 'push @s,$F[1]; END{@s=sort{$a<=>$b}@s; my $g=0; for(1..$#s){my $d=$s[$_]-$s[$_-1]; $g=$d if $d>$g} printf "%.1f roots=%d",$g,scalar @s}' "$1"; }
one(){ label=$1 repo=$2 ax=$3 p=$4 tab=$5; shift 5
  "$R/stall-driver.sh" "$label" "$repo" "$LAB/stall" "$ax" "$p" "$tab" 900 "$@" > "$R/stall-$label.txt" 2>&1
  printf '%-22s longest_start_gap_s=%s %s\n' "$label" "$(gap "$LAB/stall/$label/spans")" "$(grep -o 'wall=.*extra' "$R/stall-$label.txt" | sed 's/ extra//')" >> "$R/stall-table.txt"
  cp "$LAB/stall/$label/spans" "$R/spans-$label.txt"
}
: > "$R/stall-table.txt"
mkdir -p "$LAB/stall"
one head-slow-ps     "$WT"         4 0.5 0.5
one prefix-slow-ps   "$LAB/prefix" 4 0.5 0.5
one head-slow-p4     "$WT"         4 4   0.5
one prefix-slow-p4   "$LAB/prefix" 4 4   0.5
one head-slow-ps-2   "$WT"         4 0.5 0.5
one head-slow-p4-2   "$WT"         4 4   0.5
one head-real-ps     "$WT"         0 0   0
one head-all-4s      "$WT"         4 4   4
echo DONE >> "$R/stall-table.txt"
