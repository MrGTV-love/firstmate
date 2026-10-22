#!/usr/bin/env bash
# Cleanup, retained-row, relocated-backlog, merge-entrypoint, and beads-
# backend regressions for captain-held tasks.
# Shared definitions and fixture setup live in fm-captain-hold-lifecycle-helpers.sh.
set -u

# shellcheck source=tests/fm-captain-hold-lifecycle-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-lifecycle-helpers.sh"

test_verify_resolves_a_hold_migrated_to_beads_notes() {
  local fixture home beads scout
  require_tasks_axi_beads "verify against a beads-migrated hold" || return 0
  fixture=$(make_beads_home migrated-notes)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-beads-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-herald-github-delete \
    "Delete the herald repo" --repo herald) >/dev/null 2>&1 \
    || fail "could not create the migrated hold fixture"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-herald-github-delete \
    --kind captain --reason "captain must confirm the delete") >/dev/null 2>&1 \
    || fail "could not hold the migrated fixture row"
  bdrow "$beads" note fm-herald-github-delete \
    "Origin: herald-retire
Decision key: github-delete
State: awaiting captain decision.

migrated from data/backlog.md id herald-retire-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  write_scout_with_attested_inventory "$home" "$scout" \
    herald-retire-decision-github-delete

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not resolve the attested legacy id through its migrated beads row"
  pass "verify resolves a captain hold migrated to a beads row with a marker note"
}

test_verify_resolves_a_hold_migrated_under_the_configured_prefix() {
  local fixture home scout out
  require_tasks_axi_beads "verify against a prefix-migrated hold" || return 0
  fixture=$(make_beads_home migrated-prefix)
  home=${fixture%%|*}
  scout=sample-prefix-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-other-legacy-row \
    "Second migrated hold" --repo sample) >/dev/null 2>&1 \
    || fail "could not create the prefix-migrated fixture row"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-other-legacy-row \
    --kind captain --reason "captain must decide") >/dev/null 2>&1 \
    || fail "could not hold the prefix-migrated fixture row"
  # No row in this graph carries a marker note, so the narrowed prefix guess is
  # the only resolution left for the attested legacy id.
  write_known_rows_stub "$(fm_fakebin "$home")" fm-other-legacy-row
  write_scout_with_attested_inventory "$home" "$scout" other-legacy-row

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not resolve the legacy id under the configured prefix"
  out=$(run_captain "$home" complete "$scout" other-legacy-row) \
    || fail "the completion gate refused the prefix-resolved hold"
  assert_contains "$out" "other-legacy-row=fm-other-legacy-row" \
    "completion did not name the row the prefix guess attested against"
  pass "verify resolves a captain hold whose id is the legacy id under the configured prefix"
}

# The prefix guess is a name, not evidence: when a row actually carries the
# migration marker, that row is the one attested even though an unrelated
# captain-held task occupies the <prefix>-<legacy id> name.
test_marker_noted_row_wins_over_a_prefix_namesake() {
  local fixture home beads scout row out
  require_tasks_axi_beads "prefer a marker-noted row over a prefix namesake" || return 0
  fixture=$(make_beads_home migrated-marker-wins)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-marker-wins-scout
  for row in fm-dual-row fm-marked-dual-row fm-solo-row; do
    (cd "$home" && BEADS_ACTOR=fixture tasks-axi add "$row" "Captain call $row" \
      --repo sample) >/dev/null 2>&1 || fail "could not create the fixture row $row"
    (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold "$row" --kind captain \
      --reason "captain must decide") >/dev/null 2>&1 \
      || fail "could not hold the fixture row $row"
  done
  bdrow "$beads" note fm-marked-dual-row \
    "migrated from data/backlog.md id dual-row on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  write_known_rows_stub "$(fm_fakebin "$home")" \
    fm-dual-row fm-marked-dual-row fm-solo-row
  write_scout_with_attested_inventory "$home" "$scout" "dual-row,solo-row"

  out=$(run_captain "$home" complete "$scout" dual-row solo-row) \
    || fail "the completion gate refused an inventory carrying both migrated shapes"
  assert_not_contains "$out" "dual-row=fm-dual-row" \
    "the bare prefix namesake shadowed the row carrying the migration marker"
  assert_contains "$out" "solo-row=fm-solo-row" \
    "completion did not name the row the prefix guess attested against"
  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not re-resolve both migrated shapes after completion"
  pass "the marker-noted row wins over an unrelated row holding the prefix namesake"
}

test_complete_accepts_a_migrated_inventory_on_beads() {
  local fixture home scout
  require_tasks_axi_beads "complete against a beads-migrated hold" || return 0
  fixture=$(make_beads_home migrated-complete)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-complete-scout
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-herald-github-delete \
    "Delete the herald repo" --repo herald) >/dev/null 2>&1 \
    || fail "could not create the migrated hold fixture"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-herald-github-delete \
    --kind captain --reason "captain must confirm the delete") >/dev/null 2>&1 \
    || fail "could not hold the migrated fixture row"
  bdrow "$beads" note fm-herald-github-delete \
    "migrated from data/backlog.md id herald-retire-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" \
    "worktree=$home/projects/missing-$scout" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "spawn_gen=fixture-$scout"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  mkdir -p "$home/data/$scout"
  printf '# Report\n\nThe investigation finished.\n' > "$home/data/$scout/report.md"

  run_captain "$home" complete "$scout" herald-retire-decision-github-delete >/dev/null \
    || fail "the completion gate refused an inventory resolved through a migrated beads row"
  assert_grep "decision_keys=herald-retire-decision-github-delete" \
    "$home/state/$scout.meta" \
    "the attestation did not record the attested legacy id"
  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not re-resolve the attested legacy id after completion"
  pass "the completion gate attests an inventory resolved through a migrated beads row"
}

test_verify_names_the_unresolvable_legacy_id_once() {
  local fixture home scout err rc
  require_tasks_axi_beads "verify an unresolvable beads legacy id" || return 0
  fixture=$(make_beads_home migrated-absent)
  home=${fixture%%|*}
  scout=sample-absent-scout
  write_scout_with_attested_inventory "$home" "$scout" ghost-legacy-id

  rc=0
  err=$(run_captain "$home" verify "$scout" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "verify accepted an attested id that resolves to nothing"
  assert_contains "$err" "ghost-legacy-id" \
    "the refusal did not name the id it could not resolve"
  [ "$(printf '%s\n' "$err" | grep -c '^fm-captain-hold:')" = 1 ] \
    || fail "the refusal emitted more than one line: $err"
  pass "an unresolvable legacy id is refused once, naming the id"
}

test_verify_resolves_a_pre_collapse_key_through_its_derived_marker() {
  local fixture home beads scout
  require_tasks_axi_beads "verify a derived pre-collapse key" || return 0
  fixture=$(make_beads_home migrated-derived)
  home=${fixture%%|*}
  beads=${fixture##*|}
  scout=sample-derived-scout
  # The row was migrated under the DERIVED pre-collapse identity, keyed by a
  # bare decision key the origin's old metadata attests.
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-dec-call \
    "Migrated pre-collapse call" --repo sample) >/dev/null 2>&1 \
    || fail "could not create the derived-marker fixture row"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-dec-call \
    --kind captain --reason "captain must decide") >/dev/null 2>&1 \
    || fail "could not hold the derived-marker fixture row"
  bdrow "$beads" note fm-dec-call \
    "migrated from data/backlog.md id $scout-decision-github-delete on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the derived-id marker note"
  write_scout_with_attested_inventory "$home" "$scout" github-delete

  run_captain "$home" verify "$scout" >/dev/null \
    || fail "verify did not probe the derived pre-collapse identity for its migrated row"
  pass "a pre-collapse key resolves through its derived identity's migration marker"
}

# The captain-hold mutation wrapper must address the configured backend like
# the transition library does: on a beads-configured home its hold/answer/done
# calls reach tasks-axi with no markdown file override. Fully portable - the
# stubbed tasks-axi fakes the beads backend, so no bd or beads-capable install
# is needed.
test_captain_hold_mutations_address_the_beads_backend() {
  local home id fb log
  home="$TMP_ROOT/captain-stub-beads/home"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$home/state"
  cat > "$home/.tasks.toml" <<'EOF'
backend = "beads"

[beads]
path = "graph/.beads"
binary = "bd"
prefix = "fm"
EOF
  id=fm-stub-held-row
  fb=$(fm_fakebin "$home")
  log="$home/tasks-axi-calls"
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "@LOG@"
case "${1:-}" in
  --version) printf '%s\n' '0.2.6' ;;
  update)
    if [ "${2:-}" = --help ]; then
      printf '%s\n' '--archive-body'
      exit 0
    fi
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads update received a markdown file override' >&2
        exit 1
        ;;
    esac
    stub_prev=
    stub_path=
    for stub_arg in "$@"; do
      if [ "$stub_prev" = --body-file ]; then stub_path=$stub_arg; fi
      stub_prev=$stub_arg
    done
    [ -n "$stub_path" ] && cp -- "$stub_path" "@HOME@/last-body"
    printf 'ok: update %s\n' "${2:-}"
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    case " $* " in
      *" --help "*) printf '%s\n' '  --kind captain' ; exit 0 ;;
      *" --file "*)
        printf '%s\n' 'error: beads hold received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf 'ok: hold %s\n' "${2:-}"
    ;;
  done)
    [ "${2:-}" = "@ID@" ] || exit 1
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads done received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf 'ok: done %s\n' "${2:-}"
    ;;
  show)
    [ "${2:-}" = "@ID@" ] || exit 1
    case " $* " in
      *" --file "*)
        printf '%s\n' 'error: beads show received a markdown file override' >&2
        exit 1
        ;;
    esac
    printf '%s\n' 'task:'
    printf '  id: %s\n' "@ID@"
    printf '%s\n' '  state: queued' '  held: yes' '  blocked: no' \
      '  hold_kind: captain'
    if [ -f "@HOME@/last-body" ]; then
      printf '%s' '  body: '
      perl -MJSON::PP -e 'local $/; print encode_json(<STDIN>)' < "@HOME@/last-body"
      printf '\n'
    else
      printf '%s\n' '  body: ""'
    fi
    ;;
  *) exit 1 ;;
esac
SH
  sed -i.bak "s|@HOME@|$home|g; s|@ID@|$id|g; s|@LOG@|$log|g" "$fb/tasks-axi"
  rm -f "$fb/tasks-axi.bak"
  chmod +x "$fb/tasks-axi"

  PATH="$fb:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason "captain must decide" >/dev/null \
    || fail "holding on a beads-configured home failed without a markdown backlog"
  assert_grep "hold $id" "$log" \
    "the captain-hold mutation never reached the configured backend"

  decision="$home/captain-decision.txt"
  printf 'Ship the gold-only plan.\n' > "$decision"
  PATH="$fb:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$decision" >/dev/null \
    || fail "answering on a beads-configured home failed without a markdown backlog"
  assert_grep "update $id --body-file" "$log" \
    "the captain answer never reached the configured backend"
  assert_grep "done $id" "$log" \
    "the captain answer close never reached the configured backend"
  assert_no_grep " --file " "$log" \
    "a captain-hold mutation passed a markdown file override to a beads home"
  pass "captain-hold mutations address the beads backend without a markdown override"
}

# A Beads workspace with due.required and no types.custom captain type is the
# live fleet shape. hold must still create a fresh captain row there: waive
# due rather than invent one, and map to native type task rather than register
# a Beads captain issue type.
test_hold_creates_a_captain_row_when_beads_requires_due_without_custom_type() {
  local fixture home beads id show issue_type
  require_tasks_axi_beads "captain-hold create under due.required without types.custom" || return 0
  fixture=$(make_beads_home due-required-no-custom-type)
  home=${fixture%%|*}
  beads=${fixture##*|}
  printf '\ndue:\n    required: true\n' >> "$beads/config.yaml"
  if bdrow "$beads" create "raw task" --id fm-raw-task --type task --json >/dev/null 2>&1; then
    fail "bd created a task without --due; the due.required fixture is not in force"
  fi
  if bdrow "$beads" create "raw captain" --id fm-raw-captain --type captain --due 2099-01-01 --json >/dev/null 2>&1; then
    fail "bd accepted --type captain; the fixture still has a types.custom captain registration"
  fi
  id=fm-fresh-captain-call
  run_captain "$home" hold "$id" --title "Choose the sample route" \
    --reason "captain must decide" --repo sample >/dev/null \
    || fail "hold could not create a captain row under due.required without types.custom"
  show=$(tasks_in "$home" show "$id") || fail "the created captain row is missing"
  assert_contains "$show" "hold_kind: captain" \
    "the created row is not captain-held"
  assert_contains "$show" "kind: captain" \
    "the created row lost its captain backlog kind"
  issue_type=$(bdrow "$beads" show "$id" --json \
    | jq -r 'if type == "array" then .[0].issue_type else .issue_type end')
  [ "$issue_type" = task ] \
    || fail "create did not map to native Beads type task, got ${issue_type:-empty}"
  pass "hold creates a captain row when Beads requires due and has no captain type"
}

# The originating work item is itself the captain call, which is what the policy
# prefers ("hold the work item the question gates"). Cleanup of that finished
# work must never be the act that closes the captain's own row: the deliverable
# is recorded on the still-held row, the call keeps reading as open on the
# board, and only a recorded answer closes it. An ordinary finished task in the
# same home must still close exactly as before, and discard authority covers
# unlanded work, never the captain's question.
test_teardown_never_closes_a_captain_held_task() {
  local home id plain forced json show
  home=$(make_home teardown-held)
  id=sample-attach-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample attachment evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample attachment evidence\n\nThe captain must choose inline or by-reference attachments.\n' \
    > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" \
    --reason "captain must choose inline or by-reference attachments" >/dev/null \
    || fail "could not hold the originating work item for the captain"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed with the origin as its own captain call"

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of a captain-held investigation failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "the captain-held row is gone after cleanup"
  assert_not_contains "$show" "state: done" \
    "cleanup closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "the finished work's row still reads as worked on"
  assert_contains "$show" "held: yes" "cleanup lifted the captain hold"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the deliverable was not recorded on the still-open row"
  assert_absent "$home/state/$id.meta" "cleanup did not release the finished worker record"
  assert_absent "$home/state/$id.backlog-close" \
    "successful cleanup left its pending transition record behind"
  assert_grep "still held for the captain" "$home/teardown.out" \
    "cleanup did not say the row stays open for the captain"
  json=$(run_bearings "$home") || fail "Bearings failed after cleanup of a captain-held task"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id == $id and .verb == "captain-hold"))
  ' >/dev/null || fail "the board no longer surfaces the captain call: $json"

  # The ordinary path is untouched: a finished task with no captain call closes.
  plain=sample-plain-review
  mkdir -p "$home/data/$plain"
  tasks_in "$home" add "$plain" "Investigate the sample cache" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the ordinary fixture"
  write_origin_meta "$home" "$plain"
  printf 'done: report complete\n' > "$home/state/$plain.status"
  printf '# Sample cache\n\nNothing waits on the captain.\n' > "$home/data/$plain/report.md"
  run_captain "$home" complete "$plain" --none >/dev/null \
    || fail "completion gate failed for the ordinary investigation"
  run_teardown "$home" "$plain" > "$home/plain.out" 2> "$home/plain.err" \
    || fail "ordinary cleanup failed: $(cat "$home/plain.err")"
  show=$(tasks_in "$home" show "$plain" --full) || fail "the ordinary row vanished"
  assert_contains "$show" "state: done" "ordinary cleanup no longer closes its backlog item"
  assert_contains "$show" "data/$plain/report.md" "ordinary cleanup lost the report link"
  assert_absent "$home/state/$plain.backlog-close" "ordinary cleanup left its pending close behind"

  # Discard authority covers unlanded work, never the captain's question.
  forced=sample-forced-review
  mkdir -p "$home/data/$forced"
  tasks_in "$home" add "$forced" "Investigate the sample forced path" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the forced fixture"
  write_origin_meta "$home" "$forced"
  printf 'done: report complete\n' > "$home/state/$forced.status"
  printf '# Sample forced path\n\nOne captain choice remains.\n' > "$home/data/$forced/report.md"
  run_captain "$home" hold "$forced" --reason "captain must choose the sample forced path" >/dev/null \
    || fail "could not hold the forced fixture for the captain"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$forced" --force --drop-file "$(fm_test_drop_file)" \
    > "$home/forced.out" 2> "$home/forced.err" \
    || fail "forced cleanup failed: $(cat "$home/forced.err")"
  show=$(tasks_in "$home" show "$forced" --full) || fail "forced cleanup erased the captain-held row"
  assert_not_contains "$show" "state: done" \
    "discard authority closed a captain call with no recorded answer"
  assert_contains "$show" "state: queued" "forced cleanup left the captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "forced cleanup dropped the captain hold"

  # Only a recorded answer closes the captain call, and the deliverable survives it.
  printf 'Ship attachments by reference.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the surviving captain call could not be answered"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answered row is gone"
  assert_contains "$show" "state: done" "the recorded answer did not close the captain call"
  assert_contains "$show" "Ship attachments by reference." "the captain's words were not recorded"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the answer lost the recorded deliverable"
  pass "cleanup leaves a captain-held work item open with its deliverable, and only an answer closes it"
}

test_retained_row_artifacts_survive_captain_answers() {
  local home retained_id precedence_id rejected_id rejected_local_id report_question_id
  local approved_id released_id local_id answered_id reportless_scout_id legacy_id
  local repo wt
  local local_repo local_wt
  local precedence_pr rejected_pr approved_pr released_pr json show
  home=$(make_home retained-row-artifacts)
  perl -0pi -e 's/done_keep = 10/done_keep = 20/' "$home/.tasks.toml"
  retained_id=sample-retained-report
  mkdir -p "$home/data/$retained_id"
  tasks_in "$home" add "$retained_id" "Investigate retained report evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the retained report fixture"
  write_origin_meta "$home" "$retained_id"
  printf 'done: report complete\n' > "$home/state/$retained_id.status"
  printf '# Retained report\n\nThe captain must choose the follow-up.\n' \
    > "$home/data/$retained_id/report.md"
  run_captain "$home" hold "$retained_id" --reason "captain must choose the report follow-up" \
    >/dev/null || fail "could not hold the retained report"
  complete_through_sibling "$home" "$retained_id" >/dev/null \
    || fail "completion gate failed for the retained report"
  run_teardown "$home" "$retained_id" > "$home/retained-teardown.out" \
    2> "$home/report-teardown.err" \
    || fail "retained report cleanup failed: $(cat "$home/report-teardown.err")"
  printf 'Proceed with the report follow-up.\n' > "$home/report-answer.txt"
  run_captain "$home" answer "$retained_id" --decision-file "$home/report-answer.txt" >/dev/null \
    || fail "could not answer the retained report call"

  precedence_id=sample-retained-report-pr-title
  precedence_pr=https://github.com/sample/sample/pull/21
  mkdir -p "$home/data/$precedence_id"
  tasks_in "$home" add "$precedence_id" "Investigate $precedence_pr regression" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the report precedence fixture"
  write_origin_meta "$home" "$precedence_id"
  printf 'done: report complete\n' > "$home/state/$precedence_id.status"
  printf '# Retained report with pull request context\n' \
    > "$home/data/$precedence_id/report.md"
  run_captain "$home" hold "$precedence_id" \
    --reason "captain must choose the report follow-up" >/dev/null \
    || fail "could not hold the report precedence fixture"
  complete_through_sibling "$home" "$precedence_id" >/dev/null \
    || fail "completion gate failed for the report precedence fixture"
  run_teardown "$home" "$precedence_id" > "$home/precedence-teardown.out" \
    2> "$home/precedence-teardown.err" \
    || fail "report precedence cleanup failed: $(cat "$home/precedence-teardown.err")"
  printf 'Proceed with the pull-request regression report.\n' \
    > "$home/precedence-answer.txt"
  run_captain "$home" answer "$precedence_id" \
    --decision-file "$home/precedence-answer.txt" >/dev/null \
    || fail "could not answer the report precedence call"
  show=$(tasks_in "$home" show "$precedence_id" --full) \
    || fail "the report precedence row disappeared"
  assert_contains "$show" "state: done" "the report precedence answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the report precedence row lost its retained-scout evidence"

  rejected_id=sample-rejected-merge
  rejected_pr="https://github.com/sample/sample/pull/22"
  tasks_in "$home" add "$rejected_id" "Decide whether $rejected_pr may merge" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the rejected merge fixture"
  run_captain "$home" hold "$rejected_id" --reason "captain merge approval pending" \
    >/dev/null || fail "could not hold the rejected merge"
  printf 'Do not merge this pull request.\n' > "$home/rejected-answer.txt"
  run_captain "$home" answer "$rejected_id" --decision-file "$home/rejected-answer.txt" \
    >/dev/null || fail "could not record the rejected merge"
  show=$(tasks_in "$home" show "$rejected_id" --full) || fail "the rejected merge disappeared"
  assert_contains "$show" "state: done" "the rejected merge answer did not close its call"
  assert_contains "$show" "hold_kind: captain" "the rejected merge lost its non-release evidence"

  rejected_local_id=sample-rejected-local
  tasks_in "$home" add "$rejected_local_id" "Decide whether to land local main" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the rejected local fixture"
  run_captain "$home" hold "$rejected_local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the rejected local merge"
  printf 'Do not land this change locally.\n' > "$home/rejected-local-answer.txt"
  run_captain "$home" answer "$rejected_local_id" \
    --decision-file "$home/rejected-local-answer.txt" >/dev/null \
    || fail "could not record the rejected local merge"
  show=$(tasks_in "$home" show "$rejected_local_id" --full) \
    || fail "the rejected local merge disappeared"
  assert_contains "$show" "state: done" "the rejected local answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the rejected local merge lost its non-release evidence"

  report_question_id=sample-report-path-question
  tasks_in "$home" add "$report_question_id" \
    "Decide whether data/$report_question_id/report.md should be published" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the report-path question fixture"
  run_captain "$home" hold "$report_question_id" \
    --reason "captain report publication decision pending" >/dev/null \
    || fail "could not hold the report-path question"
  printf 'Do not publish this report.\n' > "$home/report-question-answer.txt"
  run_captain "$home" answer "$report_question_id" \
    --decision-file "$home/report-question-answer.txt" >/dev/null \
    || fail "could not record the report-path answer"
  show=$(tasks_in "$home" show "$report_question_id" --full) \
    || fail "the report-path question disappeared"
  assert_contains "$show" "state: done" "the report-path answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the report-path question lost its non-release evidence"

  approved_id=sample-approved-merge
  approved_pr="https://github.com/sample/sample/pull/23"
  repo="$home/projects/sample-approved"
  wt="$home/projects/$approved_id"
  fm_git_worktree "$repo" "$wt" fm/approved-merge
  tasks_in "$home" add "$approved_id" "Ship the approved pull request $approved_pr" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the approved merge fixture"
  fm_write_meta "$home/state/$approved_id.meta" \
    "window=firstmate:fm-$approved_id" "endpoint_task_id=$approved_id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$approved_pr" "spawn_gen=fixture-$approved_id"
  printf 'done: PR %s merged\n' "$approved_pr" > "$home/state/$approved_id.status"
  run_captain "$home" hold "$approved_id" --reason "captain merge approval pending" \
    >/dev/null || fail "could not hold the approved merge"
  printf 'Merge the approved pull request.\n' > "$home/approved-answer.txt"
  run_captain "$home" answer "$approved_id" --release \
    --decision-file "$home/approved-answer.txt" >/dev/null \
    || fail "could not release the approved merge"
  show=$(tasks_in "$home" show "$approved_id" --full) || fail "the approved merge disappeared"
  assert_not_contains "$show" "hold_kind: captain" "merge approval retained its captain hold kind"
  run_teardown "$home" "$approved_id" > "$home/approved-teardown.out" \
    2> "$home/approved-teardown.err" \
    || fail "approved merge cleanup failed: $(cat "$home/approved-teardown.err")"

  local_id=sample-released-local
  local_repo="$home/projects/sample-local"
  local_wt="$home/projects/$local_id"
  fm_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'landed locally\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'local delivery'
  tasks_in "$home" add "$local_id" "Land the approved local-only change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the released local fixture"
  fm_write_meta "$home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  printf 'done: local merge ready\n' > "$home/state/$local_id.status"
  run_captain "$home" hold "$local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the released local merge"
  printf 'Land the approved change locally.\n' > "$home/local-answer.txt"
  run_captain "$home" answer "$local_id" --release \
    --decision-file "$home/local-answer.txt" >/dev/null \
    || fail "could not release the local merge"
  show=$(tasks_in "$home" show "$local_id" --full) || fail "the released local merge disappeared"
  assert_not_contains "$show" "hold_kind: captain" \
    "local merge approval retained its captain hold kind"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-merge-local.sh" "$local_id" \
    > "$home/local-merge.out" 2> "$home/local-merge.err" \
    || fail "approved local merge failed: $(cat "$home/local-merge.err")"
  run_teardown "$home" "$local_id" > "$home/local-teardown.out" \
    2> "$home/local-teardown.err" \
    || fail "released local cleanup failed: $(cat "$home/local-teardown.err")"

  released_id=sample-released-report
  released_pr=https://github.com/sample/sample/pull/24
  mkdir -p "$home/data/$released_id"
  tasks_in "$home" add "$released_id" "Investigate $released_pr report evidence" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the released report fixture"
  write_origin_meta "$home" "$released_id"
  printf 'done: report complete\n' > "$home/state/$released_id.status"
  printf '# Released report\n' > "$home/data/$released_id/report.md"
  run_captain "$home" hold "$released_id" --reason "captain report release pending" \
    >/dev/null || fail "could not hold the released report"
  complete_through_sibling "$home" "$released_id" >/dev/null \
    || fail "completion gate failed for the released report"
  printf 'Release the completed report.\n' > "$home/released-answer.txt"
  run_captain "$home" answer "$released_id" --release \
    --decision-file "$home/released-answer.txt" >/dev/null \
    || fail "could not release the completed report"
  run_teardown "$home" "$released_id" > "$home/released-teardown.out" \
    2> "$home/released-teardown.err" \
    || fail "released report cleanup failed: $(cat "$home/released-teardown.err")"

  answered_id=sample-artifactless-captain-answer
  tasks_in "$home" add "$answered_id" "Choose the artifactless route" --kind captain \
    --repo sample --start >/dev/null || fail "could not create the artifactless captain call"
  run_captain "$home" hold "$answered_id" --reason "captain route choice pending" \
    >/dev/null || fail "could not hold the artifactless captain call"
  printf 'Continue without a delivery artifact.\n' > "$home/artifactless-answer.txt"
  run_captain "$home" answer "$answered_id" --release \
    --decision-file "$home/artifactless-answer.txt" >/dev/null \
    || fail "could not release the artifactless captain call"
  tasks_in "$home" 'done' "$answered_id" >/dev/null \
    || fail "could not complete the released artifactless captain call"

  decision_local_id=sample-released-local-worded-decision
  tasks_in "$home" add "$decision_local_id" "Land the reviewed change" --kind ship \
    --repo sample --start >/dev/null \
    || fail "could not create the local-worded decision fixture"
  run_captain "$home" hold "$decision_local_id" --reason "captain landing route pending" \
    >/dev/null || fail "could not hold the local-worded decision fixture"
  printf 'local main\n' > "$home/local-worded-answer.txt"
  run_captain "$home" answer "$decision_local_id" --release \
    --decision-file "$home/local-worded-answer.txt" >/dev/null \
    || fail "could not release the local-worded decision fixture"
  tasks_in "$home" 'done' "$decision_local_id" >/dev/null \
    || fail "could not complete the local-worded decision fixture"

  reportless_scout_id=sample-reportless-scout
  tasks_in "$home" add "$reportless_scout_id" "Investigate without a report" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the reportless scout"
  tasks_in "$home" 'done' "$reportless_scout_id" >/dev/null \
    || fail "could not complete the reportless scout"

  legacy_id=sample-kindless-legacy-delivery
  tasks_in "$home" add "$legacy_id" "Complete the legacy work" --repo sample --start \
    >/dev/null || fail "could not create the kindless legacy delivery"
  tasks_in "$home" 'done' "$legacy_id" >/dev/null \
    || fail "could not complete the kindless legacy delivery"

  json=$(run_bearings "$home" --all-landed) \
    || fail "Bearings failed after retained delivery answers"
  printf '%s' "$json" | jq -e \
    --arg retained_id "$retained_id" --arg retained "data/$retained_id/report.md" \
    --arg precedence_id "$precedence_id" \
    --arg precedence "data/$precedence_id/report.md" \
    --arg rejected_id "$rejected_id" --arg rejected_local_id "$rejected_local_id" \
    --arg report_question_id "$report_question_id" \
    --arg approved_id "$approved_id" --arg local_id "$local_id" \
    --arg approved_pr "$approved_pr" --arg released_id "$released_id" \
    --arg answered_id "$answered_id" --arg reportless_scout_id "$reportless_scout_id" \
    --arg legacy_id "$legacy_id" --arg decision_local_id "$decision_local_id" \
    --arg released "data/$released_id/report.md" '
      (.landed | any(.id == $retained_id and .artifact == $retained))
        and (.landed | any(.id == $precedence_id and .artifact == $precedence))
        and (.landed | any(.id == $rejected_id) | not)
        and (.landed | any(.id == $rejected_local_id) | not)
        and (.landed | any(.id == $report_question_id) | not)
        and (.landed | any(.id == $approved_id and .artifact == $approved_pr))
        and (.landed | any(.id == $local_id))
        and (.landed | any(.id == $released_id and .artifact == $released))
        # Without the explicit captain-kind boundary, the artifactless answered
        # call falls through the compatibility path and this assertion fails.
        and (.landed | any(.id == $answered_id) | not)
        # Without the explicit scout-kind boundary, this row is rendered with
        # an empty artifact even though a scout has no delivery without a report.
        and (.landed | any(.id == $reportless_scout_id) | not)
        # Requiring a present non-captain kind would also remove this older
        # artifactless delivery, so the compatibility boundary stays observable.
        and (.landed | any(.id == $legacy_id))
        # The captain worded this decision "local main" and the work closed
        # with no artifact, so reading that prose as a recorded note would
        # publish a local-only landing that never happened.
        and (.landed | any(.id == $decision_local_id and .artifact == "-"))
    ' >/dev/null || fail "released, retained, or rejected deliveries were misclassified: $json"
  pass "release and scout report retention distinguish deliveries from rejected merge answers"
}

# Retention happens after destructive cleanup, through the same pending record
# an ordinary close stages first. A cleanup that fails part-way therefore leaves
# the row exactly as it was, and the next session start finishes the retention
# instead of closing the captain's question.
test_interrupted_cleanup_keeps_the_captain_call_recoverable() {
  local home id wt show rc bootstrap
  home=$(make_home teardown-held-interrupted)
  id=sample-held-cleanup-failure
  wt="$home/projects/$id"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
  tasks_in "$home" add "$id" "Investigate failed sample cleanup" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the cleanup-failure fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Failed cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after cleanup retry" >/dev/null \
    || fail "could not hold the cleanup-failure fixture"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the cleanup-failure fixture"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force --drop-file "$(fm_test_drop_file)" \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_contains "$(cat "$home/teardown.err")" "treehouse return failed for worktree $wt" \
    "cleanup failed before the injected worktree return failure"
  assert_present "$home/state/$id.meta" "a failed cleanup removed the task record"
  assert_present "$home/state/$id.backlog-close" \
    "a failed cleanup lost the pending record that replays the retention"
  show=$(tasks_in "$home" show "$id" --full) || fail "a failed cleanup erased the captain call"
  assert_contains "$show" "state: in_flight" "a failed cleanup changed the row before cleanup succeeded"
  assert_contains "$show" "hold_kind: captain" "a failed cleanup dropped the captain hold"
  assert_not_contains "$show" "Deliverable of the finished work" \
    "the deliverable was recorded before destructive cleanup succeeded"

  fm_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay the interrupted retention: $bootstrap"
  assert_contains "$bootstrap" "kept the captain call for $id open" \
    "session start did not report the retained captain call"
  assert_absent "$home/state/$id.meta" "session start left the interrupted task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the pending record behind"
  show=$(tasks_in "$home" show "$id" --full) || fail "session start erased the captain call"
  assert_not_contains "$show" "state: done" "session start closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "session start did not return the captain call to the queue"
  assert_contains "$show" "hold_kind: captain" "session start dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "session start did not record the finished work's deliverable"
  pass "an interrupted cleanup keeps the captain call recoverable and session start retains it"
}

test_answer_before_cleanup_replay_preserves_the_retained_report() {
  local home id wt rc bootstrap json intake show
  for intake in direct keyed keyed-without-meta; do
    home=$(make_home "answer-before-cleanup-replay-$intake")
    id=sample-answer-before-cleanup-replay
    wt="$home/projects/$id"
    mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
    tasks_in "$home" add "$id" "Investigate answer before cleanup replay" --kind scout \
      --repo sample --start >/dev/null || fail "could not create the answer-before-replay fixture"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
      "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
    printf 'done: report complete\n' > "$home/state/$id.status"
    printf '# Interrupted cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
    run_captain "$home" hold "$id" --reason "captain must choose after interrupted cleanup" \
      >/dev/null || fail "could not hold the answer-before-replay fixture"
    complete_through_sibling "$home" "$id" >/dev/null \
      || fail "completion gate failed for the answer-before-replay fixture"
    cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x "$home/fakebin/treehouse"

    set +e
    PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force --drop-file "$(fm_test_drop_file)" \
      > "$home/teardown.out" 2> "$home/teardown.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
    assert_contains "$(cat "$home/teardown.err")" "treehouse return failed for worktree $wt" \
      "cleanup failed before the injected worktree return failure"
    assert_present "$home/state/$id.backlog-close" \
      "the interrupted cleanup lost its retained-artifact record"

    if [ "$intake" = direct ]; then
      printf 'Proceed with the reported result.\n' > "$home/answer.txt"
      run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
        || fail "the captain could not answer before cleanup replay"
    else
      printf '%s\tgo\tProceed with the reported result.\n' "$id" \
        | run_captain "$home" answers --source "interrupted cleanup fixture" >/dev/null \
        || fail "the captain could not release work before cleanup replay"
      show=$(tasks_in "$home" show "$id" --full)
      assert_contains "$show" "state: in_flight" "the keyed answer completed work before replay"
      assert_contains "$show" "held: no" "the keyed answer left the work held before replay"
      assert_contains "$show" "Resolution mode: released" "the keyed answer did not record its release"
      [ "$intake" != keyed-without-meta ] || rm -f "$home/state/$id.meta"
    fi
    fm_fake_exit0 "$home/fakebin" treehouse
    bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
      "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
      || fail "session start could not replay cleanup after the answer: $bootstrap"
    assert_absent "$home/state/$id.meta" "session start left the interrupted task record behind"
    assert_absent "$home/state/$id.backlog-close" "session start left the pending record behind"
    show=$(tasks_in "$home" show "$id" --full)
    assert_contains "$show" "state: done" "cleanup replay reopened finished, answered work"
    assert_contains "$show" "Proceed with the reported result." "cleanup replay lost the captain's words"
    json=$(run_bearings "$home") || fail "Bearings failed after the answer-before-replay lifecycle"
    printf '%s' "$json" | jq -e \
      --arg id "$id" --arg report "data/$id/report.md" \
      '.landed | any(.id == $id and .artifact == $report)' >/dev/null \
      || fail "the retained report disappeared when the captain answered before replay: $json"
  done
  pass "cleanup replay closes answered work and preserves the report after direct or keyed answers"
}

# The opt-in fleet ledger (docs/fleet-ledger.md): teardown only keeps a held
# item open, so the close that really happens later, through an answer, a
# reconciliation, or a repair of a row closed outside the script, is the one that
# records task.closed, with the deliverable teardown retained as its evidence.
retained_held_scout() {  # <home> <id>: a held scout whose cleanup finished and left it Queued
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate $id" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the retained scout $id"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# %s\n\nThe captain must choose.\n' "$id" > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose $id" >/dev/null \
    || fail "could not hold the retained scout $id"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the retained scout $id"
  run_teardown "$home" "$id" > "$home/$id.teardown.out" 2> "$home/$id.teardown.err" \
    || fail "cleanup of the held scout $id failed: $(cat "$home/$id.teardown.err")"
  assert_contains "$(tasks_in "$home" show "$id" --full)" "state: queued" "cleanup did not keep $id open"
}

held_closed_rows() {  # <home>: one compact row per task.closed record
  [ -f "$1/state/fleet-ledger.jsonl" ] || return 0
  jq -c 'select(.event == "task.closed") | [.task, .evidence, .pr]' "$1/state/fleet-ledger.jsonl"
}

test_captain_close_of_retained_work_records_task_closed() {
  local home id reconciled repaired out
  home=$(make_home hold-closed-ledger)
  : > "$home/config/fleet-ledger"
  printf 'Ship attachments by reference.\n' > "$home/answer.txt"
  printf 'Nothing is pending. No captain answer was given.\n' > "$home/evidence.txt"

  id=sample-closed-by-answer
  retained_held_scout "$home" "$id"
  assert_equals "" "$(held_closed_rows "$home")" "cleanup that kept the held item open wrote a task.closed"
  out=$(run_captain "$home" answer "$id" --decision-file "$home/answer.txt") || fail "the answer failed"
  assert_equals "answered: $id" "$out" "answer stdout with the ledger on"
  assert_equals "[\"$id\",\"report\",null]" "$(held_closed_rows "$home")" \
    "task.closed after the answer that closed retained work"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null || fail "the repeated answer failed"
  assert_equals 1 "$(held_closed_rows "$home" | wc -l | tr -d ' ')" "task.closed records after a repeated answer"
  assert_equals 1 "$(jq -c --arg id "$id" 'select(.event == "task.answered" and .task == $id)' "$home/state/fleet-ledger.jsonl" | wc -l | tr -d ' ')" \
    "task.answered records after a repeated answer"

  reconciled=sample-closed-by-reconcile
  retained_held_scout "$home" "$reconciled"
  run_captain "$home" reconcile close "$reconciled" --evidence-file "$home/evidence.txt" --verified-outcome moot >/dev/null \
    || fail "reconcile close failed"
  run_captain "$home" reconcile close "$reconciled" --evidence-file "$home/evidence.txt" --verified-outcome moot >/dev/null \
    || fail "the repeated reconcile close failed"
  assert_equals "$(printf '%s\n' "[\"$id\",\"report\",null]" "[\"$reconciled\",\"report\",null]")" "$(held_closed_rows "$home")" \
    "task.closed after a reconcile close of retained work, and its repeat"

  repaired=sample-closed-outside
  retained_held_scout "$home" "$repaired"
  tasks_in "$home" "done" "$repaired" >/dev/null || fail "could not close the held row outside the script"
  assert_equals 2 "$(held_closed_rows "$home" | wc -l | tr -d ' ')" "closing the row outside the script wrote a task.closed"
  out=$(run_captain "$home" answer "$repaired" --decision-file "$home/answer.txt") || fail "the repairing answer failed"
  assert_equals "repaired: $repaired" "$out" "repair stdout with the ledger on"
  run_captain "$home" answer "$repaired" --decision-file "$home/answer.txt" >/dev/null || fail "the repeated repair failed"
  assert_equals "$(printf '%s\n' "[\"$id\",\"report\",null]" "[\"$reconciled\",\"report\",null]" "[\"$repaired\",\"report\",null]")" \
    "$(held_closed_rows "$home")" "task.closed after repairing a row closed outside the script, and its repeat"
  pass "ledger on: an answer, a reconcile close, or a repair that closes retained work records one task.closed naming its report, and a repeat records none"
}

fm_tasks_axi_in() {  # <home> <bin/fm-tasks-axi.sh args...>
  local home=$1
  shift
  (cd "$home" && PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-tasks-axi.sh" "$@")
}

# One dispatch-to-answer cycle of a held ship, with the steps the fleet's own
# scripts take: the ledger's dispatch record, a start, the hold, teardown's
# retention of the deliverable (none when no flag is given), and the answer.
held_ship_cycle() {  # <home> <id> <hold-stamp> <answer-text> [<retain-flag> <retain-value>]
  local home=$1 id=$2 stamp=$3 text=$4 flag=${5:-} value=${6:-}
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-fleet-ledger.sh" dispatched "$id" ship sample claude "" || fail "could not record the dispatch of $id"
  fm_tasks_axi_in "$home" start "$id" >/dev/null || fail "could not start $id"
  FM_CAPTAIN_HOLD_NOW=$stamp run_captain "$home" hold "$id" --reason "captain must choose $id" >/dev/null \
    || fail "could not hold $id"
  bash -c '. "$1/bin/fm-tasks-axi-lib.sh"; . "$1/bin/fm-backlog-transition-lib.sh"; shift; fm_backlog_retain "$@"' \
    _ "$ROOT" "$home/data" "$id" ${flag:+"$flag" "$value"} || fail "could not retain the deliverable of $id"
  printf '%s\n' "$text" > "$home/$id.answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/$id.answer.txt" >/dev/null || fail "could not answer $id"
}

held_closed_rows_of() {  # <home> <id>
  held_closed_rows "$1" | grep -F "[\"$2\"," || true
}

# A reused task id: each cycle's close names that cycle's own deliverable, and a
# replayed answer adds nothing.
test_reused_task_id_records_each_cycles_own_close_evidence() {
  local home id bare pr21=https://github.com/example/repo/pull/21 pr22=https://github.com/example/repo/pull/22
  home=$(make_home hold-closed-reuse)
  : > "$home/config/fleet-ledger"
  id=sample-reused-ship
  bare=sample-reused-bare
  tasks_in "$home" add "$id" "Reused ship" --kind ship --repo sample >/dev/null || fail "could not add $id"
  tasks_in "$home" add "$bare" "Reused bare" --kind ship --repo sample >/dev/null || fail "could not add $bare"

  held_ship_cycle "$home" "$id" 2026-07-14T12:00:00Z "Go with REST." --pr "$pr21"
  held_ship_cycle "$home" "$bare" 2026-07-14T12:00:00Z "Go with REST." --pr "$pr21"
  assert_equals "[\"$id\",\"merged_pr\",\"$pr21\"]" "$(held_closed_rows_of "$home" "$id")" \
    "a single-cycle task records its own PR"

  fm_tasks_axi_in "$home" reopen "$id" >/dev/null || fail "could not reopen $id"
  held_ship_cycle "$home" "$id" 2026-07-14T12:00:10Z "Use RPC instead." --pr "$pr22"
  assert_equals "$(printf '%s\n' "[\"$id\",\"merged_pr\",\"$pr21\"]" "[\"$id\",\"merged_pr\",\"$pr22\"]")" \
    "$(held_closed_rows_of "$home" "$id")" "a reused task id records the second cycle's PR, not the first's"
  run_captain "$home" answer "$id" --decision-file "$home/$id.answer.txt" >/dev/null || fail "the replayed answer failed"
  assert_equals 2 "$(held_closed_rows_of "$home" "$id" | wc -l | tr -d ' ')" "task.closed records after a replayed answer"
  assert_contains "$(tasks_in "$home" show "$id" --full)" "Historical deliverable of the finished work: PR $pr21" \
    "the first cycle's deliverable was not retired when the item was reused"

  fm_tasks_axi_in "$home" reopen "$bare" >/dev/null || fail "could not reopen $bare"
  held_ship_cycle "$home" "$bare" 2026-07-14T12:00:10Z "Use RPC instead."
  assert_equals "$(printf '%s\n' "[\"$bare\",\"merged_pr\",\"$pr21\"]" "[\"$bare\",\"none\",null]")" \
    "$(held_closed_rows_of "$home" "$bare")" "a second cycle that retained nothing records no evidence, not the first cycle's PR"
  pass "ledger on: a reused task id's close records its own cycle's evidence, and a replayed answer records nothing more"
}

# Fires one injected backend failure through a stand-in tasks-axi: `done` fails
# the close itself, `stamp` fails the plain body update that restores the
# resolution-first ordering after the call has already closed.
install_backend_fault() {  # <home> <done|stamp>
  local home=$1 fault=$2
  rm -f "$home/fault-fired"
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ ! -e "$home/fault-fired" ]; then
  fire=0
  case "$fault:\${1:-}" in
    done:done) fire=1 ;;
    stamp:update)
      case " \$* " in
        *" --body-file "*) case " \$* " in *" --archive-body "*) ;; *) fire=1 ;; esac ;;
      esac
      ;;
  esac
  if [ "\$fire" = 1 ]; then
    : > "$home/fault-fired"
    echo "error: injected backend failure" >&2
    exit 1
  fi
fi
exec "$TASKS_AXI_BIN" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
}

remove_backend_fault() {  # <home>
  rm -f "$1/fakebin/tasks-axi" "$1/fault-fired"
}

held_answered_count() {  # <home> <id>
  jq -c --arg id "$2" 'select(.event == "task.answered" and .task == $id)' "$1/state/fleet-ledger.jsonl" 2>/dev/null | wc -l | tr -d ' '
}

# An interrupted captain close still leaves exactly one task.closed and one
# task.answered: both are written as the call closes, so the retry that finishes
# the command's later steps, and every replay after it, adds none.
test_interrupted_captain_close_records_the_ledger_once() {
  local home id out rc
  home=$(make_home hold-ledger-interrupted)
  : > "$home/config/fleet-ledger"
  printf 'Ship attachments by reference.\n' > "$home/answer.txt"
  printf 'Nothing is pending. No captain answer was given.\n' > "$home/evidence.txt"

  id=sample-interrupted-answer
  retained_held_scout "$home" "$id"
  install_backend_fault "$home" stamp
  rc=0
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the injected failure after the close did not interrupt the answer"
  assert_present "$home/fault-fired" "the injected failure never fired"
  assert_equals "[\"$id\",\"report\",null]" "$(held_closed_rows_of "$home" "$id")" \
    "task.closed after an answer interrupted once the call had closed"
  assert_equals 1 "$(held_answered_count "$home" "$id")" "task.answered after an answer interrupted once the call had closed"
  remove_backend_fault "$home"
  out=$(run_captain "$home" answer "$id" --decision-file "$home/answer.txt") || fail "the retried answer failed"
  assert_equals "answered: $id" "$out" "retried answer stdout"
  assert_equals 1 "$(held_closed_rows_of "$home" "$id" | wc -l | tr -d ' ')" "task.closed records after the retried answer"
  assert_equals 1 "$(held_answered_count "$home" "$id")" "task.answered records after the retried answer"

  id=sample-interrupted-reconcile
  retained_held_scout "$home" "$id"
  install_backend_fault "$home" stamp
  rc=0
  run_captain "$home" reconcile close "$id" --evidence-file "$home/evidence.txt" --verified-outcome moot >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the injected failure after the close did not interrupt the reconcile close"
  assert_present "$home/fault-fired" "the injected failure never fired for the reconcile close"
  assert_equals "[\"$id\",\"report\",null]" "$(held_closed_rows_of "$home" "$id")" \
    "task.closed after a reconcile close interrupted once the call had closed"
  assert_equals 1 "$(held_answered_count "$home" "$id")" "task.answered after a reconcile close interrupted once the call had closed"
  remove_backend_fault "$home"
  out=$(run_captain "$home" reconcile close "$id" --evidence-file "$home/evidence.txt" --verified-outcome moot) \
    || fail "the retried reconcile close failed"
  assert_equals "reconciled: $id" "$out" "retried reconcile close stdout"
  assert_equals 1 "$(held_closed_rows_of "$home" "$id" | wc -l | tr -d ' ')" "task.closed records after the retried reconcile close"
  assert_equals 1 "$(held_answered_count "$home" "$id")" "task.answered records after the retried reconcile close"

  id=sample-interrupted-repair
  retained_held_scout "$home" "$id"
  tasks_in "$home" "done" "$id" >/dev/null || fail "could not close the held row outside the script"
  install_backend_fault "$home" stamp
  rc=0
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the injected failure after the repair record did not interrupt the repair"
  assert_present "$home/fault-fired" "the injected failure never fired for the repair"
  assert_equals "[\"$id\",\"report\",null]" "$(held_closed_rows_of "$home" "$id")" \
    "task.closed after a repair interrupted once its record was written"
  assert_equals 1 "$(held_answered_count "$home" "$id")" "task.answered after a repair interrupted once its record was written"
  remove_backend_fault "$home"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null || fail "the retried repair failed"
  assert_equals 1 "$(held_closed_rows_of "$home" "$id" | wc -l | tr -d ' ')" "task.closed records after the retried repair"
  assert_equals 1 "$(held_answered_count "$home" "$id")" "task.answered records after the retried repair"

  id=sample-interrupted-before-close
  retained_held_scout "$home" "$id"
  install_backend_fault "$home" "done"
  rc=0
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the injected failure of the close did not interrupt the answer"
  assert_present "$home/fault-fired" "the injected failure of the close never fired"
  assert_equals "" "$(held_closed_rows_of "$home" "$id")" "task.closed after a close that failed"
  assert_equals 0 "$(held_answered_count "$home" "$id")" "task.answered after a close that failed"
  remove_backend_fault "$home"
  out=$(run_captain "$home" answer "$id" --decision-file "$home/answer.txt") || fail "the retried close failed"
  assert_equals "answered: $id" "$out" "retried close stdout"
  assert_equals "[\"$id\",\"report\",null]" "$(held_closed_rows_of "$home" "$id")" "task.closed after the retried close"
  assert_equals 1 "$(held_answered_count "$home" "$id")" "task.answered after the retried close"
  pass "ledger on: an interrupted answer, reconcile close, or repair leaves one task.closed and one task.answered, and a retry adds none"
}

test_captain_close_before_cleanup_replay_records_task_closed_once() {
  local home id repo wt rc bootstrap gerrit_url=https://gerrit.example.com/c/project/+/12345
  home=$(make_home hold-closed-before-replay)
  : > "$home/config/fleet-ledger"
  id=sample-closed-before-replay
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" fm/closed-before-replay
  tasks_in "$home" add "$id" "Ship the held Gerrit change" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the held Gerrit fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$gerrit_url" "spawn_gen=fixture-$id"
  printf 'done: change landed\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must choose the follow-up" >/dev/null \
    || fail "could not hold the landed Gerrit task for the captain"
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$(command -v tasks-axi)" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home/fakebin/treehouse"
  chmod +x "$home/fakebin/treehouse"
  rc=0
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.backlog-close" "the interrupted cleanup lost its retained-artifact record"
  assert_equals "" "$(held_closed_rows "$home")" "the interrupted cleanup wrote a task.closed"

  printf 'Proceed with the landed change.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the captain could not answer before cleanup replay"
  assert_equals "[\"$id\",\"merged_pr\",\"$gerrit_url\"]" "$(held_closed_rows "$home")" \
    "task.closed from the pending retention's own arguments"

  fm_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay cleanup after the answer: $bootstrap"
  assert_absent "$home/state/$id.backlog-close" "session start left the pending record behind"
  assert_equals "[\"$id\",\"merged_pr\",\"$gerrit_url\"]" "$(held_closed_rows "$home")" \
    "task.closed after the session-start replay of an already answered retention"
  pass "ledger on: an answer before cleanup replay records one task.closed from the pending retention, and the replay adds none"
}

test_answer_before_cleanup_replay_notes_a_retained_gerrit_change() {
  local home id repo wt rc show real_tasks_axi gerrit_url=https://gerrit.example.com/c/project/+/12345
  home=$(make_home answer-before-replay-gerrit)
  id=sample-answer-before-replay-gerrit
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" fm/answer-before-replay-gerrit
  tasks_in "$home" add "$id" "Ship the held Gerrit change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held Gerrit answer fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$gerrit_url" "spawn_gen=fixture-$id"
  printf 'done: change landed\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must choose the follow-up" >/dev/null \
    || fail "could not hold the landed Gerrit task for the captain"
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_contains "$(cat "$home/teardown.err")" "treehouse return failed for worktree $wt" \
    "cleanup failed before the injected worktree return failure"
  assert_present "$home/state/$id.backlog-close" \
    "the interrupted cleanup lost its retained-artifact record"

  printf 'Proceed with the landed change.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the captain could not answer a Gerrit task before cleanup replay"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answered Gerrit row is gone"
  assert_contains "$show" "state: done" "the answer did not close the Gerrit row"
  assert_contains "$show" "Gerrit change $gerrit_url" \
    "the answer dropped the retained Gerrit change URL"
  pass "an answer before cleanup replay notes the retained Gerrit change"
}

test_unusable_pending_close_record_names_its_reason() {
  local home id wt rc err marker
  home=$(make_home unusable-pending-close-reason)
  id=sample-unusable-pending-close
  wt="$home/projects/$id"
  marker="$home/state/$id.backlog-close"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample" "$home/elsewhere"
  tasks_in "$home" add "$id" "Investigate the unusable pending close" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the unusable pending-close fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Unusable pending close\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after interrupted cleanup" \
    >/dev/null || fail "could not hold the unusable pending-close fixture"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the unusable pending-close fixture"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force --drop-file "$(fm_test_drop_file)" \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_contains "$(cat "$home/teardown.err")" "treehouse return failed for worktree $wt" \
    "cleanup failed before the injected worktree return failure"
  assert_present "$marker" "the interrupted cleanup lost its retained-artifact record"
  sed "s|^data=.*$|data=$home/elsewhere|" "$marker" > "$marker.rewritten" \
    || fail "could not rewrite the pending-close record"
  mv "$marker.rewritten" "$marker"

  printf 'Proceed with the reported result.\n' > "$home/answer.txt"
  set +e
  err=$(run_captain "$home" answer "$id" --decision-file "$home/answer.txt" 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the unusable pending-close record was answered as if it were valid"
  assert_contains "$err" "$marker" \
    "the refusal did not name the pending-close record the captain must repair"
  assert_contains "$err" "foreign data directory" \
    "the refusal did not name why the pending-close record could not be used"
  pass "an unusable pending-close record names its reason instead of a bare refusal"
}

test_relocated_report_does_not_wedge_an_answer_before_replay() {
  local home data id wt rc show bootstrap json intake=${1:-close}
  local -a release_args=()
  home=$(make_home "relocated-answer-before-replay-$intake")
  if [ "$intake" = close ]; then data="$home/données"; else data="$home/records"; fi
  mv "$home/data" "$data"
  id=sample-relocated-answer-before-replay
  wt="$home/projects/$id"
  mkdir -p "$home/data" "$data/$id" "$wt" "$home/projects/sample"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  (cd "$home" && tasks-axi add "$id" "Investigate relocated answer replay" --kind scout \
    --repo sample --start --file "$data/backlog.md" >/dev/null) \
    || fail "could not create the relocated answer-before-replay fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Relocated interrupted cleanup\n\nThe captain call remains open.\n' > "$data/$id/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --reason "captain must choose after relocated interrupted cleanup" >/dev/null \
    || fail "could not hold the relocated answer-before-replay fixture"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id-call" --title "Sibling captain call" \
    --reason "captain must decide the sibling call" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the sibling captain call"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" "$id-call" >/dev/null \
    || fail "completion gate failed for the relocated answer-before-replay fixture"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force --drop-file "$(fm_test_drop_file)" \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "relocated cleanup succeeded despite the failed worktree return"
  assert_contains "$(cat "$home/teardown.err")" "treehouse return failed for worktree $wt" \
    "cleanup failed before the injected worktree return failure"
  assert_present "$home/state/$id.backlog-close" \
    "the interrupted relocated cleanup lost its pending record"

  printf 'Proceed despite the reporting limitation.\n' > "$home/answer.txt"
  if [ "$intake" = keyed ]; then
    printf '%s\tgo\tProceed despite the reporting limitation.\n' "$id" \
      | PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
        FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
        "$ROOT/bin/fm-captain-hold.sh" answers --source "relocated cleanup fixture" \
        >/dev/null || fail "the relocated task could not be released by a keyed answer"
  else
    [ "$intake" != release ] || release_args=(--release)
    PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
      "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$home/answer.txt" \
      "${release_args[@]+"${release_args[@]}"}" \
      >/dev/null || fail "the unsupported relocated report wedged the captain's answer"
  fi
  show=$(cd "$home" && tasks-axi show "$id" --full --file "$data/backlog.md") \
    || fail "the answered relocated row disappeared"
  if [ "$intake" = close ]; then
    assert_contains "$show" "state: done" "the relocated report kept the answered call open"
  else
    assert_contains "$show" "state: in_flight" "the release completed work before cleanup replay"
    assert_contains "$show" "Resolution mode: released" "the answer did not record its release"
  fi
  assert_contains "$show" "held: no" "the relocated report kept the answered call held"

  fm_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay relocated cleanup after the answer: $bootstrap"
  assert_absent "$home/state/$id.meta" "session start left the relocated task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the relocated pending record behind"
  show=$(cd "$home" && tasks-axi show "$id" --full --file "$data/backlog.md") \
    || fail "the relocated row disappeared after replay"
  assert_contains "$show" "state: done" "the relocated report blocked cleanup completion"
  assert_contains "$show" "held: no" "cleanup replay left the answered task held"
  json=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    FM_BEARINGS_NOW=2026-07-14T12:00:00Z "$BEARINGS" --json) \
    || fail "Bearings failed after the relocated answer-before-replay lifecycle"
  printf '%s' "$json" | jq -e --arg id "$id" \
    '.landed | any(.id == $id) | not' >/dev/null \
    || fail "the unsupported relocated report was published as a landed delivery: $json"
  pass "an unsupported relocated report does not wedge the captain's answer"
}

test_relocated_report_does_not_wedge_released_cleanup_replay() {
  test_relocated_report_does_not_wedge_an_answer_before_replay keyed
  test_relocated_report_does_not_wedge_an_answer_before_replay release
}

# A home whose data directory is relocated keeps one backlog; the predicate and
# the retention must address it the way teardown does, not FM_HOME/data.
test_teardown_retains_captain_calls_in_a_relocated_backlog() {
  local home data id show
  home=$(make_home teardown-relocated-hold)
  data="$home/records"
  mv "$home/data" "$data"
  id=sample-relocated-hold
  mkdir -p "$home/data" "$data/$id"
  # A backlog at the default location stays empty, so a wrongly addressed read
  # would find no row at all.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  (cd "$home" && tasks-axi add "$id" "Investigate relocated sample hold" --kind scout \
    --repo sample --start --file "$data/backlog.md" >/dev/null) \
    || fail "could not create the relocated captain-hold fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Relocated hold\n\nThe captain call remains open.\n' > "$data/$id/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --reason "captain must choose the relocated sample outcome" >/dev/null \
    || fail "could not hold the relocated work item"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id-call" --title "Sibling captain call" \
    --reason "captain must decide the sibling call" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the sibling captain call"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" "$id-call" >/dev/null \
    || fail "completion gate failed for the relocated captain hold"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of the relocated captain hold failed: $(cat "$home/teardown.err")"
  show=$(cd "$home" && tasks-axi show "$id" --full --file "$data/backlog.md") \
    || fail "the relocated captain-held row disappeared"
  assert_not_contains "$show" "state: done" "cleanup closed the relocated captain call"
  assert_contains "$show" "state: queued" "cleanup left the relocated captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the relocated captain hold"
  assert_contains "$show" "Deliverable of the finished work: report records/$id/report.md" \
    "cleanup did not record the deliverable in the relocated backlog"
  assert_absent "$home/state/$id.meta" "cleanup left the relocated task record behind"
  assert_absent "$home/state/$id.backlog-close" "cleanup left its pending record behind"
  assert_no_grep "$id" "$home/data/backlog.md" "cleanup wrote to the empty default-location backlog"
  pass "cleanup retains captain calls in the configured backlog"
}

test_teardown_retains_a_gerrit_captain_call_with_its_change_url() {
  local home id repo wt show real_tasks_axi gerrit_url=https://gerrit.example.com/c/project/+/12345
  home=$(make_home teardown-held-gerrit)
  id=sample-held-gerrit
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" fm/held-gerrit
  tasks_in "$home" add "$id" "Ship the held Gerrit change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held Gerrit fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$gerrit_url" "spawn_gen=fixture-$id"
  printf 'done: change landed\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must choose the follow-up" >/dev/null \
    || fail "could not hold the landed Gerrit task for the captain"
  # Pin the refusal tasks-axi applies to a --pr link that is not a canonical
  # GitHub pull request, so this case keeps reproducing whatever the installed
  # release accepts.
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of a captain-held Gerrit task failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "the captain-held Gerrit row is gone after cleanup"
  assert_contains "$show" "state: queued" "the held Gerrit row still reads as worked on"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: Gerrit change $gerrit_url" \
    "the Gerrit change URL was not recorded on the still-open row"
  assert_absent "$home/state/$id.backlog-close" \
    "successful cleanup left its pending transition record behind"
  pass "cleanup keeps a captain-held Gerrit task open and records its change URL"
}

test_merge_approval_releases_before_zero_done_retention() {
  local home id archive repo wt pr show
  home=$(make_home zero-done-retention)
  id=sample-zero-retention-merge
  archive="$home/data/done-archive.md"
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  pr="https://github.com/sample/sample/pull/19"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' \
    'path = "data/backlog.md"' 'archive = "data/done-archive.md"' \
    'done_keep = 0' > "$home/.tasks.toml"
  fm_git_worktree "$repo" "$wt" fm/zero-retention-merge
  tasks_in "$home" add "$id" "Ship zero-retention merge $pr" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the zero-retention fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the zero-retention merge"
  printf 'Merge the approved change.\n' > "$home/merge-answer.txt"
  run_captain "$home" answer "$id" --release \
    --decision-file "$home/merge-answer.txt" >/dev/null \
    || fail "could not release the approved zero-retention merge"
  show=$(tasks_in "$home" show "$id" --full) || fail "the released merge row disappeared"
  assert_contains "$show" "state: in_flight" \
    "merge approval completed the zero-retention row before landing"
  assert_contains "$show" "Resolution mode: released" \
    "merge approval did not record the existing release mode"
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "zero-retention cleanup failed: $(cat "$home/teardown.err")"
  assert_no_grep "$id" "$home/data/backlog.md" \
    "zero-retention cleanup kept the completed row in the active backlog"
  assert_grep "$id" "$archive" "zero-retention cleanup did not archive the completed row"
  assert_grep "$pr" "$archive" "zero-retention archival lost the merged pull request"
  assert_grep "Merge the approved change." "$archive" \
    "zero-retention archival lost the recorded merge approval"
  assert_absent "$home/state/$id.meta" "zero-retention cleanup retained task metadata"
  assert_absent "$home/state/$id.backlog-close" \
    "zero-retention cleanup retained its pending close record"
  pass "merge approval releases before zero-retention cleanup records completion"
}

test_pr_merge_entrypoint_refuses_a_captain_held_task() {
  local home pr_id pr repo wt rc
  home=$(make_home held-merge-entrypoints)
  configure_merged_github "$home"

  pr_id=sample-held-pr-entrypoint
  pr=https://github.com/sample/sample/pull/31
  repo="$home/projects/sample-pr"
  wt="$home/projects/$pr_id"
  fm_git_worktree "$repo" "$wt" "fm/$pr_id"
  tasks_in "$home" add "$pr_id" "Ship the held pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held PR fixture"
  fm_write_meta "$home/state/$pr_id.meta" \
    "window=firstmate:fm-$pr_id" "endpoint_task_id=$pr_id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$pr_id"
  run_captain "$home" hold "$pr_id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the PR entrypoint fixture"

  # Without the entrypoint guard, this run reaches gh and returns success even
  # though the task is still held for the captain.
  set +e
  run_pr_merge "$home" "$pr_id" "$pr" > "$home/pr.out" 2> "$home/pr.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the PR merge entrypoint accepted a still-held task"
  assert_no_grep 'pr merge 31 ' "$home/gh.log" \
    "the PR merge entrypoint reached the irreversible forge call for a held task"
  assert_grep "$pr_id is still held for the captain" "$home/pr.err" \
    "the PR merge refusal did not name the held task"
  assert_absent "$home/state/.control-$pr_id.lock" \
    "the refused PR merge left its task control lock held"
  pass "the PR merge entrypoint refuses a captain-held task before merging"
}

test_local_merge_entrypoint_refuses_a_captain_held_task() {
  local home local_id local_repo local_wt before after rc
  home=$(make_home held-local-merge-entrypoint)
  local_id=sample-held-local-entrypoint
  local_repo="$home/projects/sample-local"
  local_wt="$home/projects/$local_id"
  fm_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'held local delivery\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'held local delivery'
  tasks_in "$home" add "$local_id" "Ship the held local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held local fixture"
  fm_write_meta "$home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  run_captain "$home" hold "$local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the local entrypoint fixture"
  before=$(git -C "$local_repo" rev-parse main)

  # Without the entrypoint guard, this run fast-forwards main while the task
  # still carries the captain hold.
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$local_id" \
    > "$home/local.out" 2> "$home/local.err"
  rc=$?
  set -e
  after=$(git -C "$local_repo" rev-parse main)
  [ "$rc" -ne 0 ] || fail "the local merge entrypoint accepted a still-held task"
  [ "$after" = "$before" ] || fail "the local merge entrypoint moved main for a held task"
  assert_grep "$local_id is still held for the captain" "$home/local.err" \
    "the local merge refusal did not name the held task"
  assert_absent "$home/state/.control-$local_id.lock" \
    "the refused local merge left its task control lock held"
  pass "the local merge entrypoint refuses a captain-held task before merging"
}

test_pr_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one() {
  local home id pr rc merge_count
  home=$(make_home missing-pr-authority-record)
  configure_merged_github "$home"
  id=sample-missing-pr-authority
  pr=https://github.com/sample/sample/pull/43
  write_origin_meta "$home" "$id" ship

  # A backlog that exists but cannot be read may hide a live captain hold, so
  # the merge must refuse without reaching the forge.
  chmod 000 "$home/data/backlog.md"
  set +e
  run_pr_merge "$home" "$id" "$pr" > "$home/missing-pr.out" 2> "$home/missing-pr.err"
  rc=$?
  set -e
  chmod 644 "$home/data/backlog.md"
  [ "$rc" -ne 0 ] || fail "the PR merge entrypoint accepted an unreadable captain-hold authority record"
  assert_grep "could not determine whether task $id is still held for the captain" "$home/missing-pr.err" \
    "the PR merge refusal did not name its unreadable authority record"
  assert_no_grep 'pr merge 43 ' "$home/gh.log" \
    "the PR merge entrypoint reached the forge without a readable authority record"

  # A home with no backlog at all records no captain calls, so nothing can be
  # held and the merge proceeds.
  rm "$home/data/backlog.md"
  run_pr_merge "$home" "$id" "$pr" > "$home/absent-pr.out" 2> "$home/absent-pr.err" \
    || fail "the PR merge entrypoint refused a home carrying no backlog"
  merge_count=$(grep -c 'pr merge 43 ' "$home/gh.log" || true)
  [ "$merge_count" -eq 1 ] || fail "the absent backlog did not permit exactly one PR merge"
  pass "the PR merge entrypoint separates an unreadable authority record from an absent one"
}

test_local_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one() {
  local home id repo wt before after rc
  home=$(make_home missing-local-authority-record)
  id=sample-missing-local-authority
  repo="$home/projects/sample-local"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  printf 'untracked local delivery\n' > "$wt/local.txt"
  git -C "$wt" add local.txt
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'untracked local delivery'
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$id"
  before=$(git -C "$repo" rev-parse main)

  # Unreadable authority record: refuse, and leave the default branch where it was.
  chmod 000 "$home/data/backlog.md"
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$id" \
    > "$home/missing-local.out" 2> "$home/missing-local.err"
  rc=$?
  set -e
  chmod 644 "$home/data/backlog.md"
  after=$(git -C "$repo" rev-parse main)
  [ "$rc" -ne 0 ] || fail "the local merge entrypoint accepted an unreadable captain-hold authority record"
  [ "$after" = "$before" ] || fail "the local merge entrypoint moved main without a readable authority record"
  assert_grep "could not determine whether task $id is still held for the captain" "$home/missing-local.err" \
    "the local merge refusal did not name its unreadable authority record"

  # No backlog at all: nothing can be held, so the landing proceeds.
  rm "$home/data/backlog.md"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$id" \
    > "$home/absent-local.out" 2> "$home/absent-local.err" \
    || fail "the local merge entrypoint refused a home carrying no backlog"
  after=$(git -C "$repo" rev-parse main)
  [ "$after" != "$before" ] || fail "the absent backlog did not permit the local merge"
  pass "the local merge entrypoint separates an unreadable authority record from an absent one"
}

test_merge_entrypoints_validate_identity_and_state_before_locking() {
  local home pr_state local_state bad_id rc
  home=$(make_home invalid-merge-entrypoint-inputs)
  configure_merged_github "$home"

  pr_state="$home/missing-pr-state"
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$pr_state" \
    "$ROOT/bin/fm-pr-merge.sh" sample-missing-pr-state \
    https://github.com/sample/sample/pull/41 \
    > "$home/missing-pr-state.out" 2> "$home/missing-pr-state.err"
  rc=$?
  set -e
  # Without pre-lock state validation, the lock library creates the missing
  # directory before the entrypoint discovers that no task record exists.
  [ "$rc" -ne 124 ] || fail "the PR merge waited forever for a missing state directory"
  [ "$rc" -ne 0 ] || fail "the PR merge accepted a missing state directory"
  assert_absent "$pr_state" "the PR merge created a missing state directory while refusing"
  assert_grep "state directory is not a real directory" "$home/missing-pr-state.err" \
    "the PR merge did not identify its missing state directory"

  local_state="$home/missing-local-state"
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$local_state" \
    "$ROOT/bin/fm-merge-local.sh" sample-missing-local-state \
    > "$home/missing-local-state.out" 2> "$home/missing-local-state.err"
  rc=$?
  set -e
  # Without pre-lock state validation, the lock library creates the missing
  # directory before the entrypoint discovers that no task record exists.
  [ "$rc" -ne 124 ] || fail "the local merge waited forever for a missing state directory"
  [ "$rc" -ne 0 ] || fail "the local merge accepted a missing state directory"
  assert_absent "$local_state" "the local merge created a missing state directory while refusing"
  assert_grep "state directory is not a real directory" "$home/missing-local-state.err" \
    "the local merge did not identify its missing state directory"

  bad_id=sample/bad-local-id
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-merge-local.sh" "$bad_id" \
    > "$home/bad-local-id.out" 2> "$home/bad-local-id.err"
  rc=$?
  set -e
  # Without canonical ID validation, the slash creates a nested lock path whose
  # absent parent makes the blocking acquisition retry until the bound expires.
  [ "$rc" -ne 124 ] || fail "the local merge waited forever on a slash-containing task id"
  [ "$rc" -eq 2 ] || fail "the local merge returned $rc instead of rejecting the unsafe task id"
  assert_grep "invalid local merge request" "$home/bad-local-id.err" \
    "the local merge did not identify the unsafe task id"
  assert_absent "$home/state/.control-sample" \
    "the unsafe task id constructed a nested task control path"
  pass "merge entrypoints reject unsafe identities and absent state before locking"
}

test_merge_entrypoints_refuse_a_reused_task_incarnation() {
  local home id pr old_repo old_wt new_repo new_wt teardown_pid merge_pid
  local teardown_ready teardown_release merge_ready merge_release teardown_rc merge_rc
  local local_home local_id local_old_repo local_old_wt local_new_repo local_new_wt
  local local_teardown_pid local_merge_pid local_teardown_ready local_teardown_release
  local local_merge_ready local_merge_release local_teardown_rc local_merge_rc before after
  local real_perl real_sleep
  real_perl=$(command -v perl)
  real_sleep=$(command -v sleep)

  home=$(make_home reused-pr-incarnation)
  configure_merged_github "$home"
  install_reused_task_barriers "$home"
  id=sample-reused-pr-incarnation
  pr=https://github.com/sample/sample/pull/42
  old_repo="$home/projects/sample-reused-pr-old"
  old_wt="$home/projects/$id"
  fm_git_worktree "$old_repo" "$old_wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the original pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the original PR task"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$old_wt" \
    "project=$old_repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=original-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"

  teardown_ready="$home/reuse-teardown-ready"
  teardown_release="$home/reuse-teardown-release"
  merge_ready="$home/reuse-merge-ready"
  merge_release="$home/reuse-merge-release"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TEST_REUSE_TEARDOWN=1 \
    FM_TEST_REUSE_TEARDOWN_ONCE="$home/reuse-teardown-once" \
    FM_TEST_REUSE_TEARDOWN_READY="$teardown_ready" \
    FM_TEST_REUSE_TEARDOWN_RELEASE="$teardown_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    "$TEARDOWN" "$id" --force --drop-file "$(fm_test_drop_file)" > "$home/reuse-teardown.out" \
    2> "$home/reuse-teardown.err" &
  teardown_pid=$!
  if ! wait_for_test_file "$teardown_ready" "$teardown_pid"; then
    : > "$teardown_release"
    wait "$teardown_pid" 2>/dev/null || true
    fail "forced PR cleanup did not reach its task-locked synchronization point"
  fi

  FM_TEST_REUSE_MERGE=1 FM_TEST_REUSE_MERGE_ONCE="$home/reuse-merge-once" \
    FM_TEST_REUSE_MERGE_READY="$merge_ready" FM_TEST_REUSE_MERGE_RELEASE="$merge_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    run_pr_merge "$home" "$id" "$pr" > "$home/reuse-merge.out" \
    2> "$home/reuse-merge.err" &
  merge_pid=$!
  if ! wait_for_test_file "$merge_ready" "$merge_pid"; then
    : > "$teardown_release"
    : > "$merge_release"
    wait "$teardown_pid" 2>/dev/null || true
    wait "$merge_pid" 2>/dev/null || true
    fail "the PR merge did not wait behind forced cleanup"
  fi

  : > "$teardown_release"
  set +e
  wait "$teardown_pid"
  teardown_rc=$?
  set -e
  if [ "$teardown_rc" -ne 0 ]; then
    : > "$merge_release"
    wait "$merge_pid" 2>/dev/null || true
    fail "forced PR cleanup failed before the task could be reused: $(cat "$home/reuse-teardown.err")"
  fi

  new_repo="$home/projects/sample-reused-pr-new"
  new_wt="$home/projects/reused-$id"
  fm_git_worktree "$new_repo" "$new_wt" "fm/$id"
  tasks_in "$home" reopen "$id" >/dev/null || fail "could not reopen the reused PR task"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$new_wt" \
    "project=$new_repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=replacement-$id"
  tasks_in "$home" start "$id" >/dev/null || fail "could not start the reused PR task"
  : > "$merge_release"
  set +e
  wait "$merge_pid"
  merge_rc=$?
  set -e

  # Without the pre-wait generation capture and locked comparison, the waiter
  # records and merges pull request 42 against the replacement task record.
  [ "$merge_rc" -ne 0 ] || fail "the PR merge accepted a replacement task incarnation"
  assert_no_grep 'pr merge 42 ' "$home/gh.log" \
    "the PR merge reached the forge for a replacement task incarnation"
  assert_grep "changed incarnation while waiting to merge" "$home/reuse-merge.err" \
    "the PR merge did not identify the replacement task incarnation"
  assert_grep "spawn_gen=replacement-$id" "$home/state/$id.meta" \
    "the refused PR merge damaged the replacement task record"
  assert_absent "$home/state/.control-$id.lock" \
    "the reused-incarnation PR refusal left its task control lock held"

  local_home=$(make_home reused-local-incarnation)
  install_reused_task_barriers "$local_home"
  local_id=sample-reused-local-incarnation
  local_old_repo="$local_home/projects/sample-reused-local-old"
  local_old_wt="$local_home/projects/$local_id"
  fm_git_worktree "$local_old_repo" "$local_old_wt" "fm/$local_id"
  printf 'original local delivery\n' > "$local_old_wt/original.txt"
  git -C "$local_old_wt" add original.txt
  git -C "$local_old_wt" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm 'original local delivery'
  tasks_in "$local_home" add "$local_id" "Ship the original local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the original local task"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" \
    "worktree=$local_old_wt" "project=$local_old_repo" "harness=codex" \
    "kind=ship" "mode=local-only" "spawn_gen=original-$local_id"
  printf 'done: local merge ready\n' > "$local_home/state/$local_id.status"

  local_teardown_ready="$local_home/reuse-teardown-ready"
  local_teardown_release="$local_home/reuse-teardown-release"
  local_merge_ready="$local_home/reuse-merge-ready"
  local_merge_release="$local_home/reuse-merge-release"
  PATH="$local_home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" FM_TEST_REUSE_TEARDOWN=1 \
    FM_TEST_REUSE_TEARDOWN_ONCE="$local_home/reuse-teardown-once" \
    FM_TEST_REUSE_TEARDOWN_READY="$local_teardown_ready" \
    FM_TEST_REUSE_TEARDOWN_RELEASE="$local_teardown_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    "$TEARDOWN" "$local_id" --force --drop-file "$(fm_test_drop_file)" > "$local_home/reuse-teardown.out" \
    2> "$local_home/reuse-teardown.err" &
  local_teardown_pid=$!
  if ! wait_for_test_file "$local_teardown_ready" "$local_teardown_pid"; then
    : > "$local_teardown_release"
    wait "$local_teardown_pid" 2>/dev/null || true
    fail "forced local cleanup did not reach its task-locked synchronization point"
  fi

  PATH="$local_home/fakebin:$PATH" FM_TEST_REUSE_MERGE=1 \
    FM_TEST_REUSE_MERGE_ONCE="$local_home/reuse-merge-once" \
    FM_TEST_REUSE_MERGE_READY="$local_merge_ready" \
    FM_TEST_REUSE_MERGE_RELEASE="$local_merge_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" \
    "$ROOT/bin/fm-merge-local.sh" "$local_id" > "$local_home/reuse-merge.out" \
    2> "$local_home/reuse-merge.err" &
  local_merge_pid=$!
  if ! wait_for_test_file "$local_merge_ready" "$local_merge_pid"; then
    : > "$local_teardown_release"
    : > "$local_merge_release"
    wait "$local_teardown_pid" 2>/dev/null || true
    wait "$local_merge_pid" 2>/dev/null || true
    fail "the local merge did not wait behind forced cleanup"
  fi

  : > "$local_teardown_release"
  set +e
  wait "$local_teardown_pid"
  local_teardown_rc=$?
  set -e
  if [ "$local_teardown_rc" -ne 0 ]; then
    : > "$local_merge_release"
    wait "$local_merge_pid" 2>/dev/null || true
    fail "forced local cleanup failed before the task could be reused: $(cat "$local_home/reuse-teardown.err")"
  fi

  local_new_repo="$local_home/projects/sample-reused-local-new"
  local_new_wt="$local_home/projects/reused-$local_id"
  fm_git_worktree "$local_new_repo" "$local_new_wt" "fm/$local_id"
  printf 'replacement local delivery\n' > "$local_new_wt/replacement.txt"
  git -C "$local_new_wt" add replacement.txt
  git -C "$local_new_wt" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm 'replacement local delivery'
  before=$(git -C "$local_new_repo" rev-parse main)
  tasks_in "$local_home" reopen "$local_id" >/dev/null \
    || fail "could not reopen the reused local task"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" \
    "worktree=$local_new_wt" "project=$local_new_repo" "harness=codex" \
    "kind=ship" "mode=local-only" "spawn_gen=replacement-$local_id"
  tasks_in "$local_home" start "$local_id" >/dev/null \
    || fail "could not start the reused local task"
  : > "$local_merge_release"
  set +e
  wait "$local_merge_pid"
  local_merge_rc=$?
  set -e
  after=$(git -C "$local_new_repo" rev-parse main)

  # Without the pre-wait generation capture and locked comparison, the waiter
  # fast-forwards the replacement task's branch despite never approving it.
  [ "$local_merge_rc" -ne 0 ] || fail "the local merge accepted a replacement task incarnation"
  [ "$after" = "$before" ] || fail "the local merge moved main for a replacement task incarnation"
  assert_grep "changed incarnation while waiting to merge" "$local_home/reuse-merge.err" \
    "the local merge did not identify the replacement task incarnation"
  assert_grep "spawn_gen=replacement-$local_id" "$local_home/state/$local_id.meta" \
    "the refused local merge damaged the replacement task record"
  assert_absent "$local_home/state/.control-$local_id.lock" \
    "the reused-incarnation local refusal left its task control lock held"
  pass "merge entrypoints refuse a replacement incarnation after waiting for cleanup"
}

test_merge_entrypoints_serialize_forced_teardown_before_task_reads() {
  local home id pr repo wt ready release merge_pid teardown_rc merge_rc real_grep
  local local_home local_id local_repo local_wt local_ready local_release local_pid
  local local_teardown_rc local_merge_rc real_git before after i

  home=$(make_home teardown-race-pr-entrypoint)
  configure_merged_github "$home"
  id=sample-teardown-race-pr
  pr=https://github.com/sample/sample/pull/33
  repo="$home/projects/sample-pr-race"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the released pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the PR teardown-race fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the PR teardown-race fixture"
  printf 'Merge the released pull request.\n' > "$home/race-answer.txt"
  run_captain "$home" answer "$id" --release --decision-file "$home/race-answer.txt" \
    >/dev/null || fail "could not release the PR teardown-race fixture"

  real_grep=$(command -v grep)
  ready="$home/pr-metadata-read-ready"
  release="$home/pr-metadata-read-release"
  cat > "$home/fakebin/grep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -qxF ] && [ "${2:-}" = "pr=${FM_TEST_RACE_PR_URL:-}" ] \
    && [ "${3:-}" = "${FM_TEST_RACE_PR_META:-}" ]; then
  "$FM_TEST_REAL_GREP" "$@" || exit $?
  : > "$FM_TEST_RACE_READY"
  while [ ! -e "$FM_TEST_RACE_RELEASE" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.01; done
  exit 0
fi
exec "$FM_TEST_REAL_GREP" "$@"
SH
  chmod +x "$home/fakebin/grep"
  FM_TEST_REAL_GREP="$real_grep" FM_TEST_RACE_PR_URL="$pr" \
    FM_TEST_RACE_PR_META="$home/state/$id.meta" FM_TEST_RACE_READY="$ready" \
    FM_TEST_RACE_RELEASE="$release" run_pr_merge "$home" "$id" "$pr" \
    > "$home/race-pr.out" 2> "$home/race-pr.err" &
  merge_pid=$!
  i=0
  while [ "$i" -lt 500 ]; do
    [ -e "$ready" ] && break
    kill -0 "$merge_pid" 2>/dev/null || break
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$merge_pid" 2>/dev/null || true
    fail "the PR merge did not reach the post-metadata synchronization point"
  fi
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force --drop-file "$(fm_test_drop_file)" \
    > "$home/race-pr-teardown.out" 2> "$home/race-pr-teardown.err"
  teardown_rc=$?
  set -e
  : > "$release"
  wait "$merge_pid"
  merge_rc=$?

  # Without early lock ownership, forced cleanup succeeds after metadata is
  # recorded, and the resumed forge call merges work whose task was retired.
  [ "$teardown_rc" -ne 0 ] \
    || fail "forced cleanup retired the task between PR metadata recording and merge"
  assert_grep "another lifecycle action is already running for task $id" \
    "$home/race-pr-teardown.err" \
    "PR cleanup was not refused by the merge's task control lock"
  [ "$merge_rc" -eq 0 ] || fail "the serialized PR merge failed after cleanup was refused"
  assert_present "$home/state/$id.meta" "the refused PR cleanup removed task metadata"
  assert_grep 'pr merge 33 ' "$home/gh.log" \
    "the serialized PR merge did not reach the forge after cleanup was refused"

  local_home=$(make_home teardown-race-local-entrypoint)
  local_id=sample-teardown-race-local
  local_repo="$local_home/projects/sample-local-race"
  local_wt="$local_home/projects/$local_id"
  fm_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'serialized local delivery\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'serialized local delivery'
  tasks_in "$local_home" add "$local_id" "Ship the released local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the local teardown-race fixture"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  printf 'done: local merge ready\n' > "$local_home/state/$local_id.status"
  run_captain "$local_home" hold "$local_id" \
    --reason "captain local merge approval pending" >/dev/null \
    || fail "could not hold the local teardown-race fixture"
  printf 'Land the released local change.\n' > "$local_home/race-answer.txt"
  run_captain "$local_home" answer "$local_id" --release \
    --decision-file "$local_home/race-answer.txt" >/dev/null \
    || fail "could not release the local teardown-race fixture"

  real_git=$(command -v git)
  local_ready="$local_home/local-validation-ready"
  local_release="$local_home/local-validation-release"
  cat > "$local_home/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "-C ${FM_TEST_RACE_REPO:-} rev-parse --short main" ]; then
  output=$("$FM_TEST_REAL_GIT" "$@") || exit $?
  : > "$FM_TEST_RACE_READY"
  while [ ! -e "$FM_TEST_RACE_RELEASE" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.01; done
  printf '%s\n' "$output"
  exit 0
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$local_home/fakebin/git"
  before=$(git -C "$local_repo" rev-parse main)
  PATH="$local_home/fakebin:$PATH" FM_TEST_REAL_GIT="$real_git" \
    FM_TEST_RACE_REPO="$local_repo" FM_TEST_RACE_READY="$local_ready" \
    FM_TEST_RACE_RELEASE="$local_release" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$local_home" FM_STATE_OVERRIDE="$local_home/state" \
    FM_DATA_OVERRIDE="$local_home/data" FM_CONFIG_OVERRIDE="$local_home/config" \
    "$ROOT/bin/fm-merge-local.sh" "$local_id" \
    > "$local_home/race-local.out" 2> "$local_home/race-local.err" &
  local_pid=$!
  i=0
  while [ "$i" -lt 500 ]; do
    [ -e "$local_ready" ] && break
    kill -0 "$local_pid" 2>/dev/null || break
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$local_ready" ]; then
    : > "$local_release"
    wait "$local_pid" 2>/dev/null || true
    fail "the local merge did not reach the post-validation synchronization point"
  fi
  set +e
  PATH="$local_home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" "$TEARDOWN" "$local_id" --force --drop-file "$(fm_test_drop_file)" \
    > "$local_home/race-local-teardown.out" 2> "$local_home/race-local-teardown.err"
  local_teardown_rc=$?
  set -e
  : > "$local_release"
  wait "$local_pid"
  local_merge_rc=$?
  after=$(git -C "$local_repo" rev-parse main)

  # Without early lock ownership, forced cleanup succeeds after validation and
  # the resumed fast-forward lands work whose task was already retired.
  [ "$local_teardown_rc" -ne 0 ] \
    || fail "forced cleanup retired the task between local validation and merge"
  assert_grep "another lifecycle action is already running for task $local_id" \
    "$local_home/race-local-teardown.err" \
    "local cleanup was not refused by the merge's task control lock"
  [ "$local_merge_rc" -eq 0 ] || fail "the serialized local merge failed after cleanup was refused"
  [ "$after" != "$before" ] || fail "the serialized local merge did not fast-forward main"
  assert_present "$local_home/state/$local_id.meta" \
    "the refused local cleanup removed task metadata"
  pass "merge entrypoints own task state before forced cleanup can retire it"
}

# No regression covers a re-hold after a merge lands and before cleanup because
# that accepted window spans two separate lifecycle owners.
# Queued forge merges are also uncovered because they land asynchronously after
# the local merge command and its task control lock have returned.
test_released_merge_passes_the_entrypoint_and_lands() {
  local home id pr repo wt show json
  home=$(make_home released-merge-entrypoint)
  configure_merged_github "$home"
  id=sample-released-merge
  pr=https://github.com/sample/sample/pull/32
  repo="$home/projects/sample-released"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the approved pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the released merge fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the released merge fixture"
  printf 'Merge the approved pull request.\n' > "$home/merge-answer.txt"
  run_captain "$home" answer "$id" --release \
    --decision-file "$home/merge-answer.txt" >/dev/null \
    || fail "could not release the approved merge"
  show=$(tasks_in "$home" show "$id" --full) || fail "the released merge task disappeared"
  assert_not_contains "$show" "hold_kind: captain" \
    "the approved merge remained captain-held after its release"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-review-record.py" captain-word \
    --pr "$pr" --head 1111111111111111111111111111111111111111 \
    --words "$(cat "$home/merge-answer.txt")" >/dev/null \
    || fail "could not record the captain's released merge words"
  run_pr_merge "$home" "$id" "$pr" > "$home/merge.out" 2> "$home/merge.err" \
    || fail "the released merge was refused: $(cat "$home/merge.err")"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TEST_GH_LOG="$home/gh.log" \
    FM_TEST_MERGED_HEAD="$(git -C "$wt" rev-parse HEAD)" FM_TEST_MERGED_PR="$pr" \
    "$TEARDOWN" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "the released merge cleanup failed: $(cat "$home/teardown.err")"
  json=$(run_bearings "$home") || fail "Bearings failed after the released merge lifecycle"
  printf '%s' "$json" | jq -e --arg id "$id" --arg pr "$pr" \
    '.landed | any(.id == $id and .artifact == $pr)' >/dev/null \
    || fail "the released merge was absent from Recently Landed: $json"
  pass "a released merge passes the guarded entrypoint and remains recently landed"
}

# "Cannot tell" is not permission to close. A ship row has no separate
# inventory gate ahead of the close, so the predicate itself must refuse before
# any destructive step when the hold cannot be read.
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read() {
  local home id rc show
  home=$(make_home teardown-ship-hold-read-error)
  id=sample-unreadable-ship-hold
  tasks_in "$home" add "$id" "Ship the sample change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the unreadable-hold fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" "harness=codex" "kind=ship" "mode=direct-PR" \
    "spawn_gen=fixture-$id"
  printf 'done: PR https://github.com/sample/sample/pull/7\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must approve the sample change" >/dev/null \
    || fail "could not hold the ship fixture for the captain"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = "${TASKS_AXI_FAIL_SHOW_ID:-}" ]; then
  printf 'error: temporary backlog read failure\n' >&2
  exit 75
fi
exec "${REAL_TASKS_AXI:?}" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    TASKS_AXI_FAIL_SHOW_ID="$id" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force --drop-file "$(fm_test_drop_file)" \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup treated an unreadable captain hold as permission to close"
  assert_present "$home/state/$id.meta" "read uncertainty must refuse before removing the task record"
  assert_absent "$home/state/$id.backlog-close" "read uncertainty staged a pending transition anyway"
  show=$(tasks_in "$home" show "$id" --full) || fail "the unreadable captain-held row disappeared"
  assert_contains "$show" "state: in_flight" "read uncertainty allowed cleanup to move the row"
  assert_contains "$show" "hold_kind: captain" "read uncertainty dropped the captain hold"
  assert_grep "could not be read" "$home/teardown.err" "cleanup did not explain the refusal"
  assert_grep "temporary backlog read failure" "$home/teardown.err" \
    "the underlying captain-hold read failure was hidden"
  pass "cleanup refuses a ship row when its captain hold cannot be read"
}

tests=(
test_teardown_never_closes_a_captain_held_task
test_retained_row_artifacts_survive_captain_answers
test_interrupted_cleanup_keeps_the_captain_call_recoverable
test_answer_before_cleanup_replay_preserves_the_retained_report
test_answer_before_cleanup_replay_notes_a_retained_gerrit_change
test_captain_close_of_retained_work_records_task_closed
test_captain_close_before_cleanup_replay_records_task_closed_once
test_interrupted_captain_close_records_the_ledger_once
test_reused_task_id_records_each_cycles_own_close_evidence
test_unusable_pending_close_record_names_its_reason
test_relocated_report_does_not_wedge_an_answer_before_replay
test_relocated_report_does_not_wedge_released_cleanup_replay
test_teardown_retains_captain_calls_in_a_relocated_backlog
test_teardown_retains_a_gerrit_captain_call_with_its_change_url
test_merge_approval_releases_before_zero_done_retention
test_pr_merge_entrypoint_refuses_a_captain_held_task
test_local_merge_entrypoint_refuses_a_captain_held_task
test_pr_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one
test_local_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one
test_merge_entrypoints_validate_identity_and_state_before_locking
test_merge_entrypoints_refuse_a_reused_task_incarnation
test_merge_entrypoints_serialize_forced_teardown_before_task_reads
test_released_merge_passes_the_entrypoint_and_lands
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read
test_verify_resolves_a_hold_migrated_to_beads_notes
test_verify_resolves_a_hold_migrated_under_the_configured_prefix
test_marker_noted_row_wins_over_a_prefix_namesake
test_complete_accepts_a_migrated_inventory_on_beads
test_verify_names_the_unresolvable_legacy_id_once
test_verify_resolves_a_pre_collapse_key_through_its_derived_marker
test_captain_hold_mutations_address_the_beads_backend
test_hold_creates_a_captain_row_when_beads_requires_due_without_custom_type
)
captain_hold_run_tests "$@"
