#!/usr/bin/env bash
# Runs each named scenario test at the final head, one at a time, each with its own log.
E=$1; cd "$2" || exit 2
for t in test_memory_budget_bounds_the_aggregate_across_homes test_root_larger_than_the_budget_runs_alone_and_a_killed_run_frees_its_charge test_memory_charge_survives_unknown_records_and_an_unreadable_table test_slot_survives_gate_death test_slot_file_failures_refuse_and_never_run_unbounded test_slot_pool_can_be_disabled_or_misconfigured test_fast_record_does_not_lower_the_full_charge test_default_pool_is_one_directory_for_every_home test_unbounded_root_over_resident_bound_is_ended_and_retried_narrower test_memory_failure_retries_without_external_sources test_cached_success_does_not_wait_for_host_slots; do
  s=$SECONDS
  { echo "\$ bash tests/fm-lint-slots.test.sh $t"; echo "start $(date -u +%FT%TZ) load: $(uptime | sed 's/.*load/load/')"; bash tests/fm-lint-slots.test.sh "$t" 2>&1; rc=$?; echo "rc=$rc wall=$((SECONDS-s))s"; } > "$E/$t.log"
  echo "$t rc=$rc $((SECONDS-s))s" >> "$E/index.txt"
done
echo DONE >> "$E/index.txt"
