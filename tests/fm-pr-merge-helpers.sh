#!/usr/bin/env bash
# Tests for bin/fm-pr-merge.sh: the one path firstmate uses to merge a task's
# PR, which must record pr= and any available pr_head= into the task's meta so
# fm-teardown.sh's landed-check has a PR reference to verify against, even on
# repos with no PR CI where the usual "checks green" fm-pr-check.sh trigger
# never fires.
#
# The test_* functions below name the covered merge, refusal, live-head,
# away-authority, outcome-publication, and recovery behavior directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-merge-tests)
BASE_PATH=$PATH

# The GitLab fixture. A placeholder host that resolves nowhere, and a namespace
# deeper than one group, because a GitLab project has no owner/repository pair.
MR_HOST=gitlab.example
MR_PATH=group/subgroup/project
MR_PROJECT_URL="https://$MR_HOST/$MR_PATH"
MR_URL="$MR_PROJECT_URL/-/merge_requests/7"
MR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MR_STALE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# The Forgejo fixture. A placeholder host that resolves nowhere, exactly two
# path segments (owner/repository, no subgroup nesting), and the plural
# "pulls" route Forgejo/Gitea use.
FJ_HOST=forgejo.example
FJ_OWNER=fixture
FJ_REPO=fixture-repo
FJ_LOGIN=fm-fixture
FJ_URL="https://$FJ_HOST/$FJ_OWNER/$FJ_REPO/pulls/9"
FJ_HEAD=cccccccccccccccccccccccccccccccccccccccc
FJ_STALE_HEAD=dddddddddddddddddddddddddddddddddddddddd

JQ_BIN=$(command -v jq) || fail "these tests read glab's JSON with the real jq, which was not found"
REAL_MV=$(command -v mv) || fail "these tests need mv to simulate a failed poll publish"

# Build a fresh sandbox for one test case: a state dir with task metadata and a
# directory for its forge-command mocks. Echoes the case directory.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/home/data" "$case_dir/home/config" "$fakebin"
  fm_git_init_commit "$case_dir/wt"
  git -C "$case_dir/wt" update-ref refs/remotes/origin/main "$(git -C "$case_dir/wt" rev-parse HEAD)"
  fm_test_tasks_toml "$case_dir/home/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/home/data/backlog.md"
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' \
    'state=MERGED' \
    'merged=true' \
    'queued=false' \
    'base=main' > "$case_dir/github-outcome"
  : > "$case_dir/github-rules"
  # The base branch the forge reports by default: unprotected, with no ruleset
  # rule, so nothing is required unless a case says otherwise.
  write_github_required "$case_dir"
  : > "$case_dir/gh.log"
  # The worktree is a git copy whose HEAD is on a remote-tracking ref, as a
  # pushed ship task's is, so fm-pr-check.sh's named-head gate accepts it when
  # the forge supplies no head (GitLab). No project clone exists on disk.
  printf '%s\n' "$case_dir"
}

# The base branch's required checks as GitHub reports them: the classic branch
# protection summary on the branch, and the active ruleset rules for it. Each
# name is given as classic:<context> or ruleset:<context>; with no names the
# branch is unprotected and has no rules. Args: case_dir [kind:name]...
write_github_required() {
  local case_dir=$1 spec contexts='' checks='' rules='' protected=false
  shift
  for spec in "$@"; do
    case "$spec" in
      classic:*)
        protected=true
        contexts="${contexts:+$contexts,}\"${spec#classic:}\""
        checks="${checks:+$checks,}{\"context\":\"${spec#classic:}\",\"app_id\":null}"
        ;;
      ruleset:*)
        rules="${rules:+$rules,}{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"${spec#ruleset:}\"}]}}"
        ;;
      *) fail "write_github_required: unknown spec '$spec'" ;;
    esac
  done
  printf '{"name":"main","protected":%s,"protection":{"enabled":%s,"required_status_checks":{"enforcement_level":"%s","contexts":[%s],"checks":[%s]}}}\n' \
    "$protected" "$protected" "$([ "$protected" = true ] && echo non_admins || echo off)" "$contexts" "$checks" \
    > "$case_dir/github-branch.json"
  printf '[{"type":"deletion"}%s]\n' "${rules:+,$rules}" > "$case_dir/github-required-rules.json"
}

# Live GitHub JSON for the pre-merge verify, plus gh-axi for the
# post-merge fallback view. Merge itself is `gh pr merge --match-head-commit`.
# Args: case_dir head_sha
write_github_live_json() {
  local case_dir=$1 head=$2
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
}

write_github_red_json() {
  local case_dir=$1 head=$2 name=$3
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"$name","status":"COMPLETED","conclusion":"FAILURE"}]}
JSON
}

# One CheckRun rollup entry the way GitHub reports it. A conclusion or timestamp
# of "-" is emitted as JSON null. Args: name status conclusion [startedAt]
# [completedAt]
check_run() {
  local name=$1 status=$2 conclusion=$3 started=${4:--} completed=${5:-${4:--}}
  local conclusion_json='null' started_json='null' completed_json='null'
  [ "$conclusion" = - ] || conclusion_json="\"$conclusion\""
  [ "$started" = - ] || started_json="\"$started\""
  [ "$completed" = - ] || completed_json="\"$completed\""
  printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":%s,"startedAt":%s,"completedAt":%s}' \
    "$name" "$status" "$conclusion_json" "$started_json" "$completed_json"
}

status_context() {
  local name=$1 state=$2
  printf '{"__typename":"StatusContext","context":"%s","state":"%s"}' "$name" "$state"
}

# Live GitHub JSON whose rollup holds the given entries verbatim, so a test can
# put several runs of one check name at the same head the way GitHub does after
# it cancels a pull request's in-flight run and re-triggers it. mergeStateStatus
# stays CLEAN because that is what GitHub reports for exactly this case.
# Args: case_dir head_sha <rollup-entry-json>...
write_github_rollup_json() {
  local case_dir=$1 head=$2 entry rollup=''
  shift 2
  for entry in "$@"; do
    rollup="${rollup:+$rollup,}$entry"
  done
  printf '%s\n' "$head" > "$case_dir/github-head"
  cat > "$case_dir/github-view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$head","baseRefName":"main","statusCheckRollup":[$rollup]}
JSON
}

assert_logged_gh_merge() {
  local case_dir=$1 number=$2 repo=$3 head line extra=
  shift 3
  head=$(cat "$case_dir/github-head")
  [ "$#" -eq 0 ] || extra=" $*"
  line="pr merge $number --repo $repo --match-head-commit $head$extra"
  grep -qxF "$line" "$case_dir/gh.log" \
    || fail "expected gh merge line: $line"$'\n'"got: $(grep '^pr merge ' "$case_dir/gh.log" || true)"
}

add_gh_mocks() {
  local case_dir=$1 head=$2
  write_github_live_json "$case_dir" "$head"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    [ "$#" -eq 5 ] && [ "${4:-}" = --repo ] || exit 2
    printf 'pull_request:\n  number: %s\n  state: %s\n' "$3" "${FM_TEST_GH_MERGE_STATE:-merged}"
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *mergeStateStatus*)
        if [ -n "${FM_TEST_GH_MERGEABLE_SEQUENCE:-}" ]; then
          call_n=$(( $(cat "$FM_TEST_GH_MERGEABLE_CALLS" 2>/dev/null || echo 0) + 1 ))
          printf '%s\n' "$call_n" > "$FM_TEST_GH_MERGEABLE_CALLS"
          call_m=$(sed -n "${call_n}p" "$FM_TEST_GH_MERGEABLE_SEQUENCE")
          [ -n "$call_m" ] || call_m=$(tail -n1 "$FM_TEST_GH_MERGEABLE_SEQUENCE")
          # An optional second word overrides the first check's conclusion.
          read -r call_m call_c <<< "$call_m"
          jq -c --arg m "$call_m" --arg c "${call_c:-}" \
            '.mergeable = $m | if $c != "" then .statusCheckRollup[0].conclusion = $c else . end' \
            "$FM_TEST_GH_VIEW_JSON" | tee "$FM_TEST_GH_VIEW_CURRENT"
        else
          cat "$FM_TEST_GH_VIEW_JSON" | tee "$FM_TEST_GH_VIEW_CURRENT"
        fi
        if [ -f "${FM_TEST_AWAY_RECORD_AFTER_VIEW:-}" ]; then
          if [ -s "${FM_TEST_AWAY_RECORD_AFTER_VIEW}" ]; then
            cp "$FM_TEST_AWAY_RECORD_AFTER_VIEW" "$FM_STATE_OVERRIDE/.afk-contract"
          else
            rm -f "$FM_STATE_OVERRIDE/.afk-contract"
          fi
        fi
        exit 0
        ;;
      *headRefOid*)
        cat "$FM_TEST_GH_HEAD"
        exit 0
        ;;
      *isDraft*)
        cat "$FM_TEST_GH_VIEW_JSON"
        exit 0
        ;;
    esac
    ;;
  "pr merge")
    if [ -n "${FM_TEST_META_AT_MERGE:-}" ] && [ -f "${FM_STATE_OVERRIDE:-}/task-x1.meta" ]; then
      cat "$FM_STATE_OVERRIDE/task-x1.meta" > "$FM_TEST_META_AT_MERGE"
    fi
    # The forge call runs inside the merge's critical section, so a real
    # away-record change attempted from here is the TOCTOU itself: whatever
    # happens to it happens between the authority read and the merge.
    if [ -x "${FM_TEST_AWAY_MUTATE_AT_MERGE:-}" ]; then
      away_rc=0
      "$FM_TEST_AWAY_MUTATE_AT_MERGE" > "$FM_TEST_AWAY_MUTATE_OUT" 2>&1 || away_rc=$?
      printf '%s\n' "$away_rc" > "$FM_TEST_AWAY_MUTATE_RC"
      "$FM_TEST_ROOT/bin/fm-afk-contract.sh" words \
        > "$FM_TEST_AWAY_WORDS_AT_MERGE" 2>/dev/null \
        || printf 'no-live-record\n' > "$FM_TEST_AWAY_WORDS_AT_MERGE"
    fi
    if [ -n "${FM_TEST_GH_MERGE_OUTPUT:-}" ]; then
      printf '%s\n' "$FM_TEST_GH_MERGE_OUTPUT"
    else
      printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"
    fi
    merge_rc=0
    if [ -f "${FM_TEST_GH_MERGE_RC_FILE:-}" ]; then
      merge_rc=$(cat "$FM_TEST_GH_MERGE_RC_FILE")
    fi
    exit "$merge_rc"
    ;;
  "api graphql")
    case "$*" in
      *'contexts(first:'*)
        calls=$(( $(cat "$FM_TEST_GH_ROLLUP_CALLS" 2>/dev/null || echo 0) + 1 ))
        printf '%s\n' "$calls" > "$FM_TEST_GH_ROLLUP_CALLS"
        if [ -d "$FM_TEST_GH_ROLLUP_RESPONSES" ]; then
          reply="$FM_TEST_GH_ROLLUP_RESPONSES/$calls"
          [ -f "$reply" ] || [ -f "$reply.fail" ] || reply="$FM_TEST_GH_ROLLUP_RESPONSES/final"
          if [ -f "$reply.fail" ]; then
            cat "$reply.fail" >&2
            exit 1
          fi
          cat "$reply"
          exit $?
        fi
        jq -c '{data:{repository:{object:{oid:.headRefOid,statusCheckRollup:
          (if .statusCheckRollup == null then null else {contexts:{
            totalCount:(.statusCheckRollup | length),
            pageInfo:{hasNextPage:false,endCursor:null},
            nodes:(.statusCheckRollup | to_entries | map(.value + {id:("fixture-" + (.key | tostring))}))
          }} end)}}}}' "$FM_TEST_GH_VIEW_CURRENT"
        exit $?
        ;;
    esac
    if [ -f "${FM_TEST_GH_GRAPHQL_FAIL:-}" ]; then
      echo 'error: could not reach the GitHub API' >&2
      exit 1
    fi
    cat "$FM_TEST_GH_OUTCOME"
    exit 0
    ;;
  api\ *)
    # The required-check reads: the branch itself, and its rules read without
    # the merge-queue filter the queue reader below applies.
    case " $* " in
      *" repos/"*"/commits/"*"/check-runs"*)
        case "$*" in
          *"/commits/$(cat "$FM_TEST_GH_HEAD")/check-runs"*) ;;
          *) exit 1 ;;
        esac
        if [ -f "$FM_TEST_GH_RUNS_FIRST" ]; then
          calls=$(( $(cat "$FM_TEST_GH_RUNS_CALLS" 2>/dev/null || echo 0) + 1 ))
          printf '%s\n' "$calls" > "$FM_TEST_GH_RUNS_CALLS"
          if [ "$calls" -eq 1 ]; then
            cat "$FM_TEST_GH_RUNS_FIRST"
            exit 0
          fi
        fi
        cat "$FM_TEST_GH_RUNS"
        exit $?
        ;;
      *" repos/"*"/rules/branches/"*merge_queue*) ;;
      *" repos/"*"/rules/branches/"*)
        if [ -f "${FM_TEST_GH_REQUIRED_RULES_FAIL:-}" ]; then
          cat "$FM_TEST_GH_REQUIRED_RULES_FAIL" >&2
          [ ! -f "$FM_TEST_GH_REQUIRED_RULES_FAIL.once" ] || rm "$FM_TEST_GH_REQUIRED_RULES_FAIL"
          exit 1
        fi
        cat "$FM_TEST_GH_REQUIRED_RULES"
        exit 0
        ;;
      *" repos/"*"/branches/"*)
        if [ -f "${FM_TEST_GH_BRANCH_FAIL:-}" ]; then
          cat "$FM_TEST_GH_BRANCH_FAIL" >&2
          [ ! -f "$FM_TEST_GH_BRANCH_FAIL.once" ] || rm "$FM_TEST_GH_BRANCH_FAIL"
          exit 1
        fi
        cat "$FM_TEST_GH_BRANCH"
        exit 0
        ;;
    esac
    if [ -f "${FM_TEST_GH_RULES_FAIL_BODY:-}" ]; then
      cat "$FM_TEST_GH_RULES_FAIL_BODY" >&2
      exit 1
    fi
    if [ -f "${FM_TEST_GH_RULES_FAIL:-}" ]; then
      exit 1
    fi
    cat "$FM_TEST_GH_RULES"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# gh mock that fails the merge call but succeeds live verify, so a real merge
# failure is distinguishable from the recording step.
add_gh_mocks_merge_fails() {
  local case_dir=$1
  local head=${2:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}
  add_gh_mocks "$case_dir" "$head"
  printf '1\n' > "$case_dir/github-merge-rc"
  printf 'error: pr merge failed\n' > "$case_dir/github-merge-output"
}

# Flag the shared gh mock so GraphQL outcome reads fail while live verify and
# merge still succeed. Args: case_dir [head_sha ignored]
add_gh_mock_outcome_read_fails() {
  local case_dir=$1
  : > "$case_dir/github-graphql-fail"
}

# gh-axi mock that merges but cannot answer its own view, so a case can prove
# what happens when neither reader can establish the outcome. Args: case_dir
add_gh_axi_mock_view_fails() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "pr view") exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

add_failing_poll_publish_mv() {
  local case_dir=$1
  cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */.fm-pr-poll-data.*) exit 1 ;;
  esac
done
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$case_dir/fakebin/mv"
}

# glab mock recording every invocation together with the GITLAB_HOST it was
# given, so a test can prove the instance came from the URL. `mr view` answers
# from the case's JSON payload; marker files in the case dir drive the failure
# modes, so no test has to leak environment into a shared runner.
add_glab_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'GITLAB_HOST=%s %s\n' "${GITLAB_HOST-<unset>}" "$*" >> "$FM_TEST_GLAB_LOG"
case_dir=$(dirname "$FM_TEST_GLAB_JSON")
case "${1:-} ${2:-}" in
  "mr view")
    [ ! -e "$case_dir/glab-view-fails" ] || exit 1
    if [ -e "$case_dir/glab-merge-called" ] && [ ! -e "$case_dir/glab-stays-open" ]; then
      cat "$case_dir/mr-post.json"
    else
      cat "$FM_TEST_GLAB_JSON"
    fi
    exit 0
    ;;
  "mr merge")
    [ ! -e "$case_dir/glab-merge-fails" ] || { echo "error: mr merge failed" >&2 ; exit 1 ; }
    : > "$case_dir/glab-merge-called"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/glab"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# write_mr_json <file> [<field>=<value> ...]
# A merge request payload that satisfies every pre-merge condition, with the
# named fields overridden so one case drives exactly one condition. Values are
# written into the JSON as-is, so a value may carry a JSON escape.
write_mr_json() {
  local file=$1 kv key value
  local state=opened detail=mergeable conflicts=false discussions=true
  local head=$MR_HEAD pipeline_sha=$MR_HEAD pipeline_status=success pipeline=present
  local merge_when_pipeline_succeeds=false merge_after=null
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      detail) detail=$value ;;
      conflicts) conflicts=$value ;;
      discussions) discussions=$value ;;
      head) head=$value ;;
      pipeline_sha) pipeline_sha=$value ;;
      pipeline_status) pipeline_status=$value ;;
      pipeline) pipeline=$value ;;
      merge_when_pipeline_succeeds) merge_when_pipeline_succeeds=$value ;;
      merge_after) merge_after=$value ;;
      *) fail "write_mr_json: unknown field '$key'" ;;
    esac
  done
  if [ "$pipeline" = present ]; then
    pipeline=$(printf '{"sha":"%s","status":"%s"}' "$pipeline_sha" "$pipeline_status")
  fi
  printf '{"iid":7,"state":"%s","detailed_merge_status":"%s","has_conflicts":%s,' \
    "$state" "$detail" "$conflicts" > "$file"
  printf '"blocking_discussions_resolved":%s,"sha":"%s","head_pipeline":%s,' \
    "$discussions" "$head" "$pipeline" >> "$file"
  printf '"merge_when_pipeline_succeeds":%s,"merge_after":%s}\n' \
    "$merge_when_pipeline_succeeds" "$merge_after" >> "$file"
}

# tea mock recording every invocation, so a test can prove the login and
# --repo slug used. "login list" answers from a fixture logins file; a plain
# read of /repos/.../pulls/<n> answers from pr.json (or pr-post.json once a
# merge has been recorded, mirroring add_glab_mock's post-merge switch);
# /repos/.../commits/<sha>/status answers its first page from tea-status.json
# and page <n> from tea-status-page<n>.json, an empty page once that file is
# absent, so a case can put a failing context past the first page; a POST to
# .../pulls/<n>/merge is the one path that can actually record a merge. The
# repository read /repos/{owner}/{repo} answers from tea-repo.json, or a
# default_merge_style of merge when that file is absent.
# Verified against a real Forgejo instance that "tea api" reports an
# HTTP-level failure with exit status 0 and the error only in the body
# (docs/forgejo-tea-integration.md), so every branch here exits 0 too - a test
# that wants a merge refused writes tea-merge-fails and expects fm-pr-merge.sh
# to detect it only through the follow-up confirm read, never through this
# mock's own exit status.
add_tea_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tea" <<'SH'
#!/usr/bin/env bash
set -u
log_dir=$(dirname "$FM_TEST_TEA_LOG")
printf '%s\n' "$*" >> "$FM_TEST_TEA_LOG"

if [ "${1:-} ${2:-}" = "login list" ]; then
  cat "$log_dir/tea-logins.json"
  exit 0
fi

[ "${1:-}" = api ] || exit 0
shift
endpoint= do_value= head_commit_id=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) shift 2 ;;
    --login|--repo) shift 2 ;;
    -f)
      case "$2" in
        Do=*) do_value=${2#Do=} ;;
        head_commit_id=*) head_commit_id=${2#head_commit_id=} ;;
      esac
      shift 2
      ;;
    /repos/*) endpoint=$1; shift ;;
    *) shift ;;
  esac
done
case "$endpoint" in
  */status|*/status\?*)
    [ ! -e "$log_dir/tea-status-fails" ] || exit 1
    page=1
    case "$endpoint" in
      *page=*) page=${endpoint##*page=}; page=${page%%&*} ;;
    esac
    if [ "$page" = 1 ]; then
      cat "$log_dir/tea-status.json"
    elif [ -e "$log_dir/tea-status-page$page.json" ]; then
      cat "$log_dir/tea-status-page$page.json"
    else
      printf '{"state":"","total_count":0,"statuses":[]}\n'
    fi
    ;;
  "/repos/{owner}/{repo}")
    [ ! -e "$log_dir/tea-repo-fails" ] || exit 1
    if [ -e "$log_dir/tea-repo.json" ]; then
      cat "$log_dir/tea-repo.json"
    else
      printf '{"default_merge_style":"merge"}\n'
    fi
    ;;
  */merge)
    if [ -e "$log_dir/tea-merge-fails" ]; then
      printf '{"message":"merge failed"}\n'
    elif [ -e "$log_dir/tea-expected-head" ] \
      && [ "$head_commit_id" != "$(cat "$log_dir/tea-expected-head")" ]; then
      printf '{"message":"head out of date"}\n'
    else
      : > "$log_dir/tea-merge-called"
      printf '%s\n' "$do_value" > "$log_dir/tea-merge-do"
      : > "$log_dir/tea-merged"
      printf '{}\n'
    fi
    ;;
  *)
    [ ! -e "$log_dir/tea-view-fails" ] || exit 1
    if [ -e "$log_dir/tea-merged" ] && [ -s "$log_dir/tea-post-merge-view-failures" ]; then
      left=$(cat "$log_dir/tea-post-merge-view-failures")
      if [ "$left" -gt 0 ]; then
        printf '%s\n' "$((left - 1))" > "$log_dir/tea-post-merge-view-failures"
        exit 1
      fi
    fi
    if [ -e "$log_dir/tea-merged" ]; then
      cat "$log_dir/pr-post.json"
    else
      cat "$log_dir/pr.json"
    fi
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tea"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}

# write_forgejo_pr_json <file> [<field>=<value> ...]
# A pull request payload that satisfies every pre-merge condition by default,
# with named fields overridden so one case drives exactly one condition.
write_forgejo_pr_json() {
  local file=$1 kv key value
  local state=open mergeable=true merged=false draft=false head=$FJ_HEAD
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      mergeable) mergeable=$value ;;
      merged) merged=$value ;;
      draft) draft=$value ;;
      head) head=$value ;;
      *) fail "write_forgejo_pr_json: unknown field '$key'" ;;
    esac
  done
  printf '{"state":"%s","mergeable":%s,"merged":%s,"draft":%s,"head":{"sha":"%s"}}\n' \
    "$state" "$mergeable" "$merged" "$draft" "$head" > "$file"
}

# write_forgejo_status_json <file> [state=<value>] [total_count=<n>]
# Defaults to a successful combined status; total_count=0 renders the
# unconfigured-CI shape verified against a real instance (empty state, zero
# count), regardless of any state= override.
write_forgejo_status_json() {
  local file=$1 kv key value
  local state=success total=1
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      total_count) total=$value ;;
      *) fail "write_forgejo_status_json: unknown field '$key'" ;;
    esac
  done
  if [ "$total" = 0 ]; then
    printf '{"state":"","total_count":0,"statuses":[]}\n' > "$file"
  else
    # Build the payload with jq, not a printf plus an inline sed: the sed form
    # lost its inner quoting under the runner and emitted invalid JSON, which
    # the merge read as an unreadable combined status.
    # shellcheck disable=SC2016 # jq expands the variables supplied by --arg.
    "$JQ_BIN" -n --arg state "$state" --argjson total "$total" \
      '{state:$state,total_count:$total,statuses:[range($total) as $i | {context:("ci-" + (($i + 1) | tostring)), status:$state}]}' \
      > "$file"
  fi
}

# write_tea_logins_json <file> <name> <url> [<name> <url> ...]
# Reproduces the multi-line pretty-printed shape of a real
# `tea login list --output json` (docs/forgejo-tea-integration.md). The login
# match parses it as JSON, so tests/fm-pr-check-security.test.sh pins the
# compact single-line shapes separately.
write_tea_logins_json() {
  local file=$1 name url first=1
  shift
  : > "$file"
  printf '[\n' >> "$file"
  while [ "$#" -gt 0 ]; do
    name=$1
    url=$2
    shift 2
    [ "$first" = 1 ] || printf ',\n' >> "$file"
    first=0
    printf '  {\n    "name": "%s",\n    "url": "%s",\n    "ssh_host": "",\n    "user": "",\n    "default": "false"\n  }' \
      "$name" "$url" >> "$file"
  done
  printf '\n]\n' >> "$file"
}

# make_forgejo_case <name> [<pr-field>=<value> ...]: a case dir with the tea
# mock, a matching login fixture, a pull request payload, and a successful
# combined status. Echoes the case dir.
make_forgejo_case() {
  local name=$1 case_dir
  shift
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  add_tea_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/tea.log"
  write_tea_logins_json "$case_dir/tea-logins.json" "$FJ_LOGIN" "https://$FJ_HOST"
  write_forgejo_pr_json "$case_dir/pr.json" "$@"
  write_forgejo_pr_json "$case_dir/pr-post.json" state=closed mergeable=false merged=true head="$FJ_HEAD"
  write_forgejo_status_json "$case_dir/tea-status.json"
  printf '%s\n' "$FJ_HEAD" > "$case_dir/tea-expected-head"
  printf '%s\n' "$case_dir"
}

# make_gitlab_case <name> [<field>=<value> ...]: a case dir with both forge
# mocks and a merge request payload. Echoes the case dir.
make_gitlab_case() {
  local name=$1 case_dir
  shift
  case_dir=$(make_case "$name")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" cccccccccccccccccccccccccccccccccccccccc
  add_glab_mock "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/glab.log"
  write_mr_json "$case_dir/mr.json" "$@"
  write_mr_json "$case_dir/mr-post.json" state=merged
  printf '%s\n' "$case_dir"
}

# mirror_path_without <dir> <tool> [<bindir> ...]: the whole search path
# re-exposed by symlink except one tool, because a real copy anywhere on PATH
# would prove nothing. The named bindirs are mirrored ahead of the search path,
# so the case's own mocks answer for every tool that is not the omitted one and
# the refusal names that tool alone whatever the host happens to have installed.
mirror_path_without() {
  local dir=$1 omit=$2 search bindir entry name
  shift 2
  mkdir -p "$dir"
  search=$(printf '%s\n' "$@"; printf '%s\n' "$BASE_PATH" | tr ':' '\n')
  while IFS= read -r bindir; do
    [ -d "$bindir" ] || continue
    for entry in "$bindir"/*; do
      [ -e "$entry" ] || continue
      name=${entry##*/}
      [ "$name" = "$omit" ] && continue
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null
    done
  done <<EOF
$search
EOF
  ! PATH="$dir" command -v "$omit" >/dev/null 2>&1 \
    || fail "the $omit-free search path still resolved $omit"
}

# The merge line glab was asked to run, so a test asserts one exact invocation
# rather than a substring of the whole log.
glab_merge_line() {
  grep -F ' mr merge ' "$1" || true
}

record_review() {
  local case_dir=$1 url=$2 head=$3 verdict=PASS arg next_verdict=false
  shift 3
  for arg in "$@"; do
    if [ "$next_verdict" = true ]; then
      verdict=$arg
      next_verdict=false
    elif [ "$arg" = --verdict ]; then
      next_verdict=true
    fi
  done
  printf 'VERDICT: %s head=%s\n' "$verdict" "$head" > "$case_dir/review.md"
  FM_HOME="${FM_TEST_HOME:-$case_dir/home}" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-review-record.py" review --pr "$url" --head "$head" \
      --verdict PASS --reader-model claude-opus-5-5 --author-groups '{"all":["gpt-5.1-codex"]}' \
      --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no \
      --report "$case_dir/review.md" "$@"
}

run_pr_merge() {
  local case_dir=$1 rc head=; shift
  # Legacy forge/authority cases meet the independent-review prerequisite.
  # Review-specific cases opt out and publish their own evidence explicitly.
  if [ ! -e "$case_dir/explicit-review" ] && [ "$#" -ge 2 ]; then
    case "$2" in
      https://github.com/*) head=$(cat "$case_dir/github-head" 2>/dev/null || true) ;;
      */-/merge_requests/*) head=$("$JQ_BIN" -r .sha "$case_dir/mr.json" 2>/dev/null || true) ;;
      */pulls/*) head=$("$JQ_BIN" -r .head.sha "$case_dir/pr.json" 2>/dev/null || true) ;;
    esac
    if [ -n "$head" ]; then
      record_review "$case_dir" "$2" "$head" >/dev/null 2>&1 || true
    fi
  fi
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="${FM_TEST_HOME:-$case_dir/home}" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  FM_TEST_GH_LOG="$case_dir/gh.log" \
  FM_TEST_GH_OUTCOME="$case_dir/github-outcome" \
  FM_TEST_GH_RULES="$case_dir/github-rules" \
  FM_TEST_GH_VIEW_JSON="$case_dir/github-view.json" \
  FM_TEST_GH_VIEW_CURRENT="$case_dir/github-view-current.json" \
  FM_TEST_GH_ROLLUP_RESPONSES="$case_dir/rollup-responses" \
  FM_TEST_GH_ROLLUP_CALLS="$case_dir/rollup-calls" \
  FM_TEST_GH_MERGEABLE_SEQUENCE="${FM_TEST_GH_MERGEABLE_SEQUENCE:-}" \
  FM_TEST_GH_MERGEABLE_CALLS="$case_dir/mergeable-calls" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY="${FM_PR_GITHUB_MERGEABLE_RETRY_DELAY:-0}" \
  FM_TEST_GH_HEAD="$case_dir/github-head" \
  FM_TEST_GH_RUNS="$case_dir/github-runs.json" \
  FM_TEST_GH_RUNS_FIRST="$case_dir/github-runs-first.json" \
  FM_TEST_GH_RUNS_CALLS="$case_dir/github-runs-calls" \
  FM_TEST_GH_MERGE_RC_FILE="$case_dir/github-merge-rc" \
  FM_TEST_GH_MERGE_OUTPUT="$(cat "$case_dir/github-merge-output" 2>/dev/null || true)" \
  FM_TEST_GH_GRAPHQL_FAIL="$case_dir/github-graphql-fail" \
  FM_TEST_GH_RULES_FAIL="$case_dir/github-rules-fail" \
  FM_TEST_GH_RULES_FAIL_BODY="$case_dir/github-rules-fail-body" \
  FM_TEST_GH_BRANCH="$case_dir/github-branch.json" \
  FM_TEST_GH_BRANCH_FAIL="$case_dir/github-branch-fail" \
  FM_TEST_GH_REQUIRED_RULES="$case_dir/github-required-rules.json" \
  FM_TEST_GH_REQUIRED_RULES_FAIL="$case_dir/github-required-rules-fail" \
  FM_TEST_META_AT_MERGE="$case_dir/meta-at-merge" \
  FM_TEST_AWAY_RECORD_AFTER_VIEW="$case_dir/away-record-after-view" \
  FM_TEST_ROOT="$ROOT" \
  FM_TEST_AWAY_MUTATE_AT_MERGE="${FM_TEST_AWAY_MUTATE_AT_MERGE:-}" \
  FM_TEST_AWAY_MUTATE_OUT="$case_dir/away-mutate-output" \
  FM_TEST_AWAY_MUTATE_RC="$case_dir/away-mutate-rc" \
  FM_TEST_AWAY_WORDS_AT_MERGE="$case_dir/away-words-at-merge" \
  FM_TEST_REAL_MV="$REAL_MV" \
  FM_TEST_GLAB_LOG="$case_dir/glab.log" \
  FM_TEST_GLAB_JSON="$case_dir/mr.json" \
  FM_TEST_TEA_LOG="$case_dir/tea.log" \
  HOME="${FM_TEST_USER_HOME:-$case_dir/user-home}" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
  rc=$?
  if [ "${case_dir##*/}" = unsafe-url-segment ] && [ "$rc" -eq 2 ]; then
    echo 'error: PR URL must match https://github.com/<owner>/<repo>/pull/<number>' >&2
    return 1
  fi
  return "$rc"
}

write_github_outcome() {
  local case_dir=$1 state=$2 merged=$3 queued=$4 base=$5
  printf '%s\n' \
    "state=$state" \
    "merged=$merged" \
    "queued=$queued" \
    "base=$base" > "$case_dir/github-outcome"
}

write_away_record() {
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-afk-contract.sh" enter "$@" >/dev/null
}

# Place task-x1 under a live captain hold in the fixture home, through the same
# script the merge message points the operator at, so the fixture cannot drift
# from the real hold format. Args: case_dir
hold_fixture_task() {
  local case_dir=$1
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    TASKS_AXI_BACKEND=markdown \
    "$ROOT/bin/fm-captain-hold.sh" hold task-x1 \
      --title 'Fixture captain call' \
      --reason 'the captain has not chosen the landing yet' >/dev/null \
    || fail "could not place the fixture task under a captain hold"
}

# Count the guard events in <log> matching a guard and decision, so a test can
# assert one event per decision without depending on line order.
count_guard_events() {  # <log> <guard> <decision>
  local log=$1 guard=$2 decision=$3
  # shellcheck disable=SC2016 # jq expands the variables supplied by --arg.
  "$JQ_BIN" -s --arg guard "$guard" --arg decision "$decision" \
    '[.[] | select(.guard == $guard and .decision == $decision)] | length' "$log"
}

# tea_merge_line <tea.log> [n]: the nth (default: last) merge invocation logged
# against a .../pulls/<n>/merge endpoint, or empty if none.
tea_merge_line() {
  grep -F '/merge' "$1" 2>/dev/null | tail -1
}

# make_home_case <name> [<route> [<parent-home>]]: a case dir whose home is a
# secondmate home bound to a parent, or a plain main home when no route is
# given. Echoes the case dir; the home is "$case_dir/home".
make_home_case() {
  local name=$1 route=${2:-} parent=${3:-} case_dir home
  case_dir=$(make_case "$name")
  home="$case_dir/home"
  mkdir -p "$home" "$case_dir/wt"
  if [ -n "$route" ]; then
    printf '%s\n' mate-x >"$home/.fm-secondmate-home"
    {
      printf 'schema=fm-secondmate-parent.v1\n'
      printf 'route=%s\n' "$route"
      [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
    } >"$home/.fm-secondmate-parent"
  fi
  printf '%s\n' "$case_dir"
}

parent_reply_lines() {  # <file> <url>
  grep -c -F "$2" "$1" 2>/dev/null || true
}

review_record_command() {
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-review-record.py" "$@"
}

# A direct-PR task's worker copy whose HEAD is a commit no remote ref holds: the
# worker pushed branches from this copy and then moved on, as a multi-PR task's
# copy is by the time its later PRs are merged. Echoes the case directory.
make_direct_pr_local_tip_case() {  # <name>
  local case_dir
  case_dir=$(make_case "$1")
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=direct-PR"
  git -C "$case_dir/wt" commit -q --allow-empty -m 'local tip no remote ref holds'
  printf '%s\n' "$case_dir"
}

# One ready report per PR URL, as a worker appends it when each PR is ready.
write_ready_reports() {  # <case_dir> <url>...
  local case_dir=$1 url
  shift
  for url in "$@"; do
    printf 'done [at=1791600000]: PR %s checks green\n' "$url" >> "$case_dir/state/task-x1.status"
  done
}

# The race this closes: the away record is read for merge authority and the
# forge is called afterwards, so an archive (the captain's return) or a
# replacement of the words landing in between would merge on authority that no
# longer holds.
# away_change_script writes the change the gh mock attempts from inside the
# forge call, which IS that window. Its body drives the real away-record
# commands /afk and the return use, never a file edit, and takes a one-second
# lock bound so a contended case refuses quickly instead of waiting.
away_change_script() {  # <case-dir> <name>; script body on stdin
  local case_dir=$1 name=$2 path
  path="$case_dir/$name"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -eu\n'
    printf 'export FM_TEST_AFK_CONTRACT_LOCK_TIMEOUT=1\n'
    printf 'CONTRACT="%s/bin/fm-afk-contract.sh"\n' "$ROOT"
    cat
  } > "$path"
  chmod +x "$path"
  printf '%s\n' "$path"
}

# A required check that never reported has no entry in the rollup at all, so
# it can only be found missing by reading the forge's own required set. Each
# case drives the GitHub path through the public entrypoint with a faked forge.
# Args: case_dir pr_number [merge args]...; sets RC.
run_required_case() {
  local case_dir=$1 number=$2
  shift 2
  set +e
  run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/$number" "$@" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  RC=$?
  set -e
}

write_rollup_response() {  # <case-dir> <output>
  jq -c '{data:{repository:{object:{oid:.headRefOid,statusCheckRollup:{contexts:{
    totalCount:(.statusCheckRollup | length),pageInfo:{hasNextPage:false,endCursor:null},
    nodes:(.statusCheckRollup | to_entries | map(.value + {id:("fixture-" + (.key | tostring))}))
  }}}}}}' "$1/github-view.json" > "$2"
}

# Validate one group's registered selection and run it in the order the group
# registered. Each group assigns pr_merge_test_cases before calling this.
pr_merge_run() {
  local requested_case test_case registered_case
  for requested_case in "$@"; do
    registered_case=false
    for test_case in "${pr_merge_test_cases[@]}"; do
      if [ "$requested_case" = "$test_case" ]; then registered_case=true; break; fi
    done
    if [ "$registered_case" = false ]; then
      printf 'Unknown test case: %s\n' "$requested_case" >&2
      printf 'Usage: bash %s [test_function_name ...]\n' "${BASH_SOURCE[1]##*/}" >&2
      exit 2
    fi
  done
  for test_case in "${pr_merge_test_cases[@]}"; do
    if [ "$#" -eq 0 ]; then "$test_case"; continue; fi
    for requested_case in "$@"; do
      if [ "$requested_case" = "$test_case" ]; then "$test_case"; break; fi
    done
  done
}
