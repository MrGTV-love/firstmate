# scan_once: source the lab's real bin/fm-watch.sh (its source guard stops before the loop) and run the same
# fm_session_end_relaunch_scan call that session_end_relaunch_tick makes; print the wake it would emit.
scan_once() {
  (cd "$LAB" && lr bash -c '. "$FM_HOME/bin/fm-watch.sh" >/dev/null 2>&1; fm_session_end_relaunch_scan "$STATE" "$WATCHER_STALE_GRACE"; echo "scan-rc=$?"; printf "WAKE: %s\n" "${FM_SESSION_END_WAKE:-<none>}"' 2>&1) | grep -v '^●'
}
