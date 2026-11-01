#!/usr/bin/env bash
# Targeted suites, each under the per-tree process budget, serially.
cd "$1" || exit 1
EV=$2
run() { local name=$1; shift; local t0=$SECONDS rc=0
  bin/fm-proc-budget.sh --own-procs 128 -- "$@" >"$EV/suite-$name.log" 2>&1 || rc=$?
  printf '%s rc=%s ok=%s notok=%s secs=%s\n' "$name" "$rc" "$(grep -c '^ok\|^PASS\|^  ok' "$EV/suite-$name.log")" "$(grep -c 'not ok\|^FAIL' "$EV/suite-$name.log")" $((SECONDS-t0)) >>"$EV/suites-summary.txt"; }
: >"$EV/suites-summary.txt"
run guard-telemetry bash tests/fm-guard-telemetry.test.sh
run spawn-batch bash tests/fm-spawn-batch.test.sh
run spawn-worktree-settle bash tests/fm-spawn-worktree-settle.test.sh
run teardown-pool-late-recheck bash tests/fm-teardown-pool.test.sh test_pool_return_rechecks_work_after_waiting_for_project_custody
run teardown-cleanup-force bash tests/fm-teardown-cleanup.test.sh test_local_only_force_overrides_unpushed
run pr-merge-checks bash tests/fm-pr-merge-checks.test.sh
run spawn-compact-adviser-disable bash tests/fm-spawn-compact-adviser-disable.test.sh
run spawn-claude-api-key-guard bash tests/fm-spawn-claude-api-key-guard.test.sh
run secondmate-sync bash tests/fm-secondmate-sync.test.sh
echo DONE >>"$EV/suites-summary.txt"
