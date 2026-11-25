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


# --- append-only corrections ------------------------------------------------
# Synthetic rows only: the PR URL, models, digests and report paths below are
# invented, and every ledger row is written by the test with a fixed epoch so a
# case controls exactly which row a correction names.

DIGEST_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
DIGEST_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

ledger_of() { printf '%s/home/state/review-records.jsonl' "$1"; }

# synth_row <case_dir> <at> <head> <verdict> <reader> <author-groups-json> <covered-json> [digest] [widens-guard]
# Appends one fm-review-record.v1 review row, shaped like the CLI writes it.
synth_row() {
  local case_dir=$1 at=$2 head=$3 verdict=$4 reader=$5 groups=$6 covered=$7 digest=${8:-} widens=${9:-no}
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -nc --arg pr "$URL" --argjson at "$at" --arg head "$head" --arg verdict "$verdict" \
    --arg reader "$reader" --argjson groups "$groups" --argjson covered "$covered" \
    --arg digest "$digest" --arg widens "$widens" '
    {schema:"fm-review-record.v1",kind:"review",pr:$pr,at:$at,head:$head,verdict:$verdict,
     reader_model:$reader,reader_family:"unknown",
     author_groups:($groups | with_entries(.value |= map({model:., family:"unknown"}))),
     loosens_deny_allow_list:"no",widens_guard:$widens,customer_data_billing_spend:"no",
     covered_groups:$covered,report:("/synthetic/report-" + ($at|tostring) + ".md")}
    + (if $digest == "" then {} else {report_sha256:$digest} end)' >> "$(ledger_of "$case_dir")"
}

test_older_ledger_without_corrections_verifies_unchanged() {
  local case_dir out rc=0 row word
  case_dir=$(make_case older-ledger claude-opus-5-5)
  row='{"schema":"fm-review-record.v1","kind":"review","pr":"'"$URL"'","at":1700000001,"head":"'"$HEAD1"'","verdict":"PASS","reader_model":"gpt-5.2","reader_family":"openai","author_groups":{"ship":[{"model":"claude-opus-5-5","family":"anthropic"}]},"loosens_deny_allow_list":"no","widens_guard":"no","customer_data_billing_spend":"no","covered_groups":["ship"],"report":"/synthetic/report-1.md","report_sha256":"'"$DIGEST_A"'"}'
  word='{"schema":"fm-review-record.v1","kind":"captain-word","pr":"'"$URL"'","at":1700000002,"head":"'"$HEAD1"'","words":"Merge this PR."}'
  printf '%s\n' "$row" > "$(ledger_of "$case_dir")"
  out=$(FM_HOME="$case_dir/home" "$RECORD" latest --pr "$URL")
  assert_equals '{"review":'"$row"',"captain-word":null}' "$out" "latest output for a ledger without corrections must stay byte-identical"
  out=$(run_verify "$case_dir" "$HEAD1" --json) || fail "older ledger default verify: $out"
  assert_equals '{"schema":"fm-review-verification.v1","ok":true,"basis":"independent-review","pr":"'"$URL"'","head":"'"$HEAD1"'","at":1700000001,"reader_model":"gpt-5.2","reader_family":"openai","author_groups":{"ship":[{"model":"claude-opus-5-5","family":"anthropic"}]},"report":"/synthetic/report-1.md","report_sha256":"'"$DIGEST_A"'"}' \
    "$out" "older ledger verify --json must stay byte-identical"
  out=$(run_verify "$case_dir" "$HEAD1") || fail "older ledger text verify: $out"
  assert_equals "review: PASS" "$out" "older ledger verify text must stay review: PASS"
  out=$(NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$RECORD" plan --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE")
  assert_equals '{"schema":"fm-review-plan.v1","ok":true,"pr":"'"$URL"'","head":"'"$HEAD1"'","groups":{"ship":[{"model":"claude-opus-5-5","family":"anthropic"}]},"uncovered":[]}' \
    "$out" "older ledger plan must stay byte-identical"
  printf '%s\n' "$word" >> "$(ledger_of "$case_dir")"
  out=$(FM_HOME="$case_dir/home" "$RECORD" latest --pr "$URL")
  assert_equals '{"review":'"$row"',"captain-word":'"$word"'}' "$out" "latest output with a captain-word must stay byte-identical"
  out=$(run_verify "$case_dir" "$HEAD1" --json) || fail "older ledger captain-word verify: $out"
  assert_equals '{"schema":"fm-review-verification.v1","ok":true,"basis":"captain-word","pr":"'"$URL"'","head":"'"$HEAD1"'","at":1700000002,"words":"Merge this PR."}' \
    "$out" "older ledger captain-word verify --json must stay byte-identical"
  out=$(run_verify "$case_dir" "$HEAD1") || fail "older ledger captain-word text verify: $out"
  assert_equals "review: captain-word" "$out" "older ledger captain-word text must stay review: captain-word"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || fail "older ledger review-only verify: $out"
  "$JQ_BIN" -e '.ok == true and .basis == "independent-review" and (has("facts") | not)' <<<"$out" >/dev/null \
    || fail "older ledger review-only verify must carry no correction fact: $out"
  out=$(run_verify "$case_dir" "$HEAD2" --review-only --json) || rc=$?
  expect_code 1 "$rc" "older ledger other head must still refuse"
  expect_not_qualified "$out" "head mismatch" "older ledger other head"
  pass "ledgers without correction rows (review and captain-word) verify, plan and report latest exactly as before"
}


# Every correction carries its own authority; AUTH_WORDS and AUTH_AT are the defaults and
# any extra flag after the fixed arguments overrides them (argparse keeps the last one).
AUTH_WORDS='Drop the copied claim from the reviewer row.'
AUTH_AT=1795300000

record_correction() {  # <case_dir> <head> <effect> <target-at> <reader> <digest|-> [extra flags...]
  local case_dir=$1 head=$2 effect=$3 at=$4 reader=$5 digest=$6
  shift 6
  local flags=()
  [ "$digest" = - ] || flags=(--target-report-sha256 "$digest")
  FM_HOME="$case_dir/home" "$RECORD" correction --pr "$URL" --head "$head" --effect "$effect" \
    --target-at "$at" --target-reader-model "$reader" ${flags[@]+"${flags[@]}"} \
    --authority-words "$AUTH_WORDS" --authority-at "$AUTH_AT" --reason 'synthetic correction' "$@"
}

# forge_correction <case_dir> <target-at> <reader> <digest> <jq patch>
# Appends a hand-written correction row (a well-formed one, then the patch applied), as someone
# who can write the ledger file could.
forge_correction() {
  local case_dir=$1 at=$2 reader=$3 digest=$4 patch=$5
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -nc --arg pr "$URL" --arg head "$HEAD1" --argjson at "$at" --arg reader "$reader" --arg digest "$digest" \
    --arg words "$AUTH_WORDS" --argjson authority_at "$AUTH_AT" '
    {schema:"fm-review-record.v1",kind:"correction",pr:$pr,at:1795300001,head:$head,effect:"exclude-review",
     target:{at:$at,reader_model:$reader,report_sha256:$digest},
     authority:{words:$words,at:$authority_at},reason:"hand-written"}' | "$JQ_BIN" -c "$patch" >> "$(ledger_of "$case_dir")"
}

ledger_sum() {  # <case_dir>: digest of the ledger, or "absent"
  if [ -e "$(ledger_of "$1")" ]; then sha256_of "$(ledger_of "$1")"; else printf absent; fi
}

# verify_snapshot <case_dir> default|json|merge: exit status and all output of one verify run.
# merge is the exact invocation bin/fm-pr-merge.sh makes (no --review-only, no --json).
verify_snapshot() {
  local case_dir=$1 mode=$2 rc=0 out
  case "$mode" in
    default) out=$(run_verify "$case_dir" "$HEAD1" 2>&1) || rc=$? ;;
    json) out=$(run_verify "$case_dir" "$HEAD1" --json 2>&1) || rc=$? ;;
    merge) out=$(NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/home/state" \
      "$RECORD" verify --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE" 2>&1) || rc=$? ;;
    *) fail "verify_snapshot: unknown mode $mode" ;;
  esac
  printf 'rc=%s\n%s' "$rc" "$out"
}

# expect_correction_rejected <label> <needle> <case_dir> <record_correction args after case_dir...>
# A rejected correction exits 1 (2 for a malformed request, REJECT_CODE=2) naming why and leaves the ledger byte-identical.
expect_correction_rejected() {
  local label=$1 needle=$2 case_dir=$3 before after out rc=0
  shift 3
  before=$(ledger_sum "$case_dir")
  out=$(record_correction "$case_dir" "$@") || rc=$?
  expect_code "${REJECT_CODE:-1}" "$rc" "$label must be rejected: $out"
  assert_contains "$out" "$needle" "$label must say why"
  after=$(ledger_sum "$case_dir")
  assert_equals "$before" "$after" "$label must leave the ledger byte-identical"
}

# A synthetic PR shaped like the live case: ship authors claude-sonnet-5-5 and
# openai-codex/gpt-6-luna (task meta plus relaunch history) and one recorded
# pipeline invocation by claude-opus-5-5, so the derived groups are ship and
# no-mistakes:anthropic. BAD over-claims coverage with an invented
# no-mistakes group; GOOD is the genuine independent read and also carries the
# copied no-mistakes entry.
LIVE_NM="$TMP_ROOT/live-nm"
fm_test_empty_pipeline_db "$LIVE_NM"
python3 -c 'import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("INSERT INTO runs VALUES (?, ?, ?, ?)", ("run-1", "repo-1", "fm/fixture", sys.argv[2]))
db.execute("INSERT INTO agent_invocations VALUES (?, ?, ?, ?)", ("run-1", "claude", "claude-opus-5-5", ""))
db.commit()' "$LIVE_NM/state.sqlite" "$URL"
BAD_AT=1795202232
GOOD_AT=1795206560
BAD_READER=openai-codex/gpt-6.1-terra
GOOD_READER=deepseek/deepseek-v4-pro

live_case() {  # <name> [bad|nobad] [good|nogood]
  local case_dir
  case_dir=$(make_case "$1" claude-sonnet-5-5)
  printf 'model=openai-codex/gpt-6-luna\n' > "$case_dir/home/state/task-x1.control-relaunch.meta-prior"
  if [ "${2:-bad}" = bad ]; then
    synth_row "$case_dir" "$BAD_AT" "$HEAD1" PASS "$BAD_READER" \
      '{"ship":["claude-sonnet-5-5"],"no-mistakes":["anthropic"]}' '["ship","no-mistakes"]' "$DIGEST_A"
  fi
  if [ "${3:-good}" = good ]; then
    synth_row "$case_dir" "$GOOD_AT" "$HEAD1" PASS "$GOOD_READER" \
      '{"ship":["claude-sonnet-5-5","openai-codex/gpt-6-luna"],"no-mistakes:anthropic":["claude-opus-5-5"],"no-mistakes":["anthropic"]}' \
      '["ship","no-mistakes:anthropic"]' "$DIGEST_B"
  fi
  printf '%s\n' "$case_dir"
}

run_live_verify() {  # <case_dir> [flags...]
  local case_dir=$1
  shift
  NM_HOME="$LIVE_NM" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" --head "$HEAD1" \
    --task task-x1 --base "$BASE" --review-only --json "$@"
}

# The facts verify prints for corrections: the count, then one line per applied correction that
# carries its authority words (JSON-quoted) and the epoch they were given.
# expect_correction_facts <json> <count> <label>
expect_correction_facts() {
  local out=$1 count=$2 label=$3
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --argjson count "$count" --arg words "$AUTH_WORDS" --arg at "$AUTH_AT" '
    .facts[0] == "corrections applied: \($count)" and (.facts | length) == ($count + 1)
    and (.facts[1:] | all(contains("authority given at \($at): \($words | tojson)")))' <<<"$out" >/dev/null \
    || fail "$label: expected 'corrections applied: $count' followed by each authority's words and epoch: $out"
}

test_correction_live_shape_judges_genuine_coverage_only() {
  local case_dir out rc=0 before size
  # Step 1: before any correction the bad row carries the verdict (the defect).
  case_dir=$(live_case live-shape)
  out=$(run_live_verify "$case_dir") || fail "C5 step 1: bad row plus genuine row passes before correction: $out"
  "$JQ_BIN" -e '.ok == true and .basis == "independent-review" and .reader_model == "deepseek/deepseek-v4-pro"' \
    <<<"$out" >/dev/null || fail "C5 step 1: expected the genuine row to be the evidence: $out"
  # The same evidence without the bad row refuses: the pass rests on the bad row.
  local replay
  replay=$(live_case live-shape-replay nobad)
  out=$(run_live_verify "$replay") || rc=$?
  expect_code 1 "$rc" "C5: replay without the bad row must refuse: $out"
  expect_not_qualified "$out" "uncovered commit group no-mistakes, family anthropic" "C5 replay without the bad row"
  # Step 2: exclude the bad row and supersede the copied entry; the genuine read passes alone.
  # No captain-word is recorded anywhere in this ledger: a correction carries its own authority.
  before=$(cat "$(ledger_of "$case_dir")")
  size=$(wc -c < "$(ledger_of "$case_dir")" | tr -d ' ')
  record_correction "$case_dir" "$HEAD1" exclude-review "$BAD_AT" "$BAD_READER" "$DIGEST_A" >/dev/null \
    || fail "C5: record the exclusion"
  record_correction "$case_dir" "$HEAD1" supersede-author-group "$GOOD_AT" "$GOOD_READER" "$DIGEST_B" \
    --group no-mistakes >/dev/null || fail "C5: record the supersession"
  [ "$(head -c "$size" "$(ledger_of "$case_dir")")" = "$before" ] \
    || fail "C1: the rows recorded before the corrections must stay byte-identical"
  [ "$(wc -l < "$(ledger_of "$case_dir")" | tr -d ' ')" = 4 ] || fail "C1: two corrections append exactly two rows"
  out=$(run_live_verify "$case_dir") || fail "C5 step 2: corrected evidence must pass: $out"
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --arg digest "$DIGEST_B" --argjson at "$GOOD_AT" '
    .ok == true and .basis == "independent-review" and .reader_model == "deepseek/deepseek-v4-pro"
    and .at == $at and .report_sha256 == $digest
    and (.author_groups | keys) == ["no-mistakes:anthropic","ship"]' <<<"$out" >/dev/null \
    || fail "C5 step 2: the genuine row must be the evidence: $out"
  expect_correction_facts "$out" 2 "C5 step 2 disclosure"
  out=$(NM_HOME="$LIVE_NM" FM_HOME="$case_dir/home" "$RECORD" plan --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE")
  "$JQ_BIN" -e '.ok == true and .uncovered == [] and (.groups | has("no-mistakes") | not)
    and (.groups | has("ship") and has("no-mistakes:anthropic"))' <<<"$out" >/dev/null \
    || fail "C5 step 2: plan must agree and still carry the derived groups: $out"
  # Step 3: remove the genuine independent row from the corrected ledger; the guard refuses.
  local stripped
  stripped=$(live_case live-shape-stripped nobad nogood)
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -c --arg reader "$GOOD_READER" 'select(.kind != "review" or .reader_model != $reader)' \
    "$(ledger_of "$case_dir")" > "$(ledger_of "$stripped")"
  [ "$(wc -l < "$(ledger_of "$stripped")" | tr -d ' ')" = 3 ] || fail "C5 step 3 fixture must keep the bad row and both corrections, and only drop the genuine row"
  out=$(run_live_verify "$stripped") || rc=$?
  expect_code 1 "$rc" "C5 step 3: corrected ledger without the genuine row must refuse: $out"
  expect_not_qualified "$out" "no independent review record" "C5 step 3 with no read left"
  # The same ledger with a read by a builder-family reader in the genuine row's place leaves groups uncovered.
  synth_row "$stripped" "$GOOD_AT" "$HEAD1" PASS claude-opus-5-5 \
    '{"ship":["claude-sonnet-5-5","openai-codex/gpt-6-luna"],"no-mistakes:anthropic":["claude-opus-5-5"]}' \
    '["ship","no-mistakes:anthropic"]' "$DIGEST_B"
  rc=0
  out=$(run_live_verify "$stripped") || rc=$?
  expect_code 1 "$rc" "C5 step 3: a read from a builder family must not stand in for the genuine row: $out"
  expect_not_qualified "$out" "uncovered commit group no-mistakes:anthropic, family anthropic" "C5 step 3 without genuine coverage"
  pass "C5 the corrected live-shape ledger passes on the genuine DeepSeek read alone, with each authority disclosed, and refuses without it"
}

test_correction_exclusion_effects() {
  local case_dir out rc=0
  # (a) coverage: the excluded row is the only cover of the ship family.
  case_dir=$(make_case excl-coverage gpt-5.1)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_A"
  synth_row "$case_dir" 1700000020 "$HEAD1" PASS gpt-5.2 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_B"
  run_verify "$case_dir" "$HEAD1" --review-only >/dev/null || fail "C2 coverage fixture must pass before correction"
  record_correction "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_A" >/dev/null \
    || fail "C2 record exclusion"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "C2 an excluded row must stop covering its group: $out"
  expect_not_qualified "$out" "uncovered commit group ship, family openai" "C2 excluded sole cover"
  # (b) constraint: the excluded row's typed group stops constraining; coverage of ship comes from the other row.
  case_dir=$(make_case excl-constraint gpt-5.1)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS claude-sonnet-4 \
    '{"ship":["gpt-5.1"],"extra":["claude-opus-5-5"]}' '["ship","extra"]' "$DIGEST_A"
  synth_row "$case_dir" 1700000020 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_B"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "C2 the typed group must constrain before correction: $out"
  expect_not_qualified "$out" "uncovered commit group extra, family anthropic" "C2 typed constraint before correction"
  record_correction "$case_dir" "$HEAD1" exclude-review 1700000010 claude-sonnet-4 "$DIGEST_A" >/dev/null \
    || fail "C2 record exclusion of the constraining row"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || fail "C2 an excluded row's typed groups add no constraint: $out"
  "$JQ_BIN" -e '.ok == true and .reader_model == "claude-opus-5-5"' <<<"$out" >/dev/null \
    || fail "C2 the remaining read must carry the verdict: $out"
  expect_correction_facts "$out" 1 "C2 exclusion disclosure"
  # (c) the newest review is the newest row that still counts.
  case_dir=$(make_case excl-newest claude-opus-5-5)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS gpt-5.2 '{"ship":["claude-opus-5-5"]}' '["ship"]' "$DIGEST_A"
  synth_row "$case_dir" 1700000020 "$HEAD1" PASS mystery-9 '{"ship":["claude-opus-5-5"]}' '["ship"]' "$DIGEST_B"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "C2 an unknown-family newest reader must refuse: $out"
  expect_not_qualified "$out" "model family unknown for newest reader mystery-9" "C2 newest reader before exclusion"
  record_correction "$case_dir" "$HEAD1" exclude-review 1700000020 mystery-9 "$DIGEST_B" >/dev/null \
    || fail "C2 record exclusion of the newest row"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || fail "C2 verification must fall back to the newest remaining read: $out"
  "$JQ_BIN" -e '.ok == true and .reader_model == "gpt-5.2"' <<<"$out" >/dev/null || fail "C2 fallback evidence: $out"
  pass "C2 an excluded review row counts for no coverage and adds no author constraint, each shown separately"
}

test_correction_supersede_effects() {
  local case_dir out rc=0
  case_dir=$(make_case supersede gpt-5.1)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS claude-opus-5-5 \
    '{"ship":["gpt-5.1"],"extra":["claude-opus-5-4"],"other":["claude-opus-5-4"]}' '["ship"]' "$DIGEST_A"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "C3 the typed entries must constrain before correction: $out"
  expect_not_qualified "$out" "uncovered commit group extra, family anthropic" "C3 typed entry before correction"
  expect_correction_rejected "C3 superseding an entry the row does not hold" "holds no author_groups entry nothing" \
    "$case_dir" "$HEAD1" supersede-author-group 1700000010 claude-opus-5-5 "$DIGEST_A" --group nothing
  record_correction "$case_dir" "$HEAD1" supersede-author-group 1700000010 claude-opus-5-5 "$DIGEST_A" \
    --group extra >/dev/null || fail "C3 record the first supersession"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "C3 only the named entry stops constraining: $out"
  expect_not_qualified "$out" "uncovered commit group other, family anthropic" "C3 the row's other entry still constrains"
  record_correction "$case_dir" "$HEAD1" supersede-author-group 1700000010 claude-opus-5-5 "$DIGEST_A" \
    --group other >/dev/null || fail "C3 record the second supersession"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || fail "C3 both entries superseded must pass: $out"
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --arg digest "$DIGEST_A" '
    .ok == true and .reader_model == "claude-opus-5-5" and .at == 1700000010 and .report_sha256 == $digest
    and (.author_groups | keys) == ["ship"]' <<<"$out" >/dev/null \
    || fail "C3 the row keeps its reader, digest, verdict and ship coverage: $out"
  expect_correction_facts "$out" 2 "C3 supersession disclosure"
  pass "C3 superseding one typed entry drops only that entry; the row's other entries, coverage, verdict and digest stay in force"
}

test_correction_cannot_clear_derived_groups() {
  local case_dir out rc=0
  case_dir=$(live_case derived-groups nobad)
  record_correction "$case_dir" "$HEAD1" supersede-author-group "$GOOD_AT" "$GOOD_READER" "$DIGEST_B" \
    --group no-mistakes >/dev/null || fail "C4 supersede the copied entry"
  run_live_verify "$case_dir" >/dev/null || fail "C4 fixture must pass once the copied entry is superseded"
  record_correction "$case_dir" "$HEAD1" supersede-author-group "$GOOD_AT" "$GOOD_READER" "$DIGEST_B" \
    --group ship >/dev/null || fail "C4 record the attempt on the derived ship group"
  out=$(run_live_verify "$case_dir") || rc=$?
  expect_code 1 "$rc" "C4 superseding the typed ship entry must not clear derived ship: $out"
  expect_not_qualified "$out" "uncovered commit group ship, family anthropic,openai" "C4 derived ship stays required"
  case_dir=$(live_case derived-groups-pipeline nobad)
  record_correction "$case_dir" "$HEAD1" supersede-author-group "$GOOD_AT" "$GOOD_READER" "$DIGEST_B" \
    --group no-mistakes >/dev/null || fail "C4 supersede the copied entry"
  record_correction "$case_dir" "$HEAD1" supersede-author-group "$GOOD_AT" "$GOOD_READER" "$DIGEST_B" \
    --group no-mistakes:anthropic >/dev/null || fail "C4 record the attempt on the derived pipeline group"
  rc=0
  out=$(run_live_verify "$case_dir") || rc=$?
  expect_code 1 "$rc" "C4 superseding the typed pipeline entry must not clear derived no-mistakes:anthropic: $out"
  expect_not_qualified "$out" "uncovered commit group no-mistakes:anthropic, family anthropic" "C4 derived pipeline group stays required"
  pass "C4 a correction cannot clear the derived ship or no-mistakes:anthropic group"
}

test_correction_rejections_leave_the_ledger_untouched() {
  local case_dir out rc=0 headb before
  case_dir=$(make_case rejections gpt-5.1)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_A"
  synth_row "$case_dir" 1700000030 "$HEAD1" FAIL claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_B"
  synth_row "$case_dir" 1700000040 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_B" yes
  # Two rows that no field tells apart.
  synth_row "$case_dir" 1700000050 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_A"
  synth_row "$case_dir" 1700000050 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_A"
  # A legacy row with no digest.
  synth_row "$case_dir" 1700000060 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]'
  # The same row fields at another head.
  headb=$(git -C "$case_dir/wt" -c user.name=Tests -c user.email=tests@example.invalid commit -q --allow-empty -m 'second ship change' && git -C "$case_dir/wt" rev-parse HEAD)
  synth_row "$case_dir" 1700000010 "$headb" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_A"
  expect_correction_rejected "C4 a wrong target epoch" "0 rows match" \
    "$case_dir" "$HEAD1" exclude-review 1700000011 claude-opus-5-5 "$DIGEST_A"
  expect_correction_rejected "C4 a wrong target reader" "0 rows match" \
    "$case_dir" "$HEAD1" exclude-review 1700000010 gpt-5.2 "$DIGEST_A"
  expect_correction_rejected "C4 a wrong target digest" "0 rows match" \
    "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_B"
  expect_correction_rejected "C4 a target that omits the digest its row has" "0 rows match" \
    "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 -
  expect_correction_rejected "C4 a target that names a digest the row lacks" "0 rows match" \
    "$case_dir" "$HEAD1" exclude-review 1700000060 claude-opus-5-5 "$DIGEST_A"
  expect_correction_rejected "C4 an ambiguous target" "2 rows match" \
    "$case_dir" "$HEAD1" exclude-review 1700000050 claude-opus-5-5 "$DIGEST_A"
  expect_correction_rejected "C4 a head with no such row" "0 rows match" \
    "$case_dir" "$HEAD2" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_A"
  expect_correction_rejected "C4 a FAIL row" "a FAIL row stands" \
    "$case_dir" "$HEAD1" exclude-review 1700000030 claude-opus-5-5 "$DIGEST_B"
  expect_correction_rejected "C4 a row with a yes trigger" "widens_guard is yes" \
    "$case_dir" "$HEAD1" exclude-review 1700000040 claude-opus-5-5 "$DIGEST_B"
  REJECT_CODE=2 expect_correction_rejected "C4 a supersede with no group" "correction group names" \
    "$case_dir" "$HEAD1" supersede-author-group 1700000010 claude-opus-5-5 "$DIGEST_A"
  REJECT_CODE=2 expect_correction_rejected "C4 an exclusion that names a group" "only supersede-author-group takes one" \
    "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_A" --group ship
  # The authority must be present, non-empty words and an epoch.
  REJECT_CODE=2 expect_correction_rejected "C4 empty authority words" "correction authority words must be non-empty" \
    "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_A" --authority-words ''
  REJECT_CODE=2 expect_correction_rejected "C4 blank authority words" "correction authority words must be non-empty" \
    "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_A" --authority-words '   '
  REJECT_CODE=2 expect_correction_rejected "C4 a negative authority epoch" "authority at must be the epoch" \
    "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_A" --authority-at -1
  before=$(ledger_sum "$case_dir")
  out=$(FM_HOME="$case_dir/home" "$RECORD" correction --pr "$URL" --head "$HEAD1" --effect exclude-review \
    --target-at 1700000010 --target-reader-model claude-opus-5-5 --target-report-sha256 "$DIGEST_A" \
    --authority-at "$AUTH_AT" --reason 'no words' 2>&1) || rc=$?
  expect_code 2 "$rc" "C4 a correction with no authority words flag must be rejected: $out"
  assert_contains "$out" "--authority-words" "C4 the missing authority words flag must be named"
  assert_equals "$before" "$(ledger_sum "$case_dir")" "C4 a correction with no authority words must leave the ledger byte-identical"
  rc=0
  out=$(FM_HOME="$case_dir/home" "$RECORD" correction --pr "$URL" --head "$HEAD1" --effect exclude-review \
    --target-at 1700000010 --target-reader-model claude-opus-5-5 --target-report-sha256 "$DIGEST_A" \
    --authority-words "$AUTH_WORDS" --reason 'no epoch' 2>&1) || rc=$?
  expect_code 2 "$rc" "C4 a correction with no authority epoch flag must be rejected: $out"
  assert_contains "$out" "--authority-at" "C4 the missing authority epoch flag must be named"
  assert_equals "$before" "$(ledger_sum "$case_dir")" "C4 a correction with no authority epoch must leave the ledger byte-identical"
  # A correction naming exactly one row with its own authority records with no captain-word anywhere,
  # stores the authority in the row and cites no captain-word, and applies at its own head only.
  record_correction "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_A" >/dev/null \
    || fail "C4 a correction naming exactly one row must record"
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  tail -n 1 "$(ledger_of "$case_dir")" | "$JQ_BIN" -e --arg words "$AUTH_WORDS" --argjson at "$AUTH_AT" '
    .kind == "correction" and .authority == {words: $words, at: $at} and (has("captain_word") | not)' >/dev/null \
    || fail "C4 the recorded correction must hold its own authority and cite no captain-word: $(tail -n 1 "$(ledger_of "$case_dir")")"
  out=$(FM_HOME="$case_dir/home" "$RECORD" latest --pr "$URL")
  # shellcheck disable=SC2016  # jq program; single quotes are intended.
  "$JQ_BIN" -e --arg head "$headb" '.review.head == $head and .review.at == 1700000010 and ."captain-word" == null' <<<"$out" >/dev/null \
    || fail "C4 the other head's row must stay the newest recorded review and no captain-word may appear: $out"
  out=$(NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" --head "$headb" \
    --task task-x1 --base "$BASE" --review-only --json) || fail "C4 the other head must verify as before: $out"
  "$JQ_BIN" -e '.ok == true and (has("facts") | not)' <<<"$out" >/dev/null \
    || fail "C4 a correction at one head must not apply at another: $out"
  # Away posture: a correction loosens the guard, so it is not recorded while the captain is away.
  printf 'mode: away\n' > "$case_dir/home/state/.afk-contract"
  REJECT_CODE=2 expect_correction_rejected "C4 a correction while an away record exists" "away" \
    "$case_dir" "$HEAD1" exclude-review 1700000050 claude-opus-5-5 "$DIGEST_A"
  out=$(record_correction "$case_dir" "$HEAD1" exclude-review 1700000050 claude-opus-5-5 "$DIGEST_A") || true
  assert_contains "$out" "correction authority" "C4 an away correction must name correction authority"
  assert_not_contains "$out" "merge word" "C4 an away correction must not ask for a merge word"
  before=$(ledger_sum "$case_dir")
  out=$(FM_HOME="$case_dir/home" "$RECORD" captain-word --pr "$URL" --head "$HEAD1" --words 'merge it') || true
  assert_contains "$out" "captain-word refused: the away-posture record $case_dir/home/state/.afk-contract exists, so the captain is away and away words are never captain words; the captain must give the merge word after return" \
    "C4 an away captain-word must keep its message"
  assert_equals "$before" "$(ledger_sum "$case_dir")" "C4 an away captain-word must leave the ledger byte-identical"
  rm -f "$case_dir/home/state/.afk-contract"
  # No history at all: nothing to name, and no ledger is created.
  case_dir=$(make_case rejection-no-ledger gpt-5.1)
  expect_correction_rejected "C4 a correction with no review history" "0 rows match" \
    "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_A"
  [ ! -e "$(ledger_of "$case_dir")" ] || fail "C4 a rejected correction must not create the ledger"
  pass "C4 wrong, ambiguous, other-head, authority-less, FAIL, trigger and away corrections are each rejected with the ledger byte-identical"
}

test_unusable_correction_rows_never_loosen_or_block() {
  local case_dir out rc=0
  # The excl-constraint shape: refuses before any correction because row 10 types an extra group; a
  # correction that excludes row 10 would pass it.
  case_dir=$(make_case unusable-corrections gpt-5.1)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS claude-sonnet-4 \
    '{"ship":["gpt-5.1"],"extra":["claude-opus-5-5"]}' '["ship","extra"]' "$DIGEST_A"
  synth_row "$case_dir" 1700000020 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_B"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "unusable corrections fixture must refuse before any correction: $out"
  expect_not_qualified "$out" "uncovered commit group extra, family anthropic" "unusable corrections fixture before correction"
  # Hand-written corrections that no longer resolve or carry no usable authority. Each one would
  # loosen the guard if it applied; none may block the ledger, and none may disclose anything.
  local patch
  for patch in \
    '.target.at = 1700000011' \
    '.target.report_sha256 = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' \
    '.authority.words = ""' \
    '.authority.words = "   "' \
    '.authority.words = 7' \
    '.authority.words = null' \
    'del(.authority.words)' \
    'del(.authority.at)' \
    '.authority.at = -1' \
    '.authority.at = "1795300000"' \
    '.authority.at = 1.5' \
    '.authority = null' \
    '.authority = "the captain agreed"' \
    'del(.authority)' \
    'del(.authority) | .captain_word = {at: 1700000099, words_sha256: "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}'; do
    forge_correction "$case_dir" 1700000010 claude-sonnet-4 "$DIGEST_A" "$patch"
    rc=0
    out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
    expect_code 1 "$rc" "a correction ($patch) must remove nothing: $out"
    expect_not_qualified "$out" "uncovered commit group extra, family anthropic" "correction ($patch)"
  done
  out=$(FM_HOME="$case_dir/home" "$RECORD" latest --pr "$URL") || fail "unusable corrections must not make the ledger unreadable: $out"
  "$JQ_BIN" -e '.review.reader_model == "claude-opus-5-5" and ."captain-word" == null' <<<"$out" >/dev/null \
    || fail "latest must keep reporting the newest review: $out"
  out=$(NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir/home" "$RECORD" plan --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE") \
    || fail "plan must read a ledger holding unusable corrections: $out"
  "$JQ_BIN" -e '.ok == true and (has("facts") | not) and (.uncovered | length) > 0' <<<"$out" >/dev/null \
    || fail "plan must still owe the typed extra group: $out"
  # The same row with usable authority applies, so the fixture does pass once it is genuine.
  forge_correction "$case_dir" 1700000010 claude-sonnet-4 "$DIGEST_A" .
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || fail "the same row with usable authority must apply: $out"
  expect_correction_facts "$out" 1 "the genuine correction after the unusable ones"
  pass "a correction with no usable authority or no resolvable target is ignored: it neither blocks the ledger nor loosens the guard"
}

test_correction_is_never_merge_authority() {
  local case_dir out rc=0
  # (a) Coverage lost to the correction: default verify, with no captain-word row anywhere, refuses.
  case_dir=$(make_case never-merge-refused gpt-5.1)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_A"
  synth_row "$case_dir" 1700000020 "$HEAD1" PASS gpt-5.2 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_B"
  record_correction "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_A" >/dev/null \
    || fail "record the exclusion"
  out=$(run_verify "$case_dir" "$HEAD1" --json) || rc=$?
  expect_code 1 "$rc" "a correction must not let default verify pass: $out"
  expect_not_qualified "$out" "uncovered commit group ship, family openai" "default verify with a correction and no captain-word"
  out=$(verify_snapshot "$case_dir" merge)
  assert_contains "$out" "rc=1" "the merge path must refuse with a correction and no captain-word"
  assert_contains "$out" "uncovered commit group ship, family openai" "the merge path must name the uncovered group"
  case "$out" in *"review: captain-word"*) fail "a correction must never produce captain-word: $out" ;; esac
  # (b) Coverage that survives: basis is independent-review, never captain-word, and latest shows no captain-word.
  case_dir=$(make_case never-merge-passes gpt-5.1)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS claude-sonnet-4 \
    '{"ship":["gpt-5.1"],"extra":["claude-opus-5-5"]}' '["ship","extra"]' "$DIGEST_A"
  synth_row "$case_dir" 1700000020 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_B"
  record_correction "$case_dir" "$HEAD1" exclude-review 1700000010 claude-sonnet-4 "$DIGEST_A" >/dev/null \
    || fail "record the exclusion"
  out=$(run_verify "$case_dir" "$HEAD1" --json) || fail "default verify must pass on the corrected coverage: $out"
  "$JQ_BIN" -e '.ok == true and .basis == "independent-review" and (has("words") | not)' <<<"$out" >/dev/null \
    || fail "the basis must be independent-review, never captain-word: $out"
  out=$(FM_HOME="$case_dir/home" "$RECORD" latest --pr "$URL")
  "$JQ_BIN" -e '."captain-word" == null' <<<"$out" >/dev/null || fail "a correction must not appear as a captain-word: $out"
  pass "a ledger with a correction and no captain-word never returns captain-word: default verify and the merge path judge coverage alone"
}

test_default_and_merge_verify_match_with_and_without_a_correction() {
  local case_dir with without mode name
  # (i) A captain-word at the head: default verify, its JSON and the merge path return exactly the
  # same output and status whether or not a correction (even one that removes all coverage) follows.
  case_dir=$(make_case match-word gpt-5.1)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_A"
  record_word "$case_dir" "$HEAD1" 'Merge this PR.' >/dev/null || fail "record captain-word"
  for mode in default json merge; do
    printf -v "before_$mode" '%s' "$(verify_snapshot "$case_dir" "$mode")"
  done
  record_correction "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_A" >/dev/null \
    || fail "record the exclusion that removes the only cover"
  for mode in default json merge; do
    name="before_$mode"
    assert_equals "${!name}" "$(verify_snapshot "$case_dir" "$mode")" "$mode verify with a captain-word must not change when a correction is appended"
  done
  # (ii) A FAIL after the captain-word still stands, with and without the correction.
  case_dir=$(make_case match-fail gpt-5.1)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_A"
  record_word "$case_dir" "$HEAD1" 'Merge this PR.' >/dev/null || fail "record captain-word"
  synth_row "$case_dir" 1700000030 "$HEAD1" FAIL claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_B"
  without=$(verify_snapshot "$case_dir" merge)
  assert_contains "$without" "rc=1" "a FAIL after the captain-word must stand"
  record_correction "$case_dir" "$HEAD1" exclude-review 1700000010 claude-opus-5-5 "$DIGEST_A" >/dev/null \
    || fail "record the exclusion"
  assert_equals "$without" "$(verify_snapshot "$case_dir" merge)" "a FAIL after the captain-word must stand the same with a correction"
  # (iii) Corrections that do not apply (no usable authority, unresolvable target) change nothing at all:
  # byte-identical output and status in every mode.
  case_dir=$(make_case match-ignored gpt-5.1)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_A"
  for mode in default json merge; do
    printf -v "before_$mode" '%s' "$(verify_snapshot "$case_dir" "$mode")"
  done
  forge_correction "$case_dir" 1700000010 claude-opus-5-5 "$DIGEST_A" '.authority.words = ""'
  forge_correction "$case_dir" 1700000010 claude-opus-5-5 "$DIGEST_A" 'del(.authority)'
  forge_correction "$case_dir" 1700000011 claude-opus-5-5 "$DIGEST_A" .
  for mode in default json merge; do
    name="before_$mode"
    assert_equals "${!name}" "$(verify_snapshot "$case_dir" "$mode")" "$mode verify must not change for corrections that do not apply"
  done
  # (iv) A correction that applies but leaves coverage as it was changes only the disclosed facts.
  case_dir=$(make_case match-applied gpt-5.1)
  synth_row "$case_dir" 1700000010 "$HEAD1" PASS claude-opus-5-5 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_A"
  synth_row "$case_dir" 1700000020 "$HEAD1" PASS claude-sonnet-4 '{"ship":["gpt-5.1"]}' '["ship"]' "$DIGEST_B"
  without=$(verify_snapshot "$case_dir" merge)
  assert_equals $'rc=0\nreview: PASS' "$without" "two covering reads pass the merge path"
  record_correction "$case_dir" "$HEAD1" exclude-review 1700000020 claude-sonnet-4 "$DIGEST_B" >/dev/null \
    || fail "record the exclusion of the redundant read"
  with=$(verify_snapshot "$case_dir" merge)
  assert_contains "$with" $'rc=0\nreview: PASS\nreview: corrections applied: 1\nreview: correction exclude-review of the review row at 1700000020' \
    "an applied correction keeps the same status and basis and adds only its disclosure"
  assert_contains "$with" "authority given at $AUTH_AT: \"$AUTH_WORDS\"" "the merge path must print the correction's authority words and epoch"
  pass "default verify, its JSON and the merge path give the same result with and without a correction, except through the corrected coverage and its disclosure"
}

fm_test_run_cases \
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
  test_plan_agrees_with_verify_for_an_unrecorded_pipeline_family \
  test_older_ledger_without_corrections_verifies_unchanged \
  test_correction_live_shape_judges_genuine_coverage_only \
  test_correction_exclusion_effects \
  test_correction_supersede_effects \
  test_correction_cannot_clear_derived_groups \
  test_correction_rejections_leave_the_ledger_untouched \
  test_unusable_correction_rows_never_loosen_or_block \
  test_correction_is_never_merge_authority \
  test_default_and_merge_verify_match_with_and_without_a_correction -- "$@"
