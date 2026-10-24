#!/usr/bin/env bash
# S4: five dead-launcher copies z1..z5 sort first (deepest path first, reverse
# path order) and refuse on every run, each a different way:
#   z1 plan refusal, z2 preservation failure (unreadable ignored file),
#   z3 driver liveness refusal (cleanup_skipped_live_or_unknown),
#   z4 reproof failure (lock bytes change during the plan),
#   z5 driver lease refusal (cleanup_lease_conflict).
# Seven clean copies c1..c7 follow. Limit 5. Run 1 must release five clean
# copies and defer two; run 2 must release the other two. The z copies stay.
set -u
. "$(dirname "$0")/live-lab-lib.sh"
new_world s4
echo "LAB=$W"
printf 'unreadable.dat\n' >> "$SLOT/.git/info/exclude"
for n in z1 z2 z3 z4 z5 c1 c2 c3 c4 c5 c6 c7; do add_copy "$n"; lock_dead "$n"; done
: > "$CTL/refuse-plan-z1"
printf 'secret\n' > "$(cp_ z2)/unreadable.dat"; chmod 000 "$(cp_ z2)/unreadable.dat"
: > "$CTL/live-z3"
: > "$CTL/mutate-lock-z4"
: > "$CTL/lease-z5"
for run in 1 2; do
  echo "=== run $run (FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=5)"
  FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=5 sweep --apply; echo "rc=$?"
  echo "--- registered after run $run:"
  for n in z1 z2 z3 z4 z5 c1 c2 c3 c4 c5 c6 c7; do printf '%s=%s ' "$n" "$(registered "$n" && echo yes || echo no)"; done; echo
  echo "--- executes so far per copy:"
  for n in z1 z2 z3 z4 z5 c1 c2 c3 c4 c5 c6 c7; do printf '%s=%s ' "$n" "$(grep -cF "/$n --execute-cleanup" "$CTL/closeout.log")"; done; echo
done
chmod 600 "$(cp_ z2)/unreadable.dat"
rm -rf "$W"; echo "lab removed"
