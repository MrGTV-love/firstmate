#!/usr/bin/env bash
# --attended-override that admits a protected forge arg (-- --auto --merge): bypass row with override.
set -u
. "$PWD/tests/fm-pr-merge-helpers.sh"
show() { jq -c 'select(.guard|test("^merge-"))|{guard,decision,rule,task,override}' "$1" 2>/dev/null; }
for mode in "no waiver" "--attended-override"; do
  printf '\n=== %s -- --auto --merge ===\n' "$mode"
  c=$(make_case "r6-att-${mode//[^a-z]/}"); mkdir -p "$c/wt"; add_gh_mocks "$c" 8181818181818181818181818181818181818181
  write_github_outcome "$c" MERGED true false main; printf 'merge_method=MERGE\n' > "$c/github-rules"
  args=(); [ "$mode" = "no waiver" ] || args=(--attended-override)
  rc=0; FM_GUARD_EVENT_LOG="$c/e" run_pr_merge "$c" task-x1 https://github.com/example/repo/pull/68 ${args[@]+"${args[@]}"} -- --auto --merge >"$c/o" 2>"$c/er" || rc=$?
  echo "rc=$rc forge merge calls=$(grep -c 'pr merge' "$c/gh.log" 2>/dev/null)"; grep -m2 -iE 'refus|protected|attended' "$c/er" | cut -c1-200
  show "$c/e" | grep -E 'away|bypass|deny' || echo "(no away/bypass/deny rows)"
done
