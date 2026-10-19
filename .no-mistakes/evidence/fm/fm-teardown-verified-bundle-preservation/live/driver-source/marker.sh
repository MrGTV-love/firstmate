set -u
ROOT=$1; T=$2
. "$ROOT/bin/fm-tasks-axi-lib.sh"; . "$ROOT/bin/fm-backlog-transition-lib.sh"
STATE=$T/state; DATA=$T/data
note="preserved in bundle $T/bundles/task-m1.bundle, not landed"
marker=$(fm_backlog_close_marker_path "$STATE" task-m1)
echo "== stage + validate a pending-close marker with the bundle note"
fm_backlog_close_marker_stage "$marker" task-m1 "$DATA" gen-1 "$STATE" 0 --note "$note" && echo "stage: accepted" || { echo "stage: REFUSED: ${FM_BACKLOG_TRANSITION_ERROR:-}"; exit 1; }
cat "$marker"
echo "== crash recovery replay (what bootstrap runs)"
fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA"; echo "replay rc=$? result=$FM_BACKLOG_CLOSE_REPLAY_RESULT err=${FM_BACKLOG_TRANSITION_ERROR:-}"
echo "== backlog after replay"; cat "$DATA/backlog.md"
echo "== adversarial: forged notes must be rejected by the marker validator"
for bad in "preserved in bundle relative/x.bundle, not landed" "preserved in bundle /x.bundle, and more" "dropped extra" "$(printf 'preserved in bundle /x%.0s' 1)$(head -c 5000 /dev/zero | tr '\0' a), not landed"; do
  m2="$STATE/task-m2.backlog-close"; rm -f "$m2"
  if fm_backlog_close_marker_stage "$m2" task-m2 "$DATA" gen-1 "$STATE" 0 --note "$bad" 2>/dev/null; then echo "ACCEPTED (bad): ${bad:0:60}"; else echo "rejected: ${bad:0:60}"; fi
done
