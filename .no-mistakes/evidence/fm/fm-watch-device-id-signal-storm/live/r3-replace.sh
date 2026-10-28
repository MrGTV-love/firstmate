. /Users/charlesabrooker/.no-mistakes/evidence/01M60Q9NTSDEB99J8Q1NC7JYGW/live/harness.sh
replace_same_bytes() { cp -p "$1" "$1.new" && mv "$1.new" "$1"; }
idof() { stat -f 'dev=%d inode=%i birth=%B size=%z' "$1"; }
# rival <code>: a second watcher arm for the same home, as fm-watch-arm would start it
rival() {
  local code=$1
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    TMUX_TMPDIR="$(cat "$S/tmux-$code.path")" FM_HOME="$(labof "$code")" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_WATCHER_STALE_GRACE="$STALE" FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 FM_LAVISH_AUTO_RETIRE_INTERVAL=0 \
    bash "$(codebin "$code")/fm-watch.sh" 2>&1 | head -2 | tr '\n' ' '
}
# probe_rivals <code> <out>: while the primary watcher lives, try a rival arm every 3 s
probe_rivals() {
  local code=$1 out=$2 pid n=0 bage
  while [ ! -s "$S/watch-$code.pid" ]; do sleep 0.1; done
  pid=$(cat "$S/watch-$code.pid"); sleep 1
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 30 ]; do
    bage=$(( $(date +%s) - $(mtime "$(labof "$code")/state/.last-watcher-beat") ))
    printf '%s beacon_age=%ss rival: %s\n' "$(date +%T)" "$bage" "$(rival "$code")" >> "$out"
    n=$((n + 1)); sleep 3
  done
}
echo "## R3a task05 replaced by a byte-identical file (new inode and birth), same device"
echo "before: task05 $(idof "$LH/state/task05.status")"
replace_same_bytes "$LH/state/task05.status"
echo "after:  task05 $(idof "$LH/state/task05.status")"
echo "-- head"; round head 4 30
echo "## R3c task06: same inode, birth time moved earlier (touch -t), plus device remount"
echo "before: task06 $(idof "$LH/state/task06.status")"
touch -t 202001010000 "$LH/state/task06.status"
echo "## R3b task01 (1.05 MB) replaced by a byte-identical file (new inode and birth), plus the same remount"
for lab in "$LH" "$LB"; do replace_same_bytes "$lab/state/task01.status"; done
remount_new_dev || exit 1
d=$(devof "$S/mnt")
echo "after:  task06 $(idof "$LH/state/task06.status")"
echo "after:  task01 $(idof "$LH/state/task01.status")"
echo "-- head (FM_WATCHER_STALE_GRACE=$STALE, stall bound $((STALE * 3))s; rival arm every 3 s during pass 1)"
rm -f "$S/watch-head.pid" "$S/rival-head.out"
probe_rivals head "$S/rival-head.out" & rp=$!
t0=$(date +%s); round head 4 60; t1=$(date +%s); wait "$rp"
echo "  head beacon [$t0..$t1]: $(beacon_max head "$t0" "$t1")"
echo "  rival arms during head pass 1:"; sed 's/^/    /' "$S/rival-head.out"
echo "after: head markers $(marker_devices head "$d") ; $(markers_current head)"
echo "after: task01 seen classified=$(classified "$LH/state/.seen-task01_status") size=$(stat -f %z "$LH/state/task01.status")"
echo "after: task06 seen classified=$(classified "$LH/state/.seen-task06_status")"
echo "-- base (comparison; rival arm every 3 s during pass 1)"
rm -f "$S/watch-base.pid" "$S/rival-base.out"
probe_rivals base "$S/rival-base.out" & rp=$!
t0=$(date +%s); round base 2 60; t1=$(date +%s); wait "$rp"
echo "  base beacon [$t0..$t1]: $(beacon_max base "$t0" "$t1")"
echo "  rival arms during base pass 1:"; sed 's/^/    /' "$S/rival-base.out"
