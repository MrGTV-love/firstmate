#!/usr/bin/env bash
# Ad-hoc adversarial driver (not committed): reuses the suite's sandbox helpers and runs the REAL
# bin/fm-pr-auto-review.py, fm-review-record.py and fm-pr-merge.sh over fake gh and a FAKE reader.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M7637EDYXZNT9V5HPEF877ZM
. "$WT/tests/fm-pr-merge-helpers.sh"
eval "$(sed -n '2346,2517p;2620,2640p' "$WT/tests/fm-pr-merge.test.sh")"
export FM_AUTO_EVIDENCE=1

adv_pipeline_absent_only_ship_family_readers() {
  local case_dir
  case_dir=$(auto_case adv-pa-openai-only)
  rm -f "$case_dir/user-home/.no-mistakes/state.sqlite"
  auto_use_models "$case_dir" "$AUTO_TERRA" openai/gpt-5.2
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 0 "$(auto_calls "$case_dir")" "adv-pa-openai-only: an OpenAI reader must never be sent for an OpenAI ship plus unrecorded pipeline family"
  expect_code 0 "$(auto_merges "$case_dir")" "adv-pa-openai-only: nothing may merge"
  expect_code 1 "$(auto_notes "$case_dir" 'held: no eligible reader')" "adv-pa-openai-only: one no-eligible-reader hold"
  expect_code 0 "$(auto_notes "$case_dir" 'author family unknown')" "adv-pa-openai-only: not reported as author family unknown"
  auto_dump "$case_dir" "ADV pipeline-absent, only ship-family readers configured"
  pass "pipeline-absent: only ship-family readers configured -> no read, no merge, one no-eligible-reader hold"
}

adv_unknown_ship_second_reader_same_family_refused() {
  local case_dir
  case_dir=$(auto_case adv-unk-same mystery-9)
  auto_use_models "$case_dir" "$AUTO_SONNET" claude-opus-5-5
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code "$AUTO_SONNET" "$(auto_runner_models "$case_dir")" "adv-unk-same: only the first Anthropic read; a second Anthropic reader must not count"
  expect_code 0 "$(auto_merges "$case_dir")" "adv-unk-same: one known reader family must not merge an unknown author"
  expect_code 1 "$(auto_notes "$case_dir" 'held: no eligible reader')" "adv-unk-same: one no-eligible-reader hold"
  auto_dump "$case_dir" "ADV unknown ship author, two Anthropic readers configured"
  pass "unknown ship author: a second reader of the first reader's family is never sent, nothing merges"
}

adv_pipeline_absent_quota_switch_stays_outside_ship_family() {
  local case_dir
  case_dir=$(auto_case adv-pa-quota)
  rm -f "$case_dir/user-home/.no-mistakes/state.sqlite"
  auto_mode "$case_dir" "$AUTO_SONNET" quota
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code "$AUTO_SONNET,$AUTO_DEEPSEEK" "$(auto_runner_models "$case_dir")" "adv-pa-quota: after a quota failure the next reader is outside OpenAI, never Terra, never Sonnet again"
  expect_code 1 "$(auto_merges "$case_dir")" "adv-pa-quota: the DeepSeek PASS merges once"
  auto_dump "$case_dir" "ADV pipeline-absent, first outside reader hits quota"
  pass "pipeline-absent: a quota failure switches to the next reader outside the ship family and merges once"
}

adv_pipeline_absent_reader_fail_never_merges() {
  local case_dir
  case_dir=$(auto_case adv-pa-fail)
  rm -f "$case_dir/user-home/.no-mistakes/state.sqlite"
  auto_mode "$case_dir" "$AUTO_SONNET" fail
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"; auto_step "$case_dir"
  expect_code 1 "$(auto_calls "$case_dir")" "adv-pa-fail: one read"
  expect_code 0 "$(auto_merges "$case_dir")" "adv-pa-fail: a FAIL never merges"
  auto_dump "$case_dir" "ADV pipeline-absent, reader FAIL"
  pass "pipeline-absent: a FAIL from the outside reader never merges and asks no second read"
}

fm_test_run_cases adv_pipeline_absent_only_ship_family_readers adv_unknown_ship_second_reader_same_family_refused \
  adv_pipeline_absent_quota_switch_stays_outside_ship_family adv_pipeline_absent_reader_fail_never_merges -- "$@"
