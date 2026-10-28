#!/usr/bin/env bash
# Live: a foreign writer holds the log's lock and is over the cap; a sanctioned append
# waits on that lock while the real guard scan runs. The guard must stop the foreign
# holder, spare the capped append, and the append must return 75 within its 10 s bound.
set -u
A="$PWD/bin/fm-status-append.sh"; GUARD="$PWD/bin/fm-status-cap-guard.sh"; ST="$FM_HOME/state"; F="$ST/lockcase.status"
export FM_STATUS_CAP_BYTES=65536 FM_STATUS_CAP_RESERVE_BYTES=8192
st(){ ps -p "$1" -o state= | tr -d ' ' | cut -c1; }
head -c 70000 /dev/zero | tr '\0' x > "$F"; echo >> "$F"
perl -e 'open(my $f, ">>", $ARGV[0]) or die; flock($f, 2) or die; print STDERR "holder locked\n"; sleep 120' "$F" & HOLDER=$!
sleep 1
start=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
"$A" "$F" "done [at=$(date +%s)]: wants the lock" 2>"$ST/lock.err" & APP=$!
sleep 1
APP_PERL=$(pgrep -P "$APP" perl | head -1)
echo "foreign holder pid=$HOLDER (perl, no marker); sanctioned append shell pid=$APP, its perl pid=$APP_PERL"
lsof -nP -- "$F" | sed 's/^/lsof: /'
echo "== guard scan"
"$GUARD" scan; echo "guard exit=$?"
echo "holder state=$(st $HOLDER) (T = stopped)"
echo "append perl state=$( [ -n "$APP_PERL" ] && st $APP_PERL || echo gone)"
wait "$APP"; rc=$?
end=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
echo "sanctioned append exit=$rc after $(echo "$end - $start" | bc) s"
echo "append stderr: $(cat "$ST/lock.err")"
kill -CONT $HOLDER; kill -9 $HOLDER 2>/dev/null; wait $HOLDER 2>/dev/null
echo "== after the holder is gone, a done: lands? (log is 70001 bytes, under cap+reserve 73728)"
"$A" "$F" "done [at=$(date +%s)]: lock free now"; echo "exit=$?  last line: $(tail -n1 "$F")"
