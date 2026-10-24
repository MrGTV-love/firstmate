#!/usr/bin/env bash
# S5: a driver that systematically half-releases (unlocks but leaves the copy
# registered with exit 0, or unlocks then fails) must use a slot per execute,
# so limit 5 reaches at most five copies of seven; the rest are DEFERRED.
set -u
. "$(dirname "$0")/live-lab-lib.sh"
for mode in partial partial-fail; do
  new_world "s5-$mode"
  echo "##### mode=$mode LAB=$W"
  for n in 1 2 3 4 5 6 7; do add_copy "p$n"; lock_dead "p$n"; : > "$CTL/$mode-p$n"; done
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=5 sweep --apply; echo "rc=$?"
  echo "--- executes: $(grep -c -- --execute-cleanup "$CTL/closeout.log") of 7 copies"
  for n in 1 2 3 4 5 6 7; do printf 'p%s registered=%s ' "$n" "$(registered "p$n" && echo yes || echo no)"; done; echo
  echo "--- receipts written: $(ls "$HOMED/data/copy-sweep/retained" 2>/dev/null | wc -l | tr -d ' ')"
  echo "=== mode=$mode run 2 (receipts must stop a repeat on the same copies)"
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=5 sweep --apply; echo "rc=$?"
  echo "--- executes total after run 2: $(grep -c -- --execute-cleanup "$CTL/closeout.log")"
  rm -rf "$W"; echo "lab removed"
done
