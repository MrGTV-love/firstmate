# usage: bigbench.sh <bin-dir> <label>
d=$(mktemp -d); f=$d/lane.status; printf 'kind=secondmate\n' > $d/lane.meta
awk 'BEGIN { pad = sprintf("%250s", ""); gsub(/ /, "\303\251", pad); n = 0
  for (i = 1; i <= 40; i++) { printf "needs-decision [key=keep%02d] [at=%d]: kept %s\n", i, 1700000000+i, pad; n++ }
  for (i = 1; n < 1953; i++) {
    printf "needs-decision [key=k%d] [at=%d]: q %s\n", i % 60, 1700001000+i, pad; n++
    printf "resolved [key=k%d] [at=%d]: a\n", i % 60, 1700001000+i; n++
    if (n < 1953) { printf "working: progress %d %s\n", i, pad; n++ } }
  for (i = 0; i < 60; i++) printf "resolved [key=k%d]: close\n", i }' > "$f"
. "$1/fm-classify-lib.sh"
export LC_ALL=en_US.UTF-8
for fn in status_open_decisions status_open_decisions_dated; do
  s=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000'); out=$($fn "$f"); e=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000')
  printf '%s %s %sms lines=%s bytes=%s md5=%s\n' "$2" "$fn" $((e-s)) "$(printf '%s\n' "$out" | grep -c .)" "$(wc -c < "$f" | tr -d ' ')" "$(printf '%s' "$out" | md5 | cut -c1-8)"
done
rm -rf "$d"
