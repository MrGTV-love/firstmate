#!/usr/bin/env bash
# Tests for bin/fm-review-record.py: immutable review-time evidence,
# --review-only verification and the fm-review-verification.v1 JSON contract.
# Every case drives the real CLI over synthetic local reports; no forge, model
# or merge operation happens.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECORD="$ROOT/bin/fm-review-record.py"
JQ_BIN=$(command -v jq) || fail "test needs jq"
TMP_ROOT=$(fm_test_tmproot fm-review-record-tests)
URL=https://github.com/example/repo/pull/9
HEAD1=1111111111111111111111111111111111111111
HEAD2=2222222222222222222222222222222222222222

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/home"
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
  FM_HOME="$case_dir/home" "$RECORD" verify --pr "$URL" --head "$head" "$@"
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
    '{"initial":["gpt-5.1-codex"],"fixes":["Gemini-3-Pro","deepseek-v3"]}' >/dev/null \
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
    and .author_groups == {"initial":[{model:"gpt-5.1-codex",family:"openai"}],
                           "fixes":[{model:"Gemini-3-Pro",family:"google"},
                                    {model:"deepseek-v3",family:"deepseek"}]}
    and .report == $report and .report_sha256 == $digest' <<<"$out" >/dev/null \
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

  case_dir=$(make_case reject-same-family)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["claude-opus-4"]}' >/dev/null || fail "record same-family PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "same family must not qualify"
  expect_not_qualified "$out" "matches author_groups" "same family"

  case_dir=$(make_case reject-unknown-reader)
  record_review "$case_dir" "$HEAD1" PASS mystery-9 '{"all":["gpt-5.1"]}' >/dev/null || fail "record unknown-reader PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "unknown reader must not qualify"
  expect_not_qualified "$out" "model family unknown for mystery-9" "unknown reader"

  case_dir=$(make_case reject-unknown-author)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["mystery-9"]}' >/dev/null || fail "record unknown-author PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "unknown author must not qualify"
  expect_not_qualified "$out" "model family unknown for mystery-9" "unknown author"

  case_dir=$(make_case reject-trigger)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["gpt-5.1"]}' --widens-guard yes >/dev/null \
    || fail "record trigger PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "yes trigger must not qualify"
  expect_not_qualified "$out" "widens_guard is yes" "yes trigger"
  pass "stale head, FAIL, same family, unknown families and triggers are typed not-qualified"
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
  case_dir=$(make_case alias-same-family)
  record_review "$case_dir" "$HEAD1" PASS haiku '{"all":["claude-opus-4"]}' >/dev/null || fail "record alias same-family"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "bare Claude aliases share the anthropic family"
  expect_not_qualified "$out" "matches author_groups" "bare alias vs claude id"
  case_dir=$(make_case alias-same-family-bare)
  record_review "$case_dir" "$HEAD1" PASS sonnet '{"all":["opus"]}' >/dev/null || fail "record bare alias same-family"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 1 "$rc" "two bare Claude aliases share anthropic"
  expect_not_qualified "$out" "matches author_groups" "bare alias vs bare alias"
  case_dir=$(make_case alias-provider-qualified)
  record_review "$case_dir" "$HEAD1" PASS anthropic/claude-sonnet-4 '{"all":["openai/gpt-5.1"]}' >/dev/null \
    || fail "record provider-qualified PASS"
  rc=0
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || rc=$?
  expect_code 0 "$rc" "provider-qualified ids must stay supported: $out"
  "$JQ_BIN" -e '.reader_family == "anthropic" and .author_groups.all[0].family == "openai"' <<<"$out" >/dev/null \
    || fail "provider-qualified families must derive from the model id: $out"
  pass "bare opus, sonnet and haiku ids map to anthropic while unknown ids stay untrusted"
}

test_stored_family_metadata_cannot_retroactively_change_independence() {
  local case_dir out ledger
  case_dir=$(make_case mutable-metadata)
  record_review "$case_dir" "$HEAD1" PASS gpt-5.1 '{"all":["claude-opus-4"]}' >/dev/null \
    || fail "record cross-family PASS"
  out=$(run_verify "$case_dir" "$HEAD1" --review-only --json) || fail "cross-family PASS must verify: $out"
  "$JQ_BIN" -e '.reader_family == "openai" and .author_groups.all[0].family == "anthropic"' <<<"$out" >/dev/null \
    || fail "families must derive from the recorded model ids: $out"
  printf 'reader_model=claude-opus-4\nauthor_model=claude-opus-4\nfamily=anthropic\n' \
    > "$case_dir/home/state/task-x1.meta"
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
  pass "stored family fields and task metadata cannot retroactively change recorded independence"
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
  case_dir=$(make_case invalid-input)
  out=$(FM_HOME="$case_dir/home" "$RECORD" verify --pr nonsense --head "$HEAD1" --review-only --json) || rc=$?
  expect_code 2 "$rc" "an unparseable PR is invalid input"
  "$JQ_BIN" -e '.schema == "fm-review-verification.v1" and .ok == false
    and .error.kind == "invalid-input" and (.error.message | contains("pr"))' <<<"$out" >/dev/null \
    || fail "bad caller input must produce a typed invalid-input envelope: $out"
  pass "not-qualified, unavailable and invalid-input failures stay distinguishable without parsing prose"
}

test_default_fail_after_captain_word_precedence_is_unchanged() {
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
  assert_contains "$out" "appended after the captain-word" "later FAIL must name the captain-word order"
  pass "default captain-word/FAIL precedence is unchanged"
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

test_review_only_json_is_immutable_record_time_evidence
test_default_text_and_captain_word_json
test_review_only_cannot_be_satisfied_by_captain_word
test_review_only_rejections_are_typed_not_qualified
test_native_claude_aliases_are_anthropic
test_stored_family_metadata_cannot_retroactively_change_independence
test_typed_failures_distinguish_unavailable_and_invalid_input
test_default_fail_after_captain_word_precedence_is_unchanged
test_legacy_record_without_report_digest_omits_the_field
