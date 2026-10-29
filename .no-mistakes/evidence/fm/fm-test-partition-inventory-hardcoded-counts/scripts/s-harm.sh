. /Users/charlesabrooker/tmp/fm-partition-lab.PgO9oC/lib-scn.sh
first_reg() { awk -v r="$2" '$0 ~ "^[ \t]*" r "\\+?=\\($" {on=1; next} on && /^[ \t]*test_/ {gsub(/[ \t]/,""); print; exit}' "$1"; }
show() { git diff | grep '^[+-][^+-]' | head -12; }
echo "### H1 lost case: a test defined in tests/fm-pr-merge-forges.test.sh but never registered"
printf '\ntest_lab_orphan_case() {\n  pass "never runs"\n}\n' >> tests/fm-pr-merge-forges.test.sh; show
run test_pr_merge_groups_partition_one_inventory; reset
echo; echo "### H2 ghost case: tests/fm-lint-report.test.sh registers a test it never defines"
python3 - <<'PY'
import re;f='tests/fm-lint-report.test.sh';s=open(f).read();m=re.search(r'^fm_lint_test_cases=\(\n',s,re.M);open(f,'w').write(s[:m.end()]+'test_lab_ghost_case\n'+s[m.end():])
PY
show; run test_fm_lint_groups_partition_one_inventory; reset
echo; echo "### H3 copy that should have moved: a teardown case from fm-teardown.test.sh is also defined and registered in fm-teardown-pool.test.sh"
n=$(first_reg tests/fm-teardown.test.sh teardown_test_cases); echo "case: $n"
add_case tests/fm-teardown-pool.test.sh teardown_test_cases "$n"; sed -i '' "s/^  $n\$/$n/" tests/fm-teardown-pool.test.sh; show
run test_teardown_groups_register_each_case_once; runbase test_teardown_groups_register_each_case_once; reset
echo; echo "### H4 lost case: drop one real registration line from tests/fm-teardown-cleanup.test.sh, keep its definition"
n=$(first_reg tests/fm-teardown-cleanup.test.sh teardown_test_cases); echo "case: $n"
python3 - "$n" <<'PY'
import sys,re;f='tests/fm-teardown-cleanup.test.sh';n=sys.argv[1];s=open(f).read();m=re.search(r'^teardown_test_cases=\(\n',s,re.M);i=s.index('\n'+n+'\n',m.start());open(f,'w').write(s[:i]+s[i+len(n)+1:])
PY
show; run test_teardown_groups_register_each_case_once; reset
echo; echo "### H5 same name twice in one file: a new case in tests/fm-teardown-cleanup.test.sh reuses an existing name (bash keeps only the last body)"
n=$(first_reg tests/fm-teardown-cleanup.test.sh teardown_test_cases); echo "case: $n"
printf '\n%s() {\n  pass "second body"\n}\n' "$n" >> tests/fm-teardown-cleanup.test.sh; show
run test_teardown_groups_register_each_case_once; runbase test_teardown_groups_register_each_case_once; reset
echo; echo "### H6 false heredoc opener in a comment hides an unregistered case before a real <<'SH' heredoc (tests/fm-pr-merge-checks.test.sh)"
cat >> tests/fm-pr-merge-checks.test.sh <<'X'

# the stub is written with <<'SH' below
test_lab_hidden_case() {
  cat > /dev/null <<'SH'
x
SH
}
X
show; run test_pr_merge_groups_partition_one_inventory; runbase test_pr_merge_groups_partition_one_inventory; reset
echo; echo "### H7 control-relaunch: an unregistered case in tests/fm-control-relaunch-backends.test.sh that nothing calls"
printf '\ntest_lab_uncalled_case() {\n  pass "never runs"\n}\n' >> tests/fm-control-relaunch-backends.test.sh; show
run test_control_relaunch_groups_partition_one_inventory; runbase test_control_relaunch_groups_partition_one_inventory; reset
echo; echo "### H8 watch-triage: a helper case that no script calls"
printf '\ntest_lab_uncalled_wait() {\n  pass "never runs"\n}\n' >> tests/fm-watch-triage-helpers.sh; show
run test_watch_triage_waits_groups_partition_one_inventory; reset
echo; echo "### H9 watch-triage: one existing helper case called by two scripts"
n=$(grep -E '^test_[A-Za-z0-9_]+( \|\| exit \$\?)?$' tests/fm-watch-triage-waits.test.sh | head -1 | awk '{print $1}'); echo "case: $n"
echo "$n" >> tests/fm-watch-triage-waits-away.test.sh; show
run test_watch_triage_waits_groups_partition_one_inventory; reset
echo; echo "### H10 a stray script declares the fm-pr-merge registry but is not a listed group"
printf 'pr_merge_test_cases=(\ntest_lab_stray\n)\ntest_lab_stray() { :; }\n' > tests/fm-pr-merge-stray.test.sh; cat tests/fm-pr-merge-stray.test.sh
run test_pr_merge_groups_partition_one_inventory; reset
echo; echo "### H11 legit move: one case (definition + registration) moved from fm-pr-merge-checks to fm-pr-merge-forges"
n=$(first_reg tests/fm-pr-merge-checks.test.sh pr_merge_test_cases); echo "case: $n"
python3 - "$n" <<'PY'
import sys,re
n=sys.argv[1]; src='tests/fm-pr-merge-checks.test.sh'; dst='tests/fm-pr-merge-forges.test.sh'
s=open(src).read()
m=re.search(r'^'+n+r'\(\) \{\n.*?^\}\n',s,re.M|re.S); body=m.group(0); s=s[:m.start()]+s[m.end():]
r=re.search(r'^pr_merge_test_cases=\(\n',s,re.M); i=s.index('\n'+n+'\n',r.start()); s=s[:i]+s[i+len(n)+1:]
open(src,'w').write(s)
d=open(dst).read(); r=re.search(r'^pr_merge_test_cases=\(\n',d,re.M)
d=d[:r.start()]+body+'\n'+d[r.start():r.end()]+n+'\n'+d[r.end():]
open(dst,'w').write(d)
PY
git diff --stat; run test_pr_merge_groups_partition_one_inventory; reset
