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
  test_plan_agrees_with_verify_for_an_unrecorded_pipeline_family -- "$@"
