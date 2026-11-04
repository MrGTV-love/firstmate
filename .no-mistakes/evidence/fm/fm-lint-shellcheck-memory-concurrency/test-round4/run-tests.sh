#!/usr/bin/env bash
# Each named scenario test at head, one at a time, each with its own log.
R=$1 WT=$2 LAB=$3; cd "$WT" || exit 2
: > "$R/index.txt"
for t in test_slow_ps_does_not_hold_admission_against_the_next_root test_stopped_head_waiter_does_not_block_the_queue test_stopped_admission_coordinator_does_not_freeze_free_capacity test_host_waiters_make_progress_without_barging test_unequal_runs_share_scarce_slots_per_run test_memory_budget_bounds_the_aggregate_across_homes test_root_larger_than_the_budget_runs_alone_and_a_killed_run_frees_its_charge test_memory_charge_survives_unknown_records_and_an_unreadable_table test_slot_survives_gate_death test_slot_file_failures_refuse_and_never_run_unbounded test_slot_pool_can_be_disabled_or_misconfigured test_fast_record_does_not_lower_the_full_charge test_default_pool_is_one_directory_for_every_home test_unbounded_root_over_resident_bound_is_ended_and_retried_narrower test_memory_failure_retries_without_external_sources test_cached_success_does_not_wait_for_host_slots; do
  s=$SECONDS
  { echo "\$ bash tests/fm-lint-slots.test.sh $t"; echo "start $(date -u +%FT%TZ) load: $(uptime | sed 's/.*load/load/')"; bash tests/fm-lint-slots.test.sh "$t" 2>&1; rc=$?; echo "rc=$rc wall=$((SECONDS-s))s"; } > "$R/$t.log"
  echo "$t rc=$rc $((SECONDS-s))s" >> "$R/index.txt"
done
# The new regression test against the commit before the fix: it must fail there.
t=test_slow_ps_does_not_hold_admission_against_the_next_root; s=$SECONDS
{ echo "\$ (pre-fix bin, head test) bash tests/fm-lint-slots.test.sh $t"; (cd "$LAB/regress" && bash tests/fm-lint-slots.test.sh "$t") 2>&1; rc=$?; echo "rc=$rc wall=$((SECONDS-s))s"; } > "$R/regress-new-test-on-prefix.log"
echo "regress-new-test-on-prefix rc=$rc $((SECONDS-s))s" >> "$R/index.txt"
echo DONE >> "$R/index.txt"
