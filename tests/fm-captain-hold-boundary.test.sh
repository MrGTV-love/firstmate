#!/usr/bin/env bash
# Public CLI boundary regressions. Each case is independently selectable so base
# failures and compatible legacy behavior have separate execution records.
set -u
# shellcheck source=tests/fm-captain-hold-lifecycle-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-lifecycle-helpers.sh"

boundary_cli() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "${FM_BOUNDARY_TEST_BIN:-$ROOT/bin/fm-captain-hold.sh}" "$@"
}

refusal_matrix() {  # <name> [boundary args...]
  local name=$1 mode home before after output rc
  shift
  for mode in new existing; do
    home=$(make_home "$name-$mode")
    if [ "$mode" = existing ]; then
      tasks_in "$home" add call 'Existing work' --kind ship --repo sample --body 'Unchanged work plan.' >/dev/null || fail 'fixture add failed'
    fi
    before=$(cat "$home/data/backlog.md")
    rc=0
    if [ "$mode" = new ]; then
      output=$(boundary_cli "$home" hold call --title 'New call' --reason 'Needs an owner ruling' "$@" 2>&1) || rc=$?
    else
      output=$(boundary_cli "$home" hold call --reason 'Needs an owner ruling' "$@" 2>&1) || rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "$name accepted on $mode path"
    assert_contains "$output" 'fm-captain-hold: Main decides' "$name did not use the normal refusal path routing the call to Main on $mode path"
    after=$(cat "$home/data/backlog.md")
    [ "$before" = "$after" ] || fail "$name changed backlog on $mode path"
  done
  pass "$name refuses both paths without changing the backlog"
}

test_missing_boundary() { refusal_matrix missing; }
test_unknown_boundary() { refusal_matrix unknown --boundary convenience --if-no 'Continue without the change'; }
test_boundary_case_sensitive() { refusal_matrix case --boundary Spend --if-no 'Continue without the change'; }
test_missing_if_no() { refusal_matrix no-action --boundary spend; }
test_empty_if_no() { refusal_matrix empty --boundary spend --if-no ''; }
test_whitespace_if_no() { refusal_matrix whitespace --boundary spend --if-no $' \t\n '; }

test_allowed_boundaries_round_trip() {
  local boundary mode home output stored action
  action=$'  Keep the existing path.\nDo not spend "anything".  '
  for boundary in credential spend destructive irreversible tool-denial owner-rule-change; do
    for mode in new existing; do
      home=$(make_home "valid-$boundary-$mode")
      if [ "$mode" = existing ]; then
        tasks_in "$home" add call 'Existing work' --kind ship --repo sample >/dev/null || fail 'fixture add failed'
        boundary_cli "$home" hold call --reason 'Needs an owner ruling' --boundary "$boundary" --if-no "$action" >/dev/null || fail "$boundary refused existing task"
      else
        boundary_cli "$home" hold call --title 'New call' --reason 'Needs an owner ruling' --boundary "$boundary" --if-no "$action" >/dev/null || fail "$boundary refused new task"
      fi
      output=$(tasks_in "$home" show call --full)
      assert_contains "$output" 'held: yes' "$boundary did not hold the task"
      assert_contains "$output" "Captain hold boundary: $boundary" "$boundary not stored on the task"
      stored=$(printf '%s\n' "$output" | sed -n 's/^  body: //p' | jq -r . | sed -n 's/^Captain hold if-no: //p' | jq -r .)
      [ "$stored" = "$action" ] || fail "$boundary if-no text did not round trip verbatim through tasks-axi show --full"
      boundary_cli "$home" hold call --reason 'Revisit later' --until 2099-01-01 >/dev/null || fail "$boundary re-hold required new flags"
      output=$(tasks_in "$home" show call --full)
      assert_contains "$output" "Captain hold boundary: $boundary" 're-hold lost its boundary'
      stored=$(printf '%s\n' "$output" | sed -n 's/^  body: //p' | jq -r . | sed -n 's/^Captain hold if-no: //p' | jq -r .)
      [ "$stored" = "$action" ] || fail 're-hold changed its if-no action'
    done
  done
  pass 'all six boundaries round trip on both filing paths and survive deferral'
}

# Ordinary CI uses a portable pre-boundary record written through the backend.
# The private compatibility proof explicitly supplies the immutable base writer;
# never silently call HEAD without its required new-hold flags.
legacy_boundary_hold() {  # <home> <id> <title-or-empty> <reason>
  local home=$1 id=$2 title=$3 reason=$4 stamp body_file
  local -a title_args=()
  [ -z "$title" ] || title_args=(--title "$title")
  if [ -n "${FM_BOUNDARY_BASE_BIN:-}" ]; then
    FM_BOUNDARY_TEST_BIN="$FM_BOUNDARY_BASE_BIN" boundary_cli "$home" hold "$id" \
      ${title_args[@]+"${title_args[@]}"} --reason "$reason"
    return
  fi
  stamp=${FM_CAPTAIN_HOLD_NOW:-2026-01-01T00:00:00Z}
  body_file="$home/legacy-$id.body"
  printf 'Captain hold set: %s\n' "$stamp" > "$body_file"
  if [ -n "$title" ]; then
    tasks_in "$home" add "$id" "$title" --kind captain --repo sample --body-file "$body_file" >/dev/null \
      || fail "could not create the portable legacy row $id"
  else
    tasks_in "$home" update "$id" --body-file "$body_file" >/dev/null \
      || fail "could not stamp the portable legacy row $id"
  fi
  tasks_in "$home" hold "$id" --reason "$reason" --kind captain
}

test_legacy_hold_reholds_and_answers() {
  local home output
  home=$(make_home legacy-boundary)
  legacy_boundary_hold "$home" old-call 'Old call' 'Legacy decision' >/dev/null || fail 'could not file legacy hold'
  output=$(tasks_in "$home" show old-call --full)
  assert_contains "$output" 'Captain hold set:' 'legacy fixture has no hold-set stamp'
  assert_not_contains "$output" 'Captain hold boundary:' 'fixture is not a legacy hold'
  boundary_cli "$home" open old-call >/dev/null || fail 'legacy hold no longer reads as open'
  boundary_cli "$home" reconcile list >/dev/null || fail 'legacy hold cannot be listed'
  boundary_cli "$home" hold old-call --reason 'Later' --until 2099-01-01 >/dev/null || fail 'legacy deferral required boundary flags'
  boundary_cli "$home" hold old-call --reason 'Later again' --until 2099-02-01 >/dev/null || fail 'deferred legacy re-hold required boundary flags'
  printf 'Use the existing path.\n' > "$home/answer.txt"
  boundary_cli "$home" answer old-call --decision-file "$home/answer.txt" >/dev/null || fail 'legacy hold cannot be answered'
  output=$(tasks_in "$home" show old-call --full)
  assert_contains "$output" 'state: done' 'legacy answer did not complete the call'
  assert_contains "$output" 'Use the existing path.' 'legacy answer was not recorded'
  write_scout_with_attested_inventory "$home" origin old-call
  boundary_cli "$home" complete origin old-call >/dev/null || fail 'legacy answered hold cannot satisfy complete'
  boundary_cli "$home" verify origin >/dev/null || fail 'legacy answered hold cannot satisfy verify'

  legacy_boundary_hold "$home" old-moot 'Old moot call' 'Legacy moot decision' >/dev/null || fail 'could not create moot legacy hold'
  printf 'Verified the premise no longer applies. No unanswered choice remains.\n' > "$home/evidence.txt"
  boundary_cli "$home" reconcile close old-moot --verified-outcome moot --evidence-file "$home/evidence.txt" >/dev/null || fail 'legacy hold cannot be reconciled'
  assert_contains "$(tasks_in "$home" show old-moot --full)" 'Resolution mode: reconciled' 'legacy reconciliation not stored'

  FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z legacy_boundary_hold "$home" old-withdraw 'Old withdrawn call' 'Legacy withdrawn decision' >/dev/null || fail 'could not create legacy withdrawal fixture'
  legacy_boundary_hold "$home" old-ruling 'Old ruling' 'Legacy ruling decision' >/dev/null || fail 'could not create legacy ruling'
  printf 'old-withdraw is moot; use the existing path.\n' > "$home/ruling.txt"
  boundary_cli "$home" answer old-ruling --decision-file "$home/ruling.txt" >/dev/null || fail 'legacy ruling cannot be answered'
  boundary_cli "$home" withdraw old-withdraw --ruling old-ruling --evidence-file "$home/evidence.txt" >/dev/null || fail 'legacy hold cannot be withdrawn'
  assert_contains "$(tasks_in "$home" show old-withdraw --full)" 'Resolution mode: withdrawn' 'legacy withdrawal not stored'
  if [ -n "${FM_BOUNDARY_BASE_BIN:-}" ]; then
    pass 'base-written holds remain readable, listable, deferrable, answerable, completable, reconcilable and withdrawable'
  else
    pass 'portable legacy records remain readable, listable, deferrable, answerable, completable, reconcilable and withdrawable'
  fi
}

test_released_hold_needs_a_new_boundary() {
  local home before output rc=0
  home=$(make_home released-boundary)
  tasks_in "$home" add work 'Previously gated work' --kind ship --repo sample >/dev/null || fail 'fixture add failed'
  legacy_boundary_hold "$home" work '' 'Legacy decision' >/dev/null || fail 'legacy hold failed'
  printf 'Proceed.\n' > "$home/answer.txt"
  boundary_cli "$home" answer work --decision-file "$home/answer.txt" --release >/dev/null || fail 'legacy release failed'
  before=$(tasks_in "$home" show work --full)
  output=$(boundary_cli "$home" hold work --reason 'A different decision' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail 'a resolved legacy hold bypassed the new-hold boundary gate'
  assert_contains "$output" 'fm-captain-hold: Main decides' 'resolved hold did not use the normal boundary refusal'
  [ "$(tasks_in "$home" show work --full)" = "$before" ] || fail 'refused new lifecycle changed the released row'
  pass 'a released legacy hold is not an exemption for a new captain call'
}

tests=(
  test_missing_boundary test_unknown_boundary test_boundary_case_sensitive
  test_missing_if_no test_empty_if_no test_whitespace_if_no
  test_allowed_boundaries_round_trip test_legacy_hold_reholds_and_answers
  test_released_hold_needs_a_new_boundary
)
fm_test_run_cases "${tests[@]}" -- "$@"
