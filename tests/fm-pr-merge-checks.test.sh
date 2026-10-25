#!/usr/bin/env bash
# bin/fm-pr-merge.sh's check evidence: check runs and status contexts, the
# required set from branch protection and rulesets, rollup pagination and
# supersession, the named waivers, and the away-posture authority that decides
# whether a green head may merge.
# The authority and GitHub outcome cases live in tests/fm-pr-merge.test.sh;
# the GitLab and Forgejo cases live in tests/fm-pr-merge-forges.test.sh.
# Shared fixtures: tests/fm-pr-merge-helpers.sh.

# shellcheck source=tests/fm-pr-merge-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pr-merge-helpers.sh"

# Recorded the same day, PR 3197: the copy rested on PR 3202's head, that PR
# merged, and its branch was deleted, so the head named by the copy was no
# longer on any remote ref.
test_multi_pr_task_merges_named_pr_when_copy_head_is_a_merged_siblings_head() {
  local case_dir forge_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  case_dir=$(make_direct_pr_local_tip_case multi-pr-merged-sibling)
  add_gh_mocks "$case_dir" "$forge_head"
  printf 'pr=%s\n' https://github.com/example/repo/pull/3202 >> "$case_dir/state/task-x1.meta"
  printf '%s\n' fm-pr-poll-merge-notified-v1 github github.com example/repo 3202 \
    > "$case_dir/state/task-x1.pr-poll-merge-notified"
  chmod 600 "$case_dir/state/task-x1.pr-poll-merge-notified"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/3197 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "multi-pr-merged-sibling: the named green PR was refused: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 3197 example/repo --squash
  assert_grep "pr=https://github.com/example/repo/pull/3197" "$case_dir/state/task-x1.meta" \
    "multi-pr-merged-sibling: the named PR was not recorded"
  pass "a multi-PR task merges the named green PR after a sibling merged and lost its branch"
}

# A task with one PR is judged exactly as before: a HEAD that only the copy
# holds is refused even though the forge reports the PR's head.
test_single_pr_task_with_a_local_only_head_is_still_refused() {
  local case_dir tip rc
  case_dir=$(make_direct_pr_local_tip_case single-pr-local-tip)
  tip=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  write_ready_reports "$case_dir" https://github.com/example/repo/pull/3197

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/3197 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "single-pr-local-tip: a head only the copy holds must refuse"
  assert_grep "named head $tip is unreachable outside the worker copy" "$case_dir/stderr" \
    "single-pr-local-tip: the refusal did not name the local-only head"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "single-pr-local-tip: gh pr merge ran on a refused claim"
  pass "a single-PR task whose copy HEAD exists only locally is still refused at merge"
}

# The forge must report the named PR's head. Without it the claim is judged on
# the copy's HEAD, which a never-pushed commit fails whatever else the task owns.
test_multi_pr_task_without_a_reported_forge_head_is_still_refused() {
  local case_dir tip rc
  case_dir=$(make_direct_pr_local_tip_case multi-pr-no-forge-head)
  tip=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  rm -f "$case_dir/github-head"
  write_ready_reports "$case_dir" \
    https://github.com/example/repo/pull/3196 \
    https://github.com/example/repo/pull/3197

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/3197 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "multi-pr-no-forge-head: an unreported forge head must refuse"
  assert_grep "named head $tip is unreachable outside the worker copy" "$case_dir/stderr" \
    "multi-pr-no-forge-head: the refusal did not name the local-only head"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "multi-pr-no-forge-head: gh pr merge ran with no forge head"
  pass "a multi-PR task whose named PR reports no forge head is still refused at merge"
}

# Judging the PR's own head does not loosen the live checks: a red head still
# refuses, and the merge is bound to the forge head that was verified.
test_multi_pr_task_with_a_red_head_is_still_refused() {
  local case_dir rc head=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  case_dir=$(make_direct_pr_local_tip_case multi-pr-red-head)
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_ready_reports "$case_dir" \
    https://github.com/example/repo/pull/3196 \
    https://github.com/example/repo/pull/3197

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/3197 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "multi-pr-red-head: a red head must refuse"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "multi-pr-red-head: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "multi-pr-red-head: gh pr merge ran on a red PR"
  pass "a multi-PR task's red PR head is still refused at merge"
}

# A draft cannot be merged, and neither can a pull request whose draft state the
# forge did not report as a boolean; both refuse before any merge call.
test_github_draft_or_unreadable_draft_state_refuses() {
  local case_dir rc head label filter
  head=dddddddddddddddddddddddddddddddddddddddd
  for label in draft unreadable; do
    case_dir=$(make_case "github-$label")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    case "$label" in
      draft) filter='.isDraft = true' ;;
      *) filter='del(.isDraft)' ;;
    esac
    jq -c "$filter" "$case_dir/github-view.json" > "$case_dir/github-view.tmp"
    mv "$case_dir/github-view.tmp" "$case_dir/github-view.json"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-$label: a pull request not read as non-draft must refuse"
    assert_grep "the pull request is a draft" "$case_dir/stderr" \
      "github-$label: the draft state was not named"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-$label: gh pr merge ran without a non-draft reading"
    assert_no_grep 'declare a wait instead of done' "$case_dir/stderr" \
      "github-$label: the arm-time draft refusal preempted the merge refusal"
    grep -qxF 'pr=https://github.com/example/repo/pull/82' "$case_dir/state/task-x1.meta" \
      || fail "github-$label: pr= was not recorded before the merge refusal"
  done
  pass "fm-pr-merge refuses a draft pull request and one with no boolean draft state"
}

# When the base branch advances, GitHub cancels a pull request's in-flight run
# and re-triggers it, leaving the cancelled run in the rollup beside the passing
# re-run while reporting the pull request itself CLEAN. The merge must follow the
# current run rather than the one that re-run replaced.
test_superseded_failed_check_run_no_longer_refuses() {
  local case_dir head
  head=cccccccccccccccccccccccccccccccccccccccc
  case_dir=$(make_case github-superseded-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED CANCELLED 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/90 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-superseded-red: a failed run replaced by a passing re-run must merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 90 example/repo --squash
  pass "fm-pr-merge merges when a failed check run was replaced by a passing re-run"
}

# Legacy status contexts remain independent from check runs, even when their
# reported names match.
test_check_runs_never_supersede_status_contexts() {
  local case_dir rc head
  head=cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd
  case_dir=$(make_case github-cross-check-kind)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(status_context ci FAILURE)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/97 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-cross-check-kind: a failing status context must refuse"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-cross-check-kind: the status context was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-cross-check-kind: a passing check run hid a failing status context"
  pass "fm-pr-merge never lets a check run supersede a legacy status context"
}

# The inverse, and the one that matters most: a check whose current run failed is
# still red however many earlier runs of it passed.
test_current_failed_check_run_still_refuses() {
  local case_dir rc head
  head=dddddddddddddddddddddddddddddddddddddddd
  case_dir=$(make_case github-current-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/91 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-current-red: a currently failing check must refuse"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-current-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-current-red: gh pr merge ran on a currently failing check"
  pass "fm-pr-merge still refuses when a check's current run failed after an earlier pass"
}

# Run generation follows startedAt rather than the order overlapping runs finish.
test_late_finishing_old_success_does_not_hide_current_failure() {
  local case_dir rc head
  head=dededededededededededededededededededede
  case_dir=$(make_case github-old-success-finishes-last)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:01Z 2026-01-01T00:00:10Z)" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:09Z 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/98 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-old-success-finishes-last: the later-started failure must refuse"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-old-success-finishes-last: the current failure was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-old-success-finishes-last: completion order hid the current failure"
  pass "fm-pr-merge uses start order when the old success finishes last"
}

# A cancelled old run may settle after the passing re-run that superseded it.
test_late_finishing_old_cancellation_is_superseded() {
  local case_dir head
  head=dfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdf
  case_dir=$(make_case github-old-cancellation-finishes-last)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED CANCELLED 2026-01-01T00:00:01Z 2026-01-01T00:00:10Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z 2026-01-01T00:00:09Z)"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/99 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "github-old-cancellation-finishes-last: the passing re-run must merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 99 example/repo --squash
  pass "fm-pr-merge supersedes an old cancellation that finishes last"
}

# A re-run that has not finished proves nothing, so it can neither be superseded
# nor supersede: the check stays red whether the run it replaces passed or failed.
test_unfinished_rerun_keeps_a_check_red() {
  local case_dir rc head prior
  head=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  for prior in FAILURE SUCCESS; do
    case_dir=$(make_case "github-pending-rerun-$prior")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    write_github_rollup_json "$case_dir" "$head" \
      "$(check_run ci COMPLETED "$prior" 2026-01-01T00:00:01Z)" \
      "$(check_run ci IN_PROGRESS - -)"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/92 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-pending-rerun-$prior: an unfinished re-run must refuse"
    assert_grep "check 'ci' is not green" "$case_dir/stderr" \
      "github-pending-rerun-$prior: the pending check was not named"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-pending-rerun-$prior: gh pr merge ran with a re-run still in flight"
  done
  pass "fm-pr-merge keeps a check red while its re-run is still in flight"
}

# Supersession is scoped to one check name, which is also the name --allow-red
# matches, so a newer passing check never clears a different check's failure.
test_supersession_never_crosses_check_names() {
  local case_dir rc head
  head=ffffffffffffffffffffffffffffffffffffffff
  case_dir=$(make_case github-cross-name)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/93 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-cross-name: another check passing must not clear this failure"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "github-cross-name: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-cross-name: gh pr merge ran on a red check of a different name"
  pass "fm-pr-merge never lets one check's pass clear another check's failure"
}

# Supersession has to be proven from the forge's own start timestamps, so a run
# GitHub dated in any other way is treated as undated and clears nothing.
test_undated_runs_never_supersede() {
  local case_dir rc spec label older newer
  local head=0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a
  set -- \
    'undated-failure|-|2026-01-01T00:00:09Z' \
    'undated-pass|2026-01-01T00:00:01Z|-' \
    'fractional-pass|2026-01-01T00:00:01Z|2026-01-01T00:00:09.500Z' \
    'offset-pass|2026-01-01T00:00:01Z|2026-01-01T00:00:09+00:00'
  for spec in "$@"; do
    label=${spec%%|*}
    older=${spec#*|}
    older=${older%%|*}
    newer=${spec##*|}
    case_dir=$(make_case "github-undated-$label")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" "$head"
    write_github_rollup_json "$case_dir" "$head" \
      "$(check_run ci COMPLETED FAILURE "$older")" \
      "$(check_run ci COMPLETED SUCCESS "$newer")"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/94 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "github-undated-$label: an unproven supersession must refuse"
    assert_grep "check 'ci' is not green" "$case_dir/stderr" \
      "github-undated-$label: the red check was not named"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "github-undated-$label: gh pr merge ran on an unproven supersession"
  done
  pass "fm-pr-merge clears a failure only on a proven later pass of the same check"
}

# A superseded failure changes nothing about the waiver: --allow-red still covers
# exactly the named check, still needs every other check green, and the merge is
# still bound to the verified head.
test_allow_red_still_waives_only_the_current_failure() {
  local case_dir rc head
  head=0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b
  case_dir=$(make_case github-superseded-allow-red-wrong-name)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:09Z)"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/95 \
    --allow-red ci > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "superseded-allow-red-wrong-name: waiving the green check must not merge"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "superseded-allow-red-wrong-name: the unwaived red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "superseded-allow-red-wrong-name: gh pr merge ran with an unwaived red check"

  case_dir=$(make_case github-superseded-allow-red-named)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED FAILURE 2026-01-01T00:00:01Z)" \
    "$(check_run ci COMPLETED SUCCESS 2026-01-01T00:00:09Z)" \
    "$(check_run lint COMPLETED FAILURE 2026-01-01T00:00:09Z)"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/96 \
    --allow-red lint > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "superseded-allow-red-named: the named waiver should merge"$'\n'"$(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 96 example/repo --squash
  pass "fm-pr-merge keeps --allow-red scoped to its named check beside a superseded failure"
}

test_allow_red_is_refused_while_away() {
  local case_dir rc head
  head=abababababababababababababababababababab
  case_dir=$(make_case github-allow-red-away)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-away: --allow-red must be refused while away"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" \
    "github-allow-red-away: refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-away: gh pr merge ran despite away --allow-red"

  case_dir=$(make_case github-allow-red-away-after-view)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  mv "$case_dir/state/.afk-contract" "$case_dir/away-record-after-view"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/82 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-away-after-view: late away publication must refuse --allow-red"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" \
    "github-allow-red-away-after-view: late refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-away-after-view: gh pr merge ran after late away publication"
  pass "fm-pr-merge rechecks away presence before an attended red merge"
}

# A quiet-mode record is a present captain, not an away posture: the attended
# red-check waiver still works and the merge is recorded as attended.
test_quiet_record_keeps_merges_attended() {
  local case_dir head url
  head=adadadadadadadadadadadadadadadadadadadad
  url=https://github.com/example/repo/pull/84
  case_dir=$(make_case quiet-allow-red)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  FM_AFK_MODE=quiet write_away_record "$case_dir"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "quiet-allow-red: the attended waiver was refused under quiet mode: $(cat "$case_dir/stderr")"
  assert_no_grep 'attended-only' "$case_dir/stderr" \
    "quiet-allow-red: quiet mode was treated as away"
  assert_logged_gh_merge "$case_dir" 84 example/repo --squash
  [ "$(sed -n 6p "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)" = attended ] \
    || fail "quiet-allow-red: the persisted merge authority is not attended: $(cat "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)"
  pass "fm-pr-merge keeps a quiet-mode home's merges attended, the named red-check waiver included"
}

test_allow_red_requires_one_separate_name() {
  local case_dir rc head
  head=afafafafafafafafafafafafafafafafafafafaf

  case_dir=$(make_case github-allow-red-equals)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/87 \
    --allow-red=lint > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-equals: equals form must be refused"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-equals: gh pr merge ran for the equals alias"

  case_dir=$(make_case github-allow-red-duplicate)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/88 \
    --allow-red lint --allow-red unit > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "github-allow-red-duplicate: duplicate waiver must be refused"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-allow-red-duplicate: gh pr merge ran for duplicate waivers"
  pass "fm-pr-merge accepts exactly one separately named red-check waiver"
}

test_away_record_permits_any_green_merge_under_away_authority() {
  local case_dir rc url head
  head=acacacacacacacacacacacacacacacacacacacac
  url=https://github.com/example/repo/pull/83

  # No yolo, no per-task grant: the record's presence is the whole mechanical
  # fact, so a green merge proceeds and the ledger tags it away.
  case_dir=$(make_case away-green)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge the windows fix when green'
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "away-green: a green merge under the record should succeed: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 83 example/repo --squash
  assert_grep "merge landed: task-x1 $url away" "$case_dir/state/.wake-queue" \
    "away-green: the durable outcome did not tag away"
  assert_no_grep 'away-grant' "$case_dir/state/.wake-queue" \
    "away-green: the retired away-grant tag reappeared"
  [ "$(sed -n 6p "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)" = away ] \
    || fail "away-green: the persisted merge authority is not away: $(cat "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)"

  # A yolo=on task merges under the same away authority: the posture, not the
  # task's standing autonomy, is what the ledger records while away.
  case_dir=$(make_case away-yolo)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  printf '\nyolo=on\n' >> "$case_dir/state/task-x1.meta"
  write_away_record "$case_dir"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "away-yolo: yolo green merge should succeed"
  assert_grep "merge landed: task-x1 $url away" "$case_dir/state/.wake-queue" \
    "away-yolo: the durable outcome did not tag away"

  # --attended-override re-enables forge flags for an explicit instruction; it
  # never skips the record read, and the merge still lands under away authority.
  case_dir=$(make_case away-attended-override)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge it when green'
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" --attended-override \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "away-attended-override: a green merge should succeed: $(cat "$case_dir/stderr")"
  assert_grep "merge landed: task-x1 $url away" "$case_dir/state/.wake-queue" \
    "away-attended-override: the durable outcome did not tag away"

  # Without the record the merge is attended and the ledger row stays untagged.
  case_dir=$(make_case attended-untagged)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "attended-untagged: an attended green merge should succeed"
  case "$(grep -F "merge landed: task-x1 $url" "$case_dir/state/.wake-queue")" in
    *"$url") ;;
    *) fail "attended-untagged: the attended outcome carried an authority tag: $(grep -F 'merge landed' "$case_dir/state/.wake-queue")" ;;
  esac
  pass "while the away-posture record exists any green merge lands under away authority, yolo or not, and attended merges stay untagged"
}

# While the away-posture record exists main is parked, so the supervision
# branch actor may reach the merge gate - and meets exactly the gate main
# would: any task merges green at its live head under away authority, a red
# one is refused whatever the words say, and without the record the branch is
# refused at the role partition before any forge call
# (docs/pi-supervision-branch.md "Postures").
test_away_branch_actor_merges_green_under_the_record() {
  local case_dir rc url head
  head=dadadadadadadadadadadadadadadadadadadada
  url=https://github.com/example/repo/pull/93

  case_dir=$(make_case away-branch-attended)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  set +e
  FM_SUPERVISION_ACTOR=branch run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 6 "$rc" "away-branch-attended: an attended branch must be refused at the partition"
  assert_grep 'the supervision branch never performs this action' "$case_dir/stderr" \
    "away-branch-attended: refusal lost the partition wording"
  [ ! -e "$case_dir/gh.log" ] || assert_no_grep 'pr ' "$case_dir/gh.log" \
    "away-branch-attended: gh ran for an attended branch merge"

  # No yolo and no grant list: the record alone relocates the green merge.
  case_dir=$(make_case away-branch-green)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge the windows fix when green'
  FM_SUPERVISION_ACTOR=branch FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "away-branch-green: a green merge must succeed for the branch under the record: $(cat "$case_dir/stderr")"
  assert_grep 'main is parked' "$case_dir/stderr" \
    "away-branch-green: the relocation note was not printed"
  assert_logged_gh_merge "$case_dir" 93 example/repo --squash
  assert_grep "merge landed: task-x1 $url away" "$case_dir/state/.wake-queue" \
    "away-branch-green: the durable outcome did not tag away"

  # The green gate is absolute in this posture for the branch as for main: a
  # red check refuses on its own, and the attended waiver is refused too.
  case_dir=$(make_case away-branch-red)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    '{"__typename":"CheckRun","name":"lint","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-09-01T00:00:00Z"}'
  write_away_record "$case_dir" --words 'merge task-x1 even if lint is red'
  set +e
  FM_SUPERVISION_ACTOR=branch FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-branch-red: a red check must refuse the branch whatever the words say"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "away-branch-red: refusal did not name the red check"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-branch-red: gh pr merge ran for a red branch merge while away"
  set +e
  FM_SUPERVISION_ACTOR=branch FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-branch-red: --allow-red must stay attended-only for the branch"
  assert_grep 'allow-red is attended-only' "$case_dir/stderr" \
    "away-branch-red: refusal did not name the attended-only waiver"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-branch-red: gh pr merge ran for a waived red branch merge while away"
  pass "under the away-posture record the branch merges a green task, is refused on a red check with or without --allow-red, and is refused at the partition while attended"
}

# The race this closes: a branch merge passes the opening partition
# because the live record exists, then the captain returns and archives that
# record during the slow forge preflight. The locked authority recheck must
# treat that archive as absence and refuse the branch before gh pr merge.
# An empty away-record-after-view file is the mock's archive-during-view hook.
test_away_branch_refuses_when_record_archived_during_preflight() {
  local case_dir rc url head
  head=a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7
  url=https://github.com/example/repo/pull/127

  case_dir=$(make_case away-branch-archived-during-preflight)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  : > "$case_dir/away-record-after-view"
  set +e
  FM_SUPERVISION_ACTOR=branch FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 6 "$rc" "away-branch-archived-during-preflight: an archived record must refuse the branch under the lock"
  assert_grep 'main is parked' "$case_dir/stderr" \
    "away-branch-archived-during-preflight: the opening partition never saw the live record"
  assert_grep 'the supervision branch never performs this action' "$case_dir/stderr" \
    "away-branch-archived-during-preflight: refusal lost the partition wording"
  assert_grep 'pr view' "$case_dir/gh.log" \
    "away-branch-archived-during-preflight: the forge preflight never ran"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-branch-archived-during-preflight: gh pr merge ran after the record was archived"
  pass "a branch merge refuses under the lock when the away record is archived during preflight"
}

test_away_posture_refuses_asynchronous_merge_paths() {
  local case_dir rc url head merge_line
  head=abababababababababababababababababababab
  url=https://github.com/example/repo/pull/89

  case_dir=$(make_case away-auto-refused)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-auto-refused: auto-merge must be attended-only"
  assert_grep '--auto is attended-only' "$case_dir/stderr" \
    "away-auto-refused: refusal did not name the asynchronous flag"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-auto-refused: gh pr merge ran for an away auto-merge request"

  case_dir=$(make_case away-queue-refused)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-queue-refused: a required merge queue must refuse before submission"
  assert_grep 'merge-queue state does not prove an immediate merge' "$case_dir/stderr" \
    "away-queue-refused: refusal did not explain the away restriction"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-queue-refused: gh received a merge that could enter its queue"

  case_dir=$(make_gitlab_case away-gitlab-auto)
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --attended-override -- --auto-merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-gitlab-auto: GitLab auto-merge must refuse"
  assert_grep 'GitLab auto-merge is attended-only' "$case_dir/stderr" \
    "away-gitlab-auto: refusal did not name auto-merge"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "away-gitlab-auto: glab received an asynchronous merge"

  case_dir=$(make_gitlab_case away-gitlab-configured merge_when_pipeline_succeeds=true)
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-gitlab-configured: configured auto-merge must refuse"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "away-gitlab-configured: glab received a configured asynchronous merge"

  case_dir=$(make_gitlab_case away-gitlab-sync)
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "away-gitlab-sync: an immediate merge under the record should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *" --auto-merge=false") ;;
    *) fail "away-gitlab-sync: the final glab flag did not force an immediate merge: '$merge_line'" ;;
  esac
  pass "away posture permits immediate merges but refuses every asynchronous path"
}

# The practical effect of the fix: while away, a private repository's plan-gated 403
# must no longer refuse the merge the way any other unreadable queue response
# does.
test_away_plan_gated_403_does_not_block_the_merge() {
  local case_dir rc url head
  head=cececececececececececececececececececece
  url=https://github.com/example/repo/pull/91
  case_dir=$(make_case away-plan-gated-403)
  mkdir -p "$case_dir/wt" "$case_dir/home"
  add_gh_mocks "$case_dir" "$head"
  printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature (HTTP 403)\n' \
    > "$case_dir/github-rules-fail-body"
  printf '\nyolo=on\n' >> "$case_dir/state/task-x1.meta"
  write_away_record "$case_dir"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "away-plan-gated-403: a private repo's plan-gated 403 must not block an away merge"
  assert_logged_gh_merge "$case_dir" 91 example/repo --squash
  pass "away merge proceeds on a plan-gated 403 because that repository cannot have a merge queue"
}

test_away_record_does_not_bypass_red_or_identity() {
  local case_dir rc head
  head=adadadadadadadadadadadadadadadadadadadad
  case_dir=$(make_case away-record-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/84 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-record-red: the record must not waive red checks"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "away-record-red: C1 did not refuse the red check"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-record-red: gh pr merge ran on a red PR while away"

  case_dir=$(make_case pr-identity-mismatch)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '\npr=https://github.com/example/repo/pull/99\n' >> "$case_dir/state/task-x1.meta"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/85 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "pr-identity: a different recorded URL must refuse"
  assert_grep 'is bound to https://github.com/example/repo/pull/99' "$case_dir/stderr" \
    "pr-identity: refusal did not name the recorded URL"
  pass "the away record does not bypass red checks, and a recorded pr= must match the URL"
}

test_unreadable_away_record_refuses_merge() {
  local case_dir rc
  case_dir=$(make_case away-unreadable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae
  printf 'not-a-contract\n' > "$case_dir/state/.afk-contract"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/86 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-unreadable: an unreadable away record must refuse"
  assert_grep 'away-posture record could not be read' "$case_dir/stderr" \
    "away-unreadable: refusal did not fail closed"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-unreadable: gh pr merge ran despite an unreadable record"
  pass "an unreadable away-posture record refuses the merge instead of skipping the record"
}

# Two away-record changes, each attempted from inside the merge's critical
# section: the archive a captain return performs, and the replacement /afk with
# new words performs. Neither may land there, and the merge must still complete
# on the authority it read.
test_away_record_cannot_change_between_the_authority_read_and_the_merge() {
  local case_dir rc mutate
  case_dir=$(make_case away-archive-at-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  mutate=$(away_change_script "$case_dir" archive-at-merge <<'SH'
"$CONTRACT" archive
SH
  )

  export FM_TEST_AWAY_MUTATE_AT_MERGE="$mutate"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AWAY_MUTATE_AT_MERGE

  expect_code 0 "$rc" "away-archive-at-merge: the green merge should still land"
  [ -s "$case_dir/away-mutate-rc" ] \
    || fail "away-archive-at-merge: the archive was never attempted inside the merge"
  [ "$(cat "$case_dir/away-mutate-rc")" != 0 ] \
    || fail "away-archive-at-merge: the archive landed inside the merge's critical section"
  assert_grep 'locked by live process' "$case_dir/away-mutate-output" \
    "away-archive-at-merge: the refused archive did not name the live holder"
  assert_equals 'merge task-x1 when green' "$(cat "$case_dir/away-words-at-merge" 2>/dev/null || true)" \
    "away-archive-at-merge: the record this merge read was not still standing at the forge call"
  assert_grep "merge landed: task-x1 https://github.com/example/repo/pull/71 away" \
    "$case_dir/state/.wake-queue" \
    "away-archive-at-merge: the landed merge was not recorded under the away authority it read"
  # The lock goes with the merge rather than leaking: the captain's return
  # archives the record on its first try once the merge is done.
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null \
    || fail "away-archive-at-merge: the record stayed locked after the merge"

  case_dir=$(make_case away-replace-at-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  mutate=$(away_change_script "$case_dir" replace-at-merge <<'SH'
"$CONTRACT" enter --words 'hold everything for my return'
SH
  )
  export FM_TEST_AWAY_MUTATE_AT_MERGE="$mutate"
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AWAY_MUTATE_AT_MERGE

  expect_code 0 "$rc" "away-replace-at-merge: the green merge should still land"
  [ "$(cat "$case_dir/away-mutate-rc" 2>/dev/null || true)" != 0 ] \
    || fail "away-replace-at-merge: the replacement landed inside the critical section"
  assert_equals 'merge task-x1 when green' "$(cat "$case_dir/away-words-at-merge" 2>/dev/null || true)" \
    "away-replace-at-merge: the words were replaced inside the merge's critical section"
  pass "no away-record archive or replacement lands between the authority read and the merge"
}

# The same serialization from the other side. A record change that wins the
# race lands BEFORE the in-lock authority read, and the merge then answers to
# what it finds there: an unreadable record refuses rather than merging on the
# record the opening partition saw. The lock decides an order, it never lets a
# stale read through.
test_a_record_made_unreadable_before_the_merge_refuses_it() {
  local case_dir rc
  case_dir=$(make_case away-unreadable-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d3d
  printf 'not-a-contract\n' > "$case_dir/away-record-after-view"
  write_away_record "$case_dir" --words 'merge task-x1 when green'

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "away-unreadable-before-merge: a record made unreadable before the authority read must refuse"
  assert_grep 'away-posture record could not be read' "$case_dir/stderr" \
    "away-unreadable-before-merge: refusal did not fail closed"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-unreadable-before-merge: gh pr merge ran on a record that could not be read"
  pass "a record made unreadable before the merge's own authority read refuses the merge"
}

# Fail closed. The lock is what makes the authority read and the merge one
# action, so a merge that cannot take it has no locked window to merge in and
# refuses - including on this attended case, where the record is absent and
# there is no away authority to read at all.
test_merge_refuses_when_the_away_record_cannot_be_locked() {
  local case_dir rc holder_pid i lock
  case_dir=$(make_case away-lock-unavailable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e4e
  lock="$case_dir/state/.afk-contract.lock"

  FM_STATE_OVERRIDE="$case_dir/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 10
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$case_dir/holder.ready" "$case_dir/release-holder" &
  holder_pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$case_dir/holder.ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$case_dir/holder.ready" ] \
    || { kill "$holder_pid" 2>/dev/null || true; fail "away-lock-unavailable: the fixture never took the record lock"; }

  export FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT=1
  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  unset FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT
  : > "$case_dir/release-holder"
  wait "$holder_pid" || fail "away-lock-unavailable: the fixture holder did not release cleanly"

  expect_code 1 "$rc" "away-lock-unavailable: an unlockable away record must refuse the merge"
  assert_grep 'could not be locked for the merge' "$case_dir/stderr" \
    "away-lock-unavailable: refusal did not name the lock it could not take"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-lock-unavailable: gh pr merge ran without the away-record lock"
  pass "a merge that cannot lock the away record refuses instead of merging unlocked"
}

test_allow_red_refused_on_gitlab() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-allow-red)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "gitlab-allow-red: --allow-red must not apply on GitLab"
  assert_grep '--allow-red does not apply to GitLab' "$case_dir/stderr" \
    "gitlab-allow-red: refusal did not name GitLab"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-allow-red: glab ran despite --allow-red"
  pass "fm-pr-merge refuses --allow-red on GitLab"
}

test_required_check_that_never_reported_refuses() {
  local case_dir head kind
  head=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
  for kind in classic ruleset; do
    case_dir=$(make_case "github-required-absent-$kind")
    add_gh_mocks "$case_dir" "$head"
    write_github_required "$case_dir" "$kind:ci" "$kind:validate"
    run_required_case "$case_dir" 90
    expect_code 1 "$RC" "required-absent-$kind: an unreported required check must refuse"
    assert_grep "required check 'validate' has not reported at head $head" "$case_dir/stderr" \
      "required-absent-$kind: the unreported required check was not named"
    assert_grep 'these required checks have not reported: validate' "$case_dir/stderr" \
      "required-absent-$kind: the summary did not name the unreported check"
    assert_no_grep "required check 'ci'" "$case_dir/stderr" \
      "required-absent-$kind: a reported green required check was called missing"
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "required-absent-$kind: gh pr merge ran with a required check unreported"
    assert_no_grep 'verified: ' "$case_dir/stderr" \
      "required-absent-$kind: the refusal still claimed a verified head"
  done
  pass "fm-pr-merge refuses when a required check from branch protection or a ruleset never reported"
}

test_required_checks_reported_and_green_merge() {
  local case_dir head
  head=a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2
  case_dir=$(make_case github-required-present)
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED SUCCESS)" \
    "$(status_context 'license/cla' SUCCESS)"
  write_github_required "$case_dir" classic:ci ruleset:license/cla ruleset:ci
  run_required_case "$case_dir" 91
  expect_code 0 "$RC" "required-present: every required check reported and green must merge: $(cat "$case_dir/stderr")"
  assert_grep 'api repos/example/repo/branches/main' "$case_dir/gh.log" \
    "required-present: the branch protection summary was not read"
  assert_grep 'api --paginate repos/example/repo/rules/branches/main' "$case_dir/gh.log" \
    "required-present: the branch rules were not read"
  assert_grep "every unwaived required check reported and every unwaived check green at head $head" \
    "$case_dir/stderr" "required-present: the verified line did not state the required checks reported"
  assert_logged_gh_merge "$case_dir" 91 example/repo --squash
  pass "fm-pr-merge merges when every required check reported and is green"
}

test_red_and_unreported_checks_are_reported_together() {
  local case_dir head
  head=a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3
  case_dir=$(make_case github-red-and-unreported)
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run lint COMPLETED FAILURE)"
  sed 's/"isDraft":false/"isDraft":true/' "$case_dir/github-view.json" > "$case_dir/view.tmp"
  mv "$case_dir/view.tmp" "$case_dir/github-view.json"
  write_github_required "$case_dir" classic:lint ruleset:validate
  run_required_case "$case_dir" 92
  expect_code 1 "$RC" "red-and-unreported: must refuse"
  assert_grep 'the pull request is a draft' "$case_dir/stderr" \
    "red-and-unreported: the draft condition was dropped"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "red-and-unreported: the red check was dropped"
  assert_grep "required check 'validate' has not reported" "$case_dir/stderr" \
    "red-and-unreported: the unreported required check was dropped"
  assert_grep 'these checks are not green: lint' "$case_dir/stderr" \
    "red-and-unreported: the red summary was dropped"
  assert_grep 'these required checks have not reported: validate' "$case_dir/stderr" \
    "red-and-unreported: the unreported summary was dropped"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "red-and-unreported: gh pr merge ran"
  pass "fm-pr-merge reports a red check and an unreported required check together with every other failure"
}

test_unreadable_required_set_refuses() {
  local case_dir head label
  head=a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4
  for label in branch-read-fails branch-shape rules-read-fails rules-forbidden rules-shape; do
    case_dir=$(make_case "github-required-unreadable-$label")
    add_gh_mocks "$case_dir" "$head"
    case "$label" in
      branch-read-fails)
        printf 'gh: Not Found (HTTP 404)\n' > "$case_dir/github-branch-fail"
        ;;
      branch-shape)
        printf '{"name":"main","protected":true}\n' > "$case_dir/github-branch.json"
        ;;
      rules-read-fails)
        printf 'gh: Not Found (HTTP 404)\n' > "$case_dir/github-required-rules-fail"
        ;;
      rules-forbidden)
        printf 'gh: Resource not accessible by personal access token (HTTP 403)\n' \
          > "$case_dir/github-required-rules-fail"
        ;;
      rules-shape)
        printf '[{"type":"required_status_checks","parameters":{}}]\n' \
          > "$case_dir/github-required-rules.json"
        ;;
    esac
    # A waiver names one check, so it can never stand in for a required set
    # that could not be read.
    run_required_case "$case_dir" 93 --allow-missing validate
    expect_code 1 "$RC" "required-unreadable-$label: an unreadable required set must refuse"
    case "$label" in
      branch-*)
        assert_grep 'the branch protection summary for base branch main could not be read, so a required check that has not reported cannot be ruled out' \
          "$case_dir/stderr" "required-unreadable-$label: the refusal did not name the unreadable source"
        ;;
      rules-*)
        assert_grep 'the branch rules for base branch main could not be read, so a required check that has not reported cannot be ruled out' \
          "$case_dir/stderr" "required-unreadable-$label: the refusal did not name the unreadable source"
        ;;
    esac
    assert_no_grep 'pr merge' "$case_dir/gh.log" \
      "required-unreadable-$label: gh pr merge ran on an unreadable required set"
  done

  # GitHub's plan-gated refusal means the repository cannot have branch rules
  # at all, which is a readable answer, so the classic set alone decides.
  case_dir=$(make_case github-required-plan-gated)
  add_gh_mocks "$case_dir" "$head"
  printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)\n' \
    > "$case_dir/github-required-rules-fail"
  run_required_case "$case_dir" 94
  expect_code 0 "$RC" "required-plan-gated: a plan without branch rules must not read as unreadable: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 94 example/repo --squash

  case_dir=$(make_case github-required-plan-gated-classic-absent)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" classic:validate
  printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)\n' \
    > "$case_dir/github-required-rules-fail"
  run_required_case "$case_dir" 95
  expect_code 1 "$RC" "required-plan-gated-classic-absent: a classic required check must still be enforced"
  assert_grep "required check 'validate' has not reported" "$case_dir/stderr" \
    "required-plan-gated-classic-absent: the unreported classic check was not named"
  pass "fm-pr-merge refuses when the required checks cannot be read, and tells a plan without rules apart"
}

test_allow_missing_waives_only_the_named_unreported_check() {
  local case_dir head
  head=a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5

  case_dir=$(make_case github-allow-missing-named)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" classic:ci ruleset:validate
  run_required_case "$case_dir" 96 --allow-missing validate
  expect_code 0 "$RC" "allow-missing-named: the named waiver should merge: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 96 example/repo --squash

  case_dir=$(make_case github-allow-missing-other-missing)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate ruleset:e2e
  run_required_case "$case_dir" 97 --allow-missing validate
  expect_code 1 "$RC" "allow-missing-other-missing: another unreported check must still refuse"
  assert_grep "required check 'e2e' has not reported" "$case_dir/stderr" \
    "allow-missing-other-missing: the other unreported check was not named"
  assert_no_grep "required check 'validate'" "$case_dir/stderr" \
    "allow-missing-other-missing: the waived check was still reported"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-other-missing: gh pr merge ran with an unwaived unreported check"

  case_dir=$(make_case github-allow-missing-other-red)
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_github_required "$case_dir" ruleset:validate
  run_required_case "$case_dir" 98 --allow-missing validate
  expect_code 1 "$RC" "allow-missing-other-red: a red check must still refuse"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "allow-missing-other-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-other-red: gh pr merge ran with a red check"

  # The waiver covers absence only: a required check that did report red is
  # not missing, and waiving it takes --allow-red.
  case_dir=$(make_case github-allow-missing-names-red)
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_github_required "$case_dir" classic:lint
  run_required_case "$case_dir" 99 --allow-missing lint
  expect_code 1 "$RC" "allow-missing-names-red: a reported red check must not be waived as missing"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "allow-missing-names-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-names-red: gh pr merge ran with a red required check"
  pass "fm-pr-merge --allow-missing waives only its named unreported check"
}

test_allow_missing_follows_the_allow_red_rules() {
  local case_dir head
  head=a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6a6

  case_dir=$(make_case github-allow-missing-equals)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate
  run_required_case "$case_dir" 100 --allow-missing=validate
  expect_code 2 "$RC" "allow-missing-equals: the equals form must be refused"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-equals: gh pr merge ran for the equals form"

  case_dir=$(make_case github-allow-missing-duplicate)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate ruleset:e2e
  run_required_case "$case_dir" 101 --allow-missing validate --allow-missing e2e
  expect_code 2 "$RC" "allow-missing-duplicate: a second waiver must be refused"
  assert_grep '--allow-missing may be specified only once' "$case_dir/stderr" \
    "allow-missing-duplicate: the refusal did not say single use"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-duplicate: gh pr merge ran for two waivers"

  case_dir=$(make_case github-allow-missing-away)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  run_required_case "$case_dir" 102 --allow-missing validate
  expect_code 2 "$RC" "allow-missing-away: the waiver must be refused while away"
  assert_grep '--allow-missing is attended-only' "$case_dir/stderr" \
    "allow-missing-away: the refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-away: gh pr merge ran despite an away waiver"

  case_dir=$(make_case github-allow-missing-away-after-view)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  mv "$case_dir/state/.afk-contract" "$case_dir/away-record-after-view"
  run_required_case "$case_dir" 102 --allow-missing validate
  expect_code 2 "$RC" "allow-missing-away-after-view: late away publication must refuse the waiver"
  assert_grep '--allow-missing is attended-only' "$case_dir/stderr" \
    "allow-missing-away-after-view: the late refusal did not name attended-only"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "allow-missing-away-after-view: gh pr merge ran after late away publication"

  case_dir=$(make_case github-unreported-away)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" ruleset:validate
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  run_required_case "$case_dir" 103
  expect_code 1 "$RC" "unreported-away: the away record must not waive an unreported check"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreported-away: gh pr merge ran with an unreported check while away"

  case_dir=$(make_gitlab_case gitlab-allow-missing)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --allow-missing validate \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  RC=$?
  set -e
  expect_code 2 "$RC" "gitlab-allow-missing: the waiver must not apply on GitLab"
  assert_grep '--allow-missing does not apply to GitLab' "$case_dir/stderr" \
    "gitlab-allow-missing: the refusal did not name GitLab"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-allow-missing: glab ran despite the waiver"
  pass "fm-pr-merge --allow-missing is single use, attended-only, and GitHub-only like --allow-red"
}

test_rollup_read_retries_and_rechecks_complete_verdict() {
  local case_dir head variant expected
  head=b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2
  for variant in partial pending-page empty missing-context http-503 rate-limit graphql-error turns-red; do
    case_dir=$(make_case "rollup-retry-$variant")
    add_gh_mocks "$case_dir" "$head"
    write_github_rollup_json "$case_dir" "$head" \
      "$(check_run ci COMPLETED SUCCESS)" "$(check_run validate COMPLETED SUCCESS)"
    write_github_required "$case_dir" classic:ci ruleset:validate
    mkdir "$case_dir/rollup-responses"
    write_rollup_response "$case_dir" "$case_dir/rollup-responses/final"
    case "$variant" in
      partial|turns-red)
        jq '.data.repository.object.statusCheckRollup.contexts.nodes |= .[0:1]' \
          "$case_dir/rollup-responses/final" > "$case_dir/rollup-responses/1" ;;
      pending-page)
        jq '.data.repository.object.statusCheckRollup.contexts.pageInfo = {hasNextPage:true,endCursor:"next"}' \
          "$case_dir/rollup-responses/final" > "$case_dir/rollup-responses/1" ;;
      empty)
        jq '.data.repository.object.statusCheckRollup.contexts |= (.totalCount = 0 | .nodes = [])' \
          "$case_dir/rollup-responses/final" > "$case_dir/rollup-responses/1" ;;
      missing-context)
        jq '.data.repository.object.statusCheckRollup.contexts |= (.totalCount = 1 | .nodes |= .[0:1])' \
          "$case_dir/rollup-responses/final" > "$case_dir/rollup-responses/1" ;;
      http-503) printf 'gh: Service Unavailable (HTTP 503)\n' > "$case_dir/rollup-responses/1.fail" ;;
      rate-limit) printf 'gh: secondary rate limit (HTTP 403)\n' > "$case_dir/rollup-responses/1.fail" ;;
      graphql-error)
        jq '.errors = [{message:"temporarily unavailable"}]' \
          "$case_dir/rollup-responses/final" > "$case_dir/rollup-responses/1" ;;
    esac
    expected=0
    if [ "$variant" = turns-red ]; then
      jq '.data.repository.object.statusCheckRollup.contexts.nodes[1].conclusion = "FAILURE"' \
        "$case_dir/rollup-responses/final" > "$case_dir/updated.json"
      mv "$case_dir/updated.json" "$case_dir/rollup-responses/final"
      expected=1
    fi
    run_required_case "$case_dir" 113
    expect_code "$expected" "$RC" "rollup-$variant: $(cat "$case_dir/stderr")"
    [ "$(cat "$case_dir/rollup-calls")" -eq 2 ] || fail "rollup-$variant did not retry once"
    assert_no_grep 'these required checks have not reported' "$case_dir/stderr" \
      "rollup-$variant presented transient visibility as missing checks"
    if [ "$expected" = 0 ]; then
      assert_logged_gh_merge "$case_dir" 113 example/repo --squash
    else
      assert_grep "check 'validate' is not green" "$case_dir/stderr" "retry hid a newly red check"
      assert_no_grep 'pr merge' "$case_dir/gh.log" "retry merged a newly red check"
    fi
  done
  pass "fm-pr-merge retries incomplete and transient rollups, then judges every check anew"
}

test_unreadable_rollup_never_becomes_missing_or_waivable() {
  local case_dir head variant
  head=b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3
  for variant in partial duplicate stale error no-source changing-count; do
    case_dir=$(make_case "rollup-unreadable-$variant")
    add_gh_mocks "$case_dir" "$head"
    write_github_required "$case_dir" classic:ci ruleset:validate
    mkdir "$case_dir/rollup-responses"
    write_rollup_response "$case_dir" "$case_dir/seed.json"
    case "$variant" in
      partial) jq '.data.repository.object.statusCheckRollup.contexts.totalCount = 2' "$case_dir/seed.json" ;;
      duplicate) jq '.data.repository.object.statusCheckRollup.contexts |= (.totalCount = 2 | .nodes += .nodes)' "$case_dir/seed.json" ;;
      stale) jq '.data.repository.object.oid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$case_dir/seed.json" ;;
      error) jq '.errors = [{message:"unavailable"}]' "$case_dir/seed.json" ;;
      no-source) jq 'del(.data.repository.object.statusCheckRollup)' "$case_dir/seed.json" ;;
      changing-count)
        jq '.data.repository.object.statusCheckRollup.contexts |= (.pageInfo = {hasNextPage:true,endCursor:"next"})' "$case_dir/seed.json"
        jq '.data.repository.object.statusCheckRollup.contexts |= (.totalCount = 2 | .nodes = [])' "$case_dir/seed.json" ;;
    esac > "$case_dir/rollup-responses/final"
    run_required_case "$case_dir" 114 --allow-missing validate
    expect_code 1 "$RC" "rollup-unreadable-$variant must refuse"
    [ "$(cat "$case_dir/rollup-calls")" -eq 5 ] || fail "rollup-$variant exceeded or skipped the read retry bound"
    assert_grep 'check rollup at head' "$case_dir/stderr" "unreadable rollup source was not named"
    assert_grep 'could not be read completely' "$case_dir/stderr" "incomplete rollup was not reported unreadable"
    assert_no_grep 'has not reported' "$case_dir/stderr" "unreadable rollup was classified as missing"
    assert_no_grep 'pr merge' "$case_dir/gh.log" "waiver bypassed an unreadable rollup"
  done
  pass "fm-pr-merge refuses incomplete rollups as unreadable sources even with a missing-check waiver"
}

test_rollup_later_pages_enforce_missing_and_red_checks() {
  local case_dir head variant expected
  head=b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4
  for variant in green red; do
    case_dir=$(make_case "rollup-pages-$variant")
    add_gh_mocks "$case_dir" "$head"
    write_github_rollup_json "$case_dir" "$head" \
      "$(check_run ci COMPLETED SUCCESS)" "$(check_run validate COMPLETED SUCCESS)"
    write_github_required "$case_dir" ruleset:validate
    mkdir "$case_dir/rollup-responses"
    write_rollup_response "$case_dir" "$case_dir/seed.json"
    jq '.data.repository.object.statusCheckRollup.contexts |=
      (.nodes |= .[0:1] | .pageInfo = {hasNextPage:true,endCursor:"next"})' \
      "$case_dir/seed.json" > "$case_dir/rollup-responses/final"
    jq --arg variant "$variant" '.data.repository.object.statusCheckRollup.contexts |=
      (.nodes |= .[1:] | if $variant == "red" then .nodes[0].conclusion = "FAILURE" else . end)' \
      "$case_dir/seed.json" >> "$case_dir/rollup-responses/final"
    run_required_case "$case_dir" 115
    expected=0
    [ "$variant" != red ] || expected=1
    expect_code "$expected" "$RC" "later-page-$variant: $(cat "$case_dir/stderr")"
    if [ "$expected" = 0 ]; then
      assert_logged_gh_merge "$case_dir" 115 example/repo --squash
    else
      assert_grep "check 'validate' is not green" "$case_dir/stderr" "later-page failure was omitted"
      assert_no_grep 'pr merge' "$case_dir/gh.log" "later-page failure reached merge"
    fi
    assert_no_grep 'has not reported' "$case_dir/stderr" "later-page requirement was called missing"
  done
  pass "fm-pr-merge judges required and red checks on later rollup pages"
}

test_partial_producer_read_retries_before_merging() {
  local case_dir head
  head=b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1
  case_dir=$(make_case partial-producers-then-complete)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" classic:ci
  jq '.protection.required_status_checks.checks[0].app_id = 15368' \
    "$case_dir/github-branch.json" > "$case_dir/updated.json"
  mv "$case_dir/updated.json" "$case_dir/github-branch.json"
  printf '{"total_count":2,"check_runs":[{"name":"other","app":{"id":15368},"head_sha":"%s"}]}\n' \
    "$head" > "$case_dir/github-runs-first.json"
  printf '{"total_count":2,"check_runs":[{"name":"other","app":{"id":15368},"head_sha":"%s"},{"name":"ci","app":{"id":15368},"head_sha":"%s"}]}\n' \
    "$head" "$head" > "$case_dir/github-runs.json"

  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 run_required_case "$case_dir" 112
  expect_code 0 "$RC" "partial producer read must recover inside the bounded wait: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 112 example/repo --squash
  assert_no_grep 'these required checks have not reported' "$case_dir/stderr" \
    "a partial producer read was presented as a missing check"
  [ "$(cat "$case_dir/github-runs-calls")" -eq 2 ] \
    || fail "partial producer read was not retried exactly once"
  pass "fm-pr-merge retries an incomplete producer list before merging the verified head"
}

test_required_sources_retry_transient_failures() {
  local case_dir head source failure
  head=b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5b5
  for source in branch required-rules; do
    case_dir=$(make_case "required-transient-$source")
    add_gh_mocks "$case_dir" "$head"
    write_github_required "$case_dir" classic:ci ruleset:ci
    failure="$case_dir/github-$source-fail"
    printf 'gh: Service Unavailable (HTTP 503)\n' > "$failure"
    : > "$failure.once"
    run_required_case "$case_dir" 116
    expect_code 0 "$RC" "required-$source read did not recover: $(cat "$case_dir/stderr")"
    assert_logged_gh_merge "$case_dir" 116 example/repo --squash
    assert_no_grep 'could not be read' "$case_dir/stderr" "recovered source retained an obsolete error"
    [ "$(cat "$case_dir/rollup-calls")" -eq 2 ] || fail "required-$source did not recheck live head checks"
  done
  pass "fm-pr-merge retries transient classic and ruleset required-source failures"
}

test_incomplete_producer_source_cannot_be_waived() {
  local case_dir head
  head=b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6b6
  case_dir=$(make_case incomplete-producers-waived)
  add_gh_mocks "$case_dir" "$head"
  write_github_required "$case_dir" classic:ci
  jq '.protection.required_status_checks.checks[0].app_id = 15368' \
    "$case_dir/github-branch.json" > "$case_dir/updated.json"
  mv "$case_dir/updated.json" "$case_dir/github-branch.json"
  printf '{"total_count":1,"check_runs":[]}\n' > "$case_dir/github-runs.json"
  run_required_case "$case_dir" 117 --allow-missing ci
  expect_code 1 "$RC" "partial producer evidence must remain unreadable even with a missing-check waiver"
  assert_grep 'required check producers at head' "$case_dir/stderr" "partial producer source not identified"
  assert_no_grep 'has not reported' "$case_dir/stderr" "partial producer source was presented as absent"
  assert_no_grep 'pr merge' "$case_dir/gh.log" "missing-check waiver bypassed incomplete producer evidence"
  [ "$(cat "$case_dir/rollup-calls")" -eq 5 ] || fail "incomplete producer read did not use the bounded retry"
  pass "fm-pr-merge never waives incomplete producer evidence"
}

test_required_producer_identity() {
  local case_dir head kind variant expected app
  head=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
  for kind in classic ruleset; do
    for variant in wrong correct unreadable malformed stale waived; do
      case_dir=$(make_case "required-producer-$kind-$variant")
      add_gh_mocks "$case_dir" "$head"
      write_github_required "$case_dir" "$kind:ci"
      if [ "$kind" = classic ]; then
        jq '.protection.required_status_checks.checks[0].app_id = 15368' \
          "$case_dir/github-branch.json" > "$case_dir/updated.json"
        mv "$case_dir/updated.json" "$case_dir/github-branch.json"
      else
        jq '.[1].parameters.required_status_checks[0].integration_id = 15368' \
          "$case_dir/github-required-rules.json" > "$case_dir/updated.json"
        mv "$case_dir/updated.json" "$case_dir/github-required-rules.json"
      fi
      app=42
      [ "$variant" != correct ] || app=15368
      printf '{"total_count":1,"check_runs":[{"name":"ci","app":{"id":%s},"head_sha":"%s"}]}\n' \
        "$app" "$head" > "$case_dir/github-runs.json"
      case "$variant" in
        unreadable) rm "$case_dir/github-runs.json" ;;
        malformed) printf '{}' > "$case_dir/github-runs.json" ;;
        stale) printf '{"total_count":1,"check_runs":[{"name":"ci","app":{"id":15368},"head_sha":"bbbb"}]}' > "$case_dir/github-runs.json" ;;
      esac
      expected=1
      if [ "$variant" = waived ]; then
        run_required_case "$case_dir" 110 --attended-override --allow-missing ci -- --admin
        expected=0
      else
        run_required_case "$case_dir" 110 --attended-override -- --admin
        [ "$variant" != correct ] || expected=0
      fi
      expect_code "$expected" "$RC" "producer-$kind-$variant: $(cat "$case_dir/stderr")"
      if [ "$expected" = 1 ]; then
        case "$variant" in
          unreadable|malformed|stale)
            assert_no_grep "required check 'ci' has not reported" "$case_dir/stderr" \
              "unreadable producer source was classified as a missing check" ;;
          *) assert_grep "required check 'ci' has not reported" "$case_dir/stderr" "producer absence not reported" ;;
        esac
        assert_no_grep 'pr merge' "$case_dir/gh.log" "wrong producer reached merge"
      else
        assert_grep 'pr merge' "$case_dir/gh.log" "accepted producer did not merge"
      fi
      case "$variant" in
        unreadable|malformed|stale)
          assert_grep 'required check producers at head' "$case_dir/stderr" "producer read error not reported" ;;
      esac
    done
  done
  pass "fm-pr-merge enforces required producer identity and named waivers"
}

# A commit status carries no app id to compare, so an app-bound required context
# that arrives as a green status matches by name, while the same context left
# unreported still refuses.
test_app_bound_required_status_context_matches_by_name() {
  local case_dir head kind variant
  head=a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7
  for kind in classic ruleset; do
    for variant in reported absent; do
      case_dir=$(make_case "required-app-status-$kind-$variant")
      add_gh_mocks "$case_dir" "$head"
      if [ "$variant" = reported ]; then
        write_github_rollup_json "$case_dir" "$head" \
          "$(check_run ci COMPLETED SUCCESS)" \
          "$(status_context 'license/cla' SUCCESS)"
      fi
      write_github_required "$case_dir" "$kind:license/cla"
      if [ "$kind" = classic ]; then
        jq '.protection.required_status_checks.checks[0].app_id = 865473' \
          "$case_dir/github-branch.json" > "$case_dir/updated.json"
        mv "$case_dir/updated.json" "$case_dir/github-branch.json"
      else
        jq '.[1].parameters.required_status_checks[0].integration_id = 865473' \
          "$case_dir/github-required-rules.json" > "$case_dir/updated.json"
        mv "$case_dir/updated.json" "$case_dir/github-required-rules.json"
      fi
      printf '{"total_count":1,"check_runs":[{"name":"ci","app":{"id":42},"head_sha":"%s"}]}\n' \
        "$head" > "$case_dir/github-runs.json"
      run_required_case "$case_dir" 111
      if [ "$variant" = reported ]; then
        expect_code 0 "$RC" "app-status-$kind-reported: a green app-bound status must merge: $(cat "$case_dir/stderr")"
        assert_logged_gh_merge "$case_dir" 111 example/repo --squash
      else
        expect_code 1 "$RC" "app-status-$kind-absent: an unreported app-bound status must refuse"
        assert_grep "required check 'license/cla' has not reported" "$case_dir/stderr" \
          "app-status-$kind-absent: the unreported status was not named"
        assert_no_grep 'pr merge' "$case_dir/gh.log" \
          "app-status-$kind-absent: gh pr merge ran with the status unreported"
      fi
    done
  done
  pass "fm-pr-merge matches an app-bound required commit status by name"
}

test_required_partial_reads_report_all_failures() {
  local case_dir head variant
  head=a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1
  for variant in branch rules both; do
    case_dir=$(make_case "required-partial-$variant")
    add_gh_mocks "$case_dir" "$head"
    write_github_required "$case_dir" classic:validate ruleset:lint
    case "$variant" in
      branch|both) printf 'read failed' > "$case_dir/github-branch-fail" ;;
    esac
    case "$variant" in
      rules|both) printf 'read failed' > "$case_dir/github-required-rules-fail" ;;
    esac
    run_required_case "$case_dir" 111
    expect_code 1 "$RC" "partial-$variant must refuse"
    case "$variant" in
      branch|both) assert_grep 'branch protection summary for base branch main could not be read' "$case_dir/stderr" "lost branch error" ;;
    esac
    case "$variant" in
      rules|both) assert_grep 'branch rules for base branch main could not be read' "$case_dir/stderr" "lost rules error" ;;
    esac
    case "$variant" in
      branch) assert_grep "required check 'lint' has not reported" "$case_dir/stderr" "lost rules requirement" ;;
      rules) assert_grep "required check 'validate' has not reported" "$case_dir/stderr" "lost classic requirement" ;;
    esac
    assert_no_grep 'pr merge' "$case_dir/gh.log" "partial read reached merge"
  done
  pass "fm-pr-merge reports known missing checks and all independent read errors"
}

test_allow_red_refused_on_forgejo() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-allow-red)
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "forgejo-allow-red: --allow-red must not apply on Forgejo"
  assert_grep '--allow-red does not apply to Forgejo' "$case_dir/stderr" \
    "forgejo-allow-red: refusal did not name Forgejo"
  [ ! -s "$case_dir/tea.log" ] || fail "forgejo-allow-red: tea ran despite --allow-red"
  pass "fm-pr-merge refuses --allow-red on Forgejo"
}

test_allow_missing_refused_on_forgejo() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-allow-missing)
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" --allow-missing validate \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "forgejo-allow-missing: --allow-missing must not apply on Forgejo"
  assert_grep '--allow-missing does not apply to Forgejo' "$case_dir/stderr" \
    "forgejo-allow-missing: refusal did not name Forgejo"
  [ ! -s "$case_dir/tea.log" ] || fail "forgejo-allow-missing: tea ran despite --allow-missing"
  pass "fm-pr-merge refuses --allow-missing on Forgejo"
}

# One coherent green-head refusal: each failing check is named with whether the
# base branch requires it and whether it is still running or has failed, then
# the exact re-run that waits and each exact attended waiver. The flags are the
# ones the script really supports (--allow-red and --allow-missing); --wait and
# --waive-check do not exist and must never be invented.
test_green_head_refusal_names_each_check_and_its_repair() {
  local case_dir rc head url
  head=a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4
  url=https://github.com/example/repo/pull/191
  case_dir=$(make_case github-green-head-message)
  add_gh_mocks "$case_dir" "$head"
  write_github_rollup_json "$case_dir" "$head" \
    "$(check_run ci COMPLETED FAILURE)" \
    "$(check_run docs IN_PROGRESS -)"
  write_github_required "$case_dir" classic:ci ruleset:validate

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "green-head-message: the refusal must keep its exit status"
  assert_grep "check 'ci' is not green: it failed, and it is required by base branch main" \
    "$case_dir/stderr" \
    "green-head-message: the failed required check was not described in one line"
  assert_grep "check 'docs' is not green: it is still running, and it is not required by base branch main" \
    "$case_dir/stderr" \
    "green-head-message: the pending check was not described as still running"
  assert_grep "required check 'validate' has not reported at head $head" \
    "$case_dir/stderr" \
    "green-head-message: the unreported required check was not named"
  assert_grep "Wait for the pending or unreported check to report, then re-run this merge: $PR_MERGE task-x1 $url" \
    "$case_dir/stderr" \
    "green-head-message: the wait repair was not printed as a runnable command"
  assert_grep "A failed check clears only when the same check passes on a later run, then re-run this merge: $PR_MERGE task-x1 $url" \
    "$case_dir/stderr" \
    "green-head-message: the failed-check repair was not printed as a runnable command"
  assert_grep "Attended only, waive one named check with: $PR_MERGE task-x1 $url --allow-red ci" \
    "$case_dir/stderr" \
    "green-head-message: the exact --allow-red repair was not printed"
  assert_grep "Attended only, waive one named unreported required check with: $PR_MERGE task-x1 $url --allow-missing validate" \
    "$case_dir/stderr" \
    "green-head-message: the exact --allow-missing repair was not printed"
  assert_no_grep '--waive-check' "$case_dir/stderr" \
    "green-head-message: a waiver flag the script does not support was named"
  assert_no_grep ' --wait' "$case_dir/stderr" \
    "green-head-message: a --wait flag the script does not support was invented"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "green-head-message: gh pr merge ran on a refused head"
  pass "fm-pr-merge prints one green-head refusal naming each check, its requirement, its next action, and the exact repair"
}

# The away refusal is the other half of the same authority question: it must
# say that the away posture owns supervision now, that no waiver exists, and
# what the captain runs when attended.
test_away_waiver_refusal_names_the_posture_and_the_attended_path() {
  local case_dir rc head url
  head=acacacacacacacacacacacacacacacacacacacac
  url=https://github.com/example/repo/pull/192
  case_dir=$(make_case github-away-waiver-message)
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --words 'merge task-x1 when green'

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 2 "$rc" "away-waiver-message: --allow-red must still be refused while away"
  assert_grep '--allow-red is attended-only' "$case_dir/stderr" \
    "away-waiver-message: the refusal no longer names attended-only"
  assert_grep 'the away posture owns supervision now' "$case_dir/stderr" \
    "away-waiver-message: the refusal did not name the away posture as the owner of supervision"
  assert_grep "When the captain is attended, re-run this merge and waive that one check by name: $PR_MERGE task-x1 $url --allow-red lint" \
    "$case_dir/stderr" \
    "away-waiver-message: the attended path was not printed as a runnable command"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-waiver-message: gh pr merge ran despite the away refusal"

  # The green-check refusal tells the same truth from the other side: while
  # away, the failed check is named with no waiver offer at all.
  case_dir=$(make_case github-away-green-head-message)
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  write_away_record "$case_dir" --words 'merge task-x1 when green'
  set +e
  run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/196" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "away-waiver-message: an away red merge must still refuse"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "away-waiver-message: the away green-head refusal did not name the check"
  assert_grep 'No waiver is available in this away posture: the away record owns supervision now' \
    "$case_dir/stderr" \
    "away-waiver-message: the green-head refusal did not rule out the away waiver"
  assert_no_grep '--allow-red lint' "$case_dir/stderr" \
    "away-waiver-message: the green-head refusal offered a waiver while away"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "away-waiver-message: gh pr merge ran on an away red head"
  pass "fm-pr-merge names the away posture and the attended waiver command when it refuses a waiver while away"
}

# A held task is a dead end unless the refusal carries the release command and
# the task id it must be run against. The fixture then runs that exact command
# to prove the printed remedy really clears the hold.
test_held_task_refusal_prints_the_exact_release_command() {
  local case_dir rc head url
  head=aeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeaeae
  url=https://github.com/example/repo/pull/193
  case_dir=$(make_case github-held-task-message)
  add_gh_mocks "$case_dir" "$head"
  hold_fixture_task "$case_dir"

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "held-task-message: a held task must still refuse the merge"
  assert_grep 'task task-x1 is still held for the captain; nothing was merged' \
    "$case_dir/stderr" \
    "held-task-message: the refusal did not name the task and the consequence"
  assert_grep "$ROOT/bin/fm-captain-hold.sh answer task-x1 --decision-file" \
    "$case_dir/stderr" \
    "held-task-message: the exact release command with the task id was not printed"
  assert_grep '--release' "$case_dir/stderr" \
    "held-task-message: the release flag was not printed"
  assert_no_grep 'captain-hold.sh close' "$case_dir/stderr" \
    "held-task-message: a release subcommand the script does not support was named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "held-task-message: gh pr merge ran while the task was still held"

  printf '%s\n' 'merge it once the checks are green' > "$case_dir/captain-answer"
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    TASKS_AXI_BACKEND=markdown \
    "$ROOT/bin/fm-captain-hold.sh" answer task-x1 \
      --decision-file "$case_dir/captain-answer" --release >/dev/null \
    || fail "held-task-message: the printed release command did not release the hold"
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout-released" 2> "$case_dir/stderr-released" \
    || fail "held-task-message: the released hold still refused the merge: $(cat "$case_dir/stderr-released")"
  assert_logged_gh_merge "$case_dir" 193 example/repo --squash
  pass "fm-pr-merge prints the exact captain-hold release command with the real task id"
}

# One event per guard decision. A refused merge appends a single green-head
# deny, a green merge appends allows, and an unwritable log cannot change the
# merge's own exit status because the writer is never in a deciding condition.
test_guard_events_record_the_merge_decisions_without_changing_them() {
  local case_dir rc head url
  head=afafafafafafafafafafafafafafafafafafafaf
  url=https://github.com/example/repo/pull/194
  case_dir=$(make_case github-guard-events-refused)
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint

  set +e
  FM_GUARD_EVENT_LOG="$case_dir/refused-guard-events.jsonl" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "guard-events: a refused merge must keep its exit status"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "guard-events: the refused merge no longer names the red check"
  assert_equals 1 "$(count_guard_events "$case_dir/refused-guard-events.jsonl" merge-green-head deny)" \
    "guard-events: a refused merge must append exactly one merge-green-head deny"
  assert_equals 1 "$(count_guard_events "$case_dir/refused-guard-events.jsonl" merge-held-task allow)" \
    "guard-events: the released hold decision must append one merge-held-task allow"
  assert_equals true "$("$JQ_BIN" -s '[.[] | select(.guard == "merge-green-head" and .decision == "deny")][0].source_ok' \
    "$case_dir/refused-guard-events.jsonl")" \
    "guard-events: the deny did not record a readable source"
  assert_equals 0 "$("$JQ_BIN" -s '[.[] | select(.guard == "merge-green-head" and .decision == "deny")][0].elapsed_ms' \
    "$case_dir/refused-guard-events.jsonl")" \
    "guard-events: the deny did not record elapsed-ms 0"

  mkdir -p "$case_dir/guard-events-dir"
  set +e
  FM_GUARD_EVENT_LOG="$case_dir/guard-events-dir" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      > "$case_dir/stdout-unwritable" 2> "$case_dir/stderr-unwritable"
  rc=$?
  set -e
  expect_code 1 "$rc" "guard-events: an unwritable log must not change the refusal's exit status"
  assert_grep "check 'lint' is not green" "$case_dir/stderr-unwritable" \
    "guard-events: an unwritable log changed what the refusal said"

  url=https://github.com/example/repo/pull/195
  case_dir=$(make_case github-guard-events-allowed)
  add_gh_mocks "$case_dir" "$head"
  FM_GUARD_EVENT_LOG="$case_dir/allowed-guard-events.jsonl" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "guard-events: the green merge should have proceeded: $(cat "$case_dir/stderr")"
  assert_equals 1 "$(count_guard_events "$case_dir/allowed-guard-events.jsonl" merge-green-head allow)" \
    "guard-events: a green merge must append one merge-green-head allow"
  assert_equals 1 "$(count_guard_events "$case_dir/allowed-guard-events.jsonl" merge-held-task allow)" \
    "guard-events: a green merge must append one merge-held-task allow"
  assert_equals retry "$("$JQ_BIN" -sr '[.[] | select(.guard == "merge-green-head" and .decision == "allow")][0].cleared_by' \
    "$case_dir/allowed-guard-events.jsonl")" \
    "guard-events: the allow did not record cleared-by retry"
  pass "fm-pr-merge emits one guard event per merge decision and never lets telemetry decide the merge"
}

test_github_review_required_refuses() {
  local case_dir rc head
  head=5555555555555555555555555555555555555555
  case_dir=$(make_case github-review-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  jq -c '.reviewDecision = "REVIEW_REQUIRED"' "$case_dir/github-view.json" > "$case_dir/github-view.tmp"
  mv "$case_dir/github-view.tmp" "$case_dir/github-view.json"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/86 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-review-required: a PR awaiting review must refuse"
  assert_grep 'reviewDecision is REVIEW_REQUIRED' "$case_dir/stderr" \
    "github-review-required: the refusal did not name the review requirement"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-review-required: gh pr merge ran on a PR awaiting review"
  pass "fm-pr-merge refuses a PR whose reviewDecision is REVIEW_REQUIRED"
}

pr_merge_test_cases=(
test_multi_pr_task_merges_named_pr_when_copy_head_is_a_merged_siblings_head
test_single_pr_task_with_a_local_only_head_is_still_refused
test_multi_pr_task_without_a_reported_forge_head_is_still_refused
test_multi_pr_task_with_a_red_head_is_still_refused
test_github_draft_or_unreadable_draft_state_refuses
test_superseded_failed_check_run_no_longer_refuses
test_check_runs_never_supersede_status_contexts
test_current_failed_check_run_still_refuses
test_late_finishing_old_success_does_not_hide_current_failure
test_late_finishing_old_cancellation_is_superseded
test_unfinished_rerun_keeps_a_check_red
test_supersession_never_crosses_check_names
test_undated_runs_never_supersede
test_allow_red_still_waives_only_the_current_failure
test_allow_red_is_refused_while_away
test_quiet_record_keeps_merges_attended
test_allow_red_requires_one_separate_name
test_away_record_permits_any_green_merge_under_away_authority
test_away_branch_actor_merges_green_under_the_record
test_away_branch_refuses_when_record_archived_during_preflight
test_away_posture_refuses_asynchronous_merge_paths
test_away_plan_gated_403_does_not_block_the_merge
test_away_record_does_not_bypass_red_or_identity
test_unreadable_away_record_refuses_merge
test_away_record_cannot_change_between_the_authority_read_and_the_merge
test_a_record_made_unreadable_before_the_merge_refuses_it
test_merge_refuses_when_the_away_record_cannot_be_locked
test_allow_red_refused_on_gitlab
test_required_check_that_never_reported_refuses
test_required_checks_reported_and_green_merge
test_red_and_unreported_checks_are_reported_together
test_unreadable_required_set_refuses
test_allow_missing_waives_only_the_named_unreported_check
test_allow_missing_follows_the_allow_red_rules
test_rollup_read_retries_and_rechecks_complete_verdict
test_unreadable_rollup_never_becomes_missing_or_waivable
test_rollup_later_pages_enforce_missing_and_red_checks
test_partial_producer_read_retries_before_merging
test_required_sources_retry_transient_failures
test_incomplete_producer_source_cannot_be_waived
test_required_producer_identity
test_app_bound_required_status_context_matches_by_name
test_required_partial_reads_report_all_failures
test_allow_red_refused_on_forgejo
test_allow_missing_refused_on_forgejo
test_green_head_refusal_names_each_check_and_its_repair
test_away_waiver_refusal_names_the_posture_and_the_attended_path
test_held_task_refusal_prints_the_exact_release_command
test_guard_events_record_the_merge_decisions_without_changing_them
test_github_review_required_refuses
)
pr_merge_run "$@"
