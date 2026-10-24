#!/usr/bin/env bash
# World A: report, cap 5 of 7, deferral, live launcher, unpushed, real-driver refusal.
set -u
WT=$1 LAB=$2; . "$(dirname "$0")/lab-lib.sh"
new_world a
DEAD=$(dead_pid)
(cd "$W" && exec sleep 3600) & LIVE=$!; echo "$LIVE" > "$W/live.pid"
for i in 1 2 3 4 5 6 7; do add_copy "c$i" merged "$DEAD"; done
add_copy a-refused pushed "$DEAD"     # branch pushed, never merged: the real driver must refuse it
add_copy live merged "$LIVE"          # launcher still running
add_copy unpushed unpushed "$DEAD"    # a local commit on no remote
git -C "$SLOT" fetch -q origin
echo "dead launcher pid=$DEAD (not running: $(kill -0 "$DEAD" 2>/dev/null && echo NO || echo yes)); live launcher pid=$LIVE"
echo; echo "===== RUN 0: report (no flag)"; state > "$W/before.txt"
sweep; echo "exit=$?"; state > "$W/after0.txt"
if cmp -s "$W/before.txt" "$W/after0.txt"; then echo "report changed nothing on disk: yes"; else echo "report changed nothing: NO"; diff "$W/before.txt" "$W/after0.txt"; fi
echo; echo "===== RUN 1: --apply (default cap 5)"; sweep --apply; echo "exit=$?"; state
echo; echo "===== RUN 2: --apply"; sweep --apply; echo "exit=$?"; state
echo; echo "===== branches on origin after:"; git -C "$W/origin.git" branch --list | tr -d ' ' | tr '\n' ' '; echo
echo "===== copy-sweep.log:"; sed "s|$LAB|\$LAB|g" "$HOMED/data/copy-sweep.log"
kill "$LIVE" 2>/dev/null
