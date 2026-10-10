# usage: dbench.sh <locale> <bin-dir>...
d=$(mktemp -d); f=$d/lane.status; printf 'kind=secondmate\n' > $d/lane.meta
awk 'BEGIN { pad = sprintf("%250s", ""); gsub(/ /, "\303\251", pad); n = 0
  for (i = 1; i <= 40; i++) { printf "needs-decision [key=keep%02d] [at=%d]: kept %s\n", i, 1700000000+i, pad; n++ }
  for (i = 1; n < 600; i++) {
    printf "needs-decision [key=k%d] [at=%d]: q %s\n", i % 60, 1700001000+i, pad; n++
    printf "resolved [key=k%d] [at=%d]: a\n", i % 60, 1700001000+i; n++
    printf "working: progress %d %s\n", i, pad; n++ } }' > "$f"
loc=$1; shift
for lib in "$@"; do
  ( . "$lib/fm-classify-lib.sh"; export LC_ALL=$loc
    s=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000'); out=$(status_open_decisions_dated "$f"); e=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
    printf '%s %s dated %sms md5=%s\n' "$lib" "$loc" $((e-s)) "$(printf '%s' "$out" | md5 | cut -c1-8)" )
done
rm -rf "$d"
