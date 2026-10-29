LAB=/Users/charlesabrooker/tmp/fm-partition-lab.PgO9oC; C=$LAB/copy; HEADSRC=$C/tests/fm-test-run.test.sh; BASESRC=$LAB/base-fm-test-run.test.sh
W=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M62AT670B59Q7V6NJSKQ39G3
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M62AT670B59Q7V6NJSKQ39G3
ALL="test_teardown_groups_register_each_case_once test_control_relaunch_groups_partition_one_inventory test_watch_triage_waits_groups_partition_one_inventory test_pr_merge_groups_partition_one_inventory test_fm_lint_groups_partition_one_inventory"
cd "$C"
reset() { git -C "$C" checkout -q -- . ; git -C "$C" clean -qfd; }
run() { echo "--- head checker:"; "$W/bin/fm-proc-budget.sh" -- "$LAB/drive.sh" "$C" "$HEADSRC" "$@" 2>&1; echo "exit=$?"; }
runbase() { echo "--- base checker (commit 87351484b, before the change):"; "$W/bin/fm-proc-budget.sh" -- "$LAB/drive.sh" "$C" "$BASESRC" "$@" 2>&1; echo "exit=$?"; }
add_case() { python3 - "$@" <<'PY'
import sys,re
f,reg,name=sys.argv[1:4]
s=open(f).read()
m=re.search(r'^[ \t]*'+reg+r'\+?=\(\n',s,re.M)
s=s[:m.end()]+'  '+name+'\n'+s[m.end():]
ls=s.rfind('\n',0,m.start())+1
s=s[:ls]+name+'() {\n  pass "%s"\n}\n\n' % name+s[ls:]
open(f,'w').write(s)
PY
}
