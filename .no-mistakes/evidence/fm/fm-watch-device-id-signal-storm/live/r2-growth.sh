. /Users/charlesabrooker/.no-mistakes/evidence/01M60Q9NTSDEB99J8Q1NC7JYGW/live/harness.sh
echo "## R2 two logs grew (task03, task04 got a done: line), then device remount (FM_WATCHER_STALE_GRACE=$STALE)"
for lab in "$LH" "$LB"; do for n in 03 04; do printf 'done: task%s new result appended before the reboot\n' $n >> "$lab/state/task$n.status"; done; done
remount_new_dev || exit 1
d=$(devof "$S/mnt")
echo "-- head"; t0=$(date +%s); round head 4 30; t1=$(date +%s)
echo "  head beacon [$t0..$t1]: $(beacon_max head "$t0" "$t1")"
echo "after: head markers $(marker_devices head "$d") ; $(markers_current head)"
echo "after: task03 seen classified=$(classified "$LH/state/.seen-task03_status") size=$(stat -f %z "$LH/state/task03.status")"
echo "drain text for the grown logs:"; grep -h 'task0[34]' "$LH/drain.history" | grep -i 'done: task0[34] new result' | sort -u | head -4
echo "-- base (comparison)"; round base 2 60
