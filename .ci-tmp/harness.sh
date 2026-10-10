# usage: harness.sh <bin-dir> <label>
d=$(mktemp -d); f=$d/lane.status; printf 'kind=secondmate\n' > $d/lane.meta
awk 'BEGIN {
    pad = sprintf("%500s", ""); gsub(/ /, "\303\251", pad)
    for (i = 1; i <= 40; i++) printf "needs-decision [key=wide-q%02d] [at=%d]: question %d %s\n", i, 1700000000 + i, i, pad
    for (i = 1; i <= 200; i++) {
      printf "needs-decision [key=churn] [at=%d]: short question %d\n", 1700001000 + i, i
      printf "resolved [key=churn] [at=%d]: answered %d\n", 1700001000 + i, i
    }
  }' > "$f"
. "$1/fm-classify-lib.sh"
for loc in C C.utf8 C C.utf8; do
  ( export LC_ALL=$loc; s=$(date +%s%N); out=$(status_open_decisions "$f"); e=$(date +%s%N); rm -f $d/.*fold* $d/*.fold* 2>/dev/null; printf '%s %s %sms md5=%s\n' "$2" "$loc" $(( (e-s)/1000000 )) "$(printf '%s' "$out" | md5sum | cut -c1-8)" )
done
ls -a $d | head
