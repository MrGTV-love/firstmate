#!/usr/bin/env bash
. "$(dirname "$0")/lab.sh"
lab_reset; lab_init; lab_tmux_start
out_begin S10-watcher-sweep-prunes-an-armed-record
say "### S10: the REAL bin/fm-watch.sh (isolated lab home, 2s poll) starts the prune sweep while a record exists; the armed merged task's copy is pruned with no human step"
mkworld wsw 170 || exit 1
prune "$W" arm wsw
say "armed (no --run): record present = $(test -e "$STATE/wsw.merge-prune" && echo yes || echo no)"
say "slot before: $(cd "$W/proj" && lab_run "$W" "$LAB/bin/treehouse" status 2>&1 | sed "s#$LAB#<LAB>#g" | tr '\n' ' ')"
# the watcher exits once it has surfaced something (here the finished task's status); the primary starts it again, so do the same
K=0
for i in $(seq 1 5); do
  [ ! -e "$STATE/wsw.merge-prune" ] && break
  K=$((K+1))
  lab_run "$W" env FM_POLL=2 FM_SIGNAL_GRACE=0 FM_MERGE_PRUNE_INTERVAL=2 FM_IDLE_REAP_INTERVAL=0 FM_HEARTBEAT=999999 \
    timeout 30 "$REPO/bin/fm-watch.sh" >> "$LAB/watch.out" 2>&1
  sleep 1
done
say "watcher launches: $K"
say "--- watcher output (head):"; head -c 1500 "$LAB/watch.out" | sed "s#$LAB#<LAB>#g" | tee -a "$OUT"; say ""
dump_world wsw
check "S10 the watcher's sweep removed the prune record" test ! -e "$STATE/wsw.merge-prune"
check "S10 the task record is closed" test ! -e "$STATE/wsw.meta"
check "S10 log says armed then reaped" bash -c "grep -q armed '$DATA/wsw/merge-prune.log' && grep -q 'reaped' '$DATA/wsw/merge-prune.log'"
check "S10 no wake" test "$(wake_count wsw)" = 0
check "S10 nothing forced" nothing_forced wsw
check "S10 slot returned to the real pool (clean, detached)" bash -c "[ -z \"\$(git -C '$WT' status --porcelain --untracked-files=all)\" ] && ! git -C '$WT' symbolic-ref -q HEAD"
finish
