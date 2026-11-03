#!/usr/bin/env bash
# Adversarial live drive: many housekeeping passes at once on one green uncovered PR.
# Real bin/fm-pr-ready-reconcile.sh, fm-pr-auto-review.py, fm-review-record.py, fm-pr-merge.sh;
# FAKE forge (gh mocks) and FAKE review runner from the suite's fixtures.
WT=$1
. "$WT/tests/fm-pr-merge-helpers.sh"
src=$(mktemp)
sed -n '/^# --- automatic exact-head review and merge/,/^test_auto_review_green_uncovered_pr_is_read_recorded_and_merged()/p' "$WT/tests/fm-pr-merge.test.sh" | sed '$d' > "$src"
. "$src"
saved=$PR_MERGE
recon() { PR_MERGE=$ROOT/bin/fm-pr-ready-reconcile.sh; FM_AUTO_CASE="$1" FM_PR_AUTO_REVIEW_INTERVAL=0 FM_PR_READY_RECONCILE_TIMEOUT=60 run_pr_merge "$1" > "$1/pass.$2.out" 2>&1; echo "pass $2 rc=$?"; PR_MERGE=$saved; }
c=$(auto_case concurrent)
echo "== scenario A: 6 housekeeping passes started at the same moment, read not yet returned"
for i in 1 2 3 4 5 6; do recon "$c" "$i" & done; wait
auto_wait "$c"
echo "reads requested (fake runner argv lines): $(auto_calls "$c")"
sed "s#$TMP_ROOT#<tmp>#g" "$c/runner.calls"
echo "state now: $(auto_state "$c")"
echo "== scenario B: 6 housekeeping passes at once after the read returned"
for i in 7 8 9 10 11 12; do recon "$c" "$i" & done; wait
echo "reads requested: $(auto_calls "$c")"
echo "review records: $(auto_reviews "$c")"
echo "forge merge calls: $(auto_merges "$c")"
grep '^pr merge ' "$c/gh.log" | sed "s#$TMP_ROOT#<tmp>#g"
echo "state now: $(auto_state "$c" | sed "s#$TMP_ROOT#<tmp>#g")"
echo "events:"; sed "s#$TMP_ROOT#<tmp>#g;s/^/  /" "$(auto_event_file "$c")"
echo "pass outputs (non-empty):"; for f in "$c"/pass.*.out; do [ -s "$f" ] && { echo "-- $(basename "$f")"; sed "s#$TMP_ROOT#<tmp>#g" "$f"; }; done
rm -f "$src"
[ "$(auto_calls "$c")" = 1 ] && [ "$(auto_reviews "$c")" = 1 ] && [ "$(auto_merges "$c")" = 1 ] && echo RESULT: PASS || echo RESULT: FAIL
