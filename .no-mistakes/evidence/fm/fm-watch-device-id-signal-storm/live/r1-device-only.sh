. /Users/charlesabrooker/.no-mistakes/evidence/01M60Q9NTSDEB99J8Q1NC7JYGW/live/harness.sh
echo "## R1 device-only remount, no log changed (FM_WATCHER_STALE_GRACE=$STALE)"
for c in head base; do echo "before: $c markers $(marker_devices "$c" "$(devof "$S/mnt")") ; $(markers_current "$c")"; done
echo "before: task03 seen marker: $(cat "$LH/state/.seen-task03_status" | cut -c1-60)... classified=$(classified "$LH/state/.seen-task03_status")"
echo "before: task01 hb marker classified field: $(classified "$LH/state/.hb-surfaced-task01")"
remount_new_dev || exit 1
d=$(devof "$S/mnt"); echo "log identity now: $(stat -f '%d:%i:%B' "$LH/state/task03.status") (dev:inode:birth)"
echo "-- head"; t0=$(date +%s); round head 4 30; t1=$(date +%s)
echo "  head beacon [$t0..$t1]: $(beacon_max head "$t0" "$t1")"
echo "after: head markers $(marker_devices head "$d") ; $(markers_current head)"
echo "after: task03 seen marker classified field: $(classified "$LH/state/.seen-task03_status")"
echo "after: task01 hb marker classified field: $(classified "$LH/state/.hb-surfaced-task01")"
echo "after: task02 seen marker classified field (was unclassified): $(classified "$LH/state/.seen-task02_status")"
echo "-- base (comparison)"; t0=$(date +%s); round base 2 60; t1=$(date +%s)
echo "after: base markers $(marker_devices base "$d")"
