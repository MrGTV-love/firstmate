#!/usr/bin/env bash
# S7: a temporary refusal arrives after the copy's ignored content changed, so
# the run-1 preserve (v0) stays. The content goes back to v0. Run 2 sees a new
# fingerprint: WAITING, no driver call. Run 3 sees the same fingerprint: it
# releases without a second preserve, and reports the preserved size as
# "preserved in an earlier run" with an unmeasured net freed.
set -u
. "$(dirname "$0")/live-lab-lib.sh"
new_world s7
echo "LAB=$W"
add_copy w; lock_dead w
printf 'unique.dat\n' >> "$SLOT/.git/info/exclude"
printf 'v0 original\n' > "$(cp_ w)/unique.dat"
: > "$CTL/mutate-then-live-w"
preserves() { find "$HOMED/data/copy-sweep" -path '*nested-copy-preserved*' -name unique.dat -type f 2>/dev/null; }
echo "=== run 1 (driver: owner writes unique.dat, then cleanup_skipped_live_or_unknown)"
sweep --apply; echo "rc=$?"
echo "--- preserves after run 1:"; for p in $(preserves); do printf '%s: %s\n' "${p#$HOMED/}" "$(cat "$p")"; done
echo "--- waiting records: $(ls "$HOMED/data/copy-sweep/waiting" 2>/dev/null | wc -l | tr -d ' ')  receipts: $(ls "$HOMED/data/copy-sweep/retained" 2>/dev/null | wc -l | tr -d ' ')"
rm -f "$CTL/mutate-then-live-w"
printf 'v0 original\n' > "$(cp_ w)/unique.dat"
echo "=== run 2 (content back to v0)"
sweep --apply; echo "rc=$?"
echo "--- driver calls so far: $(wc -l < "$CTL/closeout.log" | tr -d ' ')"
echo "=== run 3 (content unchanged since run 2)"
sweep --apply; echo "rc=$?"
echo "--- driver calls total: $(wc -l < "$CTL/closeout.log" | tr -d ' ')"
echo "--- preserves after run 3 (must still be one):"; for p in $(preserves); do printf '%s: %s\n' "${p#$HOMED/}" "$(cat "$p")"; done
echo "--- registered: $(registered w && echo yes || echo no)"
echo "--- copy-sweep.log:"; cat "$HOMED/data/copy-sweep.log"
rm -rf "$W"; echo "lab removed"
