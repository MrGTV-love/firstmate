. /Users/charlesabrooker/.no-mistakes/evidence/01M60Q9NTSDEB99J8Q1NC7JYGW/live/harness.sh
echo "## R0 prime on device $(devof "$S/mnt"): first sighting of $N logs (task01 1.05 MB, task02 1.6 MB); FM_WATCHER_STALE_GRACE=$STALE => stall bound $((STALE * 3))s"
for c in head base; do
  echo "-- $c"; t0=$(date +%s)
  round "$c" 4 600
  t1=$(date +%s); echo "  $c beacon during prime [$t0..$t1]: $(beacon_max "$c" "$t0" "$t1")"
  [ "$c" = head ] && { echo "  head span-read captures seen (name alive-seconds):"; capture_spans head "$t0" "$t1"; }
done
for c in head base; do
  st=$(labof $c)/state
  echo "lab-$c markers on device $(devof "$S/mnt"): $(marker_devices $c "$(devof "$S/mnt")") ; $(markers_current $c)"
  for t in 01 02; do echo "  lab-$c task$t seen classified=$(classified "$st/.seen-task${t}_status") size=$(stat -f %z "$st/task$t.status")"; done
done
echo "head watcher stderr:"; sed 's/^/  /' "$LH/watch.err"
