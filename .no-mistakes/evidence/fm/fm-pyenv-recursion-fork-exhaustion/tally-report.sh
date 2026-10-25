#!/bin/bash
# tally-report.sh <log>: count bash starts, pyenv-prefix/pyenv-which starts, deepest parent chain.
log=$1
awk '
{ pid=$1; ppid[$1]=$2; name[$1]=$3; n++ }
$3=="pyenv-prefix"{pp++} $3=="pyenv-which"{pw++}
END {
  max=0
  for (p in ppid) { d=0; q=p; while (q in ppid && d<100000) { d++; q=ppid[q] } if (d>max) max=d }
  printf "bash starts=%d pyenv-prefix=%d pyenv-which=%d deepest bash ancestry chain=%d\n", n, pp+0, pw+0, max
}' "$log"
echo "first 6 starts:"; head -6 "$log" | sed 's/^/  /'
