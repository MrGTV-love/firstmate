f() { local LC_ALL=C; local y=$'\xc3\xa9'; printf 'in:%s ' "${#y}"; }
LC_ALL=en_US.UTF-8
x=$'\xc3\xa9'; printf 'before:%s ' "${#x}"; f; printf 'after:%s\n' "${#x}"
# cost probes on a ~19KB multibyte set
s=''; i=0; while [ $i -lt 36 ]; do s+="key-$i"$'\t'"needs-decision"$'\t'"$(printf 'caf\xc3\xa9 %.0s' $(seq 1 85))"$'\n'; i=$((i+1)); done; s=${s%$'\n'}
printf 'len=%s\n' "${#s}"
t() { local n=$1; shift; local st=$SECONDS i=0; TIMEFORMAT="$n %R"; time { while [ $i -lt 200 ]; do "$@"; i=$((i+1)); done; }; }
p_test() { [[ "$s" == *$'\n' ]]; }
p_strip() { local o=${s%$'\n'}; }
p_test_c() { local LC_ALL=C; [[ "$s" == *$'\n' ]]; }
p_strip_c() { local LC_ALL=C; local o=${s%$'\n'}; }
p_case() { case "$s" in *$'\n') ;; esac; }
p_last() { [ "${s: -1}" = $'\n' ]; }
t test p_test; t strip p_strip; t test_c p_test_c; t strip_c p_strip_c; t case p_case; t last p_last
