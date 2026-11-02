#!/usr/bin/env bash
# Real bin/fm-pr-merge.sh with a gh shim: merge-single-owner and merge-auto-not-armed
# write deny on refusal and allow on the passing path.
set -u
. "$PWD/tests/fm-pr-merge-helpers.sh"
show() { jq -c 'select(.guard=="merge-single-owner" or .guard=="merge-auto-not-armed")|{guard,decision,rule,task,override,cleared_by}' "$1" 2>/dev/null; }
landing_home_config() { mkdir -p "$1/data" "$1/state" "$1/config"; fm_test_tasks_toml "$1/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$1/data/backlog.md"; printf 'maintainer %s\n' "$2" > "$1/config/firstmate-role"; }
hr() { printf '\n=== %s ===\n' "$1"; }
c=$(make_case r6-owner); main="$c/wt"; url=https://github.com/example/repo/pull/9
git -C "$main" remote add origin https://github.com/Example/Repo.git
add_gh_mocks "$c" "$(git -C "$main" rev-parse HEAD)"; landing_home_config "$main" github.com/example/repo
hr "O1 firstmate landing from another home: refused, single-owner deny"
rc=0; FM_GUARD_EVENT_LOG="$c/e1" FM_TEST_CODE_ROOT="$main" run_pr_merge "$c" task-x1 "$url" >"$c/o" 2>"$c/er" || rc=$?
echo "rc=$rc merged=$(grep -c 'pr merge' "$c/gh.log")"; show "$c/e1"
hr "O2 same PR from the Main landing home: merged, single-owner allow"
fm_write_meta "$main/state/task-x1.meta" "window=fm-task-x1" "worktree=$main" "project=$main" 'kind=ship' 'model=gpt-5.1-codex' 'branch=fm/fixture' 'mode=no-mistakes'
rc=0; FM_GUARD_EVENT_LOG="$c/e2" FM_TEST_CODE_ROOT="$main" FM_TEST_HOME="$main" FM_TEST_STATE="$main/state" run_pr_merge "$c" task-x1 "$url" >"$c/o" 2>"$c/er" || rc=$?
echo "rc=$rc merged=$(grep -c 'pr merge' "$c/gh.log")"; show "$c/e2"
head=1818181818181818181818181818181818181818
hr "A1 off-queue --auto on a CLEAN PR: merged, auto-not-armed allow"
c=$(make_case r6-auto-clean); add_gh_mocks "$c" "$head"
rc=0; FM_GUARD_EVENT_LOG="$c/e" run_pr_merge "$c" task-x1 https://github.com/example/repo/pull/188 --attended-override -- --auto --squash >"$c/o" 2>"$c/er" || rc=$?
echo "rc=$rc merged=$(grep -c 'pr merge' "$c/gh.log")"; show "$c/e"
hr "A2 off-queue --auto on a BLOCKED PR: refused, auto-not-armed deny"
c=$(make_case r6-auto-blocked); add_gh_mocks "$c" "$head"
jq -c '.mergeStateStatus = "BLOCKED"' "$c/github-view.json" > "$c/v.tmp" && mv "$c/v.tmp" "$c/github-view.json"
rc=0; FM_GUARD_EVENT_LOG="$c/e" run_pr_merge "$c" task-x1 https://github.com/example/repo/pull/188 --attended-override -- --auto --squash >"$c/o" 2>"$c/er" || rc=$?
echo "rc=$rc merged=$(grep -c 'pr merge' "$c/gh.log")"; show "$c/e"
