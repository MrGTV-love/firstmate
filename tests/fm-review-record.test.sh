#!/usr/bin/env bash
# Tests for bin/fm-review-record.py: immutable review-time evidence,
# --review-only verification and the fm-review-verification.v1 JSON contract.
# Every case drives the real CLI over synthetic local reports and a local git
# fixture holding the PR base and head; no forge, model or merge operation
# happens.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECORD="$ROOT/bin/fm-review-record.py"
JQ_BIN=$(command -v jq) || fail "test needs jq"
TMP_ROOT=$(fm_test_tmproot fm-review-record-tests)
URL=https://github.com/example/repo/pull/9
HEAD2=2222222222222222222222222222222222222222
NM_FIXTURE="$TMP_ROOT/nm-home"
fm_test_empty_pipeline_db "$NM_FIXTURE"

# verify derives authors from the task's commits outside the PR base, so every
# case copies one fixture worktree whose tip is HEAD1 and whose base is BASE.
TEMPLATE_WT="$TMP_ROOT/template-wt"
fm_git_init_commit "$TEMPLATE_WT"
BASE=$(git -C "$TEMPLATE_WT" rev-parse HEAD)
git -C "$TEMPLATE_WT" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -q --allow-empty -m 'ship implementation'
HEAD1=$(git -C "$TEMPLATE_WT" rev-parse HEAD)

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

make_case() {  # <name> [ship author model]
  local name=$1 author=${2:-gpt-5.1} case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home/state"
  cp -R "$TEMPLATE_WT" "$case_dir/wt"
  fm_write_meta "$case_dir/home/state/task-x1.meta" \
    "worktree=$case_dir/wt" "kind=ship" "model=$author" "branch=fm/fixture" "mode=direct-PR"
  printf '%s\n' "$case_dir"
}

record_review() {  # <case_dir> <head> <verdict> <reader> <authors-json> [extra flags...]
  local case_dir=$1 head=$2 verdict=$3 reader=$4 authors=$5
  shift 5
  printf 'VERDICT: %s head=%s\nIndependent reader evidence.\n' "$verdict" "$head" > "$case_dir/report.md"
  FM_HOME="$case_dir/home" "$RECORD" review --pr "$URL" --head "$head" --verdict "$verdict" \
    --reader-model "$reader" --author-groups "$authors" \
    --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no \
    --report "$case_dir/report.md" "$@"
}

record_word() {  # <case_dir> <head> <words>
  local case_dir=$1 head=$2 words=$3
  FM_HOME="$case_dir/home" "$RECORD" captain-word --pr "$URL" --head "$head" --words "$words"
}

run_verify() {  # <case_dir> <head> [flags...]
  local case_dir=$1 head=$2
  shift 2
  NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" --head "$head" \
    --task task-x1 --base "$BASE" "$@"
}

expect_not_qualified() {  # <json> <message needle> <label>
  local out=$1 needle=$2 label=$3
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --arg needle "$needle" '
    .schema == "fm-review-verification.v1" and .ok == false
    and .error.kind == "not-qualified"
    and (.error.message | contains($needle))
    and (has("basis") | not) and (has("reader_model") | not)' <<<"$out" >/dev/null \
    || fail "$label: expected a typed not-qualified envelope mentioning '$needle': $out"
}

test_review_only_json_is_immutable_record_time_evidence() {
  local case_dir out rc=0 digest at ledger before after
  case_dir=$(make_case independent-json)
  record_review "$case_dir" "$HEAD1" PASS sonnet \
    '{"ship":["gpt-5.1"],"fixes":["Gemini-3-Pro","deepseek-v3"]}' >/dev/null \
    || fail "record independent PASS"
  digest=$(sha256_of "$case_dir/report.md")
  ledger="$case_dir/home/state/review-records.jsonl"
  at=$("$JQ_BIN" -r '.review.at' <<<"$(FM_HOME="$case_dir/home" "$RECORD" latest --pr "$URL")")
  out=$(run_verify "$case_dir" "$HEAD1" --review-only) || rc=$?
  expect_code 0 "$rc" "review-only text must succeed"
  assert_equals "review: PASS" "$out" "review-only text must stay review: PASS"
  before=$(sha256_of "$ledger")
  printf 'extra notes added after recording\n' >> "$case_dir/report.md"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 0 "$rc" "review-only JSON must succeed: $out"
  after=$(sha256_of "$ledger")
  assert_equals "$before" "$after" "verification must not mutate review history"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "success JSON must be one line: $out"
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --arg pr "$URL" --arg head "$HEAD1" --arg report "$case_dir/report.md" \
    --arg digest "$digest" --argjson at "$at" '
    .schema == "fm-review-verification.v1" and .ok == true
    and .basis == "independent-review" and .pr == $pr and .head == $head
    and .at == $at and .reader_model == "sonnet" and .reader_family == "anthropic"
    and .author_groups == {"ship":[{model:"gpt-5.1",family:"openai"}],
                           "fixes":[{model:"Gemini-3-Pro",family:"google"},
                                    {model:"deepseek-v3",family:"deepseek"}]}
    and .report == $report and .report_sha256 == $digest
    and (has("facts") | not)' <<<"$out" >/dev/null \
    || fail "review-only JSON must carry immutable record-time evidence: $out"
  pass "review-only --json reports immutable record-time independent evidence"
}

test_default_text_and_captain_word_json() {
  local case_dir out rc=0 review_at
  case_dir=$(make_case captain-word-json)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["gpt-5.1"]}' >/dev/null \
    || fail "record independent PASS"
  out=$(run_verify "$case_dir" "$HEAD1") || rc=$?
  expect_code 0 "$rc" "default verify must pass"
  assert_equals "review: PASS" "$out" "default verify PASS text must stay byte-identical"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --json) || rc=$?
  expect_code 0 "$rc" "default verify JSON must pass"
  "$JQ_BIN" -e '.ok == true and .basis == "independent-review"' <<<"$out" >/dev/null \
    || fail "default PASS JSON must stay independent: $out"
  review_at=$(printf '%s\n' "$out" | "$JQ_BIN" -r '.at')
  record_word "$case_dir" "$HEAD1" 'Merge this PR.' >/dev/null || fail "record captain word"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1") || rc=$?
  expect_code 0 "$rc" "captain-word verify must pass"
  assert_equals "review: captain-word" "$out" "default verify captain-word text must stay byte-identical"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --json) || rc=$?
  expect_code 0 "$rc" "captain-word JSON must pass"
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --argjson at "$review_at" --arg pr "$URL" --arg head "$HEAD1" '
    .schema == "fm-review-verification.v1" and .ok == true and .basis == "captain-word"
    and .pr == $pr and .head == $head and (.at | type) == "number" and .at >= $at
    and .words == "Merge this PR." and (has("reader_model") | not)' <<<"$out" >/dev/null \
    || fail "captain-word JSON must carry its own basis and words: $out"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 0 "$rc" "a captain-word must not block the recorded independent PASS"
  "$JQ_BIN" -e '.basis == "independent-review"' <<<"$out" >/dev/null \
    || fail "review-only must keep reporting independent review: $out"
  pass "default verify text and JSON preserve captain-word precedence"
}

test_review_only_cannot_be_satisfied_by_captain_word() {
  local case_dir out rc=0
  case_dir=$(make_case captain-word-only)
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "missing review must not qualify"
  expect_not_qualified "$out" "no independent review record" "missing ledger"
  [ ! -e "$case_dir/home/state/review-records.jsonl" ] \
    || fail "a missing review ledger must not be created by verification"
  record_word "$case_dir" "$HEAD1" 'Merge without review.' >/dev/null || fail "record captain word"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "captain-word alone must not satisfy review-only"
  expect_not_qualified "$out" "captain-word is not a substitute" "captain-word-only"
  out=$(run_verify "$case_dir" "$HEAD1") || fail "default verify should still accept the word"
  assert_equals "review: captain-word" "$out" "default verify keeps captain-word precedence"
  pass "captain-word alone cannot satisfy review-only"
}

test_review_only_rejections_are_typed_not_qualified() {
  local case_dir out rc=0
  case_dir=$(make_case reject-stale-head)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  out=$(run_verify "$case_dir" "$HEAD2" --review-only --json) || rc=$?
  expect_code 1 "$rc" "stale head must not qualify"
  expect_not_qualified "$out" "head mismatch" "stale head"

  case_dir=$(make_case reject-fail)
  record_review "$case_dir" "$HEAD1" FAIL sonnet '{"all":["gpt-5.1"]}' >/dev/null || fail "record FAIL"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "FAIL must not qualify"
  expect_not_qualified "$out" "verdict is FAIL" "FAIL review"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1") || rc=$?
  expect_code 1 "$rc" "default verify must still refuse FAIL"
  assert_contains "$out" "error: verdict is FAIL" "default FAIL text must stay actionable"

  case_dir=$(make_case reject-same-family claude-opus-4)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["claude-opus-4"]}' >/dev/null || fail "record same-family PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "same family must not qualify"
  expect_not_qualified "$out" "uncovered commit group ship, family anthropic" "same family"

  case_dir=$(make_case reject-unknown-reader)
  record_review "$case_dir" "$HEAD1" PASS mystery-9 '{"all":["gpt-5.1"]}' >/dev/null || fail "record unknown-reader PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "unknown reader must not qualify"
  expect_not_qualified "$out" "model family unknown for newest reader mystery-9" "unknown reader"

  case_dir=$(make_case reject-unknown-author mystery-9)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["mystery-9"]}' >/dev/null || fail "record unknown-author PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "unknown author must not qualify"
  expect_not_qualified "$out" "uncovered commit group ship, family unknown" "unknown author"
  assert_contains "$out" "two different known reader families" "unknown author refusal must name the second-family read"

  case_dir=$(make_case reject-unknown-author-one-family mystery-9)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["mystery-9"]}' >/dev/null || fail "record first same-family PASS"
  record_review "$case_dir" "$HEAD1" PASS claude-opus-4 '{"all":["mystery-9"]}' >/dev/null || fail "record second same-family PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "two readers of one family must not cover an unknown author"
  expect_not_qualified "$out" "uncovered commit group ship, family unknown" "unknown author, one reader family"

  case_dir=$(make_case reject-trigger)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["gpt-5.1"]}' --widens-guard yes >/dev/null \
    || fail "record trigger PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "yes trigger must not qualify"
  expect_not_qualified "$out" "widens_guard is yes" "yes trigger"
  pass "stale head, FAIL, same family, unknown families and triggers are typed not-qualified"
}

test_unknown_author_covered_by_two_reader_families() {
  local case_dir out rc=0
  case_dir=$(make_case unknown-author-two-families mystery-9)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["mystery-9"]}' >/dev/null || fail "record anthropic PASS"
  record_review "$case_dir" "$HEAD1" PASS gpt-5.1 '{"all":["mystery-9"]}' >/dev/null || fail "record openai PASS"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 0 "$rc" "two known reader families must cover an unknown author: $out"
  "$JQ_BIN" -e '.ok == true and .basis == "independent-review"' <<<"$out" >/dev/null \
    || fail "two-family cover must be independent review, not captain words: $out"

  case_dir=$(make_case unknown-author-stale-second-head mystery-9)
  record_review "$case_dir" "$HEAD2" PASS gpt-5.1 '{"all":["mystery-9"]}' >/dev/null || fail "record other-head PASS"
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["mystery-9"]}' >/dev/null || fail "record head PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "a second family read of another head must not cover an unknown author"
  expect_not_qualified "$out" "uncovered commit group ship, family unknown" "unknown author, second family on another head"
  pass "an unknown ship author family requires exact-head PASS reads from two known reader families"
}

test_unknown_pipeline_one_independent_reader() {
  local case_dir out rc=0
  case_dir=$(make_case pipeline-one-reader)
  printf 'mode=no-mistakes\n' >> "$case_dir/home/state/task-x1.meta"
  record_review "$case_dir" "$HEAD1" PASS sonnet \
    '{"ship":["gpt-5.1"],"no-mistakes:unknown":["unknown"]}' >/dev/null || fail 'record pipeline read'
  out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
    --head "$HEAD1" --task task-x1 --base "$BASE" --json) || rc=$?
  expect_code 0 "$rc" "T1 one reader outside every known ship family covers unknown pipeline: $out"
  "$JQ_BIN" -e '.facts == ["pipeline author family not recorded"]' <<<"$out" >/dev/null \
    || fail "T1 records the missing pipeline provenance: $out"
  pass 'T1 unknown pipeline accepts one different-builder-family reader'
}

test_unknown_pipeline_fact_output() {
  local case_dir out
  case_dir=$(make_case pipeline-fact)
  printf 'mode=no-mistakes\n' >> "$case_dir/home/state/task-x1.meta"
  record_review "$case_dir" "$HEAD1" PASS sonnet \
    '{"ship":["gpt-5.1"],"no-mistakes:unknown":["unknown"]}' >/dev/null || fail 'record the single pipeline read'
  out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
    --head "$HEAD1" --task task-x1 --base "$BASE") || fail "T6 pipeline verifies: $out"
  assert_contains "$out" 'pipeline author family not recorded' 'T6 verify discloses missing pipeline provenance'
  record_review "$case_dir" "$HEAD1" PASS gemini-3-pro \
    '{"ship":["gpt-5.1"],"no-mistakes:unknown":["unknown"]}' >/dev/null || fail 'record second pipeline read'
  out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
    --head "$HEAD1" --task task-x1 --base "$BASE") || fail "two-family pipeline verifies: $out"
  case "$out" in
    *'pipeline author family not recorded'*) fail "two known reader families prove independence, so no fact is printed: $out" ;;
  esac
  out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
    --head "$HEAD1" --task task-x1 --base "$BASE" --json) || fail "two-family pipeline verifies as JSON: $out"
  "$JQ_BIN" -e '.ok == true and (has("facts") | not)' <<<"$out" >/dev/null \
    || fail "two-family pipeline JSON must carry no facts: $out"
  pass 'T6 verify discloses the fact only for single-reader pipeline relief'
}

test_unknown_pipeline_preserves_coverage_boundaries() {
  local scenario case_dir authors reader out rc expected
  for scenario in same-ship unknown-ship unknown-reader mixed-ship no-ship no-ship-declared uncovered-known-pipeline stale-head; do
    case_dir=$(make_case "pipeline-$scenario")
    printf 'mode=no-mistakes\n' >> "$case_dir/home/state/task-x1.meta"
    authors='{"ship":["gpt-5.1"],"no-mistakes:unknown":["unknown"]}'
    reader=sonnet
    expected='uncovered commit group no-mistakes:unknown'
    case "$scenario" in
      same-ship) reader=gpt-5.1 ;;
      unknown-ship)
        printf 'model=mystery-9\n' >> "$case_dir/home/state/task-x1.meta"
        authors='{"ship":["mystery-9"],"no-mistakes:unknown":["unknown"]}' ;;
      unknown-reader) reader=mystery-9; expected='model family unknown for newest reader' ;;
      mixed-ship)
        printf 'model=sonnet\n' > "$case_dir/home/state/task-x1.control-relaunch.meta-prior"
        authors='{"ship":["gpt-5.1","sonnet"],"no-mistakes:unknown":["unknown"]}' ;;
      no-ship|no-ship-declared)
        printf 'model=\n' >> "$case_dir/home/state/task-x1.meta"
        git -C "$case_dir/wt" -c user.name=Tests -c user.email=tests@example.invalid \
          commit -q --amend --allow-empty -m 'no-mistakes(review): pipeline only'
        if [ "$scenario" = no-ship ]; then
          authors='{"no-mistakes:unknown":["unknown"]}'
        fi ;;
      uncovered-known-pipeline)
        authors='{"ship":["gpt-5.1"],"no-mistakes:unknown":["unknown"],"no-mistakes:anthropic":["sonnet"]}'
        expected='uncovered commit group no-mistakes:anthropic' ;;
      stale-head) expected='head mismatch' ;;
    esac
    local current_head
    current_head=$(git -C "$case_dir/wt" rev-parse HEAD)
    record_review "$case_dir" "$current_head" PASS "$reader" "$authors" >/dev/null || fail "record $scenario"
    [ "$scenario" != stale-head ] || current_head=$HEAD2
    rc=0
    out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
      --head "$current_head" --task task-x1 --base "$BASE" --json) || rc=$?
    expect_code 1 "$rc" "$scenario must refuse: $out"
    expect_not_qualified "$out" "$expected" "$scenario"
    pass "pipeline boundary: $scenario"
  done
}

test_unknown_pipeline_no_relief_for_partly_unknown_ship() {
  local case_dir out rc=0 authors
  case_dir=$(make_case pipeline-partly-unknown-ship)
  printf 'mode=no-mistakes\n' >> "$case_dir/home/state/task-x1.meta"
  printf 'model=mystery-9\n' > "$case_dir/home/state/task-x1.control-relaunch.meta-prior"
  authors='{"ship":["gpt-5.1","mystery-9"],"no-mistakes:unknown":["unknown"]}'
  record_review "$case_dir" "$HEAD1" PASS sonnet "$authors" >/dev/null || fail 'record Claude read of all groups'
  record_review "$case_dir" "$HEAD1" PASS gemini-3-pro "$authors" --covered-groups '["ship"]' >/dev/null \
    || fail 'record Google read of ship only'
  out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
    --head "$HEAD1" --task task-x1 --base "$BASE" --json) || rc=$?
  expect_code 1 "$rc" "a ship group with an unknown family gives the pipeline group no single-reader relief: $out"
  expect_not_qualified "$out" 'uncovered commit group no-mistakes:unknown, family unknown; model family unknown needs exact-head PASS reads of this group from two different known reader families' \
    'partly unknown ship keeps the two-reader pipeline rule'
  "$JQ_BIN" -e '.error.message | contains("outside every ship family") | not' <<<"$out" >/dev/null \
    || fail "partly unknown ship must not offer the single-reader rule: $out"
  pass 'a ship group with any unknown family gives the unknown pipeline group no relief'
}

test_unknown_pipeline_after_fail() {
  local case_dir out rc=0 authors
  case_dir=$(make_case pipeline-after-fail)
  printf 'mode=no-mistakes\n' >> "$case_dir/home/state/task-x1.meta"
  authors='{"ship":["gpt-5.1"],"no-mistakes:unknown":["unknown"]}'
  record_review "$case_dir" "$HEAD1" PASS gemini-3-pro "$authors" >/dev/null || fail 'record pre-FAIL second-family PASS'
  record_review "$case_dir" "$HEAD1" FAIL deepseek-v3 "$authors" >/dev/null || fail 'record FAIL'
  record_review "$case_dir" "$HEAD1" PASS sonnet "$authors" >/dev/null || fail 'record later independent PASS'
  out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
    --head "$HEAD1" --task task-x1 --base "$BASE" --json) || rc=$?
  expect_code 0 "$rc" "later qualifying read clears FAIL under the same coverage rule: $out"
  "$JQ_BIN" -e '.facts == ["pipeline author family not recorded"]' <<<"$out" >/dev/null \
    || fail "relief that clears the FAIL must disclose the fact despite a pre-FAIL second family: $out"
  out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
    --head "$HEAD1" --task task-x1 --base "$BASE") || fail "text verify after FAIL: $out"
  assert_contains "$out" 'pipeline author family not recorded' 'after-FAIL relief discloses the fact in text'
  pass 'a later outside-ship-family pipeline read clears an exact-head FAIL and discloses the relief'
}

test_unknown_pipeline_relief_after_captain_word() {
  local case_dir out rc=0 authors
  case_dir=$(make_case pipeline-word-fail)
  printf 'mode=no-mistakes\n' >> "$case_dir/home/state/task-x1.meta"
  authors='{"ship":["gpt-5.1"],"no-mistakes:unknown":["unknown"]}'
  record_word "$case_dir" "$HEAD1" 'Merge this PR.' >/dev/null || fail 'record captain word'
  record_review "$case_dir" "$HEAD1" FAIL deepseek-v3 "$authors" >/dev/null || fail 'record FAIL after word'
  record_review "$case_dir" "$HEAD1" PASS sonnet "$authors" >/dev/null || fail 'record sole outside-ship PASS'
  out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
    --head "$HEAD1" --task task-x1 --base "$BASE" --json) || rc=$?
  expect_code 0 "$rc" "relief clears the FAIL after the captain-word: $out"
  "$JQ_BIN" -e '.basis == "captain-word" and .facts == ["pipeline author family not recorded"]' <<<"$out" >/dev/null \
    || fail "captain-word accepted through relief must disclose the fact in JSON: $out"
  out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
    --head "$HEAD1" --task task-x1 --base "$BASE") || fail "text verify after word and FAIL: $out"
  assert_equals $'review: captain-word\nreview: pipeline author family not recorded' "$out" \
    'captain-word accepted through relief discloses the fact in text'
  pass 'relief that clears a FAIL after a captain-word discloses the fact'
}

test_native_claude_aliases_are_anthropic() {
  local case_dir out rc=0 alias
  for alias in opus sonnet haiku; do
    case_dir=$(make_case "alias-$alias")
    record_review "$case_dir" "$HEAD1" PASS "$alias" '{"all":["gpt-5.1"]}' >/dev/null \
      || fail "record $alias reader"
    out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
    expect_code 0 "$rc" "bare $alias reader must be independent: $out"
    # shellcheck disable=SC2016  # jq program; single quotes are intended.
    "$JQ_BIN" -e --arg alias "$alias" '.ok == true and .reader_model == $alias and .reader_family == "anthropic"' \
      <<<"$out" >/dev/null || fail "bare $alias must map to anthropic: $out"
    rc=0
  done
  case_dir=$(make_case alias-same-family claude-opus-4)
  record_review "$case_dir" "$HEAD1" PASS haiku '{"all":["claude-opus-4"]}' >/dev/null || fail "record alias same-family"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "bare Claude aliases share the anthropic family"
  expect_not_qualified "$out" "uncovered commit group ship, family anthropic" "bare alias vs claude id"
  case_dir=$(make_case alias-same-family-bare opus)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["opus"]}' >/dev/null || fail "record bare alias same-family"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "two bare Claude aliases share anthropic"
  expect_not_qualified "$out" "uncovered commit group ship, family anthropic" "bare alias vs bare alias"
  case_dir=$(make_case alias-provider-qualified openai/gpt-5.1)
  record_review "$case_dir" "$HEAD1" PASS anthropic/claude-sonnet-4 '{"all":["openai/gpt-5.1"]}' >/dev/null \
    || fail "record provider-qualified PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 0 "$rc" "provider-qualified ids must stay supported: $out"
  "$JQ_BIN" -e '.reader_family == "anthropic" and .author_groups.all[0].family == "openai"' <<<"$out" >/dev/null \
    || fail "provider-qualified families must derive from the model id: $out"
  pass "bare opus, sonnet and haiku ids map to anthropic while unknown ids stay untrusted"
}

test_stored_family_fields_cannot_retroactively_change_independence() {
  local case_dir out ledger
  case_dir=$(make_case mutable-metadata claude-opus-4)
  record_review "$case_dir" "$HEAD1" PASS gpt-5.1 '{"all":["claude-opus-4"]}' >/dev/null \
    || fail "record cross-family PASS"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || fail "cross-family PASS must verify: $out"
  "$JQ_BIN" -e '.reader_family == "openai" and .author_groups.all[0].family == "anthropic"' <<<"$out" >/dev/null \
    || fail "families must derive from the recorded model ids: $out"
  ledger="$case_dir/home/state/review-records.jsonl"
  "$JQ_BIN" -c 'if .kind == "review" then
      .reader_family = "anthropic"
      | .author_groups |= with_entries(.value |= map(.family = "unknown"))
    else . end' "$ledger" > "$ledger.tmp" || fail "could not rewrite stored families"
  mv "$ledger.tmp" "$ledger"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) \
    || fail "stale stored family metadata must not decide independence: $out"
  "$JQ_BIN" -e '.ok == true and .reader_family == "openai" and .author_groups.all[0].family == "anthropic"' \
    <<<"$out" >/dev/null || fail "verification must re-derive families from model ids: $out"
  pass "stored family fields cannot retroactively change recorded independence"
}

test_typed_failures_distinguish_unavailable_and_invalid_input() {
  local case_dir out rc=0
  case_dir=$(make_case corrupt-history)
  mkdir -p "$case_dir/home/state"
  printf '{"schema":"fm-review-record.v1"\n' > "$case_dir/home/state/review-records.jsonl"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "corrupt history is unavailable"
  "$JQ_BIN" -e '.schema == "fm-review-verification.v1" and .ok == false
    and .error.kind == "unavailable" and (.error.message | length) > 0
    and (has("basis") | not)' <<<"$out" >/dev/null \
    || fail "corrupt history must produce a typed unavailable envelope: $out"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1") || rc=$?
  expect_code 1 "$rc" "default text on corrupt history keeps exit 1"
  assert_contains "$out" "error: review record history is invalid" "default corrupt-history text stays actionable"
  case_dir=$(make_case missing-author-evidence)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  rm "$case_dir/home/state/task-x1.meta"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "unreadable author evidence is unavailable"
  "$JQ_BIN" -e '.ok == false and .error.kind == "unavailable"
    and (.error.message | contains("task metadata"))' <<<"$out" >/dev/null \
    || fail "unreadable task metadata must produce a typed unavailable envelope: $out"
  case_dir=$(make_case invalid-input)
  rc=0
  out=$(FM_HOME="$case_dir/home" "$RECORD" verify --pr nonsense --head "$HEAD1" \
    --task task-x1 --base "$BASE" --review-only --json) || rc=$?
  expect_code 2 "$rc" "an unparseable PR is invalid input"
  "$JQ_BIN" -e '.schema == "fm-review-verification.v1" and .ok == false
    and .error.kind == "invalid-input" and (.error.message | contains("pr"))' <<<"$out" >/dev/null \
    || fail "bad caller input must produce a typed invalid-input envelope: $out"
  pass "not-qualified, unavailable and invalid-input failures stay distinguishable without parsing prose"
}

test_default_fail_after_captain_word_precedence_holds() {
  local case_dir out rc=0
  case_dir=$(make_case fail-after-word)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  record_review "$case_dir" "$HEAD1" FAIL sonnet '{"all":["gpt-5.1"]}' >/dev/null || fail "record FAIL"
  record_word "$case_dir" "$HEAD1" 'Merge after the failure.' >/dev/null || fail "record captain word"
  out=$(run_verify "$case_dir" "$HEAD1") || rc=$?
  expect_code 0 "$rc" "a captain-word after the FAIL must still verify"
  assert_equals "review: captain-word" "$out" "captain-word after FAIL keeps its text"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "review-only must refuse the newest FAIL despite the word"
  expect_not_qualified "$out" "verdict is FAIL" "FAIL behind captain-word"
  record_review "$case_dir" "$HEAD1" FAIL sonnet '{"all":["gpt-5.1"]}' >/dev/null || fail "record later FAIL"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1") || rc=$?
  expect_code 1 "$rc" "a FAIL appended after the captain-word must re-refuse default verification"
  assert_contains "$out" "error: verdict is FAIL at live head $HEAD1" "later FAIL must refuse the captain-word"
  pass "default captain-word/FAIL precedence holds"
}

test_legacy_record_without_report_digest_omits_the_field() {
  local case_dir out ledger
  case_dir=$(make_case legacy-no-digest)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  ledger="$case_dir/home/state/review-records.jsonl"
  "$JQ_BIN" -c 'if .kind == "review" then del(.report_sha256) else . end' "$ledger" > "$ledger.tmp" \
    || fail "could not strip the legacy digest"
  mv "$ledger.tmp" "$ledger"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || fail "a legacy record must verify: $out"
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --arg report "$case_dir/report.md" '.ok == true and .basis == "independent-review"
    and (has("report_sha256") | not) and .report == $report' <<<"$out" >/dev/null \
    || fail "a legacy record without report_sha256 must omit the field instead of fabricating it: $out"
  pass "a legacy record without report_sha256 omits the digest instead of fabricating it"
}

test_plan_names_the_owed_families_and_decides_nothing() {
  local case_dir out
  case_dir=$(make_case plan-owed gpt-5.1)
  run_plan() {
    NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$RECORD" plan --pr "$URL" --head "$HEAD1" \
      --task task-x1 --base "$BASE" "$@"
  }
  out=$(run_plan)
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --arg head "$HEAD1" '.schema == "fm-review-plan.v1" and .ok == true and .head == $head
    and .groups.ship == [{"model":"gpt-5.1","family":"openai"}]
    and .uncovered == [{"group":"ship","families":["openai"]}]' <<<"$out" >/dev/null \
    || fail "plan with no review must name the ship group and the openai family it owes: $out"
  [ ! -e "$case_dir/home/state/review-records.jsonl" ] || fail "plan wrote a review record"
  record_review "$case_dir" "$HEAD1" PASS gpt-5.2 '{"ship":["gpt-5.1"]}' >/dev/null
  out=$(run_plan)
  "$JQ_BIN" -e '.uncovered == [{"group":"ship","families":["openai"]}]' <<<"$out" >/dev/null \
    || fail "a reader of the author's own family must leave the family owed: $out"
  record_review "$case_dir" "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' >/dev/null
  out=$(run_plan)
  "$JQ_BIN" -e '.uncovered == []' <<<"$out" >/dev/null || fail "a different-family PASS must clear the owed family: $out"
  record_review "$case_dir" "$HEAD1" FAIL claude-opus-5-5 '{"ship":["gpt-5.1"]}' >/dev/null
  record_word "$case_dir" "$HEAD1" 'merge it' >/dev/null
  out=$(run_plan)
  "$JQ_BIN" -e '.ok == true and .uncovered == []' <<<"$out" >/dev/null \
    || fail "plan must ignore a FAIL and a captain-word and report coverage only: $out"
  out=$(run_verify "$case_dir" "$HEAD1" --json)
  "$JQ_BIN" -e '.ok == true and .basis == "captain-word"' <<<"$out" >/dev/null \
    || fail "verify itself must still follow the captain-word rule: $out"
  out=$(run_plan --nonsense 2>&1 || true)
  case "$out" in *usage*|*unrecognized*) ;; *) fail "plan must reject an unknown flag: $out" ;; esac
  pass "plan names the owed author families from the exact head, ignores a FAIL and a captain-word, and writes nothing"
}

test_plan_agrees_with_verify_for_an_unrecorded_pipeline_family() {
  local case_dir out rc=0
  case_dir=$(make_case plan-pipeline-relief)
  printf 'mode=no-mistakes\n' >> "$case_dir/home/state/task-x1.meta"
  run_plan() {
    NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" plan --pr "$URL" --head "$HEAD1" \
      --task task-x1 --base "$BASE" "$@"
  }
  out=$(run_plan)
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e '.ok == true and (.groups | has("no-mistakes:unknown"))
    and ([.uncovered[] | select(.group == "no-mistakes:unknown") | .families] == [["unknown"]])
    and ([.uncovered[] | select(.group == "ship") | .families] == [["openai"]])
    and ([.uncovered[] | select(.group == "no-mistakes:unknown") | .reader_outside] == [["openai"]])
    and ([.uncovered[] | select(.group == "ship") | has("reader_outside")] == [false])' <<<"$out" >/dev/null \
    || fail "plan with no read must owe the unrecorded pipeline family and the ship family, and ask for a reader outside every ship family: $out"
  # A reader of the ship family covers neither group: plan and verify must both refuse to call it covered.
  record_review "$case_dir" "$HEAD1" PASS gpt-5.2 \
    '{"ship":["gpt-5.1"],"no-mistakes:unknown":["unknown"]}' >/dev/null || fail "record same-family read"
  out=$(run_plan)
  "$JQ_BIN" -e '([.uncovered[].group] | sort == ["no-mistakes:unknown","ship"])
    and ([.uncovered[] | select(.group == "no-mistakes:unknown") | .reader_outside] == [["openai"]])' <<<"$out" >/dev/null \
    || fail "a reader of the ship family must leave both groups owed in plan, the pipeline group still needing a reader outside it: $out"
  out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
    --head "$HEAD1" --task task-x1 --base "$BASE" --json) || rc=$?
  expect_code 1 "$rc" "verify must refuse the same state plan calls owed: $out"
  # A fresh case with one read outside every ship family: the relief covers the unrecorded pipeline family
  # in plan and in verify. (The case above must not be reused: its same-family read would count as a second
  # known family and so leave verify nothing to disclose.)
  case_dir=$(make_case plan-pipeline-relief-one-reader)
  printf 'mode=no-mistakes\n' >> "$case_dir/home/state/task-x1.meta"
  record_review "$case_dir" "$HEAD1" PASS sonnet \
    '{"ship":["gpt-5.1"],"no-mistakes:unknown":["unknown"]}' >/dev/null || fail "record outside-family read"
  out=$(run_plan)
  "$JQ_BIN" -e '.ok == true and .uncovered == []' <<<"$out" >/dev/null \
    || fail "plan must apply the one-reader relief that verify applies: $out"
  rc=0
  out=$(NM_HOME="$case_dir/absent-nm" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" \
    --head "$HEAD1" --task task-x1 --base "$BASE" --json) || rc=$?
  expect_code 0 "$rc" "verify must accept the state plan calls covered: $out"
  "$JQ_BIN" -e '.facts == ["pipeline author family not recorded"]' <<<"$out" >/dev/null \
    || fail "verify keeps its disclosure of the unrecorded pipeline family: $out"
  # An unknown ship author keeps the two-reader rule: plan asks for any known reader, then one outside the first.
  case_dir=$(make_case plan-unknown-two-readers mystery-9)
  run_plan() {
    NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$RECORD" plan --pr "$URL" --head "$HEAD1" \
      --task task-x1 --base "$BASE" "$@"
  }
  out=$(run_plan)
  "$JQ_BIN" -e '.uncovered == [{"group":"ship","families":["unknown"],"reader_outside":[]}]' <<<"$out" >/dev/null \
    || fail "plan must let any known reader count first toward an unknown ship author: $out"
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"ship":["mystery-9"]}' >/dev/null || fail "record first-family read"
  out=$(run_plan)
  "$JQ_BIN" -e '.uncovered == [{"group":"ship","families":["unknown"],"reader_outside":["anthropic"]}]' <<<"$out" >/dev/null \
    || fail "plan must ask for a second known family outside the first: $out"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "verify must refuse the one-family state plan calls owed: $out"
  record_review "$case_dir" "$HEAD1" PASS gpt-5.1 '{"ship":["mystery-9"]}' >/dev/null || fail "record second-family read"
  out=$(run_plan)
  "$JQ_BIN" -e '.uncovered == []' <<<"$out" >/dev/null || fail "two known reader families must leave nothing owed: $out"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 0 "$rc" "verify must accept the state plan calls covered: $out"
  pass "plan applies the one-reader relief for an unrecorded pipeline family and the two-reader rule for any other unknown group exactly as verify does, names the families a reader must lie outside, and verify keeps its disclosure"
}

# Review carry-over fixtures: branch pr adds app.txt from BASE (the reviewed
# head); trunk moves the base by adding other.txt. Each case builds its live
# head from those two, so every outcome is decided by the live head's content.
cgit() {  # <case_dir> <git args...>
  local case_dir=$1
  shift
  git -C "$case_dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' "$@"
}

make_carry_case() {  # <name>; prints the case dir
  local case_dir
  case_dir=$(make_case "$1")
  cgit "$case_dir" checkout -q -b pr "$BASE"
  printf 'one\ntwo\nthree\n' > "$case_dir/wt/app.txt"
  cgit "$case_dir" add app.txt
  cgit "$case_dir" commit -qm 'ship change'
  cgit "$case_dir" checkout -q -b trunk "$BASE"
  printf 'other\n' > "$case_dir/wt/other.txt"
  cgit "$case_dir" add other.txt
  cgit "$case_dir" commit -qm 'base moves'
  printf '%s\n' "$case_dir"
}

carry_refs() {  # <case_dir>: sets REVIEWED and TRUNK
  REVIEWED=$(cgit "$1" rev-parse pr)
  TRUNK=$(cgit "$1" rev-parse trunk)
}

merge_trunk_into_pr() {  # <case_dir>; prints the merge head
  cgit "$1" checkout -q pr
  cgit "$1" merge -q --no-edit trunk
  cgit "$1" rev-parse HEAD
}

unread_merge_into_pr() {  # <case_dir>; prints a merge head that hides one unread line
  cgit "$1" checkout -q pr
  cgit "$1" merge -q --no-commit --no-ff trunk >/dev/null 2>&1
  printf 'unread\n' >> "$1/wt/app.txt"
  cgit "$1" add app.txt
  cgit "$1" commit -qm "Merge branch 'trunk' into pr"
  cgit "$1" rev-parse HEAD
}

verify_on() {  # <case_dir> <head> <base> [flags...]
  verify_with "$RECORD" -- "$@"
}

verify_with() {  # <record script> [env-args... --] <case_dir> <head> <base> [flags...]
  # env-args go to env(1) for this call only, for example -u NAME or NAME=value.
  local script=$1 case_dir head base
  local -a envs=()
  shift
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  case_dir=$1 head=$2 base=$3
  shift 3
  env ${envs[@]+"${envs[@]}"} NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$script" verify --pr "$URL" --head "$head" \
    --task task-x1 --base "$base" "$@"
}

test_carry_over_accepts_a_clean_merge_of_the_base() {
  local case_dir live later out rc=0
  case_dir=$(make_carry_case carry-merge)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS at the reviewed head"
  live=$(merge_trunk_into_pr "$case_dir")
  # The base keeps moving after the update; the proof uses the base content the live head holds.
  cgit "$case_dir" checkout -q trunk
  printf 'later\n' > "$case_dir/wt/later.txt"
  cgit "$case_dir" add later.txt
  cgit "$case_dir" commit -qm 'base moves again'
  later=$(cgit "$case_dir" rev-parse HEAD)
  out=$(verify_on "$case_dir" "$live" "$later" --json) || rc=$?
  expect_code 0 "$rc" "a clean merge of the base must carry the PASS: $out"
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --arg live "$live" --arg reviewed "$REVIEWED" '
    .ok == true and .basis == "independent-review" and .head == $live
    and .carried_from == $reviewed and .reader_model == "sonnet"
    and (.facts | any(startswith("review carried from " + $reviewed)))' <<<"$out" >/dev/null \
    || fail "carried JSON must name the live head, the reviewed head and the fact: $out"
  rc=0
  out=$(verify_on "$case_dir" "$live" "$later") || rc=$?
  expect_code 0 "$rc" "text verify must accept the carry-over: $out"
  case "$out" in "review: PASS"*) ;; *) fail "text verify keeps review: PASS first: $out" ;; esac
  case "$out" in *"review: review carried from $REVIEWED"*) ;; *) fail "text verify discloses the carry-over: $out" ;; esac
  rc=0
  out=$(verify_on "$case_dir" "$live" "$later" --review-only) || rc=$?
  expect_code 0 "$rc" "--review-only accepts a carried independent PASS: $out"
  pass "a PASS carries to a head that is exactly the reviewed change merged with base content, and says so"
}

test_carry_over_accepts_a_clean_rebase() {
  local case_dir live out rc=0
  case_dir=$(make_carry_case carry-rebase)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  cgit "$case_dir" checkout -q -b rebased "$REVIEWED"
  cgit "$case_dir" rebase -q trunk
  live=$(cgit "$case_dir" rev-parse HEAD)
  out=$(verify_on "$case_dir" "$live" "$TRUNK") || rc=$?
  expect_code 0 "$rc" "a clean rebase onto the base must carry the PASS: $out"
  pass "a PASS carries across a clean rebase onto the base"
}

test_carry_over_refuses_an_unread_change() {
  local case_dir live out rc=0
  case_dir=$(make_carry_case carry-unread)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  # An edit hidden inside the update merge itself, where an unread line most easily hides.
  live=$(unread_merge_into_pr "$case_dir")
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "an unread line in the update merge must refuse: $out"
  expect_not_qualified "$out" "holds changes no PASS read" "unread change"
  expect_not_qualified "$out" "head mismatch" "unread change keeps the head-mismatch refusal"
  pass "an update that adds any unread line keeps the exact-head refusal"
}

test_carry_over_refusal_comes_from_the_tree_proof() {
  # Sensitivity control: a disposable copy with only the tree comparison
  # forced equal must accept the same unread change, so the refusal above is
  # the tree proof's and not a setup or coverage failure.
  local case_dir live copy out rc=0
  case_dir=$(make_carry_case carry-unread-control)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  live=$(unread_merge_into_pr "$case_dir")
  copy="$TMP_ROOT/unguarded-bin"
  cp -R "$ROOT/bin" "$copy"
  python3 - "$copy/fm-review-record.py" <<'PY' || fail "plant the fault"
import sys
path = sys.argv[1]
text = open(path).read()
needle = 'if lines[0] != live.stdout.strip():'
assert text.count(needle) == 1, "tree comparison line not found exactly once"
open(path, "w").write(text.replace(needle, "if False:"))
PY
  out=$(NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$copy/fm-review-record.py" verify --pr "$URL" \
    --head "$live" --task task-x1 --base "$TRUNK") || rc=$?
  expect_code 0 "$rc" "with the tree comparison removed the unread change must be accepted: $out"
  pass "removing only the tree comparison lets the unread change through, so the refusal is the tree proof's"
}

test_carry_over_refuses_a_conflict_resolution() {
  local case_dir live out rc=0
  case_dir=$(make_carry_case carry-conflict)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  cgit "$case_dir" checkout -q trunk
  printf 'base version\n' > "$case_dir/wt/app.txt"
  cgit "$case_dir" add app.txt
  cgit "$case_dir" commit -qm 'base edits the same file'
  TRUNK=$(cgit "$case_dir" rev-parse HEAD)
  cgit "$case_dir" checkout -q pr
  cgit "$case_dir" merge -q --no-edit trunk >/dev/null 2>&1 || true
  # Resolve by keeping the reviewed side exactly; a hand resolution still needs a read.
  printf 'one\ntwo\nthree\n' > "$case_dir/wt/app.txt"
  cgit "$case_dir" add app.txt
  cgit "$case_dir" commit -qm "Merge branch 'trunk' into pr"
  live=$(cgit "$case_dir" rev-parse HEAD)
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "a conflict resolution must refuse: $out"
  expect_not_qualified "$out" "does not merge cleanly" "conflict resolution"
  pass "a conflicted update needs a fresh read even when the resolution keeps the reviewed side"
}

test_carry_over_never_carries_a_captain_word() {
  local case_dir live out rc=0
  case_dir=$(make_carry_case carry-word)
  carry_refs "$case_dir"
  record_word "$case_dir" "$REVIEWED" 'Merge PR 9.' >/dev/null || fail "record captain-word at the reviewed head"
  live=$(merge_trunk_into_pr "$case_dir")
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "a captain-word at an older head must not carry: $out"
  expect_not_qualified "$out" "review record is missing" "captain-word carry"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  rc=0
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 0 "$rc" "the PASS carries while the older captain-word stays out: $out"
  "$JQ_BIN" -e '.basis == "independent-review"' <<<"$out" >/dev/null || fail "basis must be the review, not the word: $out"
  pass "a captain-word never carries to a new head; only recorded reads do"
}

test_carry_over_keeps_a_standing_fail() {
  local case_dir live out rc=0
  case_dir=$(make_carry_case carry-fail)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  record_review "$case_dir" "$REVIEWED" FAIL gemini-3-pro '{"ship":["gpt-5.1"]}' >/dev/null || fail "record FAIL"
  live=$(merge_trunk_into_pr "$case_dir")
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "a FAIL standing at the reviewed head must not carry as a PASS: $out"
  expect_not_qualified "$out" "do not qualify: verdict is FAIL at $REVIEWED" "standing FAIL"
  pass "a FAIL standing at the reviewed head stands at the live head too"
}

test_carry_over_never_overrides_a_read_of_the_live_head() {
  local case_dir live out rc=0
  case_dir=$(make_carry_case carry-live-read)
  carry_refs "$case_dir"
  live=$(merge_trunk_into_pr "$case_dir")
  record_review "$case_dir" "$live" FAIL gemini-3-pro '{"ship":["gpt-5.1"]}' >/dev/null || fail "record FAIL at the live head"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record a later PASS of the older head"
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "a read of the live head must not be bypassed by an older head's PASS: $out"
  expect_not_qualified "$out" "head mismatch" "live head read"
  case "$out" in *"no carry-over"*) fail "a read of the live head must stop carry-over before the proof: $out" ;; esac
  pass "any read of the live head turns carry-over off"
}

test_carry_over_refuses_a_missing_reviewed_object() {
  local case_dir live out rc=0
  case_dir=$(make_carry_case carry-missing)
  carry_refs "$case_dir"
  record_review "$case_dir" "$HEAD2" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS of an absent head"
  live=$(merge_trunk_into_pr "$case_dir")
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "an absent reviewed head must refuse: $out"
  expect_not_qualified "$out" "is not available in the task worktree" "absent reviewed head"
  pass "a reviewed head that is not available locally cannot carry"
}

test_carry_over_refuses_a_branch_that_is_not_on_the_base() {
  local case_dir live out rc=0
  case_dir=$(make_carry_case carry-side-branch)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  # A side branch that never reached the base: a clean merge of it is still unread content.
  cgit "$case_dir" checkout -q -b side "$BASE"
  printf 'side\n' > "$case_dir/wt/side.txt"
  cgit "$case_dir" add side.txt
  cgit "$case_dir" commit -qm 'side work'
  live=$(merge_trunk_into_pr "$case_dir")
  cgit "$case_dir" merge -q --no-edit side
  live=$(cgit "$case_dir" rev-parse HEAD)
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "a merged branch that is not on the base must refuse: $out"
  expect_not_qualified "$out" "holds changes no PASS read" "side branch"
  pass "a clean merge of a branch that is not on the base is unread content and refuses"
}

test_carry_over_accepts_a_same_tree_rewrite() {
  local case_dir live out rc=0
  case_dir=$(make_carry_case carry-rewrite)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  # Only the commit message changes: the content every read saw is unchanged, so the PASS stands.
  cgit "$case_dir" checkout -q -b reworded "$REVIEWED"
  cgit "$case_dir" commit -q --amend -m 'ship change, reworded'
  live=$(cgit "$case_dir" rev-parse HEAD)
  out=$(verify_on "$case_dir" "$live" "$BASE") || rc=$?
  expect_code 0 "$rc" "a same-tree rewrite must carry the PASS: $out"
  pass "a rewrite that keeps the reviewed tree, such as an amended message, carries the PASS"
}

test_carry_over_refuses_after_a_later_head_was_read() {
  local case_dir r2 live out rc=0
  case_dir=$(make_carry_case carry-later-fail)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS at R"
  r2=$(merge_trunk_into_pr "$case_dir")
  record_review "$case_dir" "$r2" FAIL gemini-3-pro '{"ship":["gpt-5.1"]}' >/dev/null || fail "record FAIL at R2"
  # A late PASS of R is appended after the FAIL, so R is again the newest review.
  record_review "$case_dir" "$REVIEWED" PASS gemini-3-pro '{"ship":["gpt-5.1"]}' >/dev/null || fail "record late PASS at R"
  cgit "$case_dir" checkout -q trunk
  printf 'more\n' > "$case_dir/wt/more.txt"
  cgit "$case_dir" add more.txt
  cgit "$case_dir" commit -qm 'base moves again'
  TRUNK=$(cgit "$case_dir" rev-parse HEAD)
  live=$(merge_trunk_into_pr "$case_dir")
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "a FAIL at a later head must not be skipped by a late PASS of an earlier head: $out"
  expect_not_qualified "$out" "head mismatch" "later head read"
  pass "a read of any later head turns carry-over off, so row order cannot skip a FAIL"
}

test_carry_over_refuses_after_a_fail_recorded_before_the_pass() {
  # GLM-5.4 review finding 1: a FAIL at a clean update H1 recorded BEFORE R's
  # first PASS, then a later clean update H2 (or a same-tree reword of H1).
  local variant case_dir h1 live out rc
  for variant in update reword; do
    case_dir=$(make_carry_case "carry-fail-first-$variant")
    carry_refs "$case_dir"
    h1=$(merge_trunk_into_pr "$case_dir")
    record_review "$case_dir" "$h1" FAIL gemini-3-pro '{"ship":["gpt-5.1"]}' >/dev/null || fail "record FAIL at H1"
    record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS at R"
    if [ "$variant" = update ]; then
      cgit "$case_dir" checkout -q trunk
      printf 'more\n' > "$case_dir/wt/more.txt"
      cgit "$case_dir" add more.txt
      cgit "$case_dir" commit -qm 'base moves again'
      TRUNK=$(cgit "$case_dir" rev-parse HEAD)
      live=$(merge_trunk_into_pr "$case_dir")
    else
      cgit "$case_dir" checkout -q pr
      cgit "$case_dir" commit -q --amend -m 'reworded update merge'
      live=$(cgit "$case_dir" rev-parse HEAD)
    fi
    rc=0
    out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
    expect_code 1 "$rc" "$variant: a FAIL recorded before R's PASS must not be skipped: $out"
    expect_not_qualified "$out" "head mismatch" "$variant: FAIL before PASS"
    rc=0
    out=$(verify_on "$case_dir" "$live" "$TRUNK" --review-only --json) || rc=$?
    expect_code 1 "$rc" "$variant: --review-only must refuse too: $out"
  done
  pass "a read of any head that is not an ancestor of R turns carry-over off, whatever the row order"
}

test_carry_over_allows_reads_of_heads_r_was_built_on() {
  # The legitimate path: a FAIL at an earlier head, fixed by commits on top
  # (R descends from it), PASS at R, then a clean base update.
  local case_dir h0 live out rc=0
  case_dir=$(make_carry_case carry-fail-then-fix)
  cgit "$case_dir" checkout -q pr
  h0=$(cgit "$case_dir" rev-parse HEAD)
  record_review "$case_dir" "$h0" FAIL gemini-3-pro '{"ship":["gpt-5.1"]}' >/dev/null || fail "record FAIL at H0"
  printf 'fixed\n' >> "$case_dir/wt/app.txt"
  cgit "$case_dir" commit -qam 'fix the FAIL'
  REVIEWED=$(cgit "$case_dir" rev-parse HEAD)
  TRUNK=$(cgit "$case_dir" rev-parse trunk)
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS at R"
  live=$(merge_trunk_into_pr "$case_dir")
  out=$(verify_on "$case_dir" "$live" "$TRUNK") || rc=$?
  expect_code 0 "$rc" "a FAIL at a head R was built on must not block carrying R's PASS: $out"
  pass "reads of earlier heads that R builds on leave carry-over available"
}

test_carry_over_writes_nothing_to_the_task_object_store() {
  # GLM-5.4 finding 4 and DeepSeek finding 1: a refusing proof builds a tree the
  # store lacks (a conflict tree here), so the scratch store is what keeps the
  # task's object store unchanged. A disposable copy without the override must
  # change the store, so this case can see the behavior it names.
  local case_dir live base before after out rc copy
  case_dir=$(make_carry_case carry-readonly)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  cgit "$case_dir" checkout -q trunk
  printf 'base version\n' > "$case_dir/wt/app.txt"
  cgit "$case_dir" add app.txt
  cgit "$case_dir" commit -qm 'base edits the same file'
  base=$(cgit "$case_dir" rev-parse HEAD)
  cgit "$case_dir" checkout -q pr
  cgit "$case_dir" merge -q --no-edit trunk >/dev/null 2>&1 || true
  printf 'one\ntwo\nthree\n' > "$case_dir/wt/app.txt"
  cgit "$case_dir" add app.txt
  cgit "$case_dir" commit -qm "Merge branch 'trunk' into pr"
  live=$(cgit "$case_dir" rev-parse HEAD)
  before=$(find "$case_dir/wt/.git/objects" -type f | sort | shasum | cut -c1-40)
  rc=0
  out=$(verify_on "$case_dir" "$live" "$base" --json) || rc=$?
  after=$(find "$case_dir/wt/.git/objects" -type f | sort | shasum | cut -c1-40)
  expect_code 1 "$rc" "the conflicted update must refuse: $out"
  expect_not_qualified "$out" "does not merge cleanly" "conflicted update"
  assert_equals "$before" "$after" "a refusing proof must not add objects to the task worktree's store"
  copy="$TMP_ROOT/no-scratch-bin"
  cp -R "$ROOT/bin" "$copy"
  python3 - "$copy/fm-review-record.py" <<'PY2' || fail "plant the fault"
import sys
path = sys.argv[1]
text = open(path).read()
needle = 'merged = isolated_merge_tree(scratch, objects.stdout.strip(), object_format.stdout.strip(), point.stdout.strip(), reviewed)'
assert text.count(needle) == 1, "isolated merge call not found exactly once"
open(path, "w").write(text.replace(needle, 'merged = run("merge-tree", "--write-tree", "--no-messages", point.stdout.strip(), reviewed)'))
PY2
  NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$copy/fm-review-record.py" verify --pr "$URL" \
    --head "$live" --task task-x1 --base "$base" >/dev/null 2>&1 || true
  after=$(find "$case_dir/wt/.git/objects" -type f | sort | shasum | cut -c1-40)
  [ "$before" != "$after" ] || fail "control: without the scratch store the refusing proof must write to the task store, or this case observes nothing"
  pass "the carry-over proof writes its merged trees to a scratch repository, and running it in the worktree makes the store change"
}

test_carry_over_ignores_grafts() {
  # DeepSeek finding 2: a graft can make a FAILed later head look like an ancestor of R.
  local case_dir h1 live out rc=0
  case_dir=$(make_carry_case carry-graft)
  carry_refs "$case_dir"
  h1=$(merge_trunk_into_pr "$case_dir")
  record_review "$case_dir" "$h1" FAIL gemini-3-pro '{"ship":["gpt-5.1"]}' >/dev/null || fail "record FAIL at H1"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS at R"
  mkdir -p "$case_dir/wt/.git/info"
  printf '%s %s %s\n' "$REVIEWED" "$BASE" "$h1" > "$case_dir/wt/.git/info/grafts"
  cgit "$case_dir" checkout -q trunk
  printf 'more\n' > "$case_dir/wt/more.txt"
  cgit "$case_dir" add more.txt
  cgit "$case_dir" commit -qm 'base moves again'
  TRUNK=$(cgit "$case_dir" rev-parse HEAD)
  live=$(merge_trunk_into_pr "$case_dir")
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "a graft must not make the FAILed head an ancestor of R: $out"
  expect_not_qualified "$out" "does not build on" "graft"
  pass "grafts are ignored by the carry-over proof, so they cannot fake ancestry"
}

test_carry_over_refuses_a_base_older_than_the_update() {
  # DeepSeek note: a --base older than the base content the live head merged
  # makes the trees differ, so it refuses rather than carries.
  local case_dir live out rc=0
  case_dir=$(make_carry_case carry-old-base)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  live=$(merge_trunk_into_pr "$case_dir")
  out=$(verify_on "$case_dir" "$live" "$BASE" --json) || rc=$?
  expect_code 1 "$rc" "a base older than the merged base content must refuse: $out"
  expect_not_qualified "$out" "holds changes no PASS read" "old base"
  pass "a base older than the base content the live head merged refuses"
}

test_carry_over_ignores_a_graft_that_fakes_base_content() {
  # DeepSeek round-2 finding 3: a graft on the base tip that makes an unread
  # side commit look like base content. A copy without the proof's graft
  # setting must accept it, so this case observes the harmful acceptance.
  local case_dir side live out rc=0 copy
  case_dir=$(make_carry_case carry-graft-base)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  cgit "$case_dir" checkout -q -b side "$BASE"
  printf 'unread side work\n' > "$case_dir/wt/side.txt"
  cgit "$case_dir" add side.txt
  cgit "$case_dir" commit -qm 'unread side work'
  side=$(cgit "$case_dir" rev-parse HEAD)
  cgit "$case_dir" checkout -q pr
  cgit "$case_dir" merge -q --no-edit side
  live=$(cgit "$case_dir" rev-parse HEAD)
  mkdir -p "$case_dir/wt/.git/info"
  printf '%s %s %s\n' "$TRUNK" "$BASE" "$side" > "$case_dir/wt/.git/info/grafts"
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "a graft must not turn unread side work into base content: $out"
  expect_not_qualified "$out" "holds changes no PASS read" "base graft"
  copy="$TMP_ROOT/graft-honoring-bin"
  cp -R "$ROOT/bin" "$copy"
  python3 - "$copy/fm-review-record.py" <<'PY2' || fail "plant the fault"
import sys
path = sys.argv[1]
text = open(path).read()
needle = '    env = {**os.environ, "GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": os.devnull}\n'
assert text.count(needle) == 1, "proof env line not found exactly once"
open(path, "w").write(text.replace(needle, '    env = {**os.environ, "GIT_NO_REPLACE_OBJECTS": "1"}\n'))
PY2
  rc=0
  out=$(NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$copy/fm-review-record.py" verify --pr "$URL" \
    --head "$live" --task task-x1 --base "$TRUNK" --json) || rc=$?
  expect_code 0 "$rc" "control: with grafts honored the side work must carry, or this case observes nothing: $out"
  pass "the proof ignores a graft that would pass unread side work off as base content"
}

plant_proof_in_worktree() {  # <copy_dir>: copy bin/ with the merge proof run in the task worktree
  cp -R "$ROOT/bin" "$1"
  python3 - "$1/fm-review-record.py" <<'PY2' || fail "plant the fault"
import sys
path = sys.argv[1]
text = open(path).read()
needle = 'merged = isolated_merge_tree(scratch, objects.stdout.strip(), object_format.stdout.strip(), point.stdout.strip(), reviewed)'
assert text.count(needle) == 1, "isolated merge call not found exactly once"
open(path, "w").write(text.replace(needle, 'merged = run("merge-tree", "--write-tree", "--no-messages", point.stdout.strip(), reviewed)'))
PY2
}

test_carry_over_ignores_a_merge_driver_in_the_task_worktree() {
  # GLM-5.4 round-3 findings 1 and 2: the PR author's worker can write the task
  # worktree's config and attributes. A merge driver there resolves a conflict
  # with bytes no reader saw; the proof must still see the conflict. A copy that
  # runs the proof in the worktree must carry, so this case observes the harm.
  local case_dir live out rc=0 copy
  case_dir=$(make_carry_case carry-driver)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  cgit "$case_dir" checkout -q trunk
  printf 'base version\n' > "$case_dir/wt/app.txt"
  cgit "$case_dir" add app.txt
  cgit "$case_dir" commit -qm 'base edits the same file'
  TRUNK=$(cgit "$case_dir" rev-parse HEAD)
  cgit "$case_dir" config merge.forge.driver "printf 'unread driver bytes\\n' > %A"
  printf 'app.txt merge=forge\n' > "$case_dir/wt/.gitattributes"
  cgit "$case_dir" checkout -q pr
  cgit "$case_dir" merge -q --no-edit trunk >/dev/null 2>&1 || fail "the driver must resolve the conflict"
  live=$(cgit "$case_dir" rev-parse HEAD)
  [ "$(cat "$case_dir/wt/app.txt")" = "unread driver bytes" ] || fail "fixture: the driver wrote the merged file"
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "a worktree merge driver must not hide a conflict resolution: $out"
  expect_not_qualified "$out" "does not merge cleanly" "worktree merge driver"
  copy="$TMP_ROOT/driver-honoring-bin"
  plant_proof_in_worktree "$copy"
  rc=0
  out=$(NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$copy/fm-review-record.py" verify --pr "$URL" \
    --head "$live" --task task-x1 --base "$TRUNK" --json) || rc=$?
  expect_code 0 "$rc" "control: a proof run in the worktree must honor the worktree config and root .gitattributes and carry: $out"
  # The same driver through the caller's environment and .git/info/attributes.
  cgit "$case_dir" config --unset merge.forge.driver
  rm "$case_dir/wt/.gitattributes"
  mkdir -p "$case_dir/wt/.git/info"
  printf 'app.txt merge=forge\n' > "$case_dir/wt/.git/info/attributes"
  rc=0
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=merge.forge.driver GIT_CONFIG_VALUE_0="printf 'unread driver bytes\\n' > %A" \
    verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "an environment merge driver must not hide a conflict resolution: $out"
  expect_not_qualified "$out" "does not merge cleanly" "environment merge driver"
  rc=0
  out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=merge.forge.driver GIT_CONFIG_VALUE_0="printf 'unread driver bytes\\n' > %A" \
    NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$copy/fm-review-record.py" verify --pr "$URL" \
    --head "$live" --task task-x1 --base "$TRUNK" --json) || rc=$?
  expect_code 0 "$rc" "control: a proof run in the worktree must honor the driver and carry, or this case observes nothing: $out"
  pass "the proof ignores merge drivers and attributes from the task worktree and the caller's environment"
}

test_carry_over_ignores_replace_refs() {
  # GLM-5.4 round-3 finding 4: a replace ref on the base tip that gives it the
  # unread side commit as a second parent. A copy without the proof's
  # replace-ref setting must accept it, so this case observes the harm.
  local case_dir side live out rc=0 copy
  case_dir=$(make_carry_case carry-replace-base)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  cgit "$case_dir" checkout -q -b side "$BASE"
  printf 'unread side work\n' > "$case_dir/wt/side.txt"
  cgit "$case_dir" add side.txt
  cgit "$case_dir" commit -qm 'unread side work'
  side=$(cgit "$case_dir" rev-parse HEAD)
  cgit "$case_dir" checkout -q pr
  cgit "$case_dir" merge -q --no-edit side
  live=$(cgit "$case_dir" rev-parse HEAD)
  cgit "$case_dir" replace --graft "$TRUNK" "$BASE" "$side" || fail "fixture: replace ref"
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  expect_code 1 "$rc" "a replace ref must not turn unread side work into base content: $out"
  expect_not_qualified "$out" "holds changes no PASS read" "base replace ref"
  copy="$TMP_ROOT/replace-honoring-bin"
  cp -R "$ROOT/bin" "$copy"
  python3 - "$copy/fm-review-record.py" <<'PY2' || fail "plant the fault"
import sys
path = sys.argv[1]
text = open(path).read()
needle = '    env = {**os.environ, "GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": os.devnull}\n'
assert text.count(needle) == 1, "proof env line not found exactly once"
open(path, "w").write(text.replace(needle, '    env = {**os.environ, "GIT_GRAFT_FILE": os.devnull}\n'))
PY2
  rc=0
  out=$(NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$copy/fm-review-record.py" verify --pr "$URL" \
    --head "$live" --task task-x1 --base "$TRUNK" --json) || rc=$?
  expect_code 0 "$rc" "control: with replace refs honored the side work must carry, or this case observes nothing: $out"
  pass "the proof ignores a replace ref that would pass unread side work off as base content"
}

conflicted_driver_case() {  # <name>; prints the case dir; sets TRUNK and LIVE to a driver-resolved update
  local case_dir
  case_dir=$(make_carry_case "$1")
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  cgit "$case_dir" checkout -q trunk
  printf 'base version\n' > "$case_dir/wt/app.txt"
  cgit "$case_dir" add app.txt
  cgit "$case_dir" commit -qm 'base edits the same file'
  cgit "$case_dir" checkout -q pr
  printf '%s\n' "$case_dir"
}

test_carry_over_ignores_global_config_and_global_attributes() {
  # DeepSeek round-4 finding 4: a merge driver and attribute mapping from the
  # caller's global configuration, at ~/.gitconfig with core.attributesFile and
  # at $XDG_CONFIG_HOME/git/config with git/attributes. Each location is
  # removed twice (GIT_CONFIG_GLOBAL or core.attributesFile, and the scratch
  # HOME and XDG_CONFIG_HOME), so no one-line removal flips the result; the
  # control runs the proof unisolated and must carry, so the fixture is real.
  # System configuration and system attributes are removed too, but a test
  # cannot plant those files, so they are not exercised here.
  local layout case_dir fake live out rc copy
  copy="$TMP_ROOT/global-honoring-bin"
  plant_proof_in_worktree "$copy"
  for layout in home xdg; do
    case_dir=$(conflicted_driver_case "carry-global-$layout")
    TRUNK=$(cgit "$case_dir" rev-parse trunk)
    fake="$case_dir/fake-home"
    mkdir -p "$fake/xdg/git"
    if [ "$layout" = home ]; then
      printf 'app.txt merge=forge\n' > "$fake/attrs"
      git config --file "$fake/.gitconfig" merge.forge.driver "printf 'unread driver bytes\\n' > %A"
      git config --file "$fake/.gitconfig" core.attributesFile "$fake/attrs"
    else
      printf 'app.txt merge=forge\n' > "$fake/xdg/git/attributes"
      git config --file "$fake/xdg/git/config" merge.forge.driver "printf 'unread driver bytes\\n' > %A"
    fi
    # The suite runs every case with GIT_CONFIG_GLOBAL=/dev/null; these calls
    # lift only that, so the planted files are the caller's real global config.
    env -u GIT_CONFIG_GLOBAL HOME="$fake" XDG_CONFIG_HOME="$fake/xdg" \
      git -C "$case_dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      merge -q --no-edit trunk >"$case_dir/merge.out" 2>&1 \
      || fail "$layout: the global driver must resolve the conflict: $(cat "$case_dir/merge.out")"
    live=$(cgit "$case_dir" rev-parse HEAD)
    [ "$(cat "$case_dir/wt/app.txt")" = "unread driver bytes" ] || fail "$layout fixture: the global driver wrote the merged file"
    rc=0
    out=$(verify_with "$RECORD" -u GIT_CONFIG_GLOBAL HOME="$fake" XDG_CONFIG_HOME="$fake/xdg" -- \
      "$case_dir" "$live" "$TRUNK" --json) || rc=$?
    expect_code 1 "$rc" "$layout: a global merge driver must not hide a conflict resolution: $out"
    expect_not_qualified "$out" "does not merge cleanly" "$layout global merge driver"
    rc=0
    out=$(verify_with "$copy/fm-review-record.py" -u GIT_CONFIG_GLOBAL HOME="$fake" XDG_CONFIG_HOME="$fake/xdg" -- \
      "$case_dir" "$live" "$TRUNK" --json) || rc=$?
    expect_code 0 "$rc" "$layout control: an unisolated proof must honor the global driver and carry: $out"
  done
  pass "the proof ignores merge drivers and attributes from the caller's global configuration in both locations"
}

test_carry_over_scratch_lives_beside_the_review_records() {
  # DeepSeek round-4 finding 5: the scratch repository is made in the state
  # directory that holds the review records, not the shared temporary
  # directory, and is gone afterwards. A git shim logs where git init runs.
  local case_dir live out rc=0 shim made
  case_dir=$(make_carry_case carry-scratch-place)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  live=$(merge_trunk_into_pr "$case_dir")
  shim="$case_dir/shim"
  mkdir -p "$shim"
  cat > "$shim/git" <<SH
#!/usr/bin/env bash
[ "\$1" != init ] || printf '%s\n' "\${@: -1}" >> "$case_dir/init.log"
exec $(command -v git) "\$@"
SH
  chmod +x "$shim/git"
  out=$(PATH="$shim:$PATH" TMPDIR="$case_dir/shared-tmp" verify_on "$case_dir" "$live" "$TRUNK") || rc=$?
  expect_code 0 "$rc" "the clean update must carry: $out"
  made=$(cat "$case_dir/init.log" 2>/dev/null || true)
  [ -n "$made" ] || fail "the proof ran no git init"
  case "$made" in
    "$case_dir/home/state/.review-carry-"*/proof.git) ;;
    *) fail "the scratch repository must be made in the state directory, not elsewhere: $made" ;;
  esac
  [ -z "$(find "$case_dir/home/state" -maxdepth 1 -name '.review-carry-*')" ] || fail "the scratch directory must be removed after the proof"
  pass "the proof's scratch repository is made beside the review records and removed afterwards"
}

test_carry_over_refuses_when_the_state_directory_takes_no_scratch() {
  # An unwritable state directory is a typed refusal with its reason, never a traceback.
  local case_dir live out rc=0
  [ "$(id -u)" != 0 ] || { printf 'skipped: running as root, a mode-500 directory is still writable\n'; return 0; }
  case_dir=$(make_carry_case carry-scratch-denied)
  carry_refs "$case_dir"
  record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS"
  live=$(merge_trunk_into_pr "$case_dir")
  chmod 500 "$case_dir/home/state"
  out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
  chmod 700 "$case_dir/home/state"
  expect_code 1 "$rc" "no scratch repository must refuse: $out"
  expect_not_qualified "$out" "cannot make the proof's scratch repository" "unwritable state directory"
  pass "a state directory that takes no scratch repository refuses carry-over with its reason"
}

test_carry_over_refuses_after_a_rewrite_was_itself_read() {
  # A same-tree rewrite carries from R, but once the rewrite has its own read,
  # the head it replaced is a reviewed head off the newest reviewed head's
  # ancestry, so a later base update refuses and needs a fresh read.
  # Both row orders: the rewrite read last, and a late read of R after it.
  # The unread order is the control: the same fixture with no read of the
  # rewrite must carry, so the extra read is what makes the others refuse.
  local order case_dir rewrite live out rc
  for order in unread rewrite-last original-last; do
    case_dir=$(make_carry_case "carry-rewrite-read-$order")
    carry_refs "$case_dir"
    record_review "$case_dir" "$REVIEWED" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null || fail "record PASS at R"
    cgit "$case_dir" checkout -q pr
    cgit "$case_dir" commit -q --amend -m 'ship change, reworded'
    rewrite=$(cgit "$case_dir" rev-parse HEAD)
    [ "$order" = unread ] || record_review "$case_dir" "$rewrite" PASS sonnet '{"ship":["gpt-5.1"]}' >/dev/null \
      || fail "record PASS at the rewrite"
    [ "$order" != original-last ] || record_review "$case_dir" "$REVIEWED" PASS gemini-3-pro '{"ship":["gpt-5.1"]}' >/dev/null \
      || fail "record a late PASS at R"
    live=$(merge_trunk_into_pr "$case_dir")
    rc=0
    out=$(verify_on "$case_dir" "$live" "$TRUNK" --json) || rc=$?
    if [ "$order" = unread ]; then
      expect_code 0 "$rc" "control: an update of a rewrite nobody read must carry from R: $out"
      continue
    fi
    expect_code 1 "$rc" "$order: an update of a rewrite that was itself read must refuse: $out"
    expect_not_qualified "$out" "which the reviewed head does not build on" "$order read rewrite"
  done
  pass "once a same-tree rewrite is itself read, a later base update needs a fresh read"
}

fm_test_run_cases \
  test_carry_over_ignores_global_config_and_global_attributes \
  test_carry_over_scratch_lives_beside_the_review_records \
  test_carry_over_refuses_when_the_state_directory_takes_no_scratch \
  test_carry_over_refuses_after_a_rewrite_was_itself_read \
  test_carry_over_ignores_a_merge_driver_in_the_task_worktree \
  test_carry_over_ignores_replace_refs \
  test_carry_over_refuses_a_branch_that_is_not_on_the_base \
  test_carry_over_ignores_a_graft_that_fakes_base_content \
  test_carry_over_refuses_a_base_older_than_the_update \
  test_carry_over_writes_nothing_to_the_task_object_store \
  test_carry_over_ignores_grafts \
  test_carry_over_refuses_after_a_fail_recorded_before_the_pass \
  test_carry_over_allows_reads_of_heads_r_was_built_on \
  test_carry_over_refuses_after_a_later_head_was_read \
  test_carry_over_accepts_a_same_tree_rewrite \
  test_carry_over_accepts_a_clean_merge_of_the_base \
  test_carry_over_accepts_a_clean_rebase \
  test_carry_over_refuses_an_unread_change \
  test_carry_over_refusal_comes_from_the_tree_proof \
  test_carry_over_refuses_a_conflict_resolution \
  test_carry_over_never_carries_a_captain_word \
  test_carry_over_keeps_a_standing_fail \
  test_carry_over_never_overrides_a_read_of_the_live_head \
  test_carry_over_refuses_a_missing_reviewed_object \
  test_review_only_json_is_immutable_record_time_evidence \
  test_default_text_and_captain_word_json \
  test_review_only_cannot_be_satisfied_by_captain_word \
  test_review_only_rejections_are_typed_not_qualified \
  test_unknown_author_covered_by_two_reader_families \
  test_unknown_pipeline_one_independent_reader \
  test_unknown_pipeline_fact_output \
  test_unknown_pipeline_preserves_coverage_boundaries \
  test_unknown_pipeline_no_relief_for_partly_unknown_ship \
  test_unknown_pipeline_after_fail \
  test_unknown_pipeline_relief_after_captain_word \
  test_native_claude_aliases_are_anthropic \
  test_stored_family_fields_cannot_retroactively_change_independence \
  test_typed_failures_distinguish_unavailable_and_invalid_input \
  test_default_fail_after_captain_word_precedence_holds \
  test_legacy_record_without_report_digest_omits_the_field \
  test_plan_names_the_owed_families_and_decides_nothing \
  test_plan_agrees_with_verify_for_an_unrecorded_pipeline_family -- "$@"
