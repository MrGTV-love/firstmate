. /Users/charlesabrooker/tmp/fm-partition-lab.PgO9oC/lib-scn.sh
echo "### S0 sanity: unmodified copy of head, all five real-suite partition checks"; run $ALL
echo; echo "### S1 a PR adds ONE registered test to tests/fm-pr-merge-checks.test.sh (the PR 295-297 failure)"
add_case tests/fm-pr-merge-checks.test.sh pr_merge_test_cases test_lab_new_merge_case; git diff | grep '^[+-][^+-]'
run test_pr_merge_groups_partition_one_inventory; runbase test_pr_merge_groups_partition_one_inventory; reset
echo; echo "### S2 a PR adds ONE registered test to tests/fm-teardown-cleanup.test.sh"
add_case tests/fm-teardown-cleanup.test.sh teardown_test_cases test_lab_new_teardown_case; git diff | grep '^[+-][^+-]'
run test_teardown_groups_register_each_case_once; runbase test_teardown_groups_register_each_case_once; reset
echo; echo "### S3 a PR adds ONE registered test to tests/fm-control-relaunch-recovery.test.sh and one to tests/fm-lint-slots.test.sh"
add_case tests/fm-control-relaunch-recovery.test.sh control_relaunch_test_cases test_lab_new_relaunch_case
add_case tests/fm-lint-slots.test.sh fm_lint_test_cases test_lab_new_lint_case; git diff | grep '^[+-][^+-]'
run test_control_relaunch_groups_partition_one_inventory test_fm_lint_groups_partition_one_inventory; runbase test_control_relaunch_groups_partition_one_inventory test_fm_lint_groups_partition_one_inventory; reset
echo; echo "### S4 a PR adds ONE watch-triage case to the helper and calls it from tests/fm-watch-triage-waits-away.test.sh"
printf '\ntest_lab_new_wait_case() {\n  pass "lab"\n}\n' >> tests/fm-watch-triage-helpers.sh
last=$(grep -nE '^test_[A-Za-z0-9_]+( \|\| exit \$\?)?$' tests/fm-watch-triage-waits-away.test.sh | tail -1 | cut -d: -f1)
sed -i '' "${last}a\\
test_lab_new_wait_case
" tests/fm-watch-triage-waits-away.test.sh; git diff | grep '^[+-][^+-]'
run test_watch_triage_waits_groups_partition_one_inventory; runbase test_watch_triage_waits_groups_partition_one_inventory; reset
