s=''; for i in $(seq 1 40); do s+="wide-q$i"$'\t'"needs-decision"$'\t'"$(printf '\303\251%.0s' $(seq 1 500))"$'\n'; done; s=${s%$'\n'}
f() { :; }
n=s
for loc in C C.utf8; do
  export LC_ALL=$loc
  TIMEFORMAT="$loc call-arg x1000 %R"; time for ((i=0;i<1000;i++)); do f "$s"; done
  TIMEFORMAT="$loc assign x1000 %R"; time for ((i=0;i<1000;i++)); do x=$s; done
  TIMEFORMAT="$loc test-n x1000 %R"; time for ((i=0;i<1000;i++)); do [ -n "$s" ]; done
  TIMEFORMAT="$loc dbl-n x1000 %R"; time for ((i=0;i<1000;i++)); do [[ -n $s ]]; done
  TIMEFORMAT="$loc indirect x1000 %R"; time for ((i=0;i<1000;i++)); do x=${!n}; done
  TIMEFORMAT="$loc printfv x1000 %R"; time for ((i=0;i<1000;i++)); do printf -v x '%s' "$s"; done
  TIMEFORMAT="$loc append x1000 %R"; time for ((i=0;i<1000;i++)); do x=$s; x+=$'\n'; done
  TIMEFORMAT="$loc len x1000 %R"; time for ((i=0;i<1000;i++)); do [ "${#s}" -gt 0 ]; done
done
