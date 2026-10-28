. /Users/charlesabrooker/.no-mistakes/evidence/01M60Q9NTSDEB99J8Q1NC7JYGW/live/harness.sh
# R6: a span read that makes NO progress is still stopped at the stall bound; afterwards the log is not stuck.
echo "## R6 stalled span read (SIGSTOP on the capture group), FM_WATCHER_STALE_GRACE=$STALE => stall bound $((STALE * 3))s"
st="$LH/state"; f="$st/task02.status"
cp -p "$f" "$f.new" && mv "$f.new" "$f"; printf 'done: task02 rerun result A\n' >> "$f"
echo "task02 replaced (new inode) + appended: $(stat -f 'inode=%i size=%z' "$f"); seen classified before=$(classified "$st/.seen-task02_status")"
rm -f "$S/watch-head.pid"; out="$S/r6-pass1.run"
t0=$(date +%s)
( run_watch head 120 > "$out" ) &
while [ ! -s "$S/watch-head.pid" ]; do sleep 0.1; done; wpid=$(cat "$S/watch-head.pid")
i=0; until ls -a "$st" | grep -q '^\.task02\.open-decisions-cursor\.span\.'; do i=$((i+1)); [ "$i" -lt 1200 ] || { echo "task02 span read never started"; break; }; sleep 0.05; done
pg=$(ps -A -o pid=,ppid=,pgid= | awk -v w="$wpid" '$2==w && $1==$3 {print $1; exit}')
kill -STOP -- "-$pg"; ts=$(date +%s)
echo "task02 span read started; SIGSTOP sent to capture process group $pg at +$((ts - t0))s"
ps -o pid=,pgid=,stat=,command= -g "$pg" | sed 's/^/  stopped: /' | cut -c1-140
until ! kill -0 -- "-$pg" 2>/dev/null || ! kill -0 "$wpid" 2>/dev/null; do sleep 0.2; done
te=$(date +%s); echo "capture group $pg gone at +$((te - t0))s, $((te - ts))s after SIGSTOP (no progress the whole time)"
wait
echo "pass 1: $(cat "$out") ; signal rows=$(signals head) ; names: $(signal_names head)"
t1=$(date +%s); echo "beacon during pass 1 [$t0..$t1]: $(beacon_max head "$t0" "$t1")"
echo "task02 seen classified after stalled read=$(classified "$st/.seen-task02_status") size=$(stat -f %z "$f")"
cp "$st/.wake-queue" "$LH/queue-r6-pass1" 2>/dev/null; ack_all head || echo "ack failed"
echo "-- next change to task02 is read again (no stop this time) and commits"
printf 'done: task02 rerun result B\n' >> "$f"
t0=$(date +%s); round head 4 120; t1=$(date +%s)
echo "beacon [$t0..$t1]: $(beacon_max head "$t0" "$t1")"
echo "  span-read captures (name alive-seconds):"; capture_spans head "$t0" "$t1"
echo "task02 seen classified=$(classified "$st/.seen-task02_status") size=$(stat -f %z "$f")"
echo "watcher stderr (this lab, whole run):"; sed 's/^/  /' "$LH/watch.err"
