#!/usr/bin/env bash
# Live driver: runs the real bin/fm-pr-merge.sh end to end against a disposable
# fake GitHub (gh / gh-axi shims from tests/fm-pr-merge-helpers.sh, which defines
# no test cases) and inspects the persisted <id>.merge-authority record.
set -u
cd "$1"
. tests/fm-pr-merge-helpers.sh
G_UNK='{"ship":["gpt-5.1-codex"],"no-mistakes:unknown":["unknown"]}'
show() {  # <label> <case_dir> <rc>
  printf '\n=== %s ===\n  fm-pr-merge.sh exit: %s\n  stderr review lines:\n' "$1" "$3"
  grep -E '^(review:|error:)' "$2/stderr" | cut -c1-300 | sed 's/^/    /'
  printf '  gh merge call: %s\n' "$(grep '^pr merge ' "$2/gh.log" || echo none)"
  printf '  state/task-x1.merge-authority:\n'; sed 's/^/    | /' "$2/state/task-x1.merge-authority" 2>/dev/null || echo '    (absent)'
}
readrec() {  # <case_dir>
  bash -c 'FM_HOME="$2/home"; FM_STATE_OVERRIDE="$2/state"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-merge-authority-lib.sh";
    if fm_merge_authority_read "$2/state" task-x1 github github.com example/repo 9; then
      printf "  reader: FM_MERGE_AUTHORITY=%s FM_MERGE_AUTHORITY_REVIEW_FACT=[%s]\n" "$FM_MERGE_AUTHORITY" "$FM_MERGE_AUTHORITY_REVIEW_FACT"
    else printf "  reader: rc=%s FM_MERGE_AUTHORITY=%s (record rejected)\n" "$?" "$FM_MERGE_AUTHORITY"; fi' x "$PWD" "$1"
}
prep() {  # <name> -> case_dir, head
  case_dir=$(make_case "$1"); rm -f "$case_dir/fakebin/git"; : > "$case_dir/explicit-review"
  head=$(git -C "$case_dir/wt" rev-parse HEAD); url=https://github.com/example/repo/pull/9
  add_gh_mocks "$case_dir" "$head"
}

# M1: absent pipeline evidence, one outside-ship Claude PASS -> merge + fact in record.
prep m1; rm "$case_dir/user-home/.no-mistakes/state.sqlite"
record_review "$case_dir" "$url" "$head" --author-groups "$G_UNK" >/dev/null
rc=0; run_pr_merge "$case_dir" task-x1 "$url" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
show "M1 absent pipeline evidence + one Claude PASS (ship gpt-5.1-codex)" "$case_dir" "$rc"; readrec "$case_dir"

# M2: absent pipeline evidence, Claude + Gemini PASS -> merge, no fact line (six-line record).
prep m2; rm "$case_dir/user-home/.no-mistakes/state.sqlite"
record_review "$case_dir" "$url" "$head" --author-groups "$G_UNK" >/dev/null
record_review "$case_dir" "$url" "$head" --author-groups "$G_UNK" --reader-model gemini-3-pro >/dev/null
rc=0; run_pr_merge "$case_dir" task-x1 "$url" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
show "M2 absent pipeline evidence + Claude and Gemini PASS" "$case_dir" "$rc"; readrec "$case_dir"

# M3: readable pipeline DB with no matching run (no pipeline group) -> merge, no fact.
prep m3
record_review "$case_dir" "$url" "$head" >/dev/null
rc=0; run_pr_merge "$case_dir" task-x1 "$url" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
show "M3 readable pipeline DB, ship-only work, one Claude PASS" "$case_dir" "$rc"; readrec "$case_dir"

# M4: absent evidence, sole reader is same family as ship (gpt-5.1) -> refuse, no merge.
prep m4; rm "$case_dir/user-home/.no-mistakes/state.sqlite"
record_review "$case_dir" "$url" "$head" --author-groups "$G_UNK" --reader-model gpt-5.1 >/dev/null
rc=0; run_pr_merge "$case_dir" task-x1 "$url" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
show "M4 absent pipeline evidence + one same-family gpt-5.1 PASS" "$case_dir" "$rc"

# M5: corrupt pipeline DB (present but unreadable) + one Claude PASS -> refuse, no merge.
prep m5; printf 'garbage\n' > "$case_dir/user-home/.no-mistakes/state.sqlite"
record_review "$case_dir" "$url" "$head" --author-groups "$G_UNK" >/dev/null
rc=0; run_pr_merge "$case_dir" task-x1 "$url" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
show "M5 corrupt pipeline DB + one Claude PASS" "$case_dir" "$rc"

# R1/R2: record-format reader. Legacy six-line record readable; bogus 7th line rejected.
prep r1; mkdir -p "$case_dir/state"
printf '%s\n' fm-merge-authority-v1 github github.com example/repo 9 attended > "$case_dir/state/task-x1.merge-authority"; chmod 600 "$case_dir/state/task-x1.merge-authority"
printf '\n=== R1 legacy six-line record ===\n'; readrec "$case_dir"
printf '%s\n' 'forged extra line' >> "$case_dir/state/task-x1.merge-authority"
printf '\n=== R2 record with an unexpected 7th line ===\n'; readrec "$case_dir"
