#!/usr/bin/env bash
# Delay accounting through direct and keyed public answer paths, in fixture homes.
set -u
# shellcheck source=tests/fm-captain-hold-lifecycle-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-lifecycle-helpers.sh"

delay_cli() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "${FM_DELAY_TEST_BIN:-$ROOT/bin/fm-captain-hold.sh}" "$@"
}

delay_hold() {  # <home> <id> [recommendation args...]
  local home=$1 id=$2
  shift 2
  FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z delay_cli "$home" hold "$id" --title 'Authorize the charge' \
    --reason $'Decision sought: Authorize the charge\nBrief: Budget boundary\nRecommendation: Approve the charge because it is required\nAlternatives: Decline' \
    --boundary spend --if-no 'Continue without the paid operation' "$@" >/dev/null || fail 'could not file the delay fixture'
}

assert_delay() {  # <home> <id> <verbatim expected answer file>
  python3 - "$1/data/error-log.jsonl" "$2" "$3" <<'PY' || fail 'delay JSON did not match the public contract'
import datetime
import json
import pathlib
import sys
path, hold_id, answer_file = sys.argv[1:]
rows = pathlib.Path(path).read_text().splitlines()
assert len(rows) == 1, rows
row = json.loads(rows[0])
assert set(row) == {'kind', 'hold_id', 'hours_open', 'answer', 'at'}, row
assert row['kind'] == 'delay' and row['hold_id'] == hold_id, row
assert row['answer'] == pathlib.Path(answer_file).read_text()[:200], row
assert isinstance(row['hours_open'], (int, float)) and not isinstance(row['hours_open'], bool), row
assert row['at'].endswith('Z'), row
at = datetime.datetime.fromisoformat(row['at'].replace('Z', '+00:00'))
opened = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
assert row['hours_open'] == round((at - opened).total_seconds() / 3600, 2), row
PY
}

test_recommended_answer_logs_once() {
  local home
  home=$(make_home direct-delay)
  delay_hold "$home" call --recommendation 'Approve the € charge'
  printf '  Approve the € charge \n\n' > "$home/answer.txt"
  delay_cli "$home" answer call --decision-file "$home/answer.txt" >/dev/null || fail 'recommended answer failed'
  assert_delay "$home" call "$home/answer.txt"
  delay_cli "$home" answer call --decision-file "$home/answer.txt" >/dev/null || fail 'recommended answer replay failed'
  assert_delay "$home" call "$home/answer.txt"
  pass 'a recommendation match records the verbatim direct answer exactly once'
}

test_different_answer_logs_nothing() {
  local home
  home=$(make_home different-delay)
  delay_hold "$home" call --recommendation 'Approve the charge'
  printf 'Decline the charge.\n' > "$home/answer.txt"
  delay_cli "$home" answer call --decision-file "$home/answer.txt" >/dev/null || fail 'different answer failed'
  [ ! -s "$home/data/error-log.jsonl" ] || fail 'a differing answer was counted as delay'
  pass 'an answer differing from the recorded exact recommendation writes no delay'
}

test_reason_prose_is_not_a_recommendation_value() {
  local home
  home=$(make_home prose-delay)
  delay_hold "$home" call
  printf 'Approve the charge because it is required\n' > "$home/answer.txt"
  delay_cli "$home" answer call --decision-file "$home/answer.txt" >/dev/null || fail 'answer without an exact recommendation failed'
  [ ! -s "$home/data/error-log.jsonl" ] || fail 'four-part card prose was guessed as an exact recommendation'
  pass 'no machine-readable recommendation means no delay, even with card prose'
}

test_keyed_answer_logs_payload_once_in_own_home() {
  local home parent payload
  parent=$(make_home delay-parent)
  home=$(make_home delay-mate)
  printf 'delay-mate\n' > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"
  # This fixture deliberately has a display label unlike its exact answer value.
  FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z delay_cli "$home" hold call --owner captain --title 'Approve the charge' \
    --reason 'Spend approval' --boundary spend --if-no 'Continue without the charge' --recommendation 'approve' >/dev/null || fail 'mate hold failed'
  payload=approve
  printf '%s' "$payload" > "$home/answer.txt"
  printf 'call\t%s\tApprove the displayed charge\n' "$payload" | delay_cli "$home" answers --source 'fixture keyed intake' >/dev/null || fail 'keyed recommended answer failed'
  assert_delay "$home" call "$home/answer.txt"
  printf 'call\t%s\tApprove the displayed charge\n' "$payload" | delay_cli "$home" answers --source 'fixture keyed intake' >/dev/null || fail 'keyed recommended replay failed'
  assert_delay "$home" call "$home/answer.txt"
  [ ! -e "$parent/data/error-log.jsonl" ] || fail 'mate delay leaked to the parent home'
  pass 'keyed matches compare and log the payload once in the owning mate home only'
}

test_long_unicode_answer_is_cut_at_200_characters() {
  local home recommendation
  home=$(make_home long-delay)
  recommendation=$(printf '€%.0s' {1..210})
  delay_hold "$home" call --recommendation "$recommendation"
  printf '%s' "$recommendation" > "$home/answer.txt"
  delay_cli "$home" answer call --decision-file "$home/answer.txt" >/dev/null || fail 'long recommended answer failed'
  assert_delay "$home" call "$home/answer.txt"
  pass 'the answer is truncated at 200 Unicode characters, not bytes'
}

test_recommendation_is_kept_only_for_the_unresolved_hold() {
  local home output rc=0
  home=$(make_home recommendation-lifecycle)
  tasks_in "$home" add work 'Gated work' --kind ship --repo sample >/dev/null || fail 'fixture add failed'
  delay_cli "$home" hold work --reason 'First gate' --boundary spend --if-no 'Skip the paid operation' --recommendation 'approve' >/dev/null || fail 'first hold failed'
  delay_cli "$home" hold work --reason 'Later' --until 2099-01-01 >/dev/null || fail 'deferral failed'
  output=$(tasks_in "$home" show work --full)
  assert_contains "$output" 'Captain hold recommendation:' 'deferral lost the exact recommendation'
  printf 'decline' > "$home/answer.txt"
  delay_cli "$home" answer work --decision-file "$home/answer.txt" --release >/dev/null || fail 'first release failed'
  delay_cli "$home" hold work --reason 'New gate' --boundary spend --if-no 'Skip the second paid operation' >/dev/null || fail 'new hold failed'
  printf 'approve' > "$home/answer.txt"
  delay_cli "$home" answer work --decision-file "$home/answer.txt" --release >/dev/null || rc=$?
  [ "$rc" = 0 ] || fail 'new lifecycle answer failed'
  [ ! -s "$home/data/error-log.jsonl" ] || fail 'a new hold inherited a resolved recommendation'
  pass 'deferral keeps the recommendation, but a released task starts without it'
}

test_retry_finishes_an_interrupted_delay_append() {
  local home rc=0
  home=$(make_home retry-delay)
  delay_hold "$home" call --recommendation approve
  printf 'approve' > "$home/answer.txt"
  mkdir "$home/data/error-log.jsonl"
  delay_cli "$home" answer call --decision-file "$home/answer.txt" > "$home/refusal.txt" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail 'an unavailable delay log was silently ignored'
  assert_contains "$(tasks_in "$home" show call --full)" 'Captain decision:' 'append failure lost the durable captain answer'
  rmdir "$home/data/error-log.jsonl"
  delay_cli "$home" answer call --decision-file "$home/answer.txt" >/dev/null || fail 'answer replay did not finish the delayed append'
  assert_delay "$home" call "$home/answer.txt"
  delay_cli "$home" answer call --decision-file "$home/answer.txt" >/dev/null || fail 'second replay failed'
  assert_delay "$home" call "$home/answer.txt"
  pass 'an exact replay finishes an interrupted delay append without duplicating the record'
}

tests=(test_recommended_answer_logs_once test_different_answer_logs_nothing
  test_reason_prose_is_not_a_recommendation_value test_keyed_answer_logs_payload_once_in_own_home
  test_long_unicode_answer_is_cut_at_200_characters test_recommendation_is_kept_only_for_the_unresolved_hold
  test_retry_finishes_an_interrupted_delay_append)
fm_test_run_cases "${tests[@]}" -- "$@"
