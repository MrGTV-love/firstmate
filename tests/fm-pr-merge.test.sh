#!/usr/bin/env bash
# bin/fm-pr-merge.sh: the record, the authority, and the GitHub merge outcome.
#
# Review and captain-word authority, pr= recording, the GitHub merge outcome
# read, queue rules, and the first argument and URL refusals.
# The three groups are contiguous slices of the former suite's registration
# order, not exact themes, so a few cases sit with their neighbors.
# The other forges, reporting, and the remaining argument/URL and multi-PR
# edges live in tests/fm-pr-merge-forges.test.sh; the check-run, rollup,
# waiver, and away-authority cases live in tests/fm-pr-merge-checks.test.sh.
# Shared fixtures: tests/fm-pr-merge-helpers.sh.

# shellcheck source=tests/fm-pr-merge-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-pr-merge-helpers.sh"

test_triggered_review_verifies_only_when_independent() {
  local case_dir head url scenario rc expected
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for scenario in independent same-family unknown-reader unknown-author wrong-head fail; do
    case_dir=$(make_case "triggered-verify-$scenario")
    record_review "$case_dir" "$url" "$head" --loosens-deny-allow-list yes \
      --widens-guard yes --customer-data-billing-spend yes >/dev/null || fail "record yes-trigger PASS"
    expected=
    local review_head=$head
    local -a args=(--verdict PASS)
    case "$scenario" in
      same-family) args=(--reader-model gpt-5.1-codex); expected=reader_family ;;
      unknown-reader) args=(--reader-model mistral-large); expected='model family unknown' ;;
      unknown-author) args=(--author-groups '{"all":["mistral-large"]}'); expected='model family unknown' ;;
      wrong-head) review_head=2222222222222222222222222222222222222222; expected='head mismatch' ;;
      fail) args=(--verdict FAIL); expected='verdict is FAIL' ;;
    esac
    if [ "$scenario" != independent ]; then
      record_review "$case_dir" "$url" "$review_head" --loosens-deny-allow-list yes \
        --widens-guard yes --customer-data-billing-spend yes "${args[@]}" >/dev/null \
        || fail "record newest $scenario review"
    fi
    rc=0
    review_record_command "$case_dir" verify --pr "$url" --head "$head" > "$case_dir/out" 2>&1 || rc=$?
    if [ "$scenario" = independent ]; then
      expect_code 0 "$rc" "yes-trigger independent PASS must verify: $(cat "$case_dir/out")"
      assert_grep 'review: PASS' "$case_dir/out" "independent evidence is accepted without captain words"
      review_record_command "$case_dir" latest --pr "$url" > "$case_dir/latest" || fail "read yes-trigger evidence"
      "$JQ_BIN" -e '.review.loosens_deny_allow_list == "yes" and .review.widens_guard == "yes"
        and .review.customer_data_billing_spend == "yes" and .["captain-word"] == null' \
        "$case_dir/latest" >/dev/null || fail "latest must print all yes triggers without captain words"
    else
      expect_code 1 "$rc" "newest $scenario review must still refuse"
      assert_grep "$expected" "$case_dir/out" "$scenario refusal must name its cause"
    fi
    pass "yes-trigger review verification: $scenario"
  done
}

# A later independent PASS clears a FAIL even when its trigger answers are yes.
test_captain_fail_triggered_independent_pass_merges() {
  local case_dir head url trigger rc
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for trigger in loosens-deny-allow-list widens-guard customer-data-billing-spend; do
    case_dir=$(make_case "captain-fail-pass-$trigger")
    : > "$case_dir/explicit-review"
    add_gh_mocks "$case_dir" "$head"
    review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge this PR.' >/dev/null \
      || fail "could not record the original captain-word"
    record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null || fail "could not record FAIL"
    record_review "$case_dir" "$url" "$head" "--$trigger" yes >/dev/null || fail "could not record triggered PASS"
    rc=0
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "captain-word, FAIL, independent PASS with $trigger=yes must merge: $(cat "$case_dir/stderr")"
    assert_logged_gh_merge "$case_dir" 9 example/repo --squash
    pass "an independent $trigger PASS clears a FAIL without renewed captain words"
  done
}

test_review_record_requires_matching_local_report() {
  local case_dir head url bad rc digest
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for bad in missing symlink verdict head directory unreadable trailing-space; do
    case_dir=$(make_case "review-report-$bad")
    record_review "$case_dir" "$url" "$head" >/dev/null || fail "could not seed report validation history"
    cp "$case_dir/state/review-records.jsonl" "$case_dir/before"
    printf 'VERDICT: PASS head=%s\nReader evidence.\n' "$head" > "$case_dir/report.md"
    case "$bad" in
      missing) rm "$case_dir/report.md" ;;
      symlink) mv "$case_dir/report.md" "$case_dir/target.md"; ln -s "$case_dir/target.md" "$case_dir/report.md" ;;
      verdict) printf 'VERDICT: FAIL head=%s\n' "$head" > "$case_dir/report.md" ;;
      head) printf 'VERDICT: PASS head=%s\n' 2222222222222222222222222222222222222222 > "$case_dir/report.md" ;;
      directory) rm "$case_dir/report.md"; mkdir "$case_dir/report.md" ;;
      unreadable) chmod 000 "$case_dir/report.md" ;;
      trailing-space) printf 'VERDICT: PASS head=%s \n' "$head" > "$case_dir/report.md" ;;
    esac
    rc=0
    record_review "$case_dir" "$url" "$head" --report "$case_dir/report.md" > "$case_dir/out" 2>&1 || rc=$?
    [ "$bad" != unreadable ] || chmod 600 "$case_dir/report.md"
    expect_code 2 "$rc" "$bad report must refuse"
    assert_grep report "$case_dir/out" "$bad report refusal must identify report"
    cmp -s "$case_dir/before" "$case_dir/state/review-records.jsonl" || fail "$bad report changed history"
    pass "review recording refuses $bad report with exit 2 and appends nothing"
  done
  case_dir=$(make_case review-report-digest)
  printf 'VERDICT: PASS head=%s\nIndependent reader evidence.\n' "$head" > "$case_dir/report.md"
  digest=$(shasum -a 256 "$case_dir/report.md")
  digest=${digest%% *}
  record_review "$case_dir" "$url" "$head" --report "$case_dir/report.md" >/dev/null || fail "matching report must record"
  review_record_command "$case_dir" latest --pr "$url" > "$case_dir/latest" || fail "could not read report provenance"
  "$JQ_BIN" -e --arg digest "$digest" --arg report "$case_dir/report.md" \
    ".review | .report == \$report and .report_sha256 == \$digest" "$case_dir/latest" >/dev/null \
    || fail "record must retain report path and exact whole-file sha256"
  printf 'VERDICT: FAIL head=%s\nNew reader finding.\n' "$head" > "$case_dir/report.md"
  record_review "$case_dir" "$url" "$head" --verdict FAIL --report "$case_dir/report.md" >/dev/null \
    || fail "matching FAIL report must record"
  rc=0
  review_record_command "$case_dir" verify --pr "$url" --head "$head" > "$case_dir/out" 2>&1 || rc=$?
  expect_code 1 "$rc" "recorded FAIL must refuse verification"
  assert_grep 'verdict is FAIL' "$case_dir/out" "FAIL report must affect merge evidence"
  pass "matching local reports record whole-file sha256 and a matching FAIL blocks verification"
}

test_late_fail_before_away_hold_refuses() {
  local case_dir forge head url rc
  for forge in github gitlab forgejo; do
    case "$forge" in
      github)
        case_dir=$(make_case late-fail-github)
        head=1111111111111111111111111111111111111111
        url=https://github.com/example/repo/pull/9
        add_gh_mocks "$case_dir" "$head" ;;
      gitlab) case_dir=$(make_gitlab_case late-fail-gitlab); head=$MR_HEAD; url=$MR_URL ;;
      forgejo) case_dir=$(make_forgejo_case late-fail-forgejo); head=$FJ_HEAD; url=$FJ_URL ;;
    esac
    : > "$case_dir/explicit-review"
    record_review "$case_dir" "$url" "$head" >/dev/null || fail "$forge could not record initial PASS"
    review_record_command "$case_dir" verify --pr "$url" --head "$head" > "$case_dir/earlier-verify" \
      || fail "$forge initial PASS must verify"
    assert_grep 'review: PASS' "$case_dir/earlier-verify" "$forge must have earlier accepted evidence"
    printf 'VERDICT: FAIL head=%s\nLate independent finding.\n' "$head" > "$case_dir/late-fail.md"
    : > "$case_dir/late-fail-pending"
    # Publish a real FAIL exactly when the merge enters the away-record hold,
    # after any review verification outside that hold, without a timing sleep.
    cat > "$case_dir/fakebin/ln" <<'SH'
#!/usr/bin/env bash
for target in "$@"; do
  if [ "$target" = "$FM_STATE_OVERRIDE/.afk-contract.lock" ] && [ -e "$FM_TEST_REVIEW_RACE_DIR/late-fail-pending" ]; then
    rm "$FM_TEST_REVIEW_RACE_DIR/late-fail-pending" || exit 10
    "$FM_TEST_ROOT/bin/fm-review-record.py" review --pr "$FM_TEST_REVIEW_RACE_URL" --head "$FM_TEST_REVIEW_RACE_HEAD" \
      --verdict FAIL --reader-model claude-opus-5-5 --author-groups '{"all":["gpt-5.1-codex"]}' \
      --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no \
      --report "$FM_TEST_REVIEW_RACE_DIR/late-fail.md" > "$FM_TEST_REVIEW_RACE_DIR/late-fail-out" || exit 11
  fi
done
exec "$FM_TEST_REAL_LN" "$@"
SH
    chmod +x "$case_dir/fakebin/ln"
    rc=0
    FM_TEST_REVIEW_RACE_DIR="$case_dir" FM_TEST_REVIEW_RACE_URL="$url" FM_TEST_REVIEW_RACE_HEAD="$head" \
      FM_TEST_REAL_LN="$(command -v ln)" run_pr_merge "$case_dir" task-x1 "$url" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    [ ! -e "$case_dir/late-fail-pending" ] || fail "$forge did not reach the injection boundary"
    assert_grep 'recorded: review' "$case_dir/late-fail-out" "$forge must append the late FAIL"
    expect_code 1 "$rc" "$forge must refuse FAIL appended after earlier verification"
    assert_grep 'verdict is FAIL' "$case_dir/stderr" "$forge must recheck late review evidence"
    assert_no_grep '^pr merge ' "$case_dir/gh.log" "$forge must not call GitHub merge"
    case "$forge" in
      gitlab) [ -z "$(glab_merge_line "$case_dir/glab.log")" ] || fail "late FAIL reached GitLab merge" ;;
      forgejo) [ -z "$(tea_merge_line "$case_dir/tea.log")" ] || fail "late FAIL reached Forgejo merge" ;;
    esac
    pass "$forge refuses a FAIL appended after earlier verify and before the merge hold"
  done
}

test_attended_override_without_review_refuses() {
  local case_dir forge url rc
  for forge in github gitlab forgejo; do
    case "$forge" in
      github)
        case_dir=$(make_case override-no-review-github)
        url=https://github.com/example/repo/pull/9
        add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111 ;;
      gitlab) case_dir=$(make_gitlab_case override-no-review-gitlab); url=$MR_URL ;;
      forgejo) case_dir=$(make_forgejo_case override-no-review-forgejo); url=$FJ_URL ;;
    esac
    : > "$case_dir/explicit-review"
    rc=0
    run_pr_merge "$case_dir" task-x1 "$url" --attended-override \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$forge attended override must not bypass missing review evidence"
    assert_grep 'review record is missing' "$case_dir/stderr" "$forge attended override must reach the review gate"
    [ ! -e "$case_dir/state/review-records.jsonl" ] || fail "$forge override unexpectedly recorded evidence"
    assert_no_grep '^pr merge ' "$case_dir/gh.log" "$forge override must not call GitHub merge"
    case "$forge" in
      gitlab) [ -z "$(glab_merge_line "$case_dir/glab.log")" ] || fail "attended override reached GitLab merge" ;;
      forgejo) [ -z "$(tea_merge_line "$case_dir/tea.log")" ] || fail "attended override reached Forgejo merge" ;;
    esac
    pass "$forge attended override cannot merge without recorded review evidence"
  done
}

test_missing_review_record_refuses() {
  local case_dir rc
  case_dir=$(make_case missing-review-record)
  : > "$case_dir/explicit-review"
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  rc=0
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "missing review record must refuse"
  assert_grep 'review record' "$case_dir/stderr" "missing review refusal names the field"
  assert_no_grep '^pr merge ' "$case_dir/gh.log" "missing review must not reach forge merge"
  pass "missing review record refuses before forge merge"
}

test_gitlab_and_forgejo_missing_review_record_refuse() {
  local case_dir rc
  case_dir=$(make_gitlab_case gitlab-missing-review-record)
  : > "$case_dir/explicit-review"
  rc=0
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "gitlab missing review record must refuse"
  assert_grep 'review record is missing' "$case_dir/stderr" "gitlab missing review refusal names the field"
  assert_grep 'fm-review-record.py' "$case_dir/stderr" "gitlab missing review refusal names completing step"
  [ -z "$(glab_merge_line "$case_dir/glab.log")" ] || fail "gitlab missing review must not reach glab mr merge"
  case_dir=$(make_forgejo_case forgejo-missing-review-record)
  : > "$case_dir/explicit-review"
  rc=0
  run_pr_merge "$case_dir" task-x1 "$FJ_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "forgejo missing review record must refuse"
  assert_grep 'review record is missing' "$case_dir/stderr" "forgejo missing review refusal names the field"
  assert_grep 'fm-review-record.py' "$case_dir/stderr" "forgejo missing review refusal names completing step"
  [ -z "$(tea_merge_line "$case_dir/tea.log")" ] || fail "forgejo missing review must not POST the merge"
  pass "gitlab and forgejo refuse a missing review record before their forge merge"
}

test_captain_word_refused_while_away() {
  local case_dir head url rc posture
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for posture in away quiet none; do
    case_dir=$(make_case "captain-word-$posture")
    case "$posture" in
      away) write_away_record "$case_dir" --words 'merge PR 9 when green' ;;
      quiet) FM_AFK_MODE=quiet write_away_record "$case_dir" ;;
    esac
    rc=0
    review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'merge PR 9 when green' \
      > "$case_dir/out" 2>&1 || rc=$?
    if [ "$posture" = away ]; then
      expect_code 2 "$rc" "captain-word must refuse under an away record"
      assert_grep "away-posture record $case_dir/state/.afk-contract exists" "$case_dir/out" "away refusal names the record"
      assert_grep 'the captain must give the merge word after return' "$case_dir/out" "away refusal names the return"
      [ ! -e "$case_dir/state/review-records.jsonl" ] || fail "an away refusal must not append a captain-word"
    else
      expect_code 0 "$rc" "captain-word must record under posture $posture: $(cat "$case_dir/out")"
      review_record_command "$case_dir" verify --pr "$url" --head "$head" > "$case_dir/verify" \
        || fail "captain-word recorded under posture $posture must verify: $(cat "$case_dir/verify")"
      assert_grep 'review: captain-word' "$case_dir/verify" "posture $posture captain-word verifies"
    fi
  done
  case_dir=$(make_case captain-word-before-away)
  : > "$case_dir/explicit-review"
  add_gh_mocks "$case_dir" "$head"
  printf '\nyolo=on\n' >> "$case_dir/state/task-x1.meta"
  review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge PR 9.' >/dev/null \
    || fail "captain-word before /afk must record"
  write_away_record "$case_dir" --words 'merge PR 9 when green'
  rc=0
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "a captain-word recorded before /afk must still verify while away: $(cat "$case_dir/stderr")"
  assert_grep 'review: captain-word' "$case_dir/stderr" "pre-away captain-word is the verified evidence"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  pass "captain-word refuses under an away record, records under quiet or no record, and pre-away words stay valid"
}

test_review_record_validation_and_latest() {
  local case_dir head url rc bad
  case_dir=$(make_case review-record-fields)
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for bad in missing-report invalid-verdict invalid-url empty-words empty-groups blank-reader blank-author captain-head; do
    rc=0
    case "$bad" in
      missing-report) record_review "$case_dir" "$url" "$head" --report '' > "$case_dir/out" 2>&1 || rc=$? ;;
      invalid-verdict) record_review "$case_dir" "$url" "$head" --verdict MAYBE > "$case_dir/out" 2>&1 || rc=$? ;;
      invalid-url) record_review "$case_dir" nonsense "$head" > "$case_dir/out" 2>&1 || rc=$? ;;
      empty-words) review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words '' > "$case_dir/out" 2>&1 || rc=$? ;;
      empty-groups) record_review "$case_dir" "$url" "$head" --author-groups '{}' > "$case_dir/out" 2>&1 || rc=$? ;;
      blank-reader) record_review "$case_dir" "$url" "$head" --reader-model '' > "$case_dir/out" 2>&1 || rc=$? ;;
      blank-author) record_review "$case_dir" "$url" "$head" --author-groups '{"all":["gpt 5"]}' > "$case_dir/out" 2>&1 || rc=$? ;;
      captain-head) review_record_command "$case_dir" captain-word --pr "$url" --head main --words 'Merge it.' > "$case_dir/out" 2>&1 || rc=$? ;;
    esac
    expect_code 2 "$rc" "$bad must refuse invalid field"
    case "$bad" in
      missing-report) assert_grep report "$case_dir/out" "invalid report named" ;;
      invalid-verdict) assert_grep verdict "$case_dir/out" "invalid verdict named" ;;
      invalid-url) assert_grep pr "$case_dir/out" "invalid PR named" ;;
      empty-words) assert_grep words "$case_dir/out" "empty words named" ;;
      empty-groups) assert_grep author_groups "$case_dir/out" "empty authors named" ;;
      blank-reader) assert_grep 'reader_model must be an exact model id' "$case_dir/out" "blank reader model named" ;;
      blank-author) assert_grep 'author_groups model must be an exact model id' "$case_dir/out" "invalid author model named" ;;
      captain-head) assert_grep head "$case_dir/out" "captain-word head named" ;;
    esac
  done
  [ ! -e "$case_dir/state/review-records.jsonl" ] || fail "refused input must not append a record"
  rc=0
  FM_HOME="$case_dir/no-such-home" "$ROOT/bin/fm-review-record.py" captain-word --pr "$url" --head "$head" \
    --words 'Merge it.' > "$case_dir/out" 2>&1 || rc=$?
  expect_code 2 "$rc" "a missing home must refuse the write"
  assert_grep 'does not exist' "$case_dir/out" "missing home named"
  [ ! -e "$case_dir/no-such-home" ] || fail "a missing home must not be created"
  record_review "$case_dir" "$url" "$head" --verdict FAIL > /dev/null || fail "record FAIL"
  cp "$case_dir/state/review-records.jsonl" "$case_dir/first-record"
  record_review "$case_dir" "$url" "$head" --reader-model Claude-Sonnet-5-5 \
    --author-groups '{"initial":["openai-codex/gpt-5.1-codex"],"fixes":["Gemini-3-Pro","o3"]}' > /dev/null || fail "record grouped PASS"
  review_record_command "$case_dir" latest --pr "$url" > "$case_dir/latest" || fail "read newest record"
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --arg pr "$url" --arg head "$head" --arg report "$case_dir/review.md" '
    .review | .pr == $pr and .head == $head and .verdict == "PASS"
    and .reader_model == "Claude-Sonnet-5-5" and .reader_family == "anthropic"
    and .author_groups == {initial:[{model:"openai-codex/gpt-5.1-codex",family:"openai"}],
      fixes:[{model:"Gemini-3-Pro",family:"google"},{model:"o3",family:"openai"}]}
    and .loosens_deny_allow_list == "no" and .widens_guard == "no"
    and .customer_data_billing_spend == "no" and .report == $report' "$case_dir/latest" >/dev/null \
    || fail "latest must preserve all review fields and groups"
  "$JQ_BIN" -sce 'length == 2 and .[0].verdict == "FAIL" and .[1].verdict == "PASS"' \
    "$case_dir/state/review-records.jsonl" >/dev/null || fail "review history must remain append-only"
  IFS= read -r bad < "$case_dir/state/review-records.jsonl"
  printf '%s\n' "$bad" > "$case_dir/retained-first"
  cmp -s "$case_dir/first-record" "$case_dir/retained-first" || fail "append changed existing bytes"
  pass "review helper validates fields, retains history, and returns newest canonical grouped evidence"
}

test_review_record_derives_model_families() {
  local case_dir head url
  case_dir=$(make_case review-model-families)
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  record_review "$case_dir" "$url" "$head" --reader-model openrouter/x-ai/grok-4 --author-groups '{
    "a":["claude-opus-5-5[1m]","anthropic/claude-haiku-5-5"],"o":["gpt-5.1-codex","chatgpt-4o","o4-mini","codex-mini"],
    "g":["gemini-3-pro","gemma-3"],"d":["deepseek-v4"],"m":["kimi-k2","moonshot-v1"],"l":["llama-4-maverick"],
    "u":["mistral-large","opus-5"]}' > /dev/null || fail "record every family"
  review_record_command "$case_dir" latest --pr "$url" > "$case_dir/latest" || fail "read derived families"
  "$JQ_BIN" -e '.review | .reader_family == "xai" and (.author_groups | map_values(map(.family))) ==
    {a:["anthropic","anthropic"],o:["openai","openai","openai","openai"],g:["google","google"],
     d:["deepseek"],m:["moonshot","moonshot"],l:["meta"],u:["unknown","unknown"]}' "$case_dir/latest" >/dev/null \
    || fail "model ids must derive their closed-set family, with unknown otherwise: $(cat "$case_dir/latest")"
  pass "review helper derives each family from the exact model id and records unknown otherwise"
}

test_review_record_survives_a_later_family_change() {
  local case_dir head url rc
  case_dir=$(make_case review-family-added-later)
  : > "$case_dir/explicit-review"
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  add_gh_mocks "$case_dir" "$head"
  record_review "$case_dir" "$url" "$head" --author-groups '{"all":["kimi-k2"]}' >/dev/null || fail "record kimi-authored PASS"
  record_review "$case_dir" https://github.com/example/repo/pull/10 "$head" >/dev/null || fail "record another PR's PASS"
  # Rows written before moonshot joined the closed set stored kimi as unknown.
  "$JQ_BIN" -c 'if .pr | endswith("/pull/9") then .author_groups.all[0].family = "unknown" else . end' \
    "$case_dir/state/review-records.jsonl" > "$case_dir/older-ledger" || fail "could not write the older ledger"
  mv "$case_dir/older-ledger" "$case_dir/state/review-records.jsonl"
  review_record_command "$case_dir" latest --pr https://github.com/example/repo/pull/10 > "$case_dir/latest" \
    || fail "a row stored under an older family set must stay valid: $(cat "$case_dir/latest")"
  rc=0
  run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "a family added after the row was stored must let the merge proceed: $(cat "$case_dir/stderr")"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  "$JQ_BIN" -se '.[0].author_groups.all[0].family == "unknown"' "$case_dir/state/review-records.jsonl" >/dev/null \
    || fail "verify must not rewrite stored history"
  pass "a family added after a row was stored leaves the row valid and verify derives the current family"
}

test_recorded_review_merge_conditions() {
  local case_dir head url scenario rc expected
  head=1111111111111111111111111111111111111111
  url=https://github.com/example/repo/pull/9
  for scenario in stale same-family same-family-model cross-family-model unknown-reader unknown-author-captain fail trigger-list trigger-guard trigger-data other-pr stale-captain-word captain-word captain-only stale-captain-only valid newest-fail captain-then-fail captain-fail-stale-pass captain-fail-stale-fail captain-fail-unknown-pass captain-fail-same-family-pass fail-then-captain captain-fail-pass; do
    case_dir=$(make_case "review-$scenario")
    : > "$case_dir/explicit-review"
    add_gh_mocks "$case_dir" "$head"
    case "$scenario" in
      stale) record_review "$case_dir" "$url" 2222222222222222222222222222222222222222 >/dev/null; expected='head mismatch' ;;
      same-family) record_review "$case_dir" "$url" "$head" --author-groups '{"initial":["gpt-5.1-codex"],"fixes":["claude-opus-5-5"]}' >/dev/null; expected=reader_family ;;
      same-family-model) record_review "$case_dir" "$url" "$head" --reader-model claude-sonnet-5-5 --author-groups '{"all":["claude-bridge/claude-opus-5-5"]}' >/dev/null; expected='reader_family anthropic (claude-sonnet-5-5) matches author_groups all (claude-bridge/claude-opus-5-5)' ;;
      cross-family-model) record_review "$case_dir" "$url" "$head" --author-groups '{"all":["kimi-k2"]}' >/dev/null ;;
      unknown-reader) record_review "$case_dir" "$url" "$head" --reader-model mistral-large >/dev/null; expected='model family unknown for mistral-large' ;;
      unknown-author-captain)
        record_review "$case_dir" "$url" "$head" --author-groups '{"all":["mistral-large"]}' >/dev/null
        review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge PR 9 despite the unknown author family.' >/dev/null ;;
      fail) record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null; expected=verdict ;;
      newest-fail)
        record_review "$case_dir" "$url" "$head" >/dev/null
        record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null; expected=verdict ;;
      trigger-list) record_review "$case_dir" "$url" "$head" --loosens-deny-allow-list yes >/dev/null ;;
      trigger-guard) record_review "$case_dir" "$url" "$head" --widens-guard yes >/dev/null ;;
      trigger-data) record_review "$case_dir" "$url" "$head" --customer-data-billing-spend yes >/dev/null ;;
      other-pr|stale-captain-word|captain-word)
        record_review "$case_dir" "$url" "$head" --customer-data-billing-spend yes \
          --reader-model gpt-5.1-codex >/dev/null
        expected=reader_family
        if [ "$scenario" = other-pr ]; then
          review_record_command "$case_dir" captain-word --pr https://github.com/example/repo/pull/10 --head "$head" --words 'Merge this PR.' >/dev/null
        elif [ "$scenario" = stale-captain-word ]; then
          review_record_command "$case_dir" captain-word --pr "$url" --head 2222222222222222222222222222222222222222 --words 'Merge this PR.' >/dev/null
        elif [ "$scenario" = captain-word ]; then
          review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge this PR despite the spend trigger.' >/dev/null
          review_record_command "$case_dir" latest --pr "$url" > "$case_dir/latest"
          "$JQ_BIN" -e '.["captain-word"].words == "Merge this PR despite the spend trigger."' "$case_dir/latest" >/dev/null \
            || fail "captain exact words not preserved"
        fi ;;
      captain-only) review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge the approved pull request.' >/dev/null ;;
      stale-captain-only)
        review_record_command "$case_dir" captain-word --pr "$url" --head 2222222222222222222222222222222222222222 --words 'Merge the approved pull request.' >/dev/null
        expected='review record is missing' ;;
      valid) record_review "$case_dir" "$url" "$head" >/dev/null ;;
      captain-then-fail|captain-fail-stale-pass|captain-fail-stale-fail|captain-fail-unknown-pass|captain-fail-same-family-pass)
        review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge PR 9.' >/dev/null
        record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null
        expected="verdict is FAIL at live head $head in the review appended after the captain-word (reader claude-opus-5-5, at $("$JQ_BIN" -sr '.[-1].at' "$case_dir/state/review-records.jsonl"), report $case_dir/review.md); the captain must give a new merge word" ;;
      fail-then-captain)
        record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null
        review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge PR 9 despite the FAIL.' >/dev/null ;;
      captain-fail-pass)
        review_record_command "$case_dir" captain-word --pr "$url" --head "$head" --words 'Merge PR 9.' >/dev/null
        record_review "$case_dir" "$url" "$head" --verdict FAIL >/dev/null
        record_review "$case_dir" "$url" "$head" >/dev/null ;;
    esac
    case "$scenario" in
      captain-fail-stale-pass) record_review "$case_dir" "$url" 2222222222222222222222222222222222222222 >/dev/null ;;
      captain-fail-stale-fail) record_review "$case_dir" "$url" 2222222222222222222222222222222222222222 --verdict FAIL >/dev/null ;;
      captain-fail-unknown-pass) record_review "$case_dir" "$url" "$head" --reader-model mistral-large >/dev/null ;;
      captain-fail-same-family-pass) record_review "$case_dir" "$url" "$head" --reader-model claude-sonnet-5-5 --author-groups '{"all":["claude-opus-5-5"]}' >/dev/null ;;
    esac
    rc=0
    run_pr_merge "$case_dir" task-x1 "$url" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    case "$scenario" in
      valid|trigger-list|trigger-guard|trigger-data|captain-word|captain-only|cross-family-model|unknown-author-captain|fail-then-captain|captain-fail-pass)
        expect_code 0 "$rc" "$scenario must merge"
        assert_logged_gh_merge "$case_dir" 9 example/repo --squash ;;
      *)
        expect_code 1 "$rc" "$scenario must refuse"
        assert_grep "$expected" "$case_dir/stderr" "$scenario refusal names field"
        assert_grep 'fm-review-record.py' "$case_dir/stderr" "$scenario refusal names completing step"
        assert_no_grep '^pr merge ' "$case_dir/gh.log" "$scenario must never call merge" ;;
    esac
    pass "recorded review merge condition: $scenario"
  done
}

test_github_zero_exit_queue_required_refuses_with_exact_retry() {
  local case_dir rc
  case_dir=$(make_case github-zero-exit-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2121212121212121212121212121212121212121
  write_github_outcome "$case_dir" OPEN false false 'release/2026'
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/56 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-zero-exit-queue-required: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the concrete observed state"
  assert_grep 'base branch release/2026 requires the merge queue' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the queue requirement"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-zero-exit-queue-required: refusal did not name the exact compatible flags"
  assert_grep 'api --paginate repos/example/repo/rules/branches/release%2F2026' "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue rules were not read with pagination and encoded branch path"
  assert_logged_gh_merge "$case_dir" 56 example/repo --squash
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "github-zero-exit-queue-required: the wrapper attempted more than one merge"
  assert_no_grep --auto "$case_dir/gh.log" \
    "github-zero-exit-queue-required: queue flags were auto-applied to the attempted merge"
  assert_grep 'pr=https://github.com/example/repo/pull/56' "$case_dir/state/task-x1.meta" \
    "github-zero-exit-queue-required: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-zero-exit-queue-required: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge reports exact queue retry flags after a zero-exit false success"
}

test_github_closed_unqueued_outcome_omits_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-closed-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2323232323232323232323232323232323232323
  write_github_outcome "$case_dir" CLOSED false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-closed-unqueued: an unproved merge must fail"
  assert_grep 'state=CLOSED, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-closed-unqueued: refusal did not name the concrete observed state"
  assert_no_grep 'requires the merge queue' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received unusable queue guidance"
  assert_no_grep '--attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-closed-unqueued: closed PR received retry flags"
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-closed-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-closed-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge omits merge-queue retry guidance for a closed GitHub PR"
}

test_github_agreeing_queue_rules_keep_retry_guidance() {
  local case_dir rc
  case_dir=$(make_case github-agreeing-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2424242424242424242424242424242424242424
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\nmerge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/58 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-agreeing-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue' "$case_dir/stderr" \
    "github-agreeing-queue-rules: refusal did not name the queue requirement"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules omitted exact retry flags"
  assert_no_grep 'exact retry flags are ambiguous' "$case_dir/stderr" \
    "github-agreeing-queue-rules: agreeing rules were reported as ambiguous"
  pass "fm-pr-merge aggregates agreeing merge-queue rules"
}

test_github_conflicting_queue_rules_report_ambiguity() {
  local case_dir rc
  case_dir=$(make_case github-conflicting-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2525252525252525252525252525252525252525
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\nmerge_method=SQUASH\nmerge_method=SQUASH\n' \
    > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/59 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-conflicting-queue-rules: an unproved merge must fail"
  assert_grep 'base branch main has conflicting merge queue methods (MERGE, SQUASH)' \
    "$case_dir/stderr" \
    "github-conflicting-queue-rules: conflicting methods were not named"
  assert_no_grep '--attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep '--attended-override -- --auto --squash' "$case_dir/stderr" \
    "github-conflicting-queue-rules: an exact retry method was guessed"
  assert_no_grep 'SQUASH, SQUASH' "$case_dir/stderr" \
    "github-conflicting-queue-rules: a repeated queue method was named twice"
  pass "fm-pr-merge reports ambiguity for conflicting merge-queue rules"
}

test_verified_merge_records_pr_and_head() {
  local case_dir rc
  case_dir=$(make_case records-before-merge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" deadbeefcafefeed0000000000000000deadbeef
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/9 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-before-merge: fm-pr-merge should succeed"
  assert_grep 'pr=https://github.com/example/repo/pull/9' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr= was not recorded"
  assert_grep 'pr_head=deadbeefcafefeed0000000000000000deadbeef' "$case_dir/state/task-x1.meta" \
    "records-before-merge: pr_head= was not recorded"
  assert_logged_gh_merge "$case_dir" 9 example/repo --squash
  pass "fm-pr-merge records pr= and pr_head= for a verified GitHub merge"
}

# The forge call is the point of no return: once gh-axi has merged, nothing this
# script does afterwards can un-merge it. Proving pr= is already in the task's
# meta at that moment is what makes a later failure unable to lose the merge.
test_pr_metadata_is_recorded_before_the_forge_call() {
  local case_dir rc
  case_dir=$(make_case records-ahead-of-forge-call)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/meta-at-merge"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/62 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "records-ahead-of-forge-call: fm-pr-merge should succeed"
  assert_logged_gh_merge "$case_dir" 62 example/repo --squash
  assert_grep 'pr=https://github.com/example/repo/pull/62' "$case_dir/meta-at-merge" \
    "records-ahead-of-forge-call: the merge ran before pr= was recorded"
  pass "fm-pr-merge records pr= before the forge call can land the merge"
}

test_merge_failure_propagates_after_recording() {
  local case_dir rc
  case_dir=$(make_case merge-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/13 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "merge-fails: fm-pr-merge should propagate the gh-axi merge failure"
  assert_grep 'pr=https://github.com/example/repo/pull/13' "$case_dir/state/task-x1.meta" \
    "merge-fails: pr= should already be recorded even though the merge itself failed"
  pass "fm-pr-merge propagates a real merge failure without silently succeeding"
}

test_github_open_unqueued_outcome_refuses() {
  local case_dir rc
  case_dir=$(make_case github-open-unqueued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2020202020202020202020202020202020202020
  write_github_outcome "$case_dir" OPEN false false master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/52 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-open-unqueued: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-open-unqueued: refusal did not name the concrete observed state"
  assert_grep 'pr=https://github.com/example/repo/pull/52' "$case_dir/state/task-x1.meta" \
    "github-open-unqueued: the attempted merge lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-open-unqueued: the attempted merge did not leave its poll armed"
  pass "fm-pr-merge refuses a GitHub merge call that leaves the PR open and unqueued"
}

# GitHub reports mergeable=UNKNOWN for a short while after a push or a base
# branch change while it recomputes mergeability. When that is the only
# failing condition, the gate re-reads and re-checks every live condition on
# a bounded retry instead of refusing a pull request that is simply pending.
test_github_mergeable_unknown_retries_then_succeeds() {
  local case_dir rc head
  head=4242424242424242424242424242424242424242
  case_dir=$(make_case github-mergeable-unknown-then-mergeable)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' UNKNOWN MERGEABLE > "$case_dir/mergeable-sequence"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  FM_TEST_GH_MERGEABLE_SEQUENCE="$case_dir/mergeable-sequence" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/83 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-mergeable-unknown-then-mergeable: a merge should succeed once mergeable resolves"
  [ "$(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")" -eq 2 ] \
    || fail "github-mergeable-unknown-then-mergeable: expected exactly 2 mergeable reads, got $(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")"
  assert_logged_gh_merge "$case_dir" 83 example/repo --squash
  [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
    || fail "github-mergeable-unknown-then-mergeable: the wrapper attempted more than one merge"
  assert_grep 'pr=https://github.com/example/repo/pull/83' "$case_dir/state/task-x1.meta" \
    "github-mergeable-unknown-then-mergeable: pr= was not recorded"
  pass "fm-pr-merge retries a bounded number of times when mergeable is UNKNOWN and merges once it resolves"
}

# Every attempt still reads mergeable=UNKNOWN: the bound is spent and the gate
# reports mergeability as still pending rather than calling the pull request
# unmergeable, never attempting a merge on an unresolved read.
test_github_mergeable_unknown_exhausts_bound_and_reports_pending() {
  local case_dir rc head
  head=4343434343434343434343434343434343434343
  case_dir=$(make_case github-mergeable-unknown-exhausted)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' UNKNOWN > "$case_dir/mergeable-sequence"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  FM_TEST_GH_MERGEABLE_SEQUENCE="$case_dir/mergeable-sequence" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/84 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-mergeable-unknown-exhausted: a mergeable read that never resolves must still fail"
  [ "$(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")" -eq 5 ] \
    || fail "github-mergeable-unknown-exhausted: expected exactly 5 bounded mergeable reads, got $(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-mergeable-unknown-exhausted: a merge was attempted while mergeable never resolved"
  assert_grep "mergeability for https://github.com/example/repo/pull/84 is still being computed by GitHub; retry shortly" \
    "$case_dir/stderr" \
    "github-mergeable-unknown-exhausted: the exhausted retry did not report mergeability as still pending"
  pass "fm-pr-merge reports mergeability still pending after its bounded UNKNOWN retry is spent"
}

# A check that turns red between two UNKNOWN reads must refuse on the re-check:
# the retry re-reads every live condition, not only mergeable.
test_github_mergeable_unknown_retry_rechecks_checks() {
  local case_dir rc head
  head=4545454545454545454545454545454545454545
  case_dir=$(make_case github-mergeable-unknown-check-turns-red)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  printf '%s\n' UNKNOWN 'UNKNOWN FAILURE' > "$case_dir/mergeable-sequence"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  FM_TEST_GH_MERGEABLE_SEQUENCE="$case_dir/mergeable-sequence" \
  FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 \
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/86 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-mergeable-unknown-check-turns-red: a check that turned red must refuse"
  [ "$(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")" -eq 2 ] \
    || fail "github-mergeable-unknown-check-turns-red: expected exactly 2 reads, got $(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")"
  assert_grep "check 'ci' is not green" "$case_dir/stderr" \
    "github-mergeable-unknown-check-turns-red: the re-check did not refuse the red check"
  assert_no_grep 'still being computed' "$case_dir/stderr" \
    "github-mergeable-unknown-check-turns-red: a red check was reported as mergeability pending"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-mergeable-unknown-check-turns-red: gh pr merge ran after a check turned red"
  pass "fm-pr-merge refuses on the UNKNOWN re-check when a check turned red between reads"
}

# A real conflict (mergeable=CONFLICTING) is a different condition from GitHub
# still computing mergeability, and must refuse immediately like every other
# refusal, never retried.
test_github_mergeable_conflicting_is_not_retried() {
  local case_dir rc head
  head=4444444444444444444444444444444444444444
  case_dir=$(make_case github-mergeable-conflicting)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" "$head"
  jq -c '.mergeable = "CONFLICTING"' "$case_dir/github-view.json" > "$case_dir/github-view.tmp"
  mv "$case_dir/github-view.tmp" "$case_dir/github-view.json"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/85 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-mergeable-conflicting: a genuine conflict must refuse"
  [ "$(grep -c '^pr view .*mergeStateStatus' "$case_dir/gh.log")" -eq 1 ] \
    || fail "github-mergeable-conflicting: a genuine conflict was retried instead of refused immediately"
  assert_grep 'mergeable is "CONFLICTING", not MERGEABLE' "$case_dir/stderr" \
    "github-mergeable-conflicting: the conflict was not named"
  assert_no_grep 'still being computed' "$case_dir/stderr" \
    "github-mergeable-conflicting: a genuine conflict was reported as still being computed"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "github-mergeable-conflicting: gh pr merge ran on a conflicting PR"
  pass "fm-pr-merge refuses a genuine mergeable conflict immediately, without retrying"
}

test_github_unreadable_outcome_keeps_pr_bookkeeping() {
  local case_dir rc
  case_dir=$(make_case github-outcome-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3131313131313131313131313131313131313131
  add_gh_mock_outcome_read_fails "$case_dir" 3131313131313131313131313131313131313131
  add_gh_axi_mock_view_fails "$case_dir"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/57 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-outcome-read-fails: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" "github-outcome-read-fails: the unreadable outcome was not reported"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" "github-outcome-read-fails: the refusal did not name both failed reads"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-outcome-read-fails: an unproved merge was reported as verified"
  # The merge call itself returned success, so the pull request may well have
  # landed. Losing the reference here would leave teardown with nothing to
  # verify against and no merge poll to catch up.
  assert_grep 'pr=https://github.com/example/repo/pull/57' "$case_dir/state/task-x1.meta" \
    "github-outcome-read-fails: a successful merge call lost its PR reference"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-outcome-read-fails: no merge poll was armed for a merge that may have landed"
  pass "fm-pr-merge keeps PR bookkeeping when it cannot read a successful merge call's outcome"
}

test_github_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-refusal-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 6161616161616161616161616161616161616161
  printf '%s\n' 'will be added to the merge queue when all requirements are met' \
    > "$case_dir/github-merge-output"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/65 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-refusal-quotes-forge: an unproved merge must fail"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's own explanation was discarded on the refusal"
  assert_grep "not this script's verdict" "$case_dir/stderr" \
    "github-refusal-quotes-forge: the forge's text was not marked as the forge's own"
  assert_grep 'error: GitHub merge outcome was not successful: state=OPEN, merged=false, isInMergeQueue=false' \
    "$case_dir/stderr" "github-refusal-quotes-forge: the wrapper's own verdict was lost"
  # A forge sentence about the merge queue must never stand on its own line, or
  # it reads as this script's verdict rather than as quoted forge output.
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-refusal-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'will be added to the merge queue' "$case_dir/stdout" \
    "github-refusal-quotes-forge: the forge's unverified report leaked to stdout"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-refusal-quotes-forge: an unproved merge was reported as verified"
  pass "fm-pr-merge refuses with the forge's own output quoted apart from its verdict"
}

test_github_unreadable_outcome_refusal_quotes_the_forge_output() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-outcome-quotes-forge)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8787878787878787878787878787878787878787
  printf '%s\n' 'will be added to the merge queue when all requirements are met' \
    > "$case_dir/github-merge-output"
  add_gh_axi_mock_view_fails "$case_dir"
  add_gh_mock_outcome_read_fails "$case_dir" 8787878787878787878787878787878787878787
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-outcome-quotes-forge: an unreadable outcome must fail"
  assert_grep 'could not read the GitHub pull request outcome after the merge attempt' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the unreadable outcome was not reported"
  assert_grep 'error: > will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    "github-unreadable-outcome-quotes-forge: the forge's only evidence was discarded"
  ! grep -qxF 'will be added to the merge queue when all requirements are met' \
    "$case_dir/stderr" \
    || fail "github-unreadable-outcome-quotes-forge: forge text was emitted as the wrapper's own line"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unreadable-outcome-quotes-forge: an unproved merge was reported as verified"
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-unreadable-outcome-quotes-forge: the attempted merge lost its merge poll"
  pass "fm-pr-merge quotes the forge output when it cannot read the outcome either"
}

test_github_accepted_queue_flags_do_not_echo_back_the_same_command() {
  local case_dir rc
  case_dir=$(make_case github-accepted-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8181818181818181818181818181818181818181
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/68 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-accepted-queue-flags: an unproved merge must still fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-accepted-queue-flags: refusal did not name the concrete observed state"
  assert_grep 'this run refuses even though the request for https://github.com/example/repo/pull/68 was accepted with the exact flags base branch main requires (--auto --merge)' \
    "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal did not explain that the right flags were already used"
  assert_grep "re-check the pull request's merge queue state" "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal named no concrete next step"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-accepted-queue-flags: the refusal echoed back the command that just refused"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-accepted-queue-flags: an unproved merge was reported as verified"
  pass "fm-pr-merge does not echo back queue flags the caller already used"
}

test_github_mismatched_queue_flags_still_name_the_retry() {
  local case_dir rc
  case_dir=$(make_case github-mismatched-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8282828282828282828282828282828282828282
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=REBASE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/69 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-mismatched-queue-flags: an unproved merge must still fail"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-mismatched-queue-flags: a caller method the queue does not use lost its retry guidance"
  assert_grep '--attended-override -- --auto --rebase' "$case_dir/stderr" \
    "github-mismatched-queue-flags: the exact compatible flags were not named"
  pass "fm-pr-merge still names retry flags when the caller used a different method"
}

test_github_unrecognised_queue_method_still_names_the_queue() {
  local case_dir rc
  case_dir=$(make_case github-unrecognised-queue-method)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8383838383838383838383838383838383838383
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=FASTFORWARD\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/70 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unrecognised-queue-method: an unproved merge must fail"
  assert_grep 'base branch main requires the merge queue, but its configured merge method (FASTFORWARD) is not one this script recognises' \
    "$case_dir/stderr" \
    "github-unrecognised-queue-method: a readable queue rule produced no queue mention: $(cat "$case_dir/stderr")"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unrecognised-queue-method: retry flags were named for a method nothing recognises"
  assert_no_grep '--auto --' "$case_dir/stderr" \
    "github-unrecognised-queue-method: a merge method was guessed for the caller"
  pass "fm-pr-merge names the queue requirement even when its method is unrecognised"
}

test_github_unreadable_queue_rules_are_not_reported_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-unreadable-queue-rules)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8484848484848484848484848484848484848484
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules-fail"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/71 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unreadable-queue-rules: an unproved merge must fail"
  assert_grep 'the branch rules for base branch main could not be read' "$case_dir/stderr" \
    "github-unreadable-queue-rules: an unreadable rules response read like a queue-less base"
  assert_no_grep 'retry with:' "$case_dir/stderr" \
    "github-unreadable-queue-rules: retry flags were named from rules nothing could read"
  pass "fm-pr-merge distinguishes unreadable branch rules from a base with no merge queue"
}

# A repository whose plan does not expose branch rules answers the rules
# endpoint with a 403 whose body is GitHub's own plan-upgrade message, not a
# generic auth or rate-limit failure. That repository cannot have a
# merge_queue rule either, so it must read as no queue rather than unreadable
# - an attended read still fails the merge here only because the queue-aware
# outcome read (api graphql) was never set up for this case, exactly like the
# no-queue-rule case below; the queue read itself is proven by the absence of
# 'merge-queue' wording in the refusal.
test_github_plan_gated_403_reads_as_no_queue() {
  local case_dir rc
  case_dir=$(make_case github-plan-gated-403)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8989898989898989898989898989898989898989
  write_github_outcome "$case_dir" OPEN false false main
  printf 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature (HTTP 403)\n' \
    > "$case_dir/github-rules-fail-body"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/75 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-plan-gated-403: an unproved merge must fail"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-plan-gated-403: a plan-gated 403 was read as an unreadable or present queue rule"
  assert_no_grep 'could not be read' "$case_dir/stderr" \
    "github-plan-gated-403: a plan-gated 403 was reported as an unreadable rules response"
  pass "fm-pr-merge reads a plan-gated 403 on branch rules as no merge queue, not unreadable"
}

test_github_no_queue_rule_says_nothing_about_a_queue() {
  local case_dir rc
  case_dir=$(make_case github-no-queue-rule)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8585858585858585858585858585858585858585
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/72 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-no-queue-rule: an unproved merge must fail"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-no-queue-rule: refusal did not name the concrete observed state"
  assert_no_grep 'merge queue' "$case_dir/stderr" \
    "github-no-queue-rule: a base with no queue rule was told it requires the merge queue"
  pass "fm-pr-merge says nothing about a merge queue when the base branch has no queue rule"
}

test_github_unmerged_fallback_cannot_replace_queue_aware_read() {
  local case_dir rc
  case_dir=$(make_case github-unmerged-fallback)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8686868686868686868686868686868686868686
  add_gh_mock_outcome_read_fails "$case_dir"
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: open\n' "$3" ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/73 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-unmerged-fallback: an unproved merge must fail"
  assert_grep 'pr view 73 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-unmerged-fallback: the fallback view was not consulted"
  assert_grep 'the gh read failed and the gh-axi view could not prove the outcome either' \
    "$case_dir/stderr" \
    "github-unmerged-fallback: an unmerged fallback was treated as a readable outcome"
  assert_no_grep 'GitHub merge outcome was not successful' "$case_dir/stderr" \
    "github-unmerged-fallback: an unmerged fallback reached detailed outcome handling"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-unmerged-fallback: an unproved merge was reported as verified"
  pass "fm-pr-merge accepts only a proved merge from the gh-axi fallback"
}

test_github_auto_merge_without_queue_refuses_legibly() {
  local case_dir rc spelling
  for spelling in --auto --auto=true; do
    case_dir=$(make_case "github-auto-no-queue${spelling#--auto}")
    mkdir -p "$case_dir/wt"
    add_gh_mocks "$case_dir" 7171717171717171717171717171717171717171
    write_github_outcome "$case_dir" OPEN false false main
    : > "$case_dir/github-rules"
    : > "$case_dir/gh-axi.log"
    : > "$case_dir/gh.log"

    set +e
    run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/66 \
      --attended-override -- "$spelling" --merge \
      > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expect_code 1 "$rc" "github-auto-no-queue: an armed but unlanded auto-merge must still fail"
    assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
      "github-auto-no-queue: refusal did not name the concrete observed state"
    assert_grep 'auto-merge was requested and armed for https://github.com/example/repo/pull/66' \
      "$case_dir/stderr" "github-auto-no-queue: the refusal never explained the armed auto-merge"
    assert_grep 'nothing is merged or in the merge queue yet' "$case_dir/stderr" \
      "github-auto-no-queue: the refusal left the operator to infer the pending state"
    assert_logged_gh_merge "$case_dir" 66 example/repo "$spelling" --merge
    [ "$(grep -c '^pr merge ' "$case_dir/gh.log")" -eq 1 ] \
      || fail "github-auto-no-queue: the wrapper attempted more than one merge"
    assert_grep 'pr=https://github.com/example/repo/pull/66' "$case_dir/state/task-x1.meta" \
      "github-auto-no-queue: the attempted merge lost its PR reference"
    assert_present "$case_dir/state/task-x1.check.sh" \
      "github-auto-no-queue: the attempted merge did not leave its poll armed"
  done
  pass "fm-pr-merge explains an armed auto-merge that landed nothing on a queue-less base"
}

test_github_failed_merge_never_claims_armed_auto_merge() {
  local case_dir rc
  case_dir=$(make_case github-auto-merge-command-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  : > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/67 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-auto-merge-command-fails: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-auto-merge-command-fails: refusal did not name the concrete observed state"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-auto-merge-command-fails: a failed merge command was reported as an armed auto-merge"
  assert_grep 'auto-merge was requested for https://github.com/example/repo/pull/67' \
    "$case_dir/stderr" \
    "github-auto-merge-command-fails: the refusal never said auto-merge had only been requested"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-auto-merge-command-fails: a failed merge command was reported as verified"
  pass "fm-pr-merge never reports auto-merge as armed when the merge command failed"
}

test_github_failed_merge_with_queue_flags_never_claims_acceptance() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-queue-flags)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false main
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/74 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-queue-flags: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the original forge error was masked"
  assert_grep 'state=OPEN, merged=false, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: refusal did not name the concrete observed state"
  assert_no_grep 'was accepted with the exact flags' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an accepted request"
  assert_no_grep 'armed' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: a failed merge command was reported as an armed auto-merge"
  assert_grep 'base branch main requires the merge queue; retry with:' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the failed merge command lost its concrete retry guidance"
  assert_grep 'task-x1 https://github.com/example/repo/pull/74 --attended-override -- --auto --merge' "$case_dir/stderr" \
    "github-failed-merge-queue-flags: the retry guidance named no queue flags"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-queue-flags: a failed merge command was reported as verified"
  pass "fm-pr-merge claims no acceptance for a failed merge command carrying queue flags"
}

test_github_failed_gh_read_falls_back_to_gh_axi() {
  local case_dir rc
  case_dir=$(make_case github-gh-read-falls-back)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 5151515151515151515151515151515151515151
  add_gh_mock_outcome_read_fails "$case_dir" 5151515151515151515151515151515151515151
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/63 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-gh-read-falls-back: a merge the gh-axi view proves must succeed"
  assert_grep 'pr view 63 --repo example/repo' "$case_dir/gh-axi.log" \
    "github-gh-read-falls-back: the gh-axi view was never consulted after gh's read failed"
  assert_grep 'verified: https://github.com/example/repo/pull/63 is merged' \
    "$case_dir/stdout" "github-gh-read-falls-back: the proven merge was not reported"
  assert_grep 'pr=https://github.com/example/repo/pull/63' "$case_dir/state/task-x1.meta" \
    "github-gh-read-falls-back: the merged PR was not recorded for teardown"
  pass "fm-pr-merge falls back to the gh-axi view when gh's read fails"
}

test_github_failed_merge_names_an_observed_landed_state() {
  local case_dir rc
  case_dir=$(make_case github-failed-merge-actually-landed)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" MERGED true false main
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/64 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-failed-merge-actually-landed: the forge failure must still fail the wrapper"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the original forge error was masked"
  assert_grep 'state=MERGED, merged=true, isInMergeQueue=false' "$case_dir/stderr" \
    "github-failed-merge-actually-landed: the observed landed state was never named"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-failed-merge-actually-landed: a failed merge command was reported as verified"
  assert_grep 'pr=https://github.com/example/repo/pull/64' "$case_dir/state/task-x1.meta" \
    "github-failed-merge-actually-landed: the landed PR lost its reference"
  pass "fm-pr-merge names a landed state hiding behind a failed GitHub merge command"
}

test_github_without_gh_still_uses_gh_axi_merge() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/60 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-without-gh: missing gh must refuse before recording"
  assert_grep 'merging a GitHub pull request requires gh on PATH' "$case_dir/stderr" \
    "github-without-gh: missing gh was not named"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "github-without-gh: pr= was recorded without gh"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-without-gh: a merge poll was armed without gh"
  pass "fm-pr-merge refuses a GitHub merge when gh is missing, before recording"
}

test_github_without_gh_failed_read_keeps_bookkeeping() {
  local case_dir ghless_path rc
  case_dir=$(make_case github-without-gh-read-fails)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4141414141414141414141414141414141414141
  rm "$case_dir/fakebin/gh"
  ghless_path="$case_dir/path-without-gh"
  mirror_path_without "$ghless_path" gh "$case_dir/fakebin"
  : > "$case_dir/gh-axi.log"

  set +e
  PATH="$ghless_path" run_pr_merge "$case_dir" task-x1 \
    https://github.com/example/repo/pull/61 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-without-gh-read-fails: missing gh must refuse before recording"
  assert_grep 'merging a GitHub pull request requires gh on PATH' "$case_dir/stderr" \
    "github-without-gh-read-fails: missing gh was not named"
  assert_no_grep 'pr=' "$case_dir/state/task-x1.meta" \
    "github-without-gh-read-fails: pr= was recorded without gh"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-without-gh-read-fails: a merge poll was armed without gh"
  pass "fm-pr-merge refuses a GitHub merge when gh is missing rather than merging blind"
}

test_github_merged_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-merged)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-merged: a merged PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/51 is merged' \
    "$case_dir/stdout" "github-verified-merged: success was not reported as verified"
  assert_grep 'api graphql' "$case_dir/gh.log" \
    "github-verified-merged: the PR outcome was not read back after merging"
  pass "fm-pr-merge verifies a genuinely merged GitHub pull request"
}

test_github_verified_merge_requires_poll_recording() {
  local case_dir rc
  case_dir=$(make_case github-poll-recording-fails)
  add_gh_mocks "$case_dir" 1111111111111111111111111111111111111111
  add_failing_poll_publish_mv "$case_dir"
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-poll-recording-fails: poll setup failure should fail the merge wrapper"
  assert_grep 'error: could not publish PR poll' "$case_dir/stderr" \
    "github-poll-recording-fails: poll setup failure was not reported"
  assert_no_grep 'verified: ' "$case_dir/stdout" \
    "github-poll-recording-fails: failed poll setup was reported as a verified merge"
  assert_grep 'pr=https://github.com/example/repo/pull/55' "$case_dir/state/task-x1.meta" \
    "github-poll-recording-fails: metadata was not retained for the attempted merge"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "github-poll-recording-fails: the failed poll setup left a runnable poll"
  pass "fm-pr-merge refuses to claim a merge when poll recording fails"
}

test_github_queued_outcome_is_verified() {
  local case_dir rc
  case_dir=$(make_case github-verified-queued)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
  write_github_outcome "$case_dir" OPEN false true master
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 --attended-override -- --auto --merge \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "github-verified-queued: a queued PR should succeed"
  assert_grep 'verified: https://github.com/example/repo/pull/53 is queued' \
    "$case_dir/stdout" "github-verified-queued: success was not reported as queued"
  assert_no_grep 'merged:' "$case_dir/stdout" \
    "github-verified-queued: the forge CLI's unverified merged report leaked through"
  assert_grep 'pr=https://github.com/example/repo/pull/53' "$case_dir/state/task-x1.meta" \
    "github-verified-queued: the queued PR was not recorded for teardown"
  pass "fm-pr-merge accepts and accurately reports a GitHub merge-queue entry"
}

test_github_queue_required_refusal_names_retry_flags() {
  local case_dir rc
  case_dir=$(make_case github-queue-required)
  mkdir -p "$case_dir/wt"
  add_gh_mocks_merge_fails "$case_dir"
  write_github_outcome "$case_dir" OPEN false false master
  printf 'merge_method=MERGE\n' > "$case_dir/github-rules"
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/gh.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/54 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "github-queue-required: an incompatible direct merge must fail"
  assert_grep 'error: pr merge failed' "$case_dir/stderr" \
    "github-queue-required: the original forge failure was not preserved"
  assert_grep 'base branch master requires the merge queue' "$case_dir/stderr" \
    "github-queue-required: refusal did not name the queue requirement"
  grep -F -- '--attended-override -- --auto --merge' "$case_dir/stderr" >/dev/null \
    || fail "github-queue-required: refusal did not name the exact compatible flags"
  assert_logged_gh_merge "$case_dir" 54 example/repo --squash
  assert_present "$case_dir/state/task-x1.check.sh" \
    "github-queue-required: the failed forge call did not leave the merge poll armed"
  pass "fm-pr-merge explains how to retry with the required GitHub merge queue method"
}

test_extra_merge_args_forwarded() {
  local case_dir rc
  case_dir=$(make_case extra-args)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "extra-args: branch deletion must be refused without --attended-override"
  assert_grep 'pass --attended-override only for an explicit captain instruction' "$case_dir/stderr" \
    "extra-args: refusal did not name --attended-override"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "extra-args: gh pr merge ran despite the denylist"

  case_dir=$(make_case extra-args-attended)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 2222222222222222222222222222222222222222
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/15 \
    --attended-override -- --squash --delete-branch \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || fail "extra-args-attended: attended override should merge"
  assert_logged_gh_merge "$case_dir" 15 example/repo --squash --delete-branch
  pass "fm-pr-merge refuses branch deletion unless --attended-override is passed"
}

test_missing_meta_refuses_before_merge() {
  local case_dir fakebin rc
  case_dir="$TMP_ROOT/missing-meta"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  add_gh_mocks "$case_dir" 3333333333333333333333333333333333333333
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" missing-x1 https://github.com/example/repo/pull/21 \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-pr-merge should refuse"
  assert_grep 'error: task metadata is unavailable' "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  [ ! -s "$case_dir/gh.log" ] || fail "missing-meta: gh pr merge was invoked"
  assert_absent "$case_dir/state/missing-x1.check.sh" \
    "missing-meta: fm-pr-check should not arm a poll for an unknown task"
  pass "fm-pr-merge refuses before merging when task meta is missing"
}

test_malformed_url_refuses_before_merge() {
  local case_dir rc
  case_dir=$(make_case malformed-url)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 4444444444444444444444444444444444444444
  : > "$case_dir/gh-axi.log"

  set +e
  # A near-miss GitLab URL: one namespace segment where a project needs at
  # least two. A well-formed merge request URL is merged now, so the refusal
  # has to be proven on a URL that genuinely does not parse.
  run_pr_merge "$case_dir" task-x1 'https://gitlab.com/example/-/merge_requests/1' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 2 "$rc" "malformed-url: fm-pr-merge should refuse a malformed merge request URL"
  assert_grep 'error: invalid PR merge request' "$case_dir/stderr" \
    "malformed-url: refusal was not fixed and non-probing"
  assert_no_grep 'pr=https://gitlab.com/example/-/merge_requests/1' "$case_dir/state/task-x1.meta" \
    "malformed-url: malformed PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "malformed-url: malformed PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "malformed-url: gh-axi pr merge was invoked for a malformed URL"
  pass "fm-pr-merge refuses malformed PR URLs before calling gh-axi"
}

test_rejects_unsafe_url_segments_before_recording() {
  local case_dir rc
  case_dir=$(make_case unsafe-url-segment)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 8888888888888888888888888888888888888888
  : > "$case_dir/gh-axi.log"

  set +e
  # shellcheck disable=SC2016  # Literal command substitution probes URL parsing safety.
  run_pr_merge "$case_dir" task-x1 'https://github.com/evil$(echo pwned)/repo/pull/7' \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "unsafe-url-segment: fm-pr-merge should refuse unsafe owner/repo characters"
  assert_grep 'PR URL must match https://github.com/<owner>/<repo>/pull/<number>' "$case_dir/stderr" \
    "unsafe-url-segment: refusal did not explain the expected URL shape"
  # shellcheck disable=SC2016  # Literal command substitution must not reach meta.
  assert_no_grep 'pr=https://github.com/evil$(echo pwned)/repo/pull/7' "$case_dir/state/task-x1.meta" \
    "unsafe-url-segment: unsafe PR URL was recorded in meta"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "unsafe-url-segment: unsafe PR URL armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "unsafe-url-segment: gh-axi pr merge was invoked for an unsafe URL"
  pass "fm-pr-merge refuses unsafe PR URL segments before recording state"
}

test_repo_override_args_refuse_before_recording() {
  local case_dir rc
  case_dir=$(make_case repo-override)
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 9999999999999999999999999999999999999999
  : > "$case_dir/gh-axi.log"

  set +e
  run_pr_merge "$case_dir" task-x1 https://github.com/right/repo/pull/5 -- --repo wrong/repo \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "repo-override: fm-pr-merge should refuse repo override flags"
  assert_grep 'extra merge arguments must not override the repository' "$case_dir/stderr" \
    "repo-override: refusal did not explain the repo override"
  assert_no_grep 'pr=https://github.com/right/repo/pull/5' "$case_dir/state/task-x1.meta" \
    "repo-override: PR URL was recorded before rejecting repo override"
  assert_absent "$case_dir/state/task-x1.check.sh" \
    "repo-override: repo override armed a merge poll"
  assert_no_grep 'pr merge' "$case_dir/gh.log" \
    "repo-override: gh-axi pr merge was invoked despite repo override"
  pass "fm-pr-merge refuses repo override args before recording state"
}

pr_merge_test_cases=(
test_triggered_review_verifies_only_when_independent
test_captain_fail_triggered_independent_pass_merges
test_review_record_requires_matching_local_report
test_late_fail_before_away_hold_refuses
test_attended_override_without_review_refuses
test_missing_review_record_refuses
test_gitlab_and_forgejo_missing_review_record_refuse
test_captain_word_refused_while_away
test_review_record_validation_and_latest
test_review_record_derives_model_families
test_review_record_survives_a_later_family_change
test_recorded_review_merge_conditions
test_github_zero_exit_queue_required_refuses_with_exact_retry
test_github_closed_unqueued_outcome_omits_retry_flags
test_github_agreeing_queue_rules_keep_retry_guidance
test_github_conflicting_queue_rules_report_ambiguity
test_verified_merge_records_pr_and_head
test_pr_metadata_is_recorded_before_the_forge_call
test_merge_failure_propagates_after_recording
test_github_open_unqueued_outcome_refuses
test_github_mergeable_unknown_retries_then_succeeds
test_github_mergeable_unknown_exhausts_bound_and_reports_pending
test_github_mergeable_unknown_retry_rechecks_checks
test_github_mergeable_conflicting_is_not_retried
test_github_unreadable_outcome_keeps_pr_bookkeeping
test_github_refusal_quotes_the_forge_output
test_github_unreadable_outcome_refusal_quotes_the_forge_output
test_github_accepted_queue_flags_do_not_echo_back_the_same_command
test_github_mismatched_queue_flags_still_name_the_retry
test_github_unrecognised_queue_method_still_names_the_queue
test_github_unreadable_queue_rules_are_not_reported_as_no_queue
test_github_plan_gated_403_reads_as_no_queue
test_github_no_queue_rule_says_nothing_about_a_queue
test_github_unmerged_fallback_cannot_replace_queue_aware_read
test_github_auto_merge_without_queue_refuses_legibly
test_github_failed_merge_never_claims_armed_auto_merge
test_github_failed_merge_with_queue_flags_never_claims_acceptance
test_github_failed_gh_read_falls_back_to_gh_axi
test_github_failed_merge_names_an_observed_landed_state
test_github_without_gh_still_uses_gh_axi_merge
test_github_without_gh_failed_read_keeps_bookkeeping
test_github_merged_outcome_is_verified
test_github_verified_merge_requires_poll_recording
test_github_queued_outcome_is_verified
test_github_queue_required_refusal_names_retry_flags
test_extra_merge_args_forwarded
test_missing_meta_refuses_before_merge
test_malformed_url_refuses_before_merge
test_rejects_unsafe_url_segments_before_recording
test_repo_override_args_refuse_before_recording
)
pr_merge_run "$@"
