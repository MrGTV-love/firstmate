. /Users/charlesabrooker/.no-mistakes/evidence/01M60Q9NTSDEB99J8Q1NC7JYGW/live/harness.sh
echo "## R4 eight logs changed in one pass; task11 changes again during the signal grace (FM_SIGNAL_GRACE=8)"
dedupe() {  # <code>
  local c=$1 lab pid i=0 out
  lab=$(labof "$c"); out="$S/r4-$c.run"
  for n in 07 08 09 10 11 12 13 14; do printf 'done: task%s batch result\n' $n >> "$lab/state/task$n.status"; done
  rm -f "$S/watch-$c.pid"
  ( GRACE=8 run_watch "$c" 90 > "$out" ) &
  while [ ! -s "$S/watch-$c.pid" ]; do sleep 0.1; done
  pid=$(cat "$S/watch-$c.pid")
  # wait until the watcher's first scan found the batch and it sleeps out the grace
  until ps -A -o ppid=,command= | awk -v p="$pid" '$1==p && $2 ~ /sleep$/ && $3 == 8 {f=1} END{exit !f}'; do
    i=$((i + 1)); [ "$i" -lt 600 ] || { echo "  $c: grace sleep never seen"; break; }; sleep 0.1
  done
  echo "  $c: grace sleep seen after ~$((i / 10))s; appending the newest state to task11"
  printf 'done: task11 newest result written between the two scans\n' >> "$lab/state/task11.status"
  wait
  echo "  $c pass 1: $(cat "$out") ; signal rows queued=$(signals "$c") ; names: $(signal_names "$c")"
  echo "  $c task11 seen marker reported == current observed signature: $([ "$(reported "$lab/state/.seen-task11_status")" = "$(observed_sig "$lab/state/task11.status")" ] && echo yes || echo no)"
  echo "  $c task11 classified offset/size: $(classified "$lab/state/.seen-task11_status" | cut -d@ -f1)/$(stat -f %z "$lab/state/task11.status")"
  cp "$lab/state/.wake-queue" "$lab/queue-r4-$c" 2>/dev/null
  ack_all "$c" || echo "  ack failed"
  echo "  $c drain shows task11 newest state: $(grep -c "task11 newest result written between the two scans" "$lab/drain.history") line(s)"
  round "$c" 3 30
}
echo "-- head"; dedupe head
echo "-- base (comparison)"; dedupe base
