#!/usr/bin/env bash
. "$(dirname "$0")/lab.sh"
lab_reset; lab_init; lab_tmux_start
out_begin S8-arming-rules-and-sweep
say "### S8: only a verified merge arms; FM_MERGE_PRUNE=0 arms nothing; arming twice keeps one record; the watcher's sweep makes the due attempt"
mkworld arm 140 || exit 1
rm -f "$STATE/arm.pr-poll-merge-notified"
prune "$W" arm arm; check "S8a an unverified merge (no merge-poll marker) arms nothing" test ! -e "$STATE/arm.merge-prune"
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n999\n' > "$STATE/arm.pr-poll-merge-notified"; chmod 0600 "$STATE/arm.pr-poll-merge-notified"
prune "$W" arm arm; check "S8c a marker for a different PR arms nothing" test ! -e "$STATE/arm.merge-prune"
printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n140\n' > "$STATE/arm.pr-poll-merge-notified"; chmod 0600 "$STATE/arm.pr-poll-merge-notified"
FM_MERGE_PRUNE=0 prune "$W" arm arm; check "S8b FM_MERGE_PRUNE=0 arms nothing" test ! -e "$STATE/arm.merge-prune"
prune "$W" arm arm; check "S8d a verified merge arms" test -e "$STATE/arm.merge-prune"
cp "$STATE/arm.merge-prune" "$LAB/arm.rec1"; sleep 1; prune "$W" arm arm
check "S8d arming twice leaves the record unchanged" cmp -s "$STATE/arm.merge-prune" "$LAB/arm.rec1"
say "--- sweep (what bin/fm-watch.sh starts every 60s while a record exists)"
prune "$W" sweep
for i in $(seq 1 90); do [ ! -e "$STATE/arm.meta" ] && break; sleep 1; done
dump_world arm
check "S8e1 task record closed by the sweep" test ! -e "$STATE/arm.meta"
check "S8e2 prune record removed by the sweep" test ! -e "$STATE/arm.merge-prune"
check "S8e3 log says reaped" grep -q reaped "$DATA/arm/merge-prune.log"
finish
