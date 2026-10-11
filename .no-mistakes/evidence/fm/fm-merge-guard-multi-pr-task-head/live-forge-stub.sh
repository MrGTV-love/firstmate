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
      *statusCheckRollup*)
        if [ -n "${FM_TEST_GH_MERGEABLE_SEQUENCE:-}" ]; then
          call_n=$(( $(cat "$FM_TEST_GH_MERGEABLE_CALLS" 2>/dev/null || echo 0) + 1 ))
          printf '%s\n' "$call_n" > "$FM_TEST_GH_MERGEABLE_CALLS"
          call_m=$(sed -n "${call_n}p" "$FM_TEST_GH_MERGEABLE_SEQUENCE")
          [ -n "$call_m" ] || call_m=$(tail -n1 "$FM_TEST_GH_MERGEABLE_SEQUENCE")
          # An optional second word overrides the first check's conclusion.
          read -r call_m call_c <<< "$call_m"
          jq -c --arg m "$call_m" --arg c "${call_c:-}" \
            '.mergeable = $m | if $c != "" then .statusCheckRollup[0].conclusion = $c else . end' \
            "$FM_TEST_GH_VIEW_JSON"
        else
          cat "$FM_TEST_GH_VIEW_JSON"
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
        cat "$FM_TEST_GH_RUNS"
        exit $?
        ;;
      *" repos/"*"/rules/branches/"*merge_queue*) ;;
      *" repos/"*"/rules/branches/"*)
        if [ -f "${FM_TEST_GH_REQUIRED_RULES_FAIL:-}" ]; then
          cat "$FM_TEST_GH_REQUIRED_RULES_FAIL" >&2
          exit 1
        fi
        cat "$FM_TEST_GH_REQUIRED_RULES"
        exit 0
        ;;
      *" repos/"*"/branches/"*)
        if [ -f "${FM_TEST_GH_BRANCH_FAIL:-}" ]; then
          cat "$FM_TEST_GH_BRANCH_FAIL" >&2
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
