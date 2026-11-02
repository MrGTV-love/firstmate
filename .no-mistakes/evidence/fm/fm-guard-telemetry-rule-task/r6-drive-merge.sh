#!/usr/bin/env bash
# Real bin/fm-pr-merge.sh (split merge guards) with a throwaway gh shim as the forge.
# Run from a checkout root: the worktree (head) or an extracted base tree.
set -u
. "$PWD/tests/fm-pr-merge-helpers.sh"
show() { jq -c 'select(.guard|test("^merge-"))|{guard,decision,rule,task,override,head:(.head//""|.[0:7]),base,opportunity}' "$1" 2>/dev/null; }
ALL=$(mktemp); head=a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5; url=https://github.com/example/repo/pull/96
hr() { printf '\n=== %s ===\n' "$1"; }
hr "M1 red check, no waiver: refused"
c=$(make_case r6-red); mkdir -p "$c/wt"; add_gh_mocks "$c" "$head"
write_github_rollup_json "$c" "$head" "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:09Z)"
rc=0; FM_GUARD_EVENT_LOG="$c/e" run_pr_merge "$c" task-x1 "$url" >"$c/o" 2>"$c/er" || rc=$?; echo "rc=$rc merged=$(grep -c 'pr merge' "$c/gh.log")"; show "$c/e"; cat "$c/e" >>"$ALL" 2>/dev/null
hr "M2 same red check, --allow-red lint: merged, bypass with override"
c=$(make_case r6-allowred); mkdir -p "$c/wt"; add_gh_mocks "$c" "$head"
write_github_rollup_json "$c" "$head" "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:09Z)"
rc=0; FM_GUARD_EVENT_LOG="$c/e" run_pr_merge "$c" task-x1 "$url" --allow-red lint >"$c/o" 2>"$c/er" || rc=$?; echo "rc=$rc merged=$(grep -c 'pr merge' "$c/gh.log")"; show "$c/e"; cat "$c/e" >>"$ALL" 2>/dev/null
hr "M3 required check absent, no waiver: refused"
c=$(make_case r6-missing); add_gh_mocks "$c" "$head"; write_github_required "$c" classic:ci ruleset:validate
FM_GUARD_EVENT_LOG="$c/e" run_required_case "$c" 96; echo "rc=$RC merged=$(grep -c 'pr merge' "$c/gh.log")"; show "$c/e"; cat "$c/e" >>"$ALL" 2>/dev/null
hr "M4 required check absent, --allow-missing validate: merged, bypass with override"
c=$(make_case r6-allowmissing); add_gh_mocks "$c" "$head"; write_github_required "$c" classic:ci ruleset:validate
FM_GUARD_EVENT_LOG="$c/e" run_required_case "$c" 96 --allow-missing validate; echo "rc=$RC merged=$(grep -c 'pr merge' "$c/gh.log")"; show "$c/e"; cat "$c/e" >>"$ALL" 2>/dev/null
hr "M5 away record, --attended-override: merged, merge-away-waiver bypass"
c=$(make_case r6-attended); mkdir -p "$c/wt" "$c/home"; add_gh_mocks "$c" "$head"; write_away_record "$c" --words 'merge it when green'
rc=0; FM_GUARD_EVENT_LOG="$c/e" FM_TEST_HOME="$c/home" run_pr_merge "$c" task-x1 "$url" --attended-override >"$c/o" 2>"$c/er" || rc=$?; echo "rc=$rc merged=$(grep -c 'pr merge' "$c/gh.log")"; show "$c/e"; cat "$c/e" >>"$ALL" 2>/dev/null
hr "M6 green head, no waiver: merged, one allow per rule"
c=$(make_case r6-green); mkdir -p "$c/wt"; add_gh_mocks "$c" "$head"
rc=0; FM_GUARD_EVENT_LOG="$c/e" run_pr_merge "$c" task-x1 "$url" >"$c/o" 2>"$c/er" || rc=$?; echo "rc=$rc merged=$(grep -c 'pr merge' "$c/gh.log")"; show "$c/e"; cat "$c/e" >>"$ALL" 2>/dev/null
hr "M7 event log is a directory while the waiver merges: same merge outcome"
c=$(make_case r6-badlog); mkdir -p "$c/wt" "$c/logdir"; add_gh_mocks "$c" "$head"
write_github_rollup_json "$c" "$head" "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:09Z)"
rc=0; FM_GUARD_EVENT_LOG="$c/logdir" run_pr_merge "$c" task-x1 "$url" --allow-red lint >"$c/o" 2>"$c/er" || rc=$?; echo "rc=$rc merged=$(grep -c 'pr merge' "$c/gh.log")"
if [ -x "$ROOT/bin/fm-guard-metrics.sh" ] && [ -s "$ALL" ]; then
hr "Metrics on the combined rows"
"$ROOT/bin/fm-guard-metrics.sh" --log "$ALL" --guards merge-checks-green,merge-required-reported,merge-landing-tree-tested,merge-away-waiver | cut -c1-300
fi
rm -f "$ALL"
