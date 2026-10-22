#!/usr/bin/env bash
R=$1
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999
H=$(mktemp -d /tmp/fm-lab.XXXXXX); mkdir -p "$H/state" "$H/data" "$H/config"; : > "$H/data/backlog.md"
FM_HOME="$H" perl -e 'setpgrp(0,0); exec @ARGV' "$R/bin/fm-watch-checkpoint.sh" --seconds 180 >"$H/c.out" 2>"$H/c.err" &
cp=$!; i=0
while [ ! -s "$H/state/.watch.lock/pid" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i+1)); done
wp=$(cat "$H/state/.watch.lock/pid"); echo "watcher=$wp"; ps -o pid,pgid,ppid,command -ax | awk -v p="$cp" -v w="$wp" '$2==p || $2==w' | grep -v awk
kill -KILL -- "-$cp"; wait "$cp" 2>/dev/null
for t in 1 2 3 4 5 6 7 8 9 10 20 40 80 120; do
  sleep 0.05
  printf 't~%s: watcher=%s lock=%s\n' "$t" "$(kill -0 "$wp" 2>/dev/null && echo alive || echo gone)" "$(cat "$H/state/.watch.lock/pid" 2>/dev/null || echo absent)"
done
echo "--- tail of deliveries/watcher-down"; cat "$H/state/.watcher-down" 2>/dev/null; echo
ps -o pid,pgid,ppid,command -ax | awk -v w="$wp" '$2==w' | grep -v awk
rm -rf "$H"
