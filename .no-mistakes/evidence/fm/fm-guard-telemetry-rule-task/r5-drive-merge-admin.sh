#!/usr/bin/env bash
# Real bin/fm-pr-merge.sh, gh shim forge: --attended-override that admits --admin, and --admin refused without it.
set -u
. "$PWD/tests/fm-pr-merge-helpers.sh"
head=a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5; url=https://github.com/example/repo/pull/197
show() { jq -c 'select(.guard=="merge-away-waiver")|{guard,decision,rule,task,override}' "$1" 2>/dev/null; echo "   merge-away-waiver rows: $(jq -s '[.[]|select(.guard=="merge-away-waiver")]|length' "$1" 2>/dev/null || echo 0)"; }
echo "=== M4b -- --admin without --attended-override: refused ==="
c=$(make_case r5-admin-refused); add_gh_mocks "$c" "$head"
rc=0; FM_GUARD_EVENT_LOG="$c/e" run_pr_merge "$c" task-x1 "$url" -- --admin >"$c/o" 2>"$c/er" || rc=$?; echo "rc=$rc merged=$(grep -c 'pr merge' "$c/gh.log") | $(grep -m1 -i 'admin' "$c/er" | cut -c1-140)"; show "$c/e"
echo "=== M4c --attended-override -- --admin: merged, one bypass with override ==="
c=$(make_case r5-admin-admitted); add_gh_mocks "$c" "$head"
rc=0; FM_GUARD_EVENT_LOG="$c/e" run_pr_merge "$c" task-x1 "$url" --attended-override -- --admin >"$c/o" 2>"$c/er" || rc=$?; echo "rc=$rc merged=$(grep -c 'pr merge' "$c/gh.log")"; show "$c/e"
