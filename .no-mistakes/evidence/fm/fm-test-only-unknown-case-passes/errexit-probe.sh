#!/usr/bin/env bash
# Probe the errexit state each case starts with, single-case vs multi-case, in a throwaway head tree.
set -u
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M639BN2X5M4ZFE83EXBJA579
T=$1; B="$W/bin/fm-proc-budget.sh"
probe() {  # <file> <case>
  perl -0pi -e "s/(\\n$2\\(\\) [({]\\n)/\$1  printf 'ERREXIT-PROBE %s errexit=%s\\\\n' '$2' \"\\\${-\\/\\/[!e]\\/}\" >&2  # probe\\n/" "$T/tests/$1"
  grep -q "ERREXIT-PROBE.*$2" "$T/tests/$1" || echo "probe not inserted: $1 $2"
}
probe fm-captain-hold-reconcile.test.sh test_reconcile_never_closes_through_the_keyed_answer_intake
probe fm-captain-hold-reconcile.test.sh test_legitimate_holds_produce_no_divergence_signal
probe fm-teardown-pool.test.sh test_reassigned_dirty_slot_retires_only_finished_task
probe fm-teardown-pool.test.sh test_subordinate_slot_cleanup_preserves_ancestor_custody
cd "$T"
run() { echo "\$ bash tests/$*"; out=$("$B" -- bash "tests/$@" 2>&1); rc=$?; printf '%s\n' "$out" | grep -E 'ERREXIT-PROBE|^ok|FAIL|changed errexit' | sed 's/^/   | /'; echo "   exit=$rc"; }
run fm-captain-hold-reconcile.test.sh test_legitimate_holds_produce_no_divergence_signal
run fm-captain-hold-reconcile.test.sh test_reconcile_never_closes_through_the_keyed_answer_intake test_legitimate_holds_produce_no_divergence_signal
run fm-teardown-pool.test.sh test_subordinate_slot_cleanup_preserves_ancestor_custody
run fm-teardown-pool.test.sh test_reassigned_dirty_slot_retires_only_finished_task test_subordinate_slot_cleanup_preserves_ancestor_custody
cd "$W"
echo "\$ bash tests/fm-captain-hold-sweep.test.sh test_sweep_retires_only_finished_board_listeners test_auto_sweep_retires_only_finished_listeners   (the CI-red pair, unmodified head)"
out=$("$B" -- bash tests/fm-captain-hold-sweep.test.sh test_sweep_retires_only_finished_board_listeners test_auto_sweep_retires_only_finished_listeners 2>&1); rc=$?
printf '%s\n' "$out" | grep -E '^ok|FAIL' | sed 's/^/   | /'; echo "   exit=$rc"
