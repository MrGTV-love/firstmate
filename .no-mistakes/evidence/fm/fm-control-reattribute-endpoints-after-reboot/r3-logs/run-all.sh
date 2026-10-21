#!/usr/bin/env bash
cd "$1" || exit 1
E=$2
: > "$E/ALL-SUMMARY.txt"
for fn in test_omp_adoption_matching_workspace test_omp_adoption_foreign_workspace test_omp_adoption_duplicate_pane test_omp_adoption_ambiguous_foreground test_omp_adoption_generation_mismatch test_omp_adoption_current_session_contradiction test_omp_adoption_unproven_same_pid test_omp_adoption_non_agent_process test_omp_adoption_unreadable_environment test_omp_adoption_other_generation_pin test_omp_adoption_caller_gate test_omp_adoption_proof_boundaries test_omp_adoption_live_recorded_pid test_omp_adoption_publication_race test_proven_task_lifecycle_remains_available; do
  FM_TEST_ONLY=$fn nice -n 20 timeout 600 bash bin/fm-test-run.sh tests/fm-control-relaunch.test.sh > "$E/final-$fn.log" 2>&1
  echo "$fn exit=$?" >> "$E/ALL-SUMMARY.txt"
done
for t in tests/fm-launch-proof.test.sh tests/fm-control-reassociate.test.sh; do
  nice -n 20 timeout 600 bash bin/fm-test-run.sh "$t" > "$E/final-$(basename "$t").log" 2>&1
  echo "$t exit=$?" >> "$E/ALL-SUMMARY.txt"
done
FM_TEST_ONLY=test_task_session_proof_tracks_active_session nice -n 20 timeout 600 bash bin/fm-test-run.sh tests/fm-omp-harness.test.sh > "$E/final-omp-harness-proof.log" 2>&1
echo "omp-harness test_task_session_proof_tracks_active_session exit=$?" >> "$E/ALL-SUMMARY.txt"
echo DONE >> "$E/ALL-SUMMARY.txt"
