#!/usr/bin/env bash
# Drives the real bin/fm-pr-merge.sh CLI against a disposable fake GitHub
# (the gh/gh-axi forge emulation from tests/fm-pr-merge.test.sh) for the
# reviewDecision scenarios. Usage: review-required-scenarios.sh <worktree> <base-bin-root>
set -u
WT=$1 BASE_ROOT=$2
. "$WT/tests/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
# The test file's helpers only (fixture builders, fake gh, run_pr_merge).
HELPERS=$(mktemp "${TMPDIR:-/tmp}/fm-rr-helpers.XXXXXX")
sed -n '15,784p' "$WT/tests/fm-pr-merge.test.sh" > "$HELPERS"
. "$HELPERS"; rm -f "$HELPERS"
NEW_ROOT=$ROOT
HEAD_SHA=5555555555555555555555555555555555555555
URL=https://github.com/example/repo/pull/86

# run_case <name> <script-root> <jq-edit>
run_case() {
  local name=$1 root=$2 edit=$3 case_dir rc
  shift 3
  case_dir=$(make_case "$name")
  add_gh_mocks "$case_dir" "$HEAD_SHA"
  jq -c "$edit" "$case_dir/github-view.json" > "$case_dir/v.tmp" && mv "$case_dir/v.tmp" "$case_dir/github-view.json"
  : > "$case_dir/gh.log"; : > "$case_dir/gh-axi.log"
  ROOT=$root PR_MERGE="$root/bin/fm-pr-merge.sh"
  set +e
  run_pr_merge "$case_dir" task-x1 "$URL" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  ROOT=$NEW_ROOT
  echo "=================================================================="
  echo "SCENARIO: $name"
  echo "script:   $root/bin/fm-pr-merge.sh"
  echo "live view (gh pr view --json ...): $(jq -c 'del(.statusCheckRollup)' "$case_dir/github-view.json")"
  echo "extra args: ${*:-(none)}"
  echo "exit code: $rc"
  echo "--- stdout"; cat "$case_dir/stdout"
  echo "--- stderr"; cat "$case_dir/stderr"
  echo "--- forge calls that merge (gh.log lines with 'pr merge'):"
  grep -F 'pr merge' "$case_dir/gh.log" || echo "(none: gh pr merge never ran)"
  echo "--- task meta after run:"; cat "$case_dir/state/task-x1.meta"
  set +e
}

set +e
run_case new-review-required        "$NEW_ROOT"  '.reviewDecision = "REVIEW_REQUIRED"'
run_case base-review-required       "$BASE_ROOT" '.reviewDecision = "REVIEW_REQUIRED"'
run_case new-approved               "$NEW_ROOT"  '.reviewDecision = "APPROVED"'
run_case new-no-review-policy-empty "$NEW_ROOT"  '.reviewDecision = ""'
run_case new-review-key-absent      "$NEW_ROOT"  'del(.reviewDecision)'
run_case new-review-null            "$NEW_ROOT"  '.reviewDecision = null'
run_case new-review-required-plus-draft-dirty-red "$NEW_ROOT" '.reviewDecision = "REVIEW_REQUIRED" | .isDraft = true | .mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY" | .statusCheckRollup[0].conclusion = "FAILURE"'
run_case new-review-required-mergeable-unknown "$NEW_ROOT" '.reviewDecision = "REVIEW_REQUIRED" | .mergeable = "UNKNOWN"'
run_case new-review-required-attended-override "$NEW_ROOT" '.reviewDecision = "REVIEW_REQUIRED"' --attended-override
