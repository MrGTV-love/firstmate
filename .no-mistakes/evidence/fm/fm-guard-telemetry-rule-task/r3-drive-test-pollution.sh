#!/usr/bin/env bash
# Driver: the shared test harness keeps guard events out of the code checkout's
# own state/guard-events.jsonl. Runs tests/fm-spawn-batch.test.sh at HEAD, then
# again with the new tests/lib.sh default removed (temporary edit, restored).
set -u
WT=${1:?worktree}
cd "$WT"
CL=state/guard-events.jsonl
BK=$(mktemp)
cp "$CL" "$BK"
U=(env -u FM_HOME -u FM_GUARD_EVENT_LOG -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE)
echo "# HEAD $(git rev-parse --short HEAD): tests/fm-spawn-batch.test.sh; code-root log = $WT/$CL"
echo "before: rows=$(wc -l <"$CL" | tr -d ' ') cksum=$(cksum <"$CL")"
"${U[@]}" bin/fm-proc-budget.sh --own-procs 256 -- bash tests/fm-spawn-batch.test.sh > /tmp/fm-pol1.$$ 2>&1
echo "suite exit=$?"
grep -E 'PASS|FAIL|ok|not ok' /tmp/fm-pol1.$$ | tail -8 | cut -c1-200
echo "after:  rows=$(wc -l <"$CL" | tr -d ' ') cksum=$(cksum <"$CL")"
echo
echo "# FAIL-BEFORE: same suite with the tests/lib.sh FM_GUARD_EVENT_LOG default removed"
python3 - <<'PY'
p = "tests/lib.sh"
s = open(p).read()
a = 'FM_GUARD_EVENT_LOG="$FM_TEST_SHELL_DIR/guard-events.jsonl"\nexport FM_GUARD_EVENT_LOG\n'
assert a in s
open(p, "w").write(s.replace(a, ""))
PY
echo "lib.sh default removed: $(git diff --numstat -- tests/lib.sh)"
"${U[@]}" bin/fm-proc-budget.sh --own-procs 256 -- bash tests/fm-spawn-batch.test.sh > /tmp/fm-pol2.$$ 2>&1
echo "suite exit=$?"
grep -E 'FAIL|code checkout|not recorded' /tmp/fm-pol2.$$ | tail -4 | cut -c1-260
echo "after:  rows=$(wc -l <"$CL" | tr -d ' ') (rows the suite wrote to the code-root log without the fix)"
echo "new rows by kind:"
tail -n +$(( $(wc -l <"$BK") + 1 )) "$CL" | jq -c '{guard,decision,rule,override}' | sort | uniq -c
git checkout -- tests/lib.sh
cp "$BK" "$CL"
rm -f "$BK" /tmp/fm-pol1.$$ /tmp/fm-pol2.$$
echo "restored: lib.sh changes=$(git diff --numstat -- tests/lib.sh | wc -l | tr -d ' ') code-root rows=$(wc -l <"$CL" | tr -d ' ')"
