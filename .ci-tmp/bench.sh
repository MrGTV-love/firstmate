f() { local LC_ALL=C; :; }
g() { :; }
s=''; for i in $(seq 1 40); do s+="wide-q$i"$'\t'"needs-decision"$'\t'"$(printf '\303\251%.0s' $(seq 1 500))"$'\n'; done; s=${s%$'\n'}
for loc in C C.utf8; do
  export LC_ALL=$loc
  TIMEFORMAT="$loc localC x2000 %R"; time for i in $(seq 1 2000); do f; done
  TIMEFORMAT="$loc plain x2000 %R"; time for i in $(seq 1 2000); do g; done
  TIMEFORMAT="$loc settest-on-40KB x400 %R"; time for i in $(seq 1 400); do [[ "$s" == *$'\n' ]]; done
  TIMEFORMAT="$loc printf-v-40KB x400 %R"; time for i in $(seq 1 400); do printf -v x '%s' "$s"; done
done
