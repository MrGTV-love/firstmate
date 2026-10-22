#!/usr/bin/env bash
# Live driver: real bin/fm-pr-merge.sh + bin/fm-review-record.py against a
# disposable marked lab home (bin/fm-lab-home.sh) and a stubbed GitHub forge.
# No real forge call is made: gh/gh-axi on PATH are the local stubs.
set -u
REPO=$1 EV=$2
fail() { echo "STUB-FAIL: $*" >&2; exit 99; }
. "$EV/forge-stub-lib.sh"
HEAD_SHA=1111111111111111111111111111111111111111
OLD_SHA=2222222222222222222222222222222222222222
URL=https://github.com/example/repo/pull/9
OTHER=https://github.com/example/repo/pull/10
LABS=()
cleanup() { for l in "${LABS[@]}"; do rm -rf "$l"; done; }
trap cleanup EXIT

new_lab() {
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LABS+=("$LAB")
  "$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || fail "lab create"
  CASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-forge.XXXXXX"); LABS+=("$CASE")
  mkdir -p "$CASE/fakebin" "$LAB/data" "$LAB/config" "$LAB/state"
  git -C "$CASE" init -q -b main wt && printf 'x\n' > "$CASE/wt/README.md" && git -C "$CASE/wt" add README.md \
    && git -C "$CASE/wt" -c user.name=lab -c user.email=lab@example.invalid commit -qm init
  git -C "$CASE/wt" update-ref refs/remotes/origin/main "$(git -C "$CASE/wt" rev-parse HEAD)"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$LAB/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  printf '%s\n' window=fm-task-x1 "worktree=$CASE/wt" "project=$CASE/project" kind=ship mode=no-mistakes > "$LAB/state/task-x1.meta"
  printf '%s\n' state=MERGED merged=true queued=false base=main > "$CASE/github-outcome"
  : > "$CASE/github-rules"; : > "$CASE/gh.log"
  write_github_required "$CASE"
  add_gh_mocks "$CASE" "$HEAD_SHA"
}

rec() { # rec <args...> : run the recorder exactly as a relay lane would, from another cwd
  (cd / && env -u FM_STATE_OVERRIDE FM_HOME="$LAB" python3 "$REPO/bin/fm-review-record.py" "$@")
}
review() { local pr=$1 head=$2; shift 2
  rec review --pr "$pr" --head "$head" --verdict PASS --reader-model claude-opus-5-5 \
    --author-groups '{"all":["gpt-5.1-codex"]}' --loosens-deny-allow-list no --widens-guard no \
    --customer-data-billing-spend no --report /tmp/lab-review.md "$@"
}
merge() {
  env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" HOME="$CASE/user-home" PATH="$CASE/fakebin:$PATH" \
    FM_TEST_GH_LOG="$CASE/gh.log" FM_TEST_GH_AXI_LOG="$CASE/gh-axi.log" FM_TEST_GH_OUTCOME="$CASE/github-outcome" \
    FM_TEST_GH_RULES="$CASE/github-rules" FM_TEST_GH_VIEW_JSON="$CASE/github-view.json" \
    FM_TEST_GH_VIEW_CURRENT="$CASE/github-view-current.json" FM_TEST_GH_ROLLUP_RESPONSES="$CASE/none" \
    FM_TEST_GH_ROLLUP_CALLS="$CASE/rollup-calls" FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    FM_TEST_GH_HEAD="$CASE/github-head" FM_TEST_GH_RUNS="$CASE/github-runs.json" \
    FM_TEST_GH_RUNS_FIRST="$CASE/none" FM_TEST_GH_RUNS_CALLS="$CASE/runs-calls" \
    FM_TEST_GH_BRANCH="$CASE/github-branch.json" FM_TEST_GH_REQUIRED_RULES="$CASE/github-required-rules.json" \
    "$REPO/bin/fm-pr-merge.sh" task-x1 "$@"
}
show() { # show <name> <expect: merge|refuse> <merge args...>
  local name=$1 expect=$2 rc=0; shift 2
  echo "=== SCENARIO: $name (expect $expect)"
  echo "--- ledger $LAB/state/review-records.jsonl:"; cat "$LAB/state/review-records.jsonl" 2>/dev/null || echo "(no ledger)"
  echo "\$ FM_HOME=\$LAB bin/fm-pr-merge.sh task-x1 $*"
  merge "$@" > "$CASE/out" 2> "$CASE/err" || rc=$?
  echo "--- exit: $rc"; echo "--- stderr:"; sed 's/^/  /' "$CASE/err"; echo "--- stdout:"; sed 's/^/  /' "$CASE/out"
  echo "--- forge merge calls:"; grep '^pr merge ' "$CASE/gh.log" | sed 's/^/  /' || echo "  (none)"
  local merged=no; grep -q '^pr merge ' "$CASE/gh.log" && merged=yes
  if { [ "$expect" = merge ] && [ "$rc" = 0 ] && [ $merged = yes ]; } || { [ "$expect" = refuse ] && [ "$rc" != 0 ] && [ $merged = no ]; }; then
    echo "RESULT: PASS ($name)"; else echo "RESULT: FAIL ($name)"; fi
  echo
}
SCEN=${3:-all}
case "$SCEN" in
  merge)
    new_lab; show "S1 no review record at all" refuse "$URL"
    new_lab; review "$URL" "$HEAD_SHA" >/dev/null; show "S2 different-family PASS at live head (openai author, anthropic reader)" merge "$URL"
    new_lab; review "$URL" "$OLD_SHA" >/dev/null; show "S3 PASS names an older head" refuse "$URL"
    new_lab; review "$URL" "$HEAD_SHA" --author-groups '{"initial":["gpt-5.1-codex"],"fixes":["claude-sonnet-5-5"]}' >/dev/null; show "S4 reader family equals one author family" refuse "$URL"
    new_lab; review "$URL" "$HEAD_SHA" >/dev/null; review "$URL" "$HEAD_SHA" --verdict FAIL >/dev/null; show "S5 newest record is FAIL after an earlier PASS" refuse "$URL"
    new_lab; review "$URL" "$HEAD_SHA" --reader-model mistral-large >/dev/null; show "S6 reader model family unknown" refuse "$URL"
    new_lab; review "$OTHER" "$HEAD_SHA" >/dev/null; show "S7 --attended-override does not replace a missing PASS (other PR only)" refuse "$URL" --attended-override
    ;;
  captain)
    for t in loosens-deny-allow-list widens-guard customer-data-billing-spend; do
      new_lab; review "$URL" "$HEAD_SHA" "--$t" yes >/dev/null; show "C1 trigger $t=yes, no captain words" refuse "$URL"
    done
    new_lab; review "$URL" "$HEAD_SHA" --customer-data-billing-spend yes >/dev/null
      rec captain-word --pr "$OTHER" --head "$HEAD_SHA" --words 'Merge PR 10.' >/dev/null; show "C2 trigger yes, captain words are for a different PR" refuse "$URL"
    new_lab; review "$URL" "$HEAD_SHA" --customer-data-billing-spend yes >/dev/null
      rec captain-word --pr "$URL" --head "$OLD_SHA" --words 'Merge PR 9.' >/dev/null; show "C3 trigger yes, captain words name an older head" refuse "$URL"
    new_lab; review "$URL" "$HEAD_SHA" --customer-data-billing-spend yes >/dev/null
      rec captain-word --pr "$URL" --head "$HEAD_SHA" --words 'Merge PR 9 now; I accept the billing change.' >/dev/null
      echo "--- latest (stored captain words):"; rec latest --pr "$URL"; echo
      show "C4 trigger yes, captain words recorded at live head" merge "$URL"
    ;;
esac
