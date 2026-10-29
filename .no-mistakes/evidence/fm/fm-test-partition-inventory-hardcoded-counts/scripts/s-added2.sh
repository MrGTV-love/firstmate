. /Users/charlesabrooker/tmp/fm-partition-lab.PgO9oC/lib-scn.sh
echo "### S2b a PR adds ONE registered test to tests/fm-teardown-cleanup.test.sh, written in that file's own unindented registry style"
add_case tests/fm-teardown-cleanup.test.sh teardown_test_cases test_lab_new_teardown_case
sed -i '' 's/^  test_lab_new_teardown_case$/test_lab_new_teardown_case/' tests/fm-teardown-cleanup.test.sh; git diff | grep '^[+-][^+-]'
run test_teardown_groups_register_each_case_once; runbase test_teardown_groups_register_each_case_once; reset
