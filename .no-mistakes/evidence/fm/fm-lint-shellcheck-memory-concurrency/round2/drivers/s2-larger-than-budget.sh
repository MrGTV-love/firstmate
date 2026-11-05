#!/usr/bin/env bash
# A root bigger than the whole budget runs alone, queues rather than fails, does not deadlock. A killed waiter frees its place.
. "$(dirname "$0")/lib.sh"
S=/tmp/nm-r2/s2; rm -rf "$S"; mkdir -p "$S/bin"; BIN=$S/bin; standin "$BIN" "$S/spans"
for r in a b c d e; do root "$S/$r.sh"; done
echo "# budget 30000 KiB, stand-in allocates 64 MiB (65536 KiB) so it is larger than the budget alone"
export FM_LINT_SLOT_DIR=$S/pool FM_LINT_HOST_SLOTS=9 FM_LINT_HOST_RSS_KIB=30000 FM_LINT_ROOT_RSS_KIB=262144 HOLD=2
t0=$SECONDS
L --jobs 2 "$S/a.sh" "$S/b.sh" > "$S/1.out" 2>&1 & p1=$!
L --jobs 2 "$S/c.sh" "$S/d.sh" > "$S/2.out" 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
echo "run1 exit=$r1 run2 exit=$r2 roots_finished=$(count "$S/spans")/4 most_at_once=$(most "$S/spans") wall_s=$((SECONDS-t0))"
echo "# a waiter is SIGKILLed while queued; the holder ends; a later run is admitted at once"
: > "$S/spans"; : > "$S/spans.starts"
HOLD=8 L --jobs 1 "$S/a.sh" > "$S/h.out" 2>&1 & h=$!
wait_count "$S/spans.starts" 1 30 || echo "holder did not start"
HOLD=1 L --jobs 1 "$S/e.sh" > "$S/w.out" 2>&1 & w=$!
sleep 2; echo "starts while waiter is queued (expect 1): $(count "$S/spans.starts")"
tree() { local p=$1; echo "$p"; for c in $(pgrep -P "$p" 2>/dev/null); do tree "$c"; done; }
kill -KILL $(tree "$w") 2>/dev/null; wait "$w" 2>/dev/null; echo "waiter killed, exit=$?"
wait "$h"; echo "holder exit=$? roots_finished=$(count "$S/spans")"
t=$SECONDS; HOLD=0.2 L --jobs 1 "$S/e.sh" > "$S/later.out" 2>&1; echo "later run exit=$? seconds=$((SECONDS-t)) stand-in starts=$(count "$S/spans.starts")"
echo "tickets left in the pool: $(ls "$S/pool" | grep -c '^queue\.0')"
