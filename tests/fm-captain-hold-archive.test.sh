#!/usr/bin/env bash
# Archived answered-call gate regressions: the done-archive lookup, the
# archive-setting reader, and its refusals.
# Shared definitions and fixture setup live in fm-captain-hold-lifecycle-helpers.sh.
set -u

# shellcheck source=tests/fm-captain-hold-lifecycle-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-lifecycle-helpers.sh"

# Retention keeps one closed row, so the next closed row archives this one.
set_archive_retention() {  # <home> <archive-path-in-toml>
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
    "archive = \"$2\"" 'done_keep = 1' > "$1/.tasks.toml"
}

# Closes <id> with the captain's recorded answer for <origin>, then closes a
# filler row so retention archives it.
archive_an_answered_call() {  # <home> <id> <origin>
  local home=$1 id=$2 origin=$3
  run_captain "$home" hold "$id" --title "Captain call $id" \
    --reason "captain must decide $id" --repo sample --origin "$origin" >/dev/null \
    || fail "could not hold the archived-call fixture $id"
  printf 'Go with the recorded option for %s.\n' "$id" > "$home/answer-$id.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer-$id.txt" >/dev/null \
    || fail "could not answer the archived-call fixture $id"
  push_through_retention "$home" "retention-filler-$(printf '%s' "$id" | cksum | cut -d' ' -f1)"
}

# Closes <id> without any recorded captain answer, then archives it.
archive_an_unanswered_call() {  # <home> <id>
  local home=$1 id=$2
  tasks_in "$home" add "$id" "Closed with no answer $id" --kind captain --repo sample >/dev/null \
    || fail "could not create the unanswered fixture $id"
  tasks_in "$home" "done" "$id" >/dev/null || fail "could not close the unanswered fixture $id"
  push_through_retention "$home" "retention-filler-$(printf '%s' "$id" | cksum | cut -d' ' -f1)"
}

push_through_retention() {  # <home> <filler-id>
  tasks_in "$1" add "$2" "Filler closed row" --kind captain --repo sample >/dev/null \
    || fail "could not create the retention filler $2"
  tasks_in "$1" "done" "$2" >/dev/null || fail "could not close the retention filler $2"
}

test_archived_answered_call_resolves_through_the_gate() {
  local home scout id out rc=0
  home=$(make_home archived-answered)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-scout
  id=sample-archived-call
  archive_an_answered_call "$home" "$id" "$scout"
  assert_no_grep "$id" "$home/data/backlog.md" "retention did not move the call out of the backlog"
  assert_grep "$id" "$home/data/done-archive.md" "the call is not in the archive fixture"
  tasks_in "$home" show "$id" >/dev/null 2>&1 \
    && fail "the live backlog still resolves the archived call"
  write_scout_with_attested_inventory "$home" "$scout" "$id"

  out=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "verify refused an answered call that retention archived: $out"
  rc=0
  out=$(run_captain "$home" complete "$scout" --none 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "complete refused an answered call that retention archived: $out"
  assert_contains "$out" "[answered and archived: $id]" \
    "the attestation does not name the archive as its evidence"
  assert_grep "decision_keys=$id" "$home/state/$scout.meta" \
    "the archived call was not recorded in the scout inventory"
  pass "the completion gate resolves an answered call that retention archived"
}

test_archive_is_read_from_the_configured_path() {
  local home scout id out rc=0
  home=$(make_home archived-custom-path)
  mkdir -p "$home/data/closed"
  set_archive_retention "$home" data/closed/answered.md
  scout=sample-archive-path-scout
  id=sample-custom-archive-call
  archive_an_answered_call "$home" "$id" "$scout"
  assert_absent "$home/data/done-archive.md" "the fixture wrote the default archive path"
  assert_grep "$id" "$home/data/closed/answered.md" "the call is not in the configured archive"
  write_scout_with_attested_inventory "$home" "$scout" "$id"

  out=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "verify did not read the archive named by .tasks.toml: $out"
  pass "the archive lookup follows the archive path in .tasks.toml"
}

test_archived_call_without_a_recorded_answer_refuses() {
  local home scout id out rc=0
  home=$(make_home archived-unanswered)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-unanswered-scout
  id=sample-archived-no-answer
  archive_an_unanswered_call "$home" "$id"
  assert_grep "$id" "$home/data/done-archive.md" "the unanswered call is not in the archive fixture"
  write_scout_with_attested_inventory "$home" "$scout" "$id"

  out=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify accepted an archived call with no recorded captain answer"
  assert_contains "$out" "archived without a recorded captain answer" \
    "the refusal does not say the archived call has no recorded answer"
  rc=0
  out=$(run_captain "$home" complete "$scout" "$id" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "complete accepted an archived call with no recorded captain answer"
  pass "an archived call with no recorded captain answer still refuses"
}

test_call_absent_from_backlog_and_archive_keeps_its_refusal() {
  local home scout out rc=0
  home=$(make_home archived-absent)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-absent-scout
  archive_an_answered_call "$home" sample-some-other-call "$scout"
  write_scout_with_attested_inventory "$home" "$scout" sample-never-existed

  out=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify accepted a call that exists nowhere"
  assert_contains "$out" "no captain-held task sample-never-existed and no migrated hold for it" \
    "a key absent from the backlog and the archive lost its existing refusal"
  rm -f "$home/data/done-archive.md"
  rc=0
  out=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify accepted a call once the archive file was gone"
  assert_contains "$out" "no captain-held task sample-never-existed" \
    "a missing archive file changed the existing refusal"
  pass "a call absent from the backlog and the archive keeps the existing refusal"
}

test_archived_call_held_for_another_origin_refuses() {
  local home scout id out rc=0
  home=$(make_home archived-other-origin)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-origin-scout
  id=sample-archived-other-origin
  archive_an_answered_call "$home" "$id" sample-someone-elses-scout
  tasks_in "$home" add sample-someone-elses-scout "The other investigation" --kind scout \
    --repo sample >/dev/null || fail "could not create the other origin"
  tasks_in "$home" add "$scout" "This investigation" --kind scout --repo sample >/dev/null \
    || fail "could not create this origin"
  write_scout_with_attested_inventory "$home" "$scout" "$id"

  out=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify accepted an archived call held for another origin"
  assert_contains "$out" "was held for origin sample-someone-elses-scout, not $scout" \
    "the archived call skipped the origin mismatch check"
  pass "an archived call held for another origin still refuses"
}

test_live_rows_resolve_exactly_as_before_the_archive_lookup() {
  local home scout out rc=0
  home=$(make_home archived-live-unchanged)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-live-scout
  # One call is still held, one is answered and still inside retention.
  run_captain "$home" hold sample-live-held --title "Held call" \
    --reason "captain must decide" --repo sample --origin "$scout" >/dev/null \
    || fail "could not hold the live fixture"
  run_captain "$home" hold sample-live-answered --title "Answered call" \
    --reason "captain must decide" --repo sample --origin "$scout" >/dev/null \
    || fail "could not hold the live answered fixture"
  printf 'Go.\n' > "$home/live-answer.txt"
  run_captain "$home" answer sample-live-answered --decision-file "$home/live-answer.txt" >/dev/null \
    || fail "could not answer the live fixture"
  write_scout_with_attested_inventory "$home" "$scout" "sample-live-answered,sample-live-held"

  out=$(run_captain "$home" complete "$scout" --none 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "complete refused live rows: $out"
  assert_not_contains "$out" "answered and archived" \
    "a live row was reported as archive evidence"
  pass "live held and live closed rows resolve exactly as before"
}

test_scout_teardown_gate_follows_the_archived_answer() {
  local home answered unanswered scout rc
  home=$(make_home archived-teardown)
  set_archive_retention "$home" data/done-archive.md
  answered=sample-archive-teardown-answered
  unanswered=sample-archive-teardown-unanswered
  scout=sample-archive-teardown-scout
  archive_an_answered_call "$home" "$answered" "$scout"
  archive_an_unanswered_call "$home" "$unanswered"
  mkdir -p "$home/data/$scout" "$home/projects/$scout"
  tasks_in "$home" add "$scout" "Investigate the archived calls" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the teardown scout"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" "worktree=$home/projects/$scout" \
    "project=$home/projects/sample" "harness=codex" "kind=scout" \
    "mode=scout" "spawn_gen=fixture-$scout" "decisions_reviewed=1" \
    "decision_keys=$unanswered"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Report\n\nThe investigation finished.\n' > "$home/data/$scout/report.md"

  rc=0
  run_teardown "$home" "$scout" > "$home/teardown-blocked.out" 2> "$home/teardown-blocked.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "teardown retired a scout whose archived call has no recorded answer"
  assert_grep "has not passed the captain-call completion gate" "$home/teardown-blocked.err" \
    "teardown did not name the completion gate for the unanswered archived call"
  assert_present "$home/state/$scout.meta" "the refused teardown removed the scout record"

  printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$answered" >> "$home/state/$scout.meta"
  rc=0
  run_teardown "$home" "$scout" > "$home/teardown.out" 2> "$home/teardown.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "teardown refused a scout whose only call is archived and answered: $(cat "$home/teardown.err")"
  assert_absent "$home/state/$scout.meta" "the passing teardown left the scout record behind"
  pass "scout teardown passes an archived answered call and blocks an archived unanswered one"
}

# Closes a done captain row whose body is <body-file>, then archives it.
archive_a_done_row_with_body() {  # <home> <id> <body-file>
  local home=$1 id=$2 body=$3
  tasks_in "$home" add "$id" "Done row $id" --kind captain --repo sample \
    --body-file "$body" >/dev/null || fail "could not create the fixture row $id"
  tasks_in "$home" "done" "$id" >/dev/null || fail "could not close the fixture row $id"
  push_through_retention "$home" "retention-filler-$(printf '%s' "$id" | cksum | cut -d' ' -f1)"
}

# Both completion entrypoints must refuse <id>; the refusal text must contain <reason>.
assert_gate_refuses_archived() {  # <home> <scout> <id> <reason>
  local home=$1 scout=$2 id=$3 reason=$4 out rc=0
  write_scout_with_attested_inventory "$home" "$scout" "$id"
  out=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify accepted archived call $id: $out"
  assert_contains "$out" "$reason" "the verify refusal for $id does not give the reason: $out"
  rc=0
  out=$(run_captain "$home" complete "$scout" --none 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "complete --none accepted archived call $id: $out"
  assert_contains "$out" "$reason" "the complete refusal for $id does not give the reason: $out"
}

test_archived_evidence_only_close_refuses() {
  local home scout id archive
  home=$(make_home archived-evidence-only)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-evidence-scout
  id=sample-archived-moot-call
  archive="$home/data/done-archive.md"
  tasks_in "$home" add "$scout" "The investigation" --kind scout --repo sample >/dev/null \
    || fail "could not create the evidence-only origin"
  run_captain "$home" hold "$id" --title "Captain call $id" --reason "captain must decide $id" \
    --repo sample --origin "$scout" >/dev/null || fail "could not hold $id"
  request_reconciles "$home" archive-evidence-source "$id" || fail "could not request the reconciliation"
  printf 'Nothing is pending. No captain answer was given.\n' > "$home/evidence-$id.txt"
  run_captain "$home" reconcile close "$id" --evidence-file "$home/evidence-$id.txt" \
    --verified-outcome moot >/dev/null || fail "could not close $id on evidence"
  push_through_retention "$home" retention-filler-evidence
  assert_grep "$id" "$archive" "the evidence-closed call is not in the archive fixture"
  assert_grep "Reconciliation evidence:" "$archive" "the archived call lost its evidence record"
  assert_no_grep "Captain decision:" "$archive" "the evidence-closed fixture carries an answer record"
  assert_gate_refuses_archived "$home" "$scout" "$id" "only reconciliation evidence, not a recorded captain answer"
  pass "a call closed only by reconcile evidence and then archived still refuses"
}

test_archived_row_quoting_the_record_markers_refuses() {
  local home scout n digest
  home=$(make_home archived-quoted-markers)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-quote-scout
  digest=$(printf '%064d' 7 | tr 0 a)
  # One line that quotes both markers in order.
  printf 'Notes: the "Resolution recorded by fm-captain-hold." line and a "Captain decision:" line.\n' \
    > "$home/quote-inline.txt"
  # The whole shape, but not at line starts.
  printf 'Quoted record:\n  > Resolution recorded by fm-captain-hold.\n> Decision digest: %s\n> Resolution mode: answered\n>\n> Captain decision:\n> Go.\n' \
    "$digest" > "$home/quote-indented.txt"
  # The whole shape with no answer text under the label.
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: answered\n\nCaptain decision:\n\n' \
    "$digest" > "$home/quote-empty.txt"
  # A mode that is not a recorded answer.
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: wished\n\nCaptain decision:\nGo.\n' \
    "$digest" > "$home/quote-mode.txt"
  # An older genuine answer under a newer evidence-only record: the newest record decides.
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: reconciled\n\nReconciliation evidence:\nMoot.\n\nResolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: answered\n\nCaptain decision:\nGo.\n' \
    "$digest" "$digest" > "$home/quote-stacked.txt"
  for n in inline indented empty mode stacked; do
    archive_a_done_row_with_body "$home" "sample-quoted-$n" "$home/quote-$n.txt"
    assert_grep "sample-quoted-$n" "$home/data/done-archive.md" "the quoted-marker row $n is not archived"
  done
  push_through_retention "$home" retention-filler-quoted-last
  for n in inline indented empty mode; do
    assert_gate_refuses_archived "$home" "$scout" "sample-quoted-$n" "archived without a recorded captain answer"
  done
  assert_gate_refuses_archived "$home" "$scout" sample-quoted-stacked "only reconciliation evidence"
  pass "an archived body that only quotes or imitates the record markers still refuses"
}

# Writes a body in the shape the retired fm-decision-hold.sh recorded. An empty
# <routed-line> or <mode-line> leaves that line out.
write_retired_record() {  # <file> <routed-line> <mode-line> <answer>
  local file=$1 routed=$2 mode=$3 answer=$4
  {
    printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\n' \
      "$(printf '%064d' 5 | tr 0 c)"
    [ -z "$routed" ] || printf '%s\n' "$routed"
    [ -z "$mode" ] || printf '%s\n' "$mode"
    printf '\nCaptain decision:\n%s\n\nRouted work:\n(none)\n' "$answer"
  } > "$file"
}

test_archived_retired_decision_hold_records_resolve() {
  local home scout out rc=0
  home=$(make_home archived-retired-pass)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-retired-scout
  write_retired_record "$home/retired-declined.txt" 'Routed identities: (none)' \
    'Resolution mode: declined' 'Dropped by the captain.'
  write_retired_record "$home/retired-modeless.txt" 'Routed identities: (none)' '' \
    'Go with option B.'
  write_retired_record "$home/retired-routed.txt" 'Routed identities: sample-routed-work' \
    'Resolution mode: routed' 'Route it to the sample work.'
  archive_a_done_row_with_body "$home" sample-retired-declined "$home/retired-declined.txt"
  archive_a_done_row_with_body "$home" sample-retired-modeless "$home/retired-modeless.txt"
  archive_a_done_row_with_body "$home" sample-retired-routed "$home/retired-routed.txt"
  push_through_retention "$home" retention-filler-retired-last
  assert_grep "sample-retired-declined" "$home/data/done-archive.md" "the declined retired row is not archived"
  assert_grep "sample-retired-modeless" "$home/data/done-archive.md" "the mode-less retired row is not archived"
  assert_grep "sample-retired-routed" "$home/data/done-archive.md" "the routed retired row is not archived"
  write_scout_with_attested_inventory "$home" "$scout" \
    "sample-retired-declined,sample-retired-modeless,sample-retired-routed"

  out=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "verify refused an archived retired decision-hold record: $out"
  rc=0
  out=$(run_captain "$home" complete "$scout" --none 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "complete refused an archived retired decision-hold record: $out"
  assert_contains "$out" "[answered and archived: sample-retired-declined sample-retired-modeless sample-retired-routed]" \
    "the retired records were not all attested from the archive"
  pass "archived records of the retired decision hold, declined and mode-less included, resolve"
}

test_archived_retired_decision_hold_records_that_are_not_answers_refuse() {
  local home scout n
  home=$(make_home archived-retired-refuse)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-retired-refuse-scout
  write_retired_record "$home/retired-reconciled.txt" 'Routed identities: (none)' \
    'Resolution mode: reconciled' 'Nothing is pending.'
  write_retired_record "$home/retired-empty.txt" 'Routed identities: (none)' \
    'Resolution mode: declined' ''
  write_retired_record "$home/retired-noroutes.txt" '' 'Resolution mode: declined' \
    'Dropped by the captain.'
  write_retired_record "$home/retired-emptyroutes.txt" 'Routed identities: ' \
    'Resolution mode: declined' 'Dropped by the captain.'
  write_retired_record "$home/retired-badmode.txt" 'Routed identities: (none)' \
    'Resolution mode: released' 'Go.'
  for n in reconciled empty noroutes emptyroutes badmode; do
    archive_a_done_row_with_body "$home" "sample-retired-$n" "$home/retired-$n.txt"
    assert_grep "sample-retired-$n" "$home/data/done-archive.md" "the retired row $n is not archived"
  done
  push_through_retention "$home" retention-filler-retired-refuse-last
  assert_gate_refuses_archived "$home" "$scout" sample-retired-reconciled \
    "only reconciliation evidence, not a recorded captain answer"
  for n in empty noroutes emptyroutes badmode; do
    assert_gate_refuses_archived "$home" "$scout" "sample-retired-$n" \
      "archived without a recorded captain answer"
  done
  pass "an archived retired record that is evidence-only, empty, or malformed still refuses"
}

test_archived_answer_after_leading_blank_lines_resolves() {
  local home scout out rc=0
  home=$(make_home archived-blank-lead)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-blank-lead-scout
  run_captain "$home" hold sample-blank-lead-one --title "Captain call one" \
    --reason "captain must decide" --repo sample --origin "$scout" >/dev/null \
    || fail "could not hold the first blank-led fixture"
  printf '\nUse option B.\n' > "$home/blank-lead-one.txt"
  run_captain "$home" answer sample-blank-lead-one --decision-file "$home/blank-lead-one.txt" >/dev/null \
    || fail "could not answer the first blank-led fixture"
  run_captain "$home" hold sample-blank-lead-two --title "Captain call two" \
    --reason "captain must decide" --repo sample --origin "$scout" >/dev/null \
    || fail "could not hold the second blank-led fixture"
  printf '\n\n\nUse option C.\n' > "$home/blank-lead-two.txt"
  run_captain "$home" answer sample-blank-lead-two --decision-file "$home/blank-lead-two.txt" >/dev/null \
    || fail "could not answer the second blank-led fixture"
  push_through_retention "$home" retention-filler-blank-lead-first
  push_through_retention "$home" retention-filler-blank-lead-second
  assert_grep "sample-blank-lead-one" "$home/data/done-archive.md" "the first blank-led call is not archived"
  assert_grep "sample-blank-lead-two" "$home/data/done-archive.md" "the second blank-led call is not archived"
  write_scout_with_attested_inventory "$home" "$scout" "sample-blank-lead-one,sample-blank-lead-two"

  out=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "verify refused an archived answer that starts with blank lines: $out"
  rc=0
  out=$(run_captain "$home" complete "$scout" --none 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "complete refused an archived answer that starts with blank lines: $out"
  pass "an archived answer whose text starts with blank lines resolves"
}

test_archived_record_with_only_blank_lines_after_the_label_refuses() {
  local home scout digest
  home=$(make_home archived-blank-only)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-blank-only-scout
  digest=$(printf '%064d' 9 | tr 0 d)
  # Blank lines to the end of the body.
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: answered\n\nCaptain decision:\n\n\n\n' \
    "$digest" > "$home/blank-only-end.txt"
  # Blank lines, then an older genuine record: its text is not this record's answer.
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: answered\n\nCaptain decision:\n\n\nResolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: answered\n\nCaptain decision:\nGo.\n' \
    "$digest" "$digest" > "$home/blank-only-stacked.txt"
  # The same, with the older record written by the retired decision hold.
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: answered\n\nCaptain decision:\n\nResolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: (none)\nResolution mode: declined\n\nCaptain decision:\nGo.\n\nRouted work:\n(none)\n' \
    "$digest" "$digest" > "$home/blank-only-retired.txt"
  archive_a_done_row_with_body "$home" sample-blank-only-end "$home/blank-only-end.txt"
  archive_a_done_row_with_body "$home" sample-blank-only-stacked "$home/blank-only-stacked.txt"
  archive_a_done_row_with_body "$home" sample-blank-only-retired "$home/blank-only-retired.txt"
  push_through_retention "$home" retention-filler-blank-only-last
  assert_grep "sample-blank-only-retired" "$home/data/done-archive.md" "the blank-only rows are not archived"
  assert_gate_refuses_archived "$home" "$scout" sample-blank-only-end "archived without a recorded captain answer"
  assert_gate_refuses_archived "$home" "$scout" sample-blank-only-stacked "archived without a recorded captain answer"
  assert_gate_refuses_archived "$home" "$scout" sample-blank-only-retired "archived without a recorded captain answer"
  pass "an archived record with only blank lines after the label still refuses"
}

test_archived_released_work_item_resolves_through_the_gate() {
  local home scout id
  home=$(make_home archived-released)
  set_archive_retention "$home" data/done-archive.md
  scout=sample-archive-release-scout
  id=sample-archived-released-work
  run_captain "$home" hold "$id" --title "Gated work $id" --reason "captain go needed" \
    --repo sample --origin "$scout" >/dev/null || fail "could not hold $id"
  printf 'Proceed as planned.\n' > "$home/release-$id.txt"
  run_captain "$home" answer "$id" --decision-file "$home/release-$id.txt" --release >/dev/null \
    || fail "could not release $id"
  tasks_in "$home" "done" "$id" >/dev/null || fail "could not finish the released work item"
  push_through_retention "$home" retention-filler-released
  assert_grep "Resolution mode: released" "$home/data/done-archive.md" \
    "the archived work item lost its release record"
  write_scout_with_attested_inventory "$home" "$scout" "$id"
  run_captain "$home" verify "$scout" >/dev/null 2>&1 \
    || fail "verify refused a released work item that retention archived"
  run_captain "$home" complete "$scout" --none 2>&1 | grep -q "answered and archived: $id" \
    || fail "complete did not attest the archived released work item"
  pass "a call answered through the release path still resolves after it is archived"
}

# The home's .tasks.toml names no archive and ~/.tasks-axi/config.toml does.
use_user_level_archive() {  # <home> <user-home> <archive-path>
  local home=$1 userhome=$2 archive=$3
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
    'done_keep = 1' > "$home/.tasks.toml"
  mkdir -p "$userhome/.tasks-axi"
  printf '[markdown]\narchive = "%s"\n' "$archive" > "$userhome/.tasks-axi/config.toml"
}

test_user_level_only_archive_path_refuses() {
  local home userhome scout id out rc=0
  home=$(make_home archived-user-level-only)
  userhome="$home/userhome"
  scout=sample-archive-userlevel-scout
  id=sample-archived-userlevel-call
  use_user_level_archive "$home" "$userhome" "$home/data/user-archive.md"
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: answered\n\nCaptain decision:\nGo.\n' \
    "$(printf '%064d' 3 | tr 0 b)" > "$home/answered-body.txt"
  HOME="$userhome" archive_a_done_row_with_body "$home" "$id" "$home/answered-body.txt"
  assert_grep "$id" "$home/data/user-archive.md" "retention did not follow the user-level archive"
  assert_absent "$home/data/done-archive.md" "the fixture wrote the default archive"
  write_scout_with_attested_inventory "$home" "$scout" "$id"
  out=$(HOME="$userhome" run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify accepted a call archived through a user-level archive path: $out"
  assert_contains "$out" "set outside this home's .tasks.toml" \
    "the refusal does not say the archive path is set outside .tasks.toml: $out"
  assert_contains "$out" "is not read" "the refusal does not say the archive is not read: $out"
  pass "an archive path set only in the user-level config refuses"
}

test_stale_default_archive_does_not_stand_in_for_the_user_level_archive() {
  local home userhome scout id first second
  home=$(make_home archived-stale-default)
  userhome="$home/userhome"
  scout=sample-archive-stale-scout
  id=sample-archived-stale-call
  # First life: answered, then archived into the default archive file.
  set_archive_retention "$home" data/done-archive.md
  archive_an_answered_call "$home" "$id" "$scout"
  assert_grep "Captain decision:" "$home/data/done-archive.md" "the stale answered row is not in the default archive"
  # Later the archive moves to a user-level path, and the same id closes again unanswered.
  use_user_level_archive "$home" "$userhome" "$home/data/user-archive.md"
  tasks_in "$home" add "$id" "Closed again with no answer" --kind captain --repo sample >/dev/null \
    || fail "could not recreate $id"
  HOME="$userhome" tasks_in "$home" "done" "$id" >/dev/null || fail "could not close the new $id"
  HOME="$userhome" push_through_retention "$home" retention-filler-stale-second
  assert_grep "$id" "$home/data/user-archive.md" "retention did not archive the newer row at the user-level path"
  write_scout_with_attested_inventory "$home" "$scout" "$id"

  first=0
  HOME="$userhome" run_captain "$home" verify "$scout" >"$home/stale.out" 2>&1 || first=$?
  [ "$first" -ne 0 ] || fail "verify passed from the stale default archive: $(cat "$home/stale.out")"
  assert_grep "set outside this home's .tasks.toml" "$home/stale.out" \
    "the stale-default refusal does not name the unread archive path"
  second=0
  HOME="$userhome" run_captain "$home" complete "$scout" --none >"$home/stale-complete.out" 2>&1 || second=$?
  [ "$second" -ne 0 ] || fail "complete --none passed from the stale default archive"
  pass "a stale default archive cannot stand in for an archive path the gate does not read"
}

# Gate checks for the quoted archive-path tests.
assert_gate_resolves() {  # <home> <scout> <id> <what>
  local out rc=0
  out=$(run_captain "$1" verify "$2" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "verify refused $4: $out"
  rc=0
  out=$(run_captain "$1" complete "$2" --none 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "complete refused $4: $out"
  assert_contains "$out" "[answered and archived: $3]" "the attestation does not name the archive for $4"
}

assert_gate_refuses_both() {  # <home> <scout> <what> [reason]
  local out rc=0
  out=$(run_captain "$1" verify "$2" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify passed $3: $out"
  [ -z "${4:-}" ] || assert_contains "$out" "$4" "the verify refusal for $3 lacks its reason: $out"
  rc=0
  out=$(run_captain "$1" complete "$2" --none 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "complete --none passed $3: $out"
  [ -z "${4:-}" ] || assert_contains "$out" "$4" "the complete refusal for $3 lacks its reason: $out"
}

test_archive_path_with_a_hash_is_read_whole() {
  local home scout id
  home=$(make_home archived-hash-path)
  scout=sample-archive-hash-scout
  id=sample-hash-archive-call
  # An older answered row sits in the truncated path `data/closed`; the
  # configured path `data/closed#later.md` holds a later row of the same id.
  set_archive_retention "$home" data/closed
  archive_an_answered_call "$home" "$id" "$scout"
  assert_grep "Captain decision:" "$home/data/closed" "the older answered row is not in the truncated path"
  set_archive_retention "$home" 'data/closed#later.md'
  tasks_in "$home" add "$id" "Closed again with no answer" --kind captain --repo sample >/dev/null \
    || fail "could not recreate $id"
  tasks_in "$home" "done" "$id" >/dev/null || fail "could not close the later $id"
  push_through_retention "$home" retention-filler-hash-second
  assert_grep "$id" "$home/data/closed#later.md" "retention did not archive the later row at the path with a hash"
  write_scout_with_attested_inventory "$home" "$scout" "$id"
  assert_gate_refuses_both "$home" "$scout" "a stale answer from the path cut at its hash"

  # The same configured path with an answered row in it resolves: the whole path is read.
  home=$(make_home archived-hash-path-answered)
  scout=sample-archive-hash-answered-scout
  id=sample-hash-answered-call
  set_archive_retention "$home" 'data/closed#later.md'
  archive_an_answered_call "$home" "$id" "$scout"
  assert_grep "Captain decision:" "$home/data/closed#later.md" "the answered row is not in the path with a hash"
  assert_absent "$home/data/closed" "the fixture wrote the truncated path"
  write_scout_with_attested_inventory "$home" "$scout" "$id"
  assert_gate_resolves "$home" "$scout" "$id" "an answered call archived at a path with a hash"
  pass "a hash inside the quoted archive path is read as part of the path"
}

test_single_quoted_archive_path_with_a_hash_is_read_whole() {
  local home scout id
  home=$(make_home archived-single-quote-hash)
  scout=sample-archive-single-scout
  id=sample-single-quote-call
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
    "archive = 'data/single#quote.md'" 'done_keep = 1' > "$home/.tasks.toml"
  archive_an_answered_call "$home" "$id" "$scout"
  assert_grep "Captain decision:" "$home/data/single#quote.md" "the answered row is not in the single-quoted path"
  write_scout_with_attested_inventory "$home" "$scout" "$id"
  assert_gate_resolves "$home" "$scout" "$id" "an answered call archived at a single-quoted path with a hash"
  pass "a single-quoted archive path with a hash is read whole"
}

test_trailing_comment_after_the_archive_path_still_works() {
  local home scout id
  home=$(make_home archived-trailing-comment)
  scout=sample-archive-comment-scout
  id=sample-trailing-comment-call
  printf '%s\n' 'backend = "markdown"' '' '[markdown] # the markdown backend' 'path = "data/backlog.md"' \
    'archive = "data/commented.md"   # closed calls' 'done_keep = 1' > "$home/.tasks.toml"
  archive_an_answered_call "$home" "$id" "$scout"
  assert_grep "Captain decision:" "$home/data/commented.md" "the answered row is not in the commented path"
  write_scout_with_attested_inventory "$home" "$scout" "$id"
  assert_gate_resolves "$home" "$scout" "$id" "an answered call whose archive setting has a trailing comment"
  pass "a trailing comment after the archive path still works"
}

# Writes a .tasks.toml whose markdown settings are the given lines (everything
# after the backend line), for the TOML spellings the gate must read.
write_tasks_toml() {  # <home> <line>...
  local home=$1
  shift
  { printf '%s\n' 'backend = "markdown"'; printf '%s\n' "$@"; } > "$home/.tasks.toml"
}

# An older answered row sits in the default archive; <toml-lines> then send
# retention to data/redirected.md, where a later row of the same id is closed
# with no answer. Leaves the scout ready for the gate.
setup_stale_default_then_redirected() {  # <home> <scout> <id> <toml-line>...
  local home=$1 scout=$2 id=$3
  shift 3
  set_archive_retention "$home" data/done-archive.md
  archive_an_answered_call "$home" "$id" "$scout"
  assert_grep "Captain decision:" "$home/data/done-archive.md" "the older answered row is not in the default archive"
  write_tasks_toml "$home" "$@"
  tasks_in "$home" add "$id" "Closed again with no answer" --kind captain --repo sample >/dev/null \
    || fail "could not recreate $id"
  tasks_in "$home" "done" "$id" >/dev/null || fail "could not close the later $id"
  push_through_retention "$home" "retention-filler-redirect-$(printf '%s' "$id" | cksum | cut -d' ' -f1)"
  assert_grep "$id" "$home/data/redirected.md" "retention did not archive the later row at the redirected path"
  write_scout_with_attested_inventory "$home" "$scout" "$id"
}

# The same spelling with the answered row in the redirected archive resolves.
setup_answered_in_redirected() {  # <home> <scout> <id> <toml-line>...
  local home=$1 scout=$2 id=$3
  shift 3
  write_tasks_toml "$home" "$@"
  archive_an_answered_call "$home" "$id" "$scout"
  assert_grep "Captain decision:" "$home/data/redirected.md" "the answered row is not in the redirected archive"
  assert_absent "$home/data/done-archive.md" "the fixture wrote the default archive"
  write_scout_with_attested_inventory "$home" "$scout" "$id"
}

test_spaced_table_header_redirects_the_archive() {
  local home scout id
  home=$(make_home archived-spaced-header)
  scout=sample-archive-spaced-scout
  id=sample-spaced-header-call
  setup_stale_default_then_redirected "$home" "$scout" "$id" '' '[ markdown ]' \
    'path = "data/backlog.md"' 'archive = "data/redirected.md"' 'done_keep = 1'
  assert_gate_refuses_both "$home" "$scout" "a stale answer from the default archive behind a spaced table header"

  home=$(make_home archived-spaced-header-answered)
  scout=sample-archive-spaced-answered-scout
  id=sample-spaced-answered-call
  setup_answered_in_redirected "$home" "$scout" "$id" '' '[ markdown ]' \
    'path = "data/backlog.md"' 'archive = "data/redirected.md"' 'done_keep = 1'
  assert_gate_resolves "$home" "$scout" "$id" "an answered call archived behind a spaced table header"
  pass "a spaced [ markdown ] table header redirects the archive the gate reads"
}

# The gate's reader is cut out of the script and run on fixture files, so every
# spelling is checked directly, including the ones tasks-axi 0.2.6 cannot take.
test_archive_setting_reader_parses_every_toml_spelling() {
  local file="$TMP_ROOT/reader.toml" out rc case_name want
  eval "$(sed -n '/^captain_markdown_archive_setting() {/,/^}/p' "$ROOT/bin/fm-captain-hold.sh")"
  for case_name in table spaced-table spaced-table-comment hash single-quote comment crlf unset other-table; do
    want='data/read.md'
    case $case_name in
      table) printf '%s\n' '[markdown]' 'archive = "data/read.md"' > "$file" ;;
      spaced-table) printf '%s\n' '[ markdown ]' 'archive = "data/read.md"' > "$file" ;;
      spaced-table-comment) printf '%s\n' '[  markdown  ] # backend' 'archive = "data/read.md"' > "$file" ;;
      hash) printf '%s\n' '[markdown]' 'archive = "data/read#me.md"' > "$file"; want='data/read#me.md' ;;
      single-quote) printf '%s\n' '[markdown]' "archive = 'data/read.md' # closed calls" > "$file" ;;
      comment) printf '%s\n' '[markdown] # backend' 'archive = "data/read.md"   # closed calls' > "$file" ;;
      crlf) printf '[markdown]\r\narchive = "data/read.md"\r\n' > "$file" ;;
      unset) printf '%s\n' '[markdown]' 'path = "data/backlog.md"' > "$file"; want= ;;
      other-table) printf '%s\n' '[other]' 'archive = "data/elsewhere.md"' > "$file"; want= ;;
    esac
    rc=0
    out=$(captain_markdown_archive_setting "$file") || rc=$?
    [ "$rc" -eq 0 ] || fail "the reader refused the $case_name spelling (exit $rc)"
    [ "$out" = "$want" ] || fail "the reader read '$out' for the $case_name spelling, wanted '$want'"
  done
  for case_name in inline quoted-header single-quoted-header dotted dotted-with-header-text duplicate-tables duplicate-key dotted-and-table unterminated unquoted trailing-text empty non-string non-table escape backslash-backslash tab-escape newline-escape triple-quote multi-line not-toml; do
    case $case_name in
      inline) printf '%s\n' 'markdown = { archive = "data/a.md" }' > "$file" ;;
      quoted-header) printf '%s\n' '["markdown"]' 'archive = "data/a.md"' > "$file" ;;
      single-quoted-header) printf '%s\n' "['markdown']" 'archive = "data/a.md"' > "$file" ;;
      dotted) printf '%s\n' 'markdown.archive = "data/a.md"' > "$file" ;;
      dotted-with-header-text) printf '%s\n' 'markdown.archive = "data/a.md"' '# [markdown]' > "$file" ;;
      duplicate-tables) printf '%s\n' '[markdown]' 'archive = "data/a.md"' '[markdown]' 'done_keep = 1' > "$file" ;;
      duplicate-key) printf '%s\n' '[markdown]' 'archive = "data/a.md"' 'archive = "data/b.md"' > "$file" ;;
      dotted-and-table) printf '%s\n' 'markdown.archive = "data/a.md"' '[markdown]' 'done_keep = 1' > "$file" ;;
      unterminated) printf '%s\n' '[markdown]' 'archive = "data/a.md' > "$file" ;;
      unquoted) printf '%s\n' '[markdown]' 'archive = data/a.md' > "$file" ;;
      trailing-text) printf '%s\n' '[markdown]' 'archive = "data/a.md" extra' > "$file" ;;
      empty) printf '%s\n' '[markdown]' 'archive = ""' > "$file" ;;
      non-string) printf '%s\n' '[markdown]' 'archive = 5' > "$file" ;;
      non-table) printf '%s\n' 'markdown = "data/a.md"' > "$file" ;;
      escape) printf '%s\n' '[markdown]' 'archive = "data/\u0072ead.md"' > "$file" ;;
      backslash-backslash) printf '%s\n' '[markdown]' 'archive = "data\\a.md"' > "$file" ;;
      tab-escape) printf '%s\n' '[markdown]' 'archive = "data/a\tb.md"' > "$file" ;;
      newline-escape) printf '%s\n' '[markdown]' 'archive = "data/a.md\n"' > "$file" ;;
      triple-quote) printf '%s\n' '[markdown]' 'archive = """data/a.md"""' > "$file" ;;
      multi-line) printf '%s\n' '[markdown]' 'archive = """' 'data/a.md"""' > "$file" ;;
      not-toml) printf '%s\n' 'this is not toml' > "$file" ;;
    esac
    case $case_name in
      escape|backslash-backslash|tab-escape|newline-escape)
        grep -qF $'\\' "$file" || fail "the $case_name fixture holds no backslash" ;;
    esac
    rc=0
    out=$(captain_markdown_archive_setting "$file") || rc=$?
    [ "$rc" -eq 3 ] || fail "the reader did not refuse the $case_name setting (exit $rc, read '$out')"
    [ -z "$out" ] || fail "the reader printed '$out' while refusing the $case_name setting"
  done
  rc=0
  out=$(captain_markdown_archive_setting "$TMP_ROOT/no-such-file.toml") || rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "the reader did not treat an absent file as no setting"
  pass "the archive setting reader parses every TOML spelling and refuses what does not parse"
}

test_inline_quoted_header_and_dotted_archive_settings_refuse() {
  local home scout id case_name
  scout=sample-archive-unread-scout
  id=sample-unread-setting-call
  # tasks-axi ignores an inline table and a quoted table name, and stops on a
  # dotted key, so the archive is written under a plain header and the setting
  # is then rewritten; the stale answer is in the archive the new setting names.
  for case_name in inline quoted-header dotted; do
    home=$(make_home "archived-unread-$case_name")
    set_archive_retention "$home" data/redirected.md
    archive_an_answered_call "$home" "$id" "$scout"
    assert_grep "Captain decision:" "$home/data/redirected.md" "the answered row is not in the archive fixture"
    write_scout_with_attested_inventory "$home" "$scout" "$id"
    case $case_name in
      inline) write_tasks_toml "$home" 'markdown = { path = "data/backlog.md", archive = "data/redirected.md", done_keep = 1 }' ;;
      quoted-header) write_tasks_toml "$home" '["markdown"]' 'path = "data/backlog.md"' 'archive = "data/redirected.md"' 'done_keep = 1' ;;
      dotted) write_tasks_toml "$home" 'markdown.path = "data/backlog.md"' 'markdown.archive = "data/redirected.md"' 'markdown.done_keep = 1' ;;
    esac
    assert_gate_refuses_both "$home" "$scout" "a setting made by the $case_name form"
  done
  pass "an archive named by an inline table, a quoted header or a dotted key refuses"
}

test_archive_setting_the_gate_cannot_read_exactly_refuses() {
  local home scout id case_name reason
  scout=sample-archive-syntax-scout
  id=sample-syntax-call
  # The fixture archives under a readable setting, then the setting is replaced.
  # Some of these stop in tasks-axi first, so only the duplicate-table case is
  # certain to reach the gate's own reader and must carry its reason.
  for case_name in duplicate-tables unterminated unquoted trailing-text empty non-string non-table; do
    reason=
    home=$(make_home "archived-syntax-$case_name")
    set_archive_retention "$home" data/syntax.md
    archive_an_answered_call "$home" "$id" "$scout"
    assert_grep "Captain decision:" "$home/data/syntax.md" "the answered row is not in the archive fixture"
    write_scout_with_attested_inventory "$home" "$scout" "$id"
    case $case_name in
      duplicate-tables)
        write_tasks_toml "$home" '' '[markdown]' 'path = "data/backlog.md"' 'archive = "data/syntax.md"' \
          '' '[markdown]' 'done_keep = 1'
        reason="uses syntax the gate cannot read exactly" ;;
      unterminated) write_tasks_toml "$home" '[markdown]' 'path = "data/backlog.md"' 'archive = "data/syntax.md' 'done_keep = 1' ;;
      unquoted) write_tasks_toml "$home" '[markdown]' 'path = "data/backlog.md"' 'archive = data/syntax.md' 'done_keep = 1' ;;
      trailing-text) write_tasks_toml "$home" '[markdown]' 'path = "data/backlog.md"' 'archive = "data/syntax.md" extra' 'done_keep = 1' ;;
      empty) write_tasks_toml "$home" '[markdown]' 'path = "data/backlog.md"' 'archive = ""' 'done_keep = 1' ;;
      non-string) write_tasks_toml "$home" '[markdown]' 'path = "data/backlog.md"' 'archive = 5' 'done_keep = 1' ;;
      non-table) write_tasks_toml "$home" 'markdown = "data/syntax.md"' ;;
    esac
    assert_gate_refuses_both "$home" "$scout" "an archive setting that is $case_name" "$reason"
  done
  pass "an archive setting that does not parse as one string refuses"
}

# A host without python3, or with a python3 that has no tomllib, gets its own
# status (4) and reason, not the syntax refusal a malformed file gets.
test_missing_python3_or_tomllib_refuses_with_its_own_reason() {
  local file="$TMP_ROOT/no-python.toml" stubs="$TMP_ROOT/no-python-stubs" hidden="$TMP_ROOT/no-tomllib-stubs"
  local empty="$TMP_ROOT/no-python-path" saved_path=$PATH real_python out rc case_name home scout id
  real_python=$(command -v python3) || fail "this test needs a python3 to wrap"
  eval "$(sed -n '/^captain_markdown_archive_setting() {/,/^}/p' "$ROOT/bin/fm-captain-hold.sh")"
  mkdir -p "$stubs" "$hidden" "$empty"
  printf '#!/bin/sh\nexit 1\n' > "$stubs/python3"
  cat > "$hidden/python3" <<STUB
#!/bin/sh
shift 2
exec "$real_python" -I -c 'import sys; sys.modules["tomllib"] = None; exec(sys.stdin.read())' "\$@"
STUB
  chmod +x "$stubs/python3" "$hidden/python3"
  printf '%s\n' '[markdown]' 'archive = "data/read.md"' > "$file"
  rc=0
  out=$(captain_markdown_archive_setting "$file") || rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "data/read.md" ] || fail "the reader did not read the fixture with the real python3 (exit $rc, read '$out')"
  for case_name in failing-python no-tomllib no-python; do
    case $case_name in
      failing-python) PATH="$stubs:$saved_path" ;;
      no-tomllib) PATH="$hidden:$saved_path" ;;
      no-python) PATH="$empty" ;;
    esac
    hash -r
    rc=0
    out=$(captain_markdown_archive_setting "$file" 2>/dev/null) || rc=$?
    PATH=$saved_path
    hash -r
    [ "$rc" -eq 4 ] || fail "the $case_name host did not return 4 (exit $rc)"
    [ -z "$out" ] || fail "the reader printed '$out' on the $case_name host"
  done

  home=$(make_home archived-no-tomllib)
  scout=sample-archive-no-tomllib-scout
  id=sample-no-tomllib-call
  set_archive_retention "$home" data/done-archive.md
  archive_an_answered_call "$home" "$id" "$scout"
  assert_grep "Captain decision:" "$home/data/done-archive.md" "the answered row is not in the archive fixture"
  write_scout_with_attested_inventory "$home" "$scout" "$id"
  rc=0
  out=$(PATH="$stubs:$PATH" run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify passed with no working python3: $out"
  assert_contains "$out" "tomllib" "the refusal does not name tomllib: $out"
  assert_not_contains "$out" "uses syntax the gate cannot read exactly" "the refusal blames the syntax of a valid file: $out"
  assert_gate_resolves "$home" "$scout" "$id" "the same call with the real python3"
  pass "a missing python3 or tomllib refuses with its own reason"
}

tests=(
test_archived_answered_call_resolves_through_the_gate
test_archive_is_read_from_the_configured_path
test_archived_call_without_a_recorded_answer_refuses
test_call_absent_from_backlog_and_archive_keeps_its_refusal
test_archived_call_held_for_another_origin_refuses
test_live_rows_resolve_exactly_as_before_the_archive_lookup
test_scout_teardown_gate_follows_the_archived_answer
test_archived_evidence_only_close_refuses
test_archived_row_quoting_the_record_markers_refuses
test_archived_retired_decision_hold_records_resolve
test_archived_retired_decision_hold_records_that_are_not_answers_refuse
test_archived_answer_after_leading_blank_lines_resolves
test_archived_record_with_only_blank_lines_after_the_label_refuses
test_archived_released_work_item_resolves_through_the_gate
test_user_level_only_archive_path_refuses
test_stale_default_archive_does_not_stand_in_for_the_user_level_archive
test_archive_path_with_a_hash_is_read_whole
test_single_quoted_archive_path_with_a_hash_is_read_whole
test_trailing_comment_after_the_archive_path_still_works
test_spaced_table_header_redirects_the_archive
test_archive_setting_reader_parses_every_toml_spelling
test_inline_quoted_header_and_dotted_archive_settings_refuse
test_archive_setting_the_gate_cannot_read_exactly_refuses
test_missing_python3_or_tomllib_refuses_with_its_own_reason
)
captain_hold_run_tests "$@"
