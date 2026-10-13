#!/usr/bin/env bash
# Live driver: real fm-project-lock-lib, real processes, throwaway lock dir.
R=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4V6XW5CXASK5PGXT9N1YKDR
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-fairwait.XXXXXX"); LOCK=$T/proj.lock
t0=$(date +%s.%N); now(){ printf '%.1f' "$(echo "$(date +%s.%N) - $t0" | bc)"; }
run(){ # name poll hold-secs
  ( . "$R/bin/fm-wake-lib.sh"; . "$R/bin/fm-project-lock-lib.sh"
    export FM_PROJECT_LOCK_POLL_SECS=$2 FM_PROJECT_LOCK_SERVICE_SECS=${SVC:-60}
    if fm_project_lock_acquire "$LOCK" "$1" 2>"$T/$1.err"; then echo "t=$(now) $1 ACQUIRED"; sleep "$3"; fm_project_lock_release "$LOCK"; echo "t=$(now) $1 RELEASED"
    else echo "t=$(now) $1 REFUSED rc=$?"; fi ) ; }
echo "== Scenario A: FIFO with slow poller first, fast poller second =="
run holder 0.2 6 & sleep 1
run slow-first 3 1 & sleep 1.5
run fast-second 0.1 1 & sleep 1
echo "t=$(now) try-while-queued:"; ( . "$R/bin/fm-wake-lib.sh"; . "$R/bin/fm-project-lock-lib.sh"; fm_project_lock_try "$LOCK" nonwaiter 2>&1; echo "try rc=$?" )
wait
echo "holds file:"; cat "$LOCK.holds"
echo "== Scenario B: dead waiter at queue head is reclaimed =="
rm -rf "$T"/*; run holder2 0.2 5 & sleep 1
( . "$R/bin/fm-wake-lib.sh"; . "$R/bin/fm-project-lock-lib.sh"; FM_PROJECT_LOCK_POLL_SECS=0.2 fm_project_lock_acquire "$LOCK" doomed 2>/dev/null ) & dp=$!
sleep 1; kill -9 $dp 2>/dev/null; echo "t=$(now) killed head waiter $dp"
run survivor 0.2 1 & wait
echo "== Scenario C: stall refusal when holder exceeds allowance (SVC=3) =="
rm -rf "$T"/*; SVC=3 run longholder 0.2 8 & sleep 1
SVC=3 run stalled-waiter 0.2 1 & wait
cat "$T/stalled-waiter.err"
echo "== Scenario D: stall limit does not kill live holder; holder still released normally above =="
rm -rf "$T"
