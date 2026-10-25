#!/usr/bin/env bash
# bin/fm-pr-merge.sh on the other forges and around the merge: GitLab and
# Forgejo resolution and refusals, secondmate and local reporting, and the
# backlog and backend-configuration reads.
# The GitHub outcome and authority cases live in tests/fm-pr-merge.test.sh;
# the check-run, rollup, and waiver cases live in
# tests/fm-pr-merge-checks.test.sh.
# Shared fixtures: tests/fm-pr-merge-helpers.sh.

# shellcheck source=tests/fm-pr-merge-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pr-merge-helpers.sh"

# A bundled short-option cluster carries -R without ever being exactly -R, and
# both CLIs expand it one character at a time, so the guard has to read the
# whole cluster. On GitLab that redirect names an instance, not only a
# repository, so it must refuse before anything is recorded or read.
test_bundled_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case bundled-repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" abababababababababababababababababababab
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/6 -- -dR wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override: fm-pr-merge should refuse a bundled repo override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/6' "$case_dir/state/task-x1.meta" \
    "bundled-repo-override: PR URL was recorded before rejecting the bundled repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override: a bundled repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "bundled-repo-override: gh-axi pr merge was invoked despite the bundled repo override"

  case_dir=$(make_gitlab_case bundled-repo-override-gitlab)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- -yR https://other.example/g/p \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "bundled-repo-override-gitlab: fm-pr-merge should refuse a bundled instance override"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "bundled-repo-override-gitlab: refusal did not explain the repo override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "bundled-repo-override-gitlab: the URL was recorded before rejecting the bundled override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "bundled-repo-override-gitlab: a bundled override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] \
    || fail "bundled-repo-override-gitlab: glab was invoked despite the bundled override"

  # Only a cluster carrying the repository flag is refused: every other short
  # cluster is still the caller's business and still reaches the forge.
  case_dir=$(make_case bundled-non-repo-cluster)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "bundled-non-repo-cluster: -d is branch deletion and must be refused"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "bundled-non-repo-cluster: refusal did not name --attended-override"

  case_dir=$(make_case bundled-delete-attended)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" bcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbcbc
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/8 --attended-override -- -d \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "bundled-delete-attended: attended override should merge"
  assert_logged_gh_merge "$case_dir" 8 example/repo --squash -d
  pass "fm-pr-merge refuses a bundled short-option repo override and refuses -d unless attended"
}

test_explicit_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case explicit-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/22 -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "explicit-merge-method: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 22 example/repo --merge
  pass "fm-pr-merge does not add default --squash when the caller passes an explicit merge method"
}

test_method_equals_merge_method_not_overridden() {
  local case_dir
  case_dir=$(make_case method-equals-merge-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/23 -- --method=merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "method-equals-merge-method: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 23 example/repo --method=merge
  pass "fm-pr-merge respects --method=<value> as an explicit merge method"
}

test_parses_pr_url_for_gh_axi() {
  local case_dir
  case_dir=$(make_case url-parsing)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"

  run_pr_merge "$case_dir" task-x1 https://github.com/my-org/my-repo/pull/126 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "url-parsing: fm-pr-merge failed"

  assert_logged_gh_merge "$case_dir" 126 my-org/my-repo --squash
  pass "fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments"
}

test_github_still_forwards_sha_arg() {
  local case_dir rc
  case_dir=$(make_case github-sha-arg)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" dddddddddddddddddddddddddddddddddddddddd
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/44 -- --sha abc123 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-sha-arg: a caller --sha must be refused on GitHub too"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "github-sha-arg: refusal did not name the head override"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-sha-arg: gh pr merge ran despite the head override"
  pass "fm-pr-merge refuses a caller --sha on GitHub because the head comes from the live read"
}

test_gitlab_url_resolves_and_merges() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-merges)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-merges: a well-formed merge request URL should merge, not error"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merges: pr= was not recorded before merging"
  assert_grep "GITLAB_HOST=$MR_HOST mr view 7 -R $MR_PROJECT_URL -F json" "$case_dir/glab.log" \
    "gitlab-merges: the pre-merge state was not read from the project URL"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes" ] \
    || fail "gitlab-merges: unexpected merge invocation: '$merge_line'"
  assert_grep "successful pipeline at head $MR_HEAD" "$case_dir/stderr" \
    "gitlab-merges: the verified head was not reported"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "gitlab-merges: a merge request reached the GitHub CLI"
  pass "fm-pr-merge merges a GitLab merge request through glab instead of refusing it"
}

test_gitlab_host_comes_from_the_url() {
  local case_dir rc host path project_url url
  host=gl.self-hosted.example
  path=deep/nested/group/project
  project_url="https://$host/$path"
  url="$project_url/-/merge_requests/31"
  case_dir=$(make_gitlab_case gitlab-host-from-url)

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-host-from-url: a self-hosted merge request should merge"
  assert_grep "GITLAB_HOST=$host mr view 31 -R $project_url -F json" "$case_dir/glab.log" \
    "gitlab-host-from-url: the read did not use the host from the URL"
  assert_grep "GITLAB_HOST=$host mr merge 31 -R $project_url" "$case_dir/glab.log" \
    "gitlab-host-from-url: the merge did not use the host from the URL"
  assert_no_grep 'gitlab.com' "$case_dir/glab.log" \
    "gitlab-host-from-url: a host was assumed instead of taken from the URL"
  assert_no_grep '<unset>' "$case_dir/glab.log" \
    "gitlab-host-from-url: glab was left to resolve the instance from its own default"
  pass "fm-pr-merge takes the GitLab instance from the URL rather than assuming one"
}

test_gitlab_imposes_no_merge_method() {
  local case_dir rc merge_line flag
  case_dir=$(make_gitlab_case gitlab-no-method)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-no-method: merge should succeed"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  for flag in --squash --rebase --merge --method; do
    case "$merge_line" in
      *"$flag"*) fail "gitlab-no-method: '$flag' was imposed on GitLab: '$merge_line'" ;;
    esac
  done
  pass "fm-pr-merge imposes no merge method on GitLab, leaving the project's own one"
}

test_gitlab_extra_args_forwarded() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-extra-args)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "gitlab-extra-args: source-branch deletion must be refused without --attended-override"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "gitlab-extra-args: refusal did not name --attended-override"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-extra-args: glab ran despite the denylist"

  case_dir=$(make_gitlab_case gitlab-extra-args-attended)
  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" --attended-override -- --remove-source-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "gitlab-extra-args-attended: attended override should merge"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  [ "$merge_line" = "GITLAB_HOST=$MR_HOST mr merge 7 -R $MR_PROJECT_URL --sha $MR_HEAD --yes --remove-source-branch" ] \
    || fail "gitlab-extra-args-attended: extra glab flags were not forwarded: '$merge_line'"
  pass "fm-pr-merge refuses GitLab source-branch deletion unless --attended-override is passed"
}

test_gitlab_merge_failure_propagates() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-merge-fails)
  : > "$case_dir/glab-merge-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-merge-fails: a failing glab merge should not report success"
  assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-merge-fails: pr= should already be recorded even though the merge failed"
  pass "fm-pr-merge propagates a real glab merge failure without silently succeeding"
}

# Each pre-merge condition, driven one at a time, so no condition can be
# carried by another. The refusal names that condition, no merge is attempted,
# and pr= is still recorded and the poll still armed exactly as the GitHub path
# leaves them when live verification or the gh merge fails.
test_gitlab_each_condition_refuses_independently() {
  local case_dir rc name expected spec
  set -- \
    "state|state=closed|state is \"closed\", not open" \
    "detail|detail=need_rebase|detailed_merge_status is \"need_rebase\", not mergeable" \
    "conflicts|conflicts=true|has_conflicts is \"true\", not false" \
    "discussions|discussions=false|blocking_discussions_resolved is \"false\", not true" \
    "pipeline-status|pipeline_status=failed|the head pipeline status is \"failed\", not success" \
    "pipeline-sha|pipeline_sha=$MR_STALE_HEAD|the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD" \
    "no-pipeline|pipeline=null|the head pipeline status is \"none\", not success"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    case_dir=$(make_gitlab_case "gitlab-refuse-$name" "${spec%%|*}")

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-refuse-$name: fm-pr-merge should refuse"
    assert_grep "error: refusing to merge $MR_URL" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the merge request"
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-$name: refusal did not name the failing condition"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-refuse-$name: a merge was attempted despite the refusal"
    assert_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-refuse-$name: a refusal should still leave the recorded PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "gitlab-refuse-$name: a refusal should still leave the merge poll armed"
  done
  pass "fm-pr-merge refuses on each GitLab pre-merge condition independently"
}

test_gitlab_reports_every_failing_condition() {
  local case_dir rc expected
  case_dir=$(make_gitlab_case gitlab-refuse-all \
    state=closed detail=conflict conflicts=true discussions=false \
    pipeline_status=failed "pipeline_sha=$MR_STALE_HEAD")

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refuse-all: fm-pr-merge should refuse"
  for expected in \
    'state is "closed", not open' \
    'detailed_merge_status is "conflict", not mergeable' \
    'has_conflicts is "true", not false' \
    'blocking_discussions_resolved is "false", not true' \
    'the head pipeline status is "failed", not success' \
    "the head pipeline ran at \"$MR_STALE_HEAD\", not at the current head $MR_HEAD"
  do
    assert_grep "$expected" "$case_dir/stderr" \
      "gitlab-refuse-all: '$expected' was not reported"
  done
  pass "fm-pr-merge reports every failing GitLab condition, not only the first"
}

test_gitlab_stale_recorded_head_is_reported() {
  local case_dir rc merge_line
  case_dir=$(make_gitlab_case gitlab-stale-head)
  # The recorded head is what a rebase leaves behind. It is read before
  # fm-pr-check.sh rewrites the metadata, which drops a head it cannot resolve
  # for a GitLab task, so reading it afterwards would find nothing at all.
  printf 'pr_head=%s\n' "$MR_STALE_HEAD" >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "gitlab-stale-head: the live head satisfies every condition, so it should merge"
  assert_grep "recorded head $MR_STALE_HEAD disagrees with the live head $MR_HEAD" \
    "$case_dir/stderr" "gitlab-stale-head: the stale recorded head was trusted silently"
  merge_line=$(glab_merge_line "$case_dir/glab.log")
  case "$merge_line" in
    *"--sha $MR_HEAD"*) : ;;
    *) fail "gitlab-stale-head: the merge was not bound to the live head: '$merge_line'" ;;
  esac
  assert_no_grep "pr_head=$MR_STALE_HEAD" "$case_dir/state/task-x1.meta" \
    "gitlab-stale-head: the recording step no longer drops an unresolvable GitLab head"
  pass "fm-pr-merge reports a stale recorded head and verifies the live one"
}

test_gitlab_unreadable_state_refuses() {
  local case_dir rc name
  for name in view-fails not-an-object split-value; do
    case_dir=$(make_gitlab_case "gitlab-unreadable-$name")
    case "$name" in
      view-fails) : > "$case_dir/glab-view-fails" ;;
      not-an-object) printf '[]\n' > "$case_dir/mr.json" ;;
      # A value carrying a newline splits into a line no field name matches, so
      # it must refuse rather than be truncated into a value a check accepts.
      split-value) write_mr_json "$case_dir/mr.json" 'state=opened\nnot-a-field' ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$MR_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-unreadable-$name: fm-pr-merge should refuse"
    assert_grep 'could not read the GitLab merge request state before merging' \
      "$case_dir/stderr" "gitlab-unreadable-$name: refusal did not name the unreadable state"
    [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
      || fail "gitlab-unreadable-$name: a merge was attempted on an unreadable state"
  done
  pass "fm-pr-merge refuses an unreadable GitLab merge request state rather than merging blind"
}

test_gitlab_invalid_head_refuses() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-invalid-head head=not-a-sha)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-invalid-head: fm-pr-merge should refuse"
  assert_grep 'could not read the GitLab merge request head commit before merging' \
    "$case_dir/stderr" "gitlab-invalid-head: refusal did not name the unreadable head"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] \
    || fail "gitlab-invalid-head: a merge was bound to a head that is not a commit"
  pass "fm-pr-merge refuses a GitLab head commit it cannot validate"
}

test_gitlab_missing_tool_refuses_before_recording() {
  local case_dir rc tool other
  for tool in glab jq; do
    if [ "$tool" = glab ]; then other=jq; else other=glab; fi
    case_dir=$(make_gitlab_case "gitlab-no-$tool")
    mirror_path_without "$case_dir/no$tool" "$tool" "$case_dir/fakebin"
    # One tool absent, the other still answered by this case's own mock, so the
    # refusal names exactly one tool on a host that ships neither.
    PATH="$case_dir/no$tool" command -v "$other" >/dev/null 2>&1 \
      || fail "gitlab-no-$tool: the $tool-free search path lost the $other mock as well"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_GLAB_LOG="$case_dir/glab.log" \
    FM_TEST_GLAB_JSON="$case_dir/mr.json" \
    PATH="$case_dir/no$tool" \
      "$PR_MERGE" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "gitlab-no-$tool: fm-pr-merge should refuse"
    assert_grep "error: merging a GitLab merge request requires $tool on PATH" \
      "$case_dir/stderr" "gitlab-no-$tool: refusal did not name the missing tool"
    assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
      "gitlab-no-$tool: a PR reference was recorded despite the missing tool"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "gitlab-no-$tool: a merge poll was armed despite the missing tool"
  done
  pass "fm-pr-merge refuses before recording anything when glab or jq is absent"
}

test_forgejo_url_resolves_and_merges() {
  local case_dir rc merge_line
  case_dir=$(make_forgejo_case forgejo-merges)

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-merges: a well-formed pull request URL should merge, not error"
  assert_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
    "forgejo-merges: pr= was not recorded before merging"
  assert_grep "--login $FJ_LOGIN --repo $FJ_OWNER/$FJ_REPO /repos/{owner}/{repo}/pulls/9" "$case_dir/tea.log" \
    "forgejo-merges: the pre-merge state was not read through the resolved login and repo slug"
  merge_line=$(tea_merge_line "$case_dir/tea.log")
  case "$merge_line" in
    *"--login $FJ_LOGIN --repo $FJ_OWNER/$FJ_REPO -X POST /repos/{owner}/{repo}/pulls/9/merge -f Do=merge -f head_commit_id=$FJ_HEAD"*) : ;;
    *) fail "forgejo-merges: unexpected merge invocation: '$merge_line'" ;;
  esac
  assert_grep "successful combined status at head $FJ_HEAD" "$case_dir/stderr" \
    "forgejo-merges: the verified head was not reported"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "forgejo-merges: a pull request reached the GitHub CLI"
  pass "fm-pr-merge merges a Forgejo pull request through tea api instead of refusing it"
}

test_forgejo_login_resolves_from_the_host() {
  local case_dir rc host url
  host=git.self-hosted.example
  url="https://$host/$FJ_OWNER/$FJ_REPO/pulls/12"
  case_dir=$(make_forgejo_case forgejo-login-from-host)
  write_tea_logins_json "$case_dir/tea-logins.json" \
    other "https://unrelated.example" "$FJ_LOGIN" "https://$host:3000"

  set +e
  run_pr_merge "$case_dir" task-x1 "$url" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-login-from-host: the matching login (port stripped) should be resolved and merge"
  assert_grep "--login $FJ_LOGIN --repo $FJ_OWNER/$FJ_REPO /repos/{owner}/{repo}/pulls/12" "$case_dir/tea.log" \
    "forgejo-login-from-host: the login was not resolved from the URL's host"
  assert_no_grep 'other' "$case_dir/tea.log" \
    "forgejo-login-from-host: an unrelated login name leaked into a tea invocation"
  pass "fm-pr-merge resolves the tea login by matching the PR's host against every registered login"
}

test_forgejo_refuses_when_login_is_ambiguous() {
  local case_dir rc name
  for name in none two; do
    case_dir=$(make_forgejo_case "forgejo-login-$name")
    case "$name" in
      none) write_tea_logins_json "$case_dir/tea-logins.json" unrelated "https://elsewhere.example" ;;
      two) write_tea_logins_json "$case_dir/tea-logins.json" a "https://$FJ_HOST" b "https://$FJ_HOST" ;;
    esac

    set +e
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "forgejo-login-$name: fm-pr-merge should refuse"
    assert_grep "requires exactly one 'tea login' registered for that host" "$case_dir/stderr" \
      "forgejo-login-$name: refusal did not name the login requirement"
    assert_no_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
      "forgejo-login-$name: a PR reference was recorded despite the ambiguous login"
    [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
      || fail "forgejo-login-$name: a merge was attempted with an unresolved login"
  done
  pass "fm-pr-merge refuses when zero or more than one tea login matches the pull request's host"
}

test_forgejo_each_condition_refuses_independently() {
  local case_dir rc name expected spec
  set -- \
    "state|state=closed|state is \"closed\", not open" \
    "mergeable|mergeable=false|mergeable is \"false\", not true" \
    "draft|draft=true|the pull request is a draft"
  for spec in "$@"; do
    name=${spec%%|*}
    expected=${spec##*|}
    spec=${spec#*|}
    case_dir=$(make_forgejo_case "forgejo-refuse-$name" "${spec%%|*}")

    set +e
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "forgejo-refuse-$name: fm-pr-merge should refuse"
    assert_grep "error: refusing to merge $FJ_URL" "$case_dir/stderr" \
      "forgejo-refuse-$name: refusal did not name the pull request"
    assert_grep "$expected" "$case_dir/stderr" \
      "forgejo-refuse-$name: refusal did not name the failing condition"
    [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
      || fail "forgejo-refuse-$name: a merge was attempted despite the refusal"
    assert_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
      "forgejo-refuse-$name: a refusal should still leave the recorded PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "forgejo-refuse-$name: a refusal should still leave the merge poll armed"
  done
  pass "fm-pr-merge refuses on each Forgejo pre-merge condition independently"
}

test_forgejo_unconfigured_ci_refuses_as_none() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-ci-none)
  write_forgejo_status_json "$case_dir/tea-status.json" total_count=0

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-ci-none: an open, mergeable PR with no configured CI should still refuse"
  assert_grep 'the combined commit status is "none", not success' "$case_dir/stderr" \
    "forgejo-ci-none: an absent combined status was not reported as none"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-ci-none: a merge was attempted with no configured CI"
  pass "fm-pr-merge treats an unconfigured Forgejo combined status as none, refusing rather than skipping the check"
}

# The combined status endpoint computes its state from one page of contexts,
# so a failing context on a later page must still refuse the merge, and a
# head whose every page is green must still merge.
test_forgejo_combined_status_reads_every_page() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-status-page2-red)
  write_forgejo_status_json "$case_dir/tea-status-page2.json" state=failure

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-status-page2-red: a failing context on page 2 should refuse"
  assert_grep 'the combined commit status is "failure", not success' "$case_dir/stderr" \
    "forgejo-status-page2-red: the later page's failure was not reported"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-status-page2-red: a merge was attempted past a failing later page"

  case_dir=$(make_forgejo_case forgejo-status-page2-green)
  write_forgejo_status_json "$case_dir/tea-status-page2.json"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-status-page2-green: every green page should merge"
  assert_grep 'page=2' "$case_dir/tea.log" \
    "forgejo-status-page2-green: the second status page was never read"
  pass "fm-pr-merge reads every Forgejo combined-status page before merging"
}

test_forgejo_stale_recorded_head_is_reported() {
  local case_dir rc merge_line
  case_dir=$(make_forgejo_case forgejo-stale-head)
  # The recorded head is what a rebase leaves behind. It is read before
  # fm-pr-check.sh rewrites the metadata, which drops a head it cannot resolve
  # for a Forgejo task, so reading it afterwards would find nothing at all.
  printf 'pr_head=%s\n' "$FJ_STALE_HEAD" >> "$case_dir/state/task-x1.meta"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-stale-head: the live head satisfies every condition, so it should merge"
  assert_grep "recorded head $FJ_STALE_HEAD disagrees with the live head $FJ_HEAD" \
    "$case_dir/stderr" "forgejo-stale-head: the stale recorded head was trusted silently"
  merge_line=$(tea_merge_line "$case_dir/tea.log")
  case "$merge_line" in
    *"head_commit_id=$FJ_HEAD"*) : ;;
    *) fail "forgejo-stale-head: the merge was not bound to the live head: '$merge_line'" ;;
  esac
  assert_no_grep "pr_head=$FJ_STALE_HEAD" "$case_dir/state/task-x1.meta" \
    "forgejo-stale-head: the recording step no longer drops an unresolvable Forgejo head"
  pass "fm-pr-merge reports a stale recorded head and binds the merge to the live one instead"
}

test_forgejo_invalid_head_refuses() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-invalid-head head=not-a-sha)

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-invalid-head: fm-pr-merge should refuse"
  assert_grep 'could not read the Forgejo pull request head commit before merging' \
    "$case_dir/stderr" "forgejo-invalid-head: refusal did not name the unreadable head"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-invalid-head: a merge was bound to a head that is not a commit"
  pass "fm-pr-merge refuses a Forgejo head commit it cannot validate"
}

test_forgejo_missing_tool_refuses_before_recording() {
  local case_dir rc tool other
  for tool in tea jq; do
    if [ "$tool" = tea ]; then other=jq; else other=tea; fi
    case_dir=$(make_forgejo_case "forgejo-no-$tool")
    mirror_path_without "$case_dir/no$tool" "$tool" "$case_dir/fakebin"
    PATH="$case_dir/no$tool" command -v "$other" >/dev/null 2>&1 \
      || fail "forgejo-no-$tool: the $tool-free search path lost the $other mock as well"

    set +e
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
    FM_TEST_TEA_LOG="$case_dir/tea.log" \
    PATH="$case_dir/no$tool" \
      "$PR_MERGE" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "forgejo-no-$tool: fm-pr-merge should refuse"
    assert_grep "error: merging a Forgejo pull request requires $tool on PATH" \
      "$case_dir/stderr" "forgejo-no-$tool: refusal did not name the missing tool"
    assert_no_grep "pr=$FJ_URL" "$case_dir/state/task-x1.meta" \
      "forgejo-no-$tool: a PR reference was recorded despite the missing tool"
    assert_absent "$case_dir/state/task-x1.check.sh" \
      "forgejo-no-$tool: a merge poll was armed despite the missing tool"
  done
  pass "fm-pr-merge refuses before recording anything when tea or jq is absent"
}

# The single most consequential finding in docs/forgejo-tea-integration.md:
# "tea api" reports an HTTP-level failure (a head-out-of-date rejection
# included) with exit status 0, verified against a real instance. A rejected
# merge here must therefore be caught only by the follow-up confirm read, not
# by trusting this mock's own (successful) exit status.
test_forgejo_rejected_merge_is_never_trusted_by_exit_status() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-rejected-merge)
  : > "$case_dir/tea-merge-fails"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "forgejo-rejected-merge: a rejected merge must fail even though tea api itself exits 0"
  assert_grep "Forgejo did not confirm $FJ_URL as merged" "$case_dir/stderr" \
    "forgejo-rejected-merge: refusal did not report the unconfirmed merge"
  assert_grep '"message":"merge failed"' "$case_dir/stderr" \
    "forgejo-rejected-merge: the forge's own rejection body was not quoted"
  [ ! -e "$case_dir/tea-merged" ] || fail "forgejo-rejected-merge: the mock recorded a landed merge"
  pass "fm-pr-merge never trusts tea api's exit status alone; a rejected merge is caught by the confirm read"
}

test_forgejo_transient_confirm_read_failure_still_persists_authority() {
  local case_dir rc
  case_dir=$(make_forgejo_case forgejo-confirm-retry)
  printf '2\n' > "$case_dir/tea-post-merge-view-failures"

  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "forgejo-confirm-retry: a landed merge must not fail on a transient read-back failure"
  [ -e "$case_dir/tea-merged" ] || fail "forgejo-confirm-retry: the mock did not record the merge"
  [ "$(cat "$case_dir/tea-post-merge-view-failures")" = 0 ] \
    || fail "forgejo-confirm-retry: the confirmation read was not retried"
  [ "$(sed -n 6p "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)" = attended ] \
    || fail "forgejo-confirm-retry: the merge authority was not persisted: $(cat "$case_dir/state/task-x1.merge-authority" 2>/dev/null || true)"
  if grep -q "did not confirm" "$case_dir/stderr"; then
    fail "forgejo-confirm-retry: a landed merge was reported as unconfirmed"
  fi
  pass "fm-pr-merge retries a failed Forgejo confirmation read and persists the merge authority"
}

test_forgejo_merge_method_and_extra_args() {
  local case_dir rc merge_line style variant

  # With no method named, the repository's own default_merge_style decides,
  # whichever style it is.
  for style in squash rebase merge; do
    case_dir=$(make_forgejo_case "forgejo-default-method-$style")
    printf '{"default_merge_style":"%s"}\n' "$style" > "$case_dir/tea-repo.json"
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" \
      || fail "forgejo-default-method-$style: an unqualified merge should succeed: $(cat "$case_dir/stderr")"
    [ "$(cat "$case_dir/tea-merge-do" 2>/dev/null)" = "$style" ] \
      || fail "forgejo-default-method-$style: the unqualified merge did not use the repository's default style"
  done

  # A named method wins without the repository read deciding anything.
  case_dir=$(make_forgejo_case forgejo-named-beats-default)
  printf '{"default_merge_style":"rebase"}\n' > "$case_dir/tea-repo.json"
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" -- --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "forgejo-named-beats-default: --merge should succeed"
  [ "$(cat "$case_dir/tea-merge-do" 2>/dev/null)" = merge ] \
    || fail "forgejo-named-beats-default: a named method was overridden by the repository default"

  # An unreadable or unrecognized default refuses before any merge.
  for variant in unreadable unknown missing; do
    case_dir=$(make_forgejo_case "forgejo-default-$variant")
    case "$variant" in
      unreadable) : > "$case_dir/tea-repo-fails" ;;
      unknown) printf '{"default_merge_style":"manually-merged"}\n' > "$case_dir/tea-repo.json" ;;
      missing) printf '{"message":"not found"}\n' > "$case_dir/tea-repo.json" ;;
    esac
    set +e
    run_pr_merge "$case_dir" task-x1 "$FJ_URL" \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    expect_code 1 "$rc" "forgejo-default-$variant: a merge with no readable default style must be refused"
    assert_grep "the repository's default merge style could not be read" "$case_dir/stderr" \
      "forgejo-default-$variant: refusal did not name the unreadable default style"
    [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
      || fail "forgejo-default-$variant: a merge was attempted without a readable default style"
  done

  case_dir=$(make_forgejo_case forgejo-squash-method)
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" -- --squash \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "forgejo-squash-method: --squash should succeed"
  [ "$(cat "$case_dir/tea-merge-do" 2>/dev/null)" = squash ] \
    || fail "forgejo-squash-method: --squash did not select Do=squash"

  case_dir=$(make_forgejo_case forgejo-unsupported-arg)
  set +e
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" -- --admin-something-unrecognized \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "forgejo-unsupported-arg: an unrecognized extra argument must be refused"
  assert_grep 'extra merge arguments are not yet supported for Forgejo merges' "$case_dir/stderr" \
    "forgejo-unsupported-arg: refusal did not name the unsupported-argument reason"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] \
    || fail "forgejo-unsupported-arg: a merge was attempted despite the unsupported argument"

  pass "fm-pr-merge maps --squash/--rebase to Forgejo's Do field, defaults to the repository's default merge style, and refuses any other extra argument"
}

test_gitlab_head_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-head-override)

  set +e
  run_pr_merge "$case_dir" task-x1 "$MR_URL" -- --sha "$MR_STALE_HEAD" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-head-override: fm-pr-merge should refuse a caller head override"
  assert_grep 'extra merge arguments must not override the head commit' "$case_dir/stderr" \
    "gitlab-head-override: refusal did not explain the head override"
  assert_no_grep "pr=$MR_URL" "$case_dir/state/task-x1.meta" \
    "gitlab-head-override: the URL was recorded before rejecting the head override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "gitlab-head-override: a head override armed a merge poll"
  [ ! -s "$case_dir/glab.log" ] || fail "gitlab-head-override: glab was invoked despite the head override"
  pass "fm-pr-merge refuses a GitLab head override before recording state"
}

test_secondmate_merge_reports_upward_once() {
  local case_dir replies url
  url=https://github.com/example/repo/pull/61
  case_dir=$(make_home_case secondmate-merge-reports remote)
  add_gh_mocks "$case_dir" 5555555555555555555555555555555555555555
  : >"$case_dir/gh-axi.log"
  replies="$case_dir/state/parent-replies.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" <(sed -E 's/ \[at=[0-9]+\]//' "$replies") \
    "secondmate-merge-reports: the landed PR was not reported upward"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: one merge produced more than one upward merge line"
  # The merge path registers the PR first, and that registration publishes the
  # child's ready line on the same channel from fm-pr-check itself.
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url" <(sed -E 's/ \[at=[0-9]+\]//' "$replies") \
    "secondmate-merge-reports: the registration's ready line was not reported upward"

  # The same merge again: the forge accepts it in this fixture, so only the
  # at-most-once contract can keep the parent from being told twice.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout2" 2>"$case_dir/stderr2" || fail "secondmate-merge-reports: repeat merge failed"
  [ "$(grep -c 'merged-task-x1' "$replies")" -eq 1 ] \
    || fail "secondmate-merge-reports: a repeat merge of the same PR duplicated the upward line"
  [ "$(parent_reply_lines "$replies" "$url")" -eq 2 ] \
    || fail "secondmate-merge-reports: a repeat merge changed the upward lines: $(cat "$replies")"
  pass "a merge a secondmate home performs itself is reported upward exactly once"
}

test_secondmate_merge_reports_on_the_local_route() {
  local case_dir parent_status url
  url=https://github.com/example/repo/pull/62
  case_dir=$(make_home_case secondmate-merge-local local "$TMP_ROOT/secondmate-merge-local/parent")
  mkdir -p "$TMP_ROOT/secondmate-merge-local/parent/state"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : >"$case_dir/gh-axi.log"
  parent_status="$TMP_ROOT/secondmate-merge-local/parent/state/mate-x.status"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "secondmate-merge-local: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" <(sed -E 's/ \[at=[0-9]+\]//' "$parent_status") \
    "secondmate-merge-local: the landed PR did not reach the parent home's channel"
  [ ! -e "$case_dir/state/parent-replies.status" ] \
    || fail "secondmate-merge-local: a local-route report also wrote the remote reply channel"
  pass "a locally routed secondmate home reports the landed PR into its parent's own channel"
}

test_gitlab_merge_reports_upward() {
  local case_dir url
  case_dir=$(make_gitlab_case gitlab-merge-reports)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"
  url=$MR_URL

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "gitlab-merge-reports: merge failed"

  assert_grep "done [key=merged-task-x1]: merged task-x1 $url" \
    <(sed -E 's/ \[at=[0-9]+\]//' "$case_dir/state/parent-replies.status") \
    "gitlab-merge-reports: a landed merge request was not reported upward"
  pass "a landed GitLab merge request is reported upward on the same channel"
}

test_queued_gitlab_merge_leaves_the_poll_armed() {
  local case_dir
  case_dir=$(make_gitlab_case queued-gitlab-merge)
  mkdir -p "$case_dir/home"
  : >"$case_dir/glab-stays-open"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-gitlab-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-gitlab-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-gitlab-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-gitlab-merge: a queued merge was marked as reported"
  pass "a queued GitLab merge stays silent and leaves confirmation to the armed poll"
}

test_failed_merge_reports_nothing() {
  local case_dir rc
  case_dir=$(make_home_case failed-merge-silent remote)
  add_gh_mocks_merge_fails "$case_dir"
  : >"$case_dir/gh-axi.log"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "failed-merge-silent: a failed merge should propagate"
  # The registration's ready line is a fact of its own; only a merge line
  # would misreport the unlanded merge.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
    "failed-merge-silent: a merge that never landed was reported as landed"
  pass "a refused or failed merge reports no outcome"
}

test_gitlab_refusal_reports_nothing() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-refusal-silent state=merged)
  mkdir -p "$case_dir/home"
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' >"$case_dir/home/.fm-secondmate-parent"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gitlab-refusal-silent: a refused GitLab merge should exit non-zero"
  # Registration succeeds before the later GitLab pre-merge refusal, so the
  # PR-ready fact is expected; only a merged outcome would be false.
  assert_no_grep 'merged-task-x1' "$case_dir/state/parent-replies.status" \
    "gitlab-refusal-silent: a refused merge request was reported as landed"
  pass "a GitLab merge refused before the forge call reports no outcome"
}

test_main_home_merge_leaves_a_durable_wake() {
  local case_dir url
  url=https://github.com/example/repo/pull/64
  case_dir=$(make_home_case main-merge-wake)
  add_gh_mocks "$case_dir" 7777777777777777777777777777777777777777
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr" || fail "main-merge-wake: merge failed"

  assert_grep "$url" "$case_dir/state/.wake-queue" \
    "main-merge-wake: a merge this home performed left no durable record naming the PR"
  [ "$(grep -c -F "$url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "main-merge-wake: one merge produced more than one durable record"
  assert_absent "$case_dir/state/parent-replies.status" \
    "main-merge-wake: a main home wrote a parent reply channel it does not have"
  pass "a merge a main home performs itself leaves one durable wake naming the PR"
}

test_queued_github_merge_leaves_the_poll_armed() {
  local case_dir url
  url=https://github.com/example/repo/pull/66
  case_dir=$(make_home_case queued-github-merge)
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  write_github_outcome "$case_dir" OPEN false true main
  : >"$case_dir/gh-axi.log"

  FM_TEST_GH_MERGE_STATE=open FM_TEST_HOME="$case_dir/home" \
    run_pr_merge "$case_dir" task-x1 "$url" \
      >"$case_dir/stdout" 2>"$case_dir/stderr" \
    || fail "queued-github-merge: accepted merge command failed"

  assert_absent "$case_dir/state/.wake-queue" \
    "queued-github-merge: a queued merge was reported as landed"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "queued-github-merge: the merge poll was not left armed"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "queued-github-merge: a queued merge was marked as reported"
  pass "a queued GitHub merge stays silent and leaves confirmation to the armed poll"
}

test_distinct_merged_prs_keep_distinct_wakes() {
  local case_dir first_url second_url
  first_url=https://github.com/example/repo/pull/68
  second_url=https://github.com/example/repo/pull/69
  case_dir=$(make_home_case distinct-merge-wakes)
  add_gh_mocks "$case_dir" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  : >"$case_dir/gh-axi.log"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$first_url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "distinct-merge-wakes: first merge failed"
  rm -f "$case_dir/state/task-x1.check.sh" \
    "$case_dir/state/task-x1.pr-poll" \
    "$case_dir/state/task-x1.pr-poll-registration"
  # The first PR's merge is already confirmed (the notified marker
  # fm_merge_outcome_report wrote), so the task's next PR is accepted with
  # pr= still bound to the first URL; no hand-edit of the recorded identity.
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$second_url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "distinct-merge-wakes: second merge failed"

  [ "$(grep -c -F "$first_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: first merge wake was missing or duplicated"
  [ "$(grep -c -F "$second_url" "$case_dir/state/.wake-queue")" -eq 1 ] \
    || fail "distinct-merge-wakes: second merge wake was missing or duplicated"
  FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-wake-drain.sh" \
    >"$case_dir/drain.out" 2>"$case_dir/drain.err" \
    || fail "distinct-merge-wakes: wake drain failed"
  assert_grep "$first_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the first PR"
  assert_grep "$second_url" "$case_dir/drain.out" \
    "distinct-merge-wakes: queue deduplication collapsed the second PR"
  pass "distinct merged PRs for one task retain distinct captain-facing wakes"
}

test_uncommitted_marker_retry_is_never_silent() {
  local case_dir url count
  url=https://github.com/example/repo/pull/67
  case_dir=$(make_home_case uncommitted-wake-retry)
  add_gh_mocks "$case_dir" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  : >"$case_dir/gh-axi.log"
  cat >"$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in
  *.pr-poll-merge-notified)
    if mkdir "$FM_TEST_MARKER_FAILURE.claim" 2>/dev/null; then
      exit 1
    fi
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
  export FM_TEST_MARKER_FAILURE="$case_dir/marker-failure"
  export FM_TEST_REAL_MV
  FM_TEST_REAL_MV=$(command -v mv)

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-1" 2>"$case_dir/stderr-1" \
    || fail "uncommitted-wake-retry: landed merge was reported as failed"
  assert_grep 'could not record the outcome' "$case_dir/stderr-1" \
    "uncommitted-wake-retry: failed marker commit was not loud"
  [ -f "$case_dir/state/task-x1.check.sh" ] \
    || fail "uncommitted-wake-retry: failed commit disarmed the retry poll"
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: failed marker commit lost the durable outcome"
  [ ! -e "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: failed marker commit was treated as complete"

  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout-2" 2>"$case_dir/stderr-2" \
    || fail "uncommitted-wake-retry: retry failed"
  unset FM_TEST_MARKER_FAILURE FM_TEST_REAL_MV
  count=$(grep -c -F "$url" "$case_dir/state/.wake-queue")
  [ "$count" -ge 1 ] \
    || fail "uncommitted-wake-retry: retry left the merge silent"
  [ -f "$case_dir/state/task-x1.pr-poll-merge-notified" ] \
    || fail "uncommitted-wake-retry: retry did not commit the canonical marker"
  pass "an uncommitted marker retry preserves at least one durable outcome"
}

test_secondmate_without_parent_binding_is_loud() {
  local case_dir rc url
  url=https://github.com/example/repo/pull/65
  case_dir=$(make_home_case unbound-secondmate)
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : >"$case_dir/gh-axi.log"
  # A secondmate identity with no parent binding: exactly the seeding gap that
  # let three real merges land in silence.
  printf '%s\n' mate-x >"$case_dir/home/.fm-secondmate-home"

  set +e
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$url" \
    >"$case_dir/stdout" 2>"$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "unbound-secondmate: the merge itself landed and must not be reported as failed"
  assert_grep 'could not report it upward' "$case_dir/stderr" \
    "unbound-secondmate: a merge that could not be reported upward said nothing about it"
  assert_absent "$case_dir/state/.wake-queue" \
    "unbound-secondmate: a secondmate home fell back to the main-home record"
  pass "a secondmate home that cannot report upward says so instead of merging in silence"
}

# The merge gate asks whether the task is still held for the captain. A home
# that carries no backlog records no captain calls at all, so nothing can be
# held and the merge must proceed; a backlog that EXISTS but cannot be read may
# hide a live hold, so that one must refuse. The two states are distinct and
# only the second is a refusal.
test_absent_backlog_still_merges() {
  local case_dir rc
  case_dir=$(make_case absent-backlog-merges)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/data/backlog.md"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absent-backlog-merges: a home with no backlog must still merge"
  assert_no_grep 'held for the captain' "$case_dir/stderr" \
    "absent-backlog-merges: an absent backlog was read as a captain hold"
  assert_logged_gh_merge "$case_dir" 61 example/repo --squash
  pass "fm-pr-merge proceeds when the home carries no backlog at all"
}

test_unreadable_backlog_refuses_the_merge() {
  local case_dir rc
  case_dir=$(make_case unreadable-backlog-refuses)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6262626262626262626262626262626262626262
  : > "$case_dir/gh-axi.log"
  chmod 000 "$case_dir/home/data/backlog.md"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$case_dir/home/data/backlog.md"

  expect_code 1 "$rc" "unreadable-backlog-refuses: an unreadable authority record must refuse"
  assert_grep 'refusing to merge' "$case_dir/stderr" \
    "unreadable-backlog-refuses: the refusal did not say it refused to merge"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-backlog-refuses: the forge merge ran despite an unreadable record"
  pass "fm-pr-merge refuses when the backlog exists but cannot be read"
}

test_unreadable_backend_config_refuses_the_merge() {
  local case_dir rc
  case_dir=$(make_case unreadable-backend-config-refuses)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6363636363636363636363636363636363636363
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/data/backlog.md"
  chmod 000 "$case_dir/home/.tasks.toml"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$case_dir/home/.tasks.toml"

  expect_code 1 "$rc" "unreadable-backend-config-refuses: an unreadable authority route must refuse"
  assert_grep 'tasks-axi backend configuration cannot be read' "$case_dir/stderr" \
    "unreadable-backend-config-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-backend-config-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its configured backend cannot be read"
}

test_unreadable_user_backend_config_refuses_the_merge() {
  local case_dir rc user_config
  case_dir=$(make_case unreadable-user-backend-config-refuses)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6464646464646464646464646464646464646464
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "$user_config"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$user_config"

  expect_code 1 "$rc" "unreadable-user-backend-config-refuses: an unreadable authority route must refuse"
  assert_grep "tasks-axi backend configuration cannot be read at $user_config" "$case_dir/stderr" \
    "unreadable-user-backend-config-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unreadable-user-backend-config-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its user backend configuration cannot be read"
}

test_untraversable_user_backend_config_directory_refuses_the_merge() {
  local case_dir rc user_config
  case_dir=$(make_case untraversable-user-backend-config-directory-refuses)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6666666666666666666666666666666666666666
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "${user_config%/*}"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 755 "${user_config%/*}"

  expect_code 1 "$rc" "untraversable-user-backend-config-directory-refuses: an unreadable authority route must refuse"
  assert_grep "tasks-axi backend configuration cannot be read at $user_config" "$case_dir/stderr" \
    "untraversable-user-backend-config-directory-refuses: the unreadable authority route was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "untraversable-user-backend-config-directory-refuses: the forge merge ran despite an unreadable authority route"
  pass "fm-pr-merge refuses when its user backend configuration directory cannot be traversed"
}

test_absent_user_backend_config_directory_and_backlog_still_merge() {
  local case_dir rc
  case_dir=$(make_case absent-user-backend-config-directory-and-backlog-merges)
  mkdir -p "$case_dir/wt" "$case_dir/user-home"
  add_gh_mocks "$case_dir" 6767676767676767676767676767676767676767
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"

  set +e
  FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "absent-user-backend-config-directory-and-backlog-merges: sound defaults and no backlog must permit merging"
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "absent-user-backend-config-directory-and-backlog-merges: the forge must merge exactly once"
  assert_logged_gh_merge "$case_dir" 67 example/repo --squash
  pass "fm-pr-merge proceeds once when its user configuration directory and backlog are genuinely absent"
}

test_backend_override_bypasses_unreadable_user_config() {
  local case_dir rc user_config
  case_dir=$(make_case backend-override-bypasses-unreadable-user-config)
  user_config="$case_dir/user-home/.tasks-axi/config.toml"
  mkdir -p "$case_dir/wt" "${user_config%/*}"
  add_gh_mocks "$case_dir" 6565656565656565656565656565656565656565
  : > "$case_dir/gh-axi.log"
  rm -f "$case_dir/home/.tasks.toml" "$case_dir/home/data/backlog.md"
  printf '%s\n' 'backend = "beads"' > "$user_config"
  chmod 000 "$user_config"

  set +e
  TASKS_AXI_BACKEND=markdown FM_TEST_USER_HOME="$case_dir/user-home" \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  chmod 644 "$user_config"

  expect_code 0 "$rc" "backend-override-bypasses-unreadable-user-config: an explicit backend must bypass config"
  assert_logged_gh_merge "$case_dir" 65 example/repo --squash
  pass "fm-pr-merge honors a backend override over an unreadable user configuration"
}

test_github_red_checks_refuse_and_allow_red_waives_named() {
  local case_dir rc head
  head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  case_dir=$(make_case github-red-checks)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/80 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "github-red: a red check must refuse"
  assert_grep "check 'lint' is not green" "$case_dir/stderr" \
    "github-red: the red check was not named"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-red: gh pr merge ran on a red PR"

  case_dir=$(make_case github-allow-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  write_github_red_json "$case_dir" "$head" lint
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/81 \
    --allow-red lint \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "github-allow-red: named waiver should merge"
  assert_logged_gh_merge "$case_dir" 81 example/repo --squash
  pass "fm-pr-merge refuses red GitHub checks and waives only a named --allow-red check"
}

# Recorded 2026-10-10, task vernant-phase-a-gre-2030, PRs 3197-3202: the worker
# copy's HEAD was a local unpushed tip whose content was already in the pushed
# PRs, and every merge was refused as "named head ... unreachable outside the
# worker copy". The merge must judge the head of the PR the call names.
test_multi_pr_task_merges_named_pr_when_copy_head_is_a_local_tip() {
  local case_dir tip forge_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  case_dir=$(make_direct_pr_local_tip_case multi-pr-local-tip)
  tip=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_mocks "$case_dir" "$forge_head"
  write_ready_reports "$case_dir" \
    https://github.com/example/repo/pull/3196 \
    https://github.com/example/repo/pull/3197 \
    https://github.com/example/repo/pull/3198

  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/3197 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "multi-pr-local-tip: the named green PR was refused: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 3197 example/repo --squash
  assert_grep "pr_head=$forge_head" "$case_dir/state/task-x1.meta" \
    "multi-pr-local-tip: the recorded head was not the named PR's forge head"
  assert_no_grep "$tip" "$case_dir/gh.log" \
    "multi-pr-local-tip: the local tip reached the forge call"
  pass "a multi-PR task merges the named green PR although the copy's HEAD is a local-only tip"
}

pr_merge_test_cases=(
test_bundled_repo_override_args_refuse_before_recording
test_explicit_merge_method_not_overridden
test_method_equals_merge_method_not_overridden
test_parses_pr_url_for_gh_axi
test_github_still_forwards_sha_arg
test_gitlab_url_resolves_and_merges
test_gitlab_host_comes_from_the_url
test_gitlab_imposes_no_merge_method
test_gitlab_extra_args_forwarded
test_gitlab_merge_failure_propagates
test_gitlab_each_condition_refuses_independently
test_gitlab_reports_every_failing_condition
test_gitlab_stale_recorded_head_is_reported
test_gitlab_unreadable_state_refuses
test_gitlab_invalid_head_refuses
test_gitlab_missing_tool_refuses_before_recording
test_forgejo_url_resolves_and_merges
test_forgejo_login_resolves_from_the_host
test_forgejo_refuses_when_login_is_ambiguous
test_forgejo_each_condition_refuses_independently
test_forgejo_unconfigured_ci_refuses_as_none
test_forgejo_combined_status_reads_every_page
test_forgejo_stale_recorded_head_is_reported
test_forgejo_invalid_head_refuses
test_forgejo_missing_tool_refuses_before_recording
test_forgejo_rejected_merge_is_never_trusted_by_exit_status
test_forgejo_transient_confirm_read_failure_still_persists_authority
test_forgejo_merge_method_and_extra_args
test_gitlab_head_override_args_refuse_before_recording
test_secondmate_merge_reports_upward_once
test_secondmate_merge_reports_on_the_local_route
test_gitlab_merge_reports_upward
test_queued_gitlab_merge_leaves_the_poll_armed
test_failed_merge_reports_nothing
test_gitlab_refusal_reports_nothing
test_main_home_merge_leaves_a_durable_wake
test_queued_github_merge_leaves_the_poll_armed
test_distinct_merged_prs_keep_distinct_wakes
test_uncommitted_marker_retry_is_never_silent
test_secondmate_without_parent_binding_is_loud
test_absent_backlog_still_merges
test_unreadable_backlog_refuses_the_merge
test_unreadable_backend_config_refuses_the_merge
test_unreadable_user_backend_config_refuses_the_merge
test_untraversable_user_backend_config_directory_refuses_the_merge
test_absent_user_backend_config_directory_and_backlog_still_merge
test_backend_override_bypasses_unreadable_user_config
test_github_red_checks_refuse_and_allow_red_waives_named
test_multi_pr_task_merges_named_pr_when_copy_head_is_a_local_tip
)
pr_merge_run "$@"
