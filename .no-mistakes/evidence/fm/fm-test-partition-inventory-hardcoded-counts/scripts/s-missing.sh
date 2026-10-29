. /Users/charlesabrooker/tmp/fm-partition-lab.PgO9oC/lib-scn.sh
echo; echo "### H12 a listed group file disappears (tests/fm-lint-slots.test.sh removed)"
rm tests/fm-lint-slots.test.sh; git status --short
run test_fm_lint_groups_partition_one_inventory; reset
echo; echo "### after reset: copy is clean again"; git status --short; run $ALL
