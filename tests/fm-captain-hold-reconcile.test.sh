#!/usr/bin/env bash
# Reconcile, verified-close, operational-key close, legacy-identity, board and
# chat intake, and record-divergence regressions.
# Shared definitions and fixture setup live in fm-captain-hold-lifecycle-helpers.sh.
set -u

# shellcheck source=tests/fm-captain-hold-lifecycle-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-lifecycle-helpers.sh"

test_legacy_reconcile_replaces_previous_choices() {
  local home result field value previous first second out
  home=$(make_home legacy-reconcile-last-choice)
  result="$home/last-choice.result"
  for field in answer choice; do
    for value in reconcile "reconcile - check first"; do
      for previous in legacy-answer legacy-choice versioned-answer versioned-reconcile; do
        case "$previous" in
          legacy-answer) first='\"answer\": \"A\"' ;;
          legacy-choice) first='\"choice\": \"A\"' ;;
          versioned-answer) first='\"schema\": \"fm-bearings-answer.v1\", \"selection\": \"A\", \"note\": \"\"' ;;
          versioned-reconcile) first='\"schema\": \"fm-bearings-answer.v1\", \"selection\": \"reconcile\", \"note\": \"earlier request\"' ;;
        esac
        second="\\\"$field\\\": \\\"$value\\\", \\\"note\\\": \\\"check first\\\""
        cat > "$result" <<EOF
prompts[3]{prompt,tag,text}:
  "Context data:\n{\"question\": \"sample-call\", $first}",choice,"Earlier"
  "Context data:\n{\"question\": \"sample-call\", $second}",choice,"Latest"
  "Context data:\n{\"question\": \"sample-other\", \"answer\": \"B\"}",choice,"Other: B"
EOF
        out=$(run_lavish "$home" answers "$result") || fail "could not extract last legacy choice"
        assert_equals "sample-other	B	Other: B" "$out" \
          "$field $value did not suppress $previous without affecting another question"
        out=$(run_lavish "$home" reconciles "$result") || fail "could not extract reconcile choices"
        assert_equals "" "$out" "$field $value left a superseded reconcile request"

        cat > "$result" <<EOF
prompts[2]{prompt,tag,text}:
  "Context data:\n{\"question\": \"sample-call\", $second}",choice,"Earlier"
  "Context data:\n{\"question\": \"sample-call\", $first}",choice,"Latest"
EOF
        out=$(run_lavish "$home" answers "$result") || fail "could not extract reversed choices"
        if [ "$previous" = versioned-reconcile ]; then
          assert_equals "" "$out" "a final versioned reconcile reached answers"
        else
          assert_equals "sample-call	A	Latest" "$out" \
            "an earlier legacy reconcile suppressed the final $previous"
        fi
        out=$(run_lavish "$home" reconciles "$result") || fail "could not extract reversed reconciles"
        if [ "$previous" = versioned-reconcile ]; then
          assert_equals "sample-call	earlier request" "$out" \
            "an earlier legacy reconcile suppressed the final versioned reconcile"
        else
          assert_equals "" "$out" "a superseded legacy reconcile reached requests"
        fi
      done
    done
  done
  pass "legacy reconcile replaces earlier choices before either intake is selected"
}

# Answer-time closure is opt-in per source. A channel with no binding must behave
# exactly as it always did: capture, announce, close nothing.
# A reconcile is "go re-check reality", never the captain's answer. The value is
# reserved at the one keyed-answer intake, so no channel and no card-declared
# close mode can turn it into a close or a release, and the obligation to verify
# survives as a durable request instead of evaporating with the wake.
test_reconcile_never_closes_through_the_keyed_answer_intake() {
  local home out rc show list
  home=$(make_home reconcile-intake)
  tasks_in "$home" add sample-reconcile-call "Captain call: still current?" --repo sample >/dev/null \
    || fail "could not create the reconcile call"
  tasks_in "$home" add sample-reconcile-gated "Gated work" --repo sample >/dev/null \
    || fail "could not create the gated work item"
  run_captain "$home" hold sample-reconcile-call --reason "is this still current?" >/dev/null \
    || fail "could not hold the reconcile call"
  run_captain "$home" hold sample-reconcile-gated --reason "waiting on the captain" >/dev/null \
    || fail "could not hold the gated work item"

  set +e
  out=$(printf 'sample-reconcile-call\treconcile\tReconcile\n%s\n' \
    "$(printf 'sample-reconcile-gated\treconcile\tReconcile\trelease')" \
    | run_captain "$home" answers --source "captain chat" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the shared answer intake accepted reconcile as an answer"
  assert_contains "$out" "refused: sample-reconcile-call" \
    "the shared intake did not visibly refuse reconcile: $out"
  case "$out" in
    *"closed: sample-reconcile"*) fail "a reconcile row closed a captain call: $out" ;;
  esac

  show=$(tasks_in "$home" show sample-reconcile-call --full)
  assert_contains "$show" "state: queued" "a reconcile row completed a captain call"
  assert_contains "$show" "held: yes" "a reconcile row released a captain call"
  case "$show" in
    *"Resolution recorded by"*) fail "a reconcile row wrote a resolution record" ;;
  esac
  show=$(tasks_in "$home" show sample-reconcile-gated --full)
  assert_contains "$show" "held: yes" "a release-mode reconcile row lifted a captain hold"

  list=$(run_captain "$home" reconcile list) || fail "could not list the reconcile requests"
  assert_contains "$list" "reconcile-requests: 0" \
    "the shared answer intake created a reconcile request: $list"
  set +e
  out=$(printf 'sample-reconcile-call\n' \
    | run_captain "$home" reconcile-requests --source-id unbound-src --source "captured board" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound captured source created a reconcile request"
  request_reconciles "$home" board-src sample-reconcile-call sample-reconcile-gated \
    || fail "the bound captured source did not create reconcile requests"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "sample-reconcile-call" "the reconcile obligation was not recorded durably: $list"
  assert_contains "$list" "reconcile-requests: 2" "the reconcile requests were not both recorded: $list"

  request_reconciles "$home" board-src sample-reconcile-call \
    || fail "replaying a captured reconcile selection failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 2" "a replayed reconcile selection duplicated the obligation: $list"
  pass "only a bound captured source creates reconcile requests"
}

test_normal_answers_retire_pending_reconcile_requests() {
  local home list id
  home=$(make_home reconcile-normal-answer)
  for id in sample-direct-close sample-direct-release sample-keyed-close; do
    tasks_in "$home" add "$id" "Captain call $id" --repo sample >/dev/null
    run_captain "$home" hold "$id" --reason "waiting for the captain" >/dev/null
  done
  request_reconciles "$home" board-src sample-direct-close sample-direct-release sample-keyed-close \
    || fail "could not create reconcile requests before normal answers"

  printf 'Captain said close.\n' > "$home/close.txt"
  printf 'Captain said release.\n' > "$home/release.txt"
  run_captain "$home" answer sample-direct-close --decision-file "$home/close.txt" >/dev/null \
    || fail "a direct close answer failed"
  run_captain "$home" answer sample-direct-release --decision-file "$home/release.txt" --release >/dev/null \
    || fail "a direct release answer failed"
  printf 'sample-keyed-close\tyes\tYes\n' \
    | run_captain "$home" answers --source "board sequence 2" >/dev/null \
    || fail "a keyed normal answer failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" \
    "normal answers left stranded reconcile requests: $list"

  run_captain "$home" answer sample-direct-close --decision-file "$home/close.txt" >/dev/null \
    || fail "a direct close replay failed"
  run_captain "$home" answer sample-direct-release --decision-file "$home/release.txt" --release >/dev/null \
    || fail "a direct release replay failed"
  printf 'sample-keyed-close\tyes\tYes\n' \
    | run_captain "$home" answers --source "board sequence 2" >/dev/null \
    || fail "a keyed answer replay failed"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" \
    "an idempotent normal-answer replay restored a reconcile request: $list"
  pass "normal answers and their replays retire reconcile requests"
}

# The two verification outcomes, and the honesty of the record each writes.
test_reconcile_closes_with_evidence_or_keeps_the_call_open() {
  local home show list rc out
  home=$(make_home reconcile-outcomes)
  tasks_in "$home" add sample-moot-call "Captain call: ship 0.1.37?" --repo sample >/dev/null
  tasks_in "$home" add sample-active-call "Captain call: which admission order?" --repo sample >/dev/null
  tasks_in "$home" add sample-mode-call "Captain call: verify replay mode?" --repo sample >/dev/null
  run_captain "$home" hold sample-moot-call --reason "ship 0.1.37?" >/dev/null
  run_captain "$home" hold sample-active-call --reason "which admission order?" >/dev/null
  run_captain "$home" hold sample-mode-call --reason "verify replay mode?" >/dev/null
  printf '0.1.38 was published on 2026-09-05, so the 0.1.37 question is moot.\n' > "$home/evidence.txt"
  printf 'Still open: nothing has shipped and the choice is unchanged.\n' > "$home/note.txt"

  set +e
  out=$(run_captain "$home" reconcile close sample-moot-call --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reconcile closed a call without a pending board request"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the ungated close refusal did not name the missing board request: $out"
  set +e
  out=$(run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "reconcile annotated a call without a pending board request"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the ungated note refusal did not name the missing board request: $out"

  request_reconciles "$home" board-src sample-moot-call sample-active-call sample-mode-call \
    || fail "could not file the reconcile requests"

  set +e
  out=$(run_captain "$home" reconcile close sample-moot-call 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reconcile close was accepted with no evidence"
  assert_contains "$out" "evidence" "the refusal did not name the missing evidence: $out"

  cp "$home/state/reconcile-requests/sample-mode-call.request" "$home/mode-request.backup"
  run_captain "$home" answer sample-mode-call --decision-file "$home/evidence.txt" >/dev/null \
    || fail "could not record the normal answer for the mode fixture"
  cp "$home/mode-request.backup" "$home/state/reconcile-requests/sample-mode-call.request"
  set +e
  out=$(run_captain "$home" reconcile close sample-mode-call --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a normal captain answer replayed as a reconciliation"
  assert_contains "$out" "was not closed by reconciliation" \
    "the reconcile replay refusal did not identify the incompatible resolution mode: $out"
  run_captain "$home" answer sample-mode-call --decision-file "$home/evidence.txt" >/dev/null \
    || fail "the normal answer replay did not retire its restored pending request"

  run_captain "$home" reconcile close sample-moot-call --evidence-file "$home/evidence.txt" >/dev/null \
    || fail "could not close the moot call with evidence"
  show=$(tasks_in "$home" show sample-moot-call --full)
  assert_contains "$show" "state: done" "the moot call did not close"
  assert_contains "$show" "Resolution mode: reconciled" "the moot call did not record how it closed"
  assert_contains "$show" "Reconciliation evidence:" "the moot call did not record the evidence"
  assert_contains "$show" "0.1.38 was published" "the recorded evidence was lost"
  case "$show" in
    *"Captain decision:"*) fail "a reconciled close was recorded as the captain's own words" ;;
  esac
  set +e
  out=$(run_captain "$home" answer sample-moot-call --decision-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a reconciled resolution replayed as a captain answer"
  assert_contains "$out" "not a captain-answer replay" \
    "the answer replay refusal did not identify the incompatible resolution mode: $out"

  run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" >/dev/null \
    || fail "could not annotate the still-active call"
  show=$(tasks_in "$home" show sample-active-call --full)
  assert_contains "$show" "state: queued" "annotating a still-active call closed it"
  assert_contains "$show" "held: yes" "annotating a still-active call released it"
  assert_contains "$show" "Captain hold reconciled:" "the re-check left no dated note"
  assert_contains "$show" "Still open: nothing has shipped" "the note body was lost"
  case "$show" in
    *"Resolution recorded by"*) fail "annotating a still-active call wrote a resolution record" ;;
  esac
  set +e
  out=$(run_captain "$home" reconcile note sample-active-call --note-file "$home/note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a retired reconcile request appended a duplicate note"
  assert_contains "$out" "no pending board-created reconcile request" \
    "the duplicate-note refusal did not name the retired request: $out"

  printf 'sample-active-call\n' \
    | FM_CAPTAIN_HOLD_NOW=2026-09-07T06:00:00Z run_captain "$home" reconcile-requests \
        --source-id board-src --source "captured board result sequence 2" >/dev/null \
    || fail "could not create the second reconcile request"
  FM_CAPTAIN_HOLD_NOW=2026-09-07T06:01:00Z run_captain "$home" reconcile note sample-active-call \
    --note-file "$home/note.txt" >/dev/null \
    || fail "the second request with the same finding was not recorded"
  show=$(tasks_in "$home" show sample-active-call --full)
  [ "$(printf '%s\n' "$show" | grep -o 'Captain hold reconciled:' | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "a later reconcile request with the same note did not append its own record"
  assert_contains "$show" "Captain hold reconciled: 2026-09-07T06:01:00Z" \
    "the second reconcile request lost its own dated note"

  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "the verified requests were not retired: $list"
  pass "reconcile closes a moot call with evidence and keeps an active one open with a note"
}

test_reconcile_outcomes_retry_partial_failures_once() {
  local home out show list rc
  home=$(make_home reconcile-partial-retry)
  tasks_in "$home" add sample-reconcile-close-retry "Close retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-note-retry "Note retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-retire-retry "Retire retry" --repo sample >/dev/null
  tasks_in "$home" add sample-reconcile-close-retire "Close retire" --repo sample >/dev/null
  tasks_in "$home" add sample-answer-retire "Answer retire" --repo sample >/dev/null
  run_captain "$home" hold sample-reconcile-close-retry --reason "verify close" >/dev/null
  run_captain "$home" hold sample-reconcile-note-retry --reason "verify note" >/dev/null
  run_captain "$home" hold sample-reconcile-retire-retry --reason "verify retire" >/dev/null
  run_captain "$home" hold sample-reconcile-close-retire --reason "verify close retirement" >/dev/null
  run_captain "$home" hold sample-answer-retire --reason "verify answer retirement" >/dev/null
  request_reconciles "$home" board-src sample-reconcile-close-retry sample-reconcile-note-retry \
    sample-reconcile-retire-retry sample-reconcile-close-retire sample-answer-retire \
    || fail "could not create partial-retry requests"
  printf 'Verified moot.\n' > "$home/retry-evidence.txt"
  printf 'Verified active.\n' > "$home/retry-note.txt"
  printf 'Verified retirement retry.\n' > "$home/retry-retire-note.txt"
  printf 'Verified close retirement.\n' > "$home/close-retire-evidence.txt"
  printf 'Captain answered despite retirement failure.\n' > "$home/answer-retire.txt"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ "${2:-}" = sample-reconcile-close-retry ] \
  && [ ! -e "$FM_HOME/reconcile-close-failed" ]; then
  : > "$FM_HOME/reconcile-close-failed"
  exit 92
fi
if [ "${1:-}" = update ] && [ "${2:-}" = sample-reconcile-note-retry ]; then
  "$REAL_TASKS_AXI" "$@" || exit $?
  : > "$FM_HOME/reconcile-note-updated"
  exit 0
fi
if [ "${1:-}" = show ] && [ "${2:-}" = sample-reconcile-note-retry ] \
  && [ -e "$FM_HOME/reconcile-note-updated" ] && [ ! -e "$FM_HOME/reconcile-note-show-failed" ]; then
  : > "$FM_HOME/reconcile-note-show-failed"
  exit 93
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  out=$(run_captain "$home" reconcile close sample-reconcile-close-retry \
    --evidence-file "$home/retry-evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the forced reconcile close failure reported success"
  run_captain "$home" reconcile close sample-reconcile-close-retry \
    --evidence-file "$home/retry-evidence.txt" >/dev/null \
    || fail "reconcile close did not recover from its partial failure"
  show=$(tasks_in "$home" show sample-reconcile-close-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Resolution mode: reconciled')" -eq 1 ] \
    || fail "reconcile close duplicated its resolution record on retry"

  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-note-retry \
    --note-file "$home/retry-note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the forced post-note probe failure reported success"
  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-note-retry \
    --note-file "$home/retry-note.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a note retry succeeded after the request was retired"
  show=$(tasks_in "$home" show sample-reconcile-note-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Captain hold reconciled:')" -eq 1 ] \
    || fail "reconcile note duplicated its durable annotation"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" reconcile close sample-reconcile-close-retire \
    --evidence-file "$home/close-retire-evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed close request retirement reported success"
  assert_contains "$out" "sample-reconcile-close-retire" \
    "the close retirement failure did not name its task: $out"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "sample-reconcile-close-retire" \
    "the failed close retirement hid its pending request"
  chmod 0700 "$home/state/reconcile-requests"
  run_captain "$home" reconcile close sample-reconcile-close-retire \
    --evidence-file "$home/close-retire-evidence.txt" >/dev/null \
    || fail "the closed reconciliation could not finish request retirement"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" answer sample-answer-retire \
    --decision-file "$home/answer-retire.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a failed answer-boundary retirement reported success"
  show=$(tasks_in "$home" show sample-answer-retire --full)
  assert_contains "$show" "state: done" "retirement failure reversed the durable captain answer"
  assert_contains "$show" "Captain answered despite retirement failure" \
    "retirement failure lost the durable captain answer"
  chmod 0700 "$home/state/reconcile-requests"
  run_captain "$home" answer sample-answer-retire --decision-file "$home/answer-retire.txt" >/dev/null \
    || fail "the answer replay could not finish request retirement"

  chmod 0500 "$home/state/reconcile-requests"
  set +e
  out=$(run_captain "$home" reconcile note sample-reconcile-retire-retry \
    --note-file "$home/retry-retire-note.txt" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$home/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "a failed request retirement reported note success"
  assert_not_contains "$out" "still-open:" "failed retirement reported a successful outcome"
  run_captain "$home" reconcile note sample-reconcile-retire-retry \
    --note-file "$home/retry-retire-note.txt" >/dev/null \
    || fail "the applied note could not finish request retirement on retry"
  show=$(tasks_in "$home" show sample-reconcile-retire-retry --full)
  [ "$(printf '%s\n' "$show" | grep -c 'Captain hold reconciled:')" -eq 1 ] \
    || fail "failed request retirement duplicated the reconcile note"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "partial retries left a reconcile request pending"
  pass "reconcile outcomes apply durable mutations once across partial failures"
}

# Recorded answers are evidence of settlement, not new captain words. No
# board interaction is required, including when parent publication must retry.
test_verified_close_without_board_request() {
  local home parent channel outcome id show before out
  home=$(make_home verified-close)
  parent=$(make_home verified-parent)
  printf 'verified-mate\n' > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$home/.fm-secondmate-parent"
  channel="$parent/state/verified-mate.status"
  printf 'Use north; keep the admission order.\n' > "$home/captured-answers.txt"
  printf 'Verified both choices against captured-answers.txt: Use north; keep the admission order. No unanswered choice remains.\n' > "$home/evidence.txt"
  for outcome in answered moot; do
    id="sample-verified-$outcome"
    run_captain "$home" hold "$id" --title "Verify $outcome" --reason "two choices to verify" >/dev/null \
      || fail "could not hold the verified-close fixture"
    if [ "$outcome" = answered ]; then
      # Block parent publication after the backlog mutation, without any board
      # request available as a retry trigger.
      mv "$channel" "$home/parent-open.backup"
      mkdir "$channel"
      if run_captain "$home" reconcile close "$id" --verified-outcome "$outcome" \
        --evidence-file "$home/evidence.txt" > "$home/publish.out" 2>&1; then
        fail "failed standalone parent publication reported success"
      fi
      show=$(tasks_in "$home" show "$id" --full)
      assert_contains "$show" "state: done" "parent publication failure undid the evidence-backed close"
      rmdir "$channel"
      mv "$home/parent-open.backup" "$channel"
    fi
    run_captain "$home" reconcile close "$id" --verified-outcome "$outcome" \
      --evidence-file "$home/evidence.txt" >/dev/null || fail "standalone verified close failed"
    show=$(tasks_in "$home" show "$id" --full)
    assert_contains "$show" "state: done" "verified call remained open"
    assert_contains "$show" "Resolution mode: reconciled" "evidence was recorded as a fresh answer"
    assert_contains "$show" "Verified outcome: $outcome" "verified disposition was not durable"
    assert_contains "$show" "captured-answers.txt" "recorded answer evidence was lost"
    assert_not_contains "$show" "Captain decision:" "operator evidence impersonated the captain"
    before=$show
    run_captain "$home" reconcile close "$id" --verified-outcome "$outcome" \
      --evidence-file "$home/evidence.txt" >/dev/null || fail "verified close replay required a board request"
    [ "$(tasks_in "$home" show "$id" --full)" = "$before" ] || fail "verified replay rewrote the durable resolution"
    printf 'Different evidence.\n' > "$home/different.txt"
    if run_captain "$home" reconcile close "$id" --verified-outcome "$outcome" \
      --evidence-file "$home/different.txt" >/dev/null 2>&1; then
      fail "changed evidence rewrote a closed call"
    fi
    if run_captain "$home" reconcile close "$id" --verified-outcome reconcile \
      --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
      fail "reconcile was accepted as a verified outcome"
    fi
  done
  out=$(run_captain "$home" reconcile list)
  assert_contains "$out" "reconcile-requests: 0" "standalone closure manufactured a board request"
  out=$(bash -c '. "$1/bin/fm-status-decision-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$channel")
  [ -z "$out" ] || fail "standalone reconciliation left a parent decision open: $out"
  pass "verified recorded-answer and moot closes work without board requests and replay parent publication"
}

test_verified_close_retries_only_its_own_hold() {
  local home id show before
  home=$(make_home verified-interrupted-close)
  id=sample-verified-interrupted
  FM_CAPTAIN_HOLD_NOW=2026-10-01T01:00:00Z run_captain "$home" hold "$id" \
    --title "Verified interrupted close" --reason "old choice" >/dev/null
  printf 'Verified source captured.txt: the old choice was already answered.\n' > "$home/evidence.txt"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ ! -e "$FM_HOME/close-failed" ]; then
  : > "$FM_HOME/close-failed"
  exit 92
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  if run_captain "$home" reconcile close "$id" --verified-outcome answered \
    --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
    fail "an interrupted standalone close reported success"
  fi
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "held: yes" "failed close lost the active hold"
  assert_contains "$show" "Captain hold set: 2026-10-01T01:00:00Z" "failed close lost the hold age"
  assert_contains "$show" "Verified outcome: answered" "failed close lost the verified evidence"
  run_captain "$home" reconcile close "$id" --verified-outcome answered \
    --evidence-file "$home/evidence.txt" >/dev/null || fail "standalone close could not resume without a board request"
  show=$(tasks_in "$home" show "$id" --full)
  [ "$(printf '%s\n' "$show" | grep -o 'Resolution mode: reconciled' | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "interrupted standalone close duplicated its resolution"
  # Model an externally reopened historical task, then establish a new hold.
  tasks_in "$home" reopen "$id" >/dev/null
  FM_CAPTAIN_HOLD_NOW=2026-10-02T01:00:00Z run_captain "$home" hold "$id" --reason "new unanswered choice" >/dev/null
  before=$(tasks_in "$home" show "$id" --full)
  if run_captain "$home" reconcile close "$id" --verified-outcome answered \
    --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
    fail "old evidence closed a new hold on a reopened task"
  fi
  [ "$(tasks_in "$home" show "$id" --full)" = "$before" ] || fail "old-hold replay mutated the new call"
  pass "standalone close retries preserve hold age and cannot replay across hold lifecycles"
}

test_interrupted_close_retries_only_as_an_exact_replay() {
  local home parent channel id show open
  home=$(make_home interrupted-replay)
  parent=$(make_home interrupted-replay-parent)
  printf 'verified-mate\n' > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$home/.fm-secondmate-parent"
  channel="$parent/state/verified-mate.status"
  id=sample-interrupted-replay
  run_captain "$home" hold "$id" --title "Interrupted evidence close" --reason "old choice" >/dev/null \
    || fail "could not hold the interrupted-close fixture"
  open=$(bash -c '. "$1/bin/fm-status-decision-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$channel")
  assert_contains "$open" "captain-hold-$id-1" "the hold did not publish its parent key"
  printf 'Verified source captured.txt: the choice was already answered.\n' > "$home/answered.txt"
  printf 'Verified premise: the choice no longer applies.\n' > "$home/moot.txt"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = done ]; then
  attempts=$(cat "$FM_HOME/done-attempts" 2>/dev/null || echo 0)
  printf '%s\n' "$((attempts + 1))" > "$FM_HOME/done-attempts"
  [ "$attempts" -ge 1 ] || exit 92
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  if run_captain "$home" reconcile close "$id" --verified-outcome answered \
    --evidence-file "$home/answered.txt" >/dev/null 2>&1; then
    fail "an interrupted close reported success"
  fi
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "held: yes" "the interrupted close released the hold"
  # A different outcome, different evidence, or both is no replay of the recorded
  # close: it stacks no second record and publishes no later occurrence key.
  for retry in "moot moot.txt" "answered moot.txt" "moot answered.txt"; do
    if out=$(run_captain "$home" reconcile close "$id" --verified-outcome "${retry%% *}" \
      --evidence-file "$home/${retry##* }" 2>&1); then
      fail "a changed retry ($retry) replaced an interrupted close: $out"
    fi
    assert_contains "$out" "records a different resolution for this hold" \
      "the changed retry ($retry) refusal did not name its reason: $out"
    [ "$(tasks_in "$home" show "$id" --full)" = "$show" ] || fail "the refused changed retry ($retry) mutated the task"
  done
  assert_not_contains "$(cat "$channel")" "captain-hold-$id-2" "a refused retry minted a second occurrence key"
  run_captain "$home" reconcile close "$id" --verified-outcome answered \
    --evidence-file "$home/answered.txt" >/dev/null || fail "the exact retry did not finish the interrupted close"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: done" "the exact retry left the task open"
  [ "$(printf '%s\n' "$show" | grep -o 'Resolution mode: reconciled' | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "the interrupted close stacked a second resolution"
  open=$(bash -c '. "$1/bin/fm-status-decision-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$channel")
  [ -z "$open" ] || fail "the exact retry left the original parent key open: $open"
  assert_contains "$(cat "$channel")" "resolved [key=captain-hold-$id-1]" \
    "the exact retry did not resolve the hold's original key"
  assert_not_contains "$(cat "$channel")" "captain-hold-$id-2" "the exact retry minted a second occurrence key"
  run_captain "$home" reconcile close "$id" --verified-outcome answered \
    --evidence-file "$home/answered.txt" >/dev/null || fail "closed-task exact retry failed"
  assert_not_contains "$(cat "$channel")" "captain-hold-$id-2" "the closed-task retry minted a second occurrence key"
  if run_captain "$home" reconcile close "$id" --verified-outcome moot \
    --evidence-file "$home/moot.txt" >/dev/null 2>&1; then
    fail "a closed call accepted a different resolution"
  fi
  pass "an interrupted close retries only as an exact replay and resolves the hold's original parent key"
}

# The one exact-replay rule, pinned cell by cell. Every cell builds a call whose
# first evidence close wrote a resolution record, then retries it. A retry may
# finish only the newest record, with the same evidence digest (the verified
# outcome is part of it) for the same hold, and then resolves that hold's own
# parent key. A different digest against the hold the record names is refused
# and stacks nothing; only an open task whose hold is a newer opening takes it
# as the first close of that opening. Older evidence never closes a newer hold,
# and a closed call never replays across one.
matrix_expectation() {  # <task-state> <digest> <opening> -> "accept <key-occurrence>" | "refuse <reason>"
  case "$1:$3:$2" in
    closed:same:same) echo "accept 1" ;;
    closed:same:changed) echo "refuse records a different resolution; it cannot be reconciled again" ;;
    closed:reopened:same) echo "refuse newer or unidentifiable hold" ;;
    closed:reopened:changed) echo "refuse records a different resolution; it cannot be reconciled again" ;;
    open:same:same) echo "accept 1" ;;
    open:same:changed) echo "refuse records a different resolution for this hold" ;;
    open:reopened:same) echo "refuse newer or unidentifiable hold" ;;
    open:reopened:changed) echo "accept 2" ;;
  esac
}

matrix_open_keys() {  # <channel> <task-id>
  bash -c '. "$1/bin/fm-status-decision-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$1" \
    | awk -F'\t' -v p="captain-hold-$2-" 'index($1, p) == 1 { print $1 }' | sort
}

matrix_home() {  # <n>; builds one secondmate home with a parent, sets MATRIX_HOME and MATRIX_CHANNEL
  local home parent
  home=$(make_home "retry-matrix-$1")
  parent=$(make_home "retry-matrix-parent-$1")
  printf 'verified-mate\n' > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$home/.fm-secondmate-parent"
  printf 'Verified source captured.txt: the recorded answers settle this call.\n' > "$home/e1.txt"
  printf 'Corrected verified source captured-v2.txt: the answers settle this call.\n' > "$home/e2.txt"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ -e "$FM_HOME/fail-done-${2:-}" ]; then
  exit 92
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  MATRIX_HOME=$home
  MATRIX_CHANNEL="$parent/state/verified-mate.status"
}

matrix_cell() {  # <n> <task-state> <evidence> <outcome> <request> <stamp> <opening>
  local n=$1 task_state=$2 evidence=$3 outcome=$4 request=$5 stamp=$6 opening=$7
  local id="matrix-$n" digest=same file outcome_arg=answered label want kind detail rc=0 out
  local home channel before_show before_chan before_open after_open req_path
  matrix_home "$n"
  home=$MATRIX_HOME
  channel=$MATRIX_CHANNEL
  req_path="$home/state/reconcile-requests/$id.request"
  [ "$evidence" = same ] && [ "$outcome" = same ] || digest=changed
  label="$task_state/evidence-$evidence/outcome-$outcome/request-$request/$stamp/$opening"
  if [ "$stamp" = stamped ]; then
    FM_CAPTAIN_HOLD_NOW=2026-10-01T01:00:00Z run_captain "$home" hold "$id" \
      --title "Matrix $n" --reason "choice $n" >/dev/null || fail "matrix $label: could not hold"
  else
    tasks_in "$home" add "$id" "Matrix $n" --repo sample >/dev/null
    tasks_in "$home" hold "$id" --reason "choice $n" --kind captain >/dev/null
    printf 'needs-decision [key=captain-hold-%s-1]: captain hold %s: choice %s\n' "$id" "$id" "$n" >> "$channel"
  fi
  request_reconciles "$home" matrix-src "$id" || fail "matrix $label: could not file the request"
  cp "$req_path" "$home/request.backup"
  rm -f "$req_path"
  [ "$task_state" = closed ] || : > "$home/fail-done-$id"
  if run_captain "$home" reconcile close "$id" --verified-outcome answered \
    --evidence-file "$home/e1.txt" >/dev/null 2>&1; then
    [ "$task_state" = closed ] || fail "matrix $label: the interrupted close fixture succeeded"
  else
    [ "$task_state" = open ] || fail "matrix $label: the first close failed"
  fi
  rm -f "$home/fail-done-$id"
  if [ "$opening" = reopened ]; then
    if [ "$task_state" = open ]; then
      tasks_in "$home" unhold "$id" >/dev/null || fail "matrix $label: could not release the hold"
    else
      tasks_in "$home" reopen "$id" >/dev/null || fail "matrix $label: could not reopen"
    fi
    FM_CAPTAIN_HOLD_NOW=2026-10-02T01:00:00Z run_captain "$home" hold "$id" \
      --reason "new choice $n" >/dev/null || fail "matrix $label: could not re-hold"
    [ "$task_state" = open ] || tasks_in "$home" "done" "$id" >/dev/null \
      || fail "matrix $label: could not close the reopened call outside the tool"
  fi
  [ "$request" = present ] && cp "$home/request.backup" "$req_path"
  file="$home/e1.txt"
  [ "$evidence" = same ] || file="$home/e2.txt"
  [ "$outcome" = same ] || outcome_arg=moot
  before_show=$(tasks_in "$home" show "$id" --full)
  before_chan=$(cat "$channel")
  before_open=$(matrix_open_keys "$channel" "$id")
  out=$(run_captain "$home" reconcile close "$id" --verified-outcome "$outcome_arg" \
    --evidence-file "$file" 2>&1) || rc=$?
  want=$(matrix_expectation "$task_state" "$digest" "$opening")
  kind=${want%% *}
  detail=${want#* }
  after_open=$(matrix_open_keys "$channel" "$id")
  if [ "$opening" = same ]; then
    assert_not_contains "$(cat "$channel")" "captain-hold-$id-2" "matrix $label: a same-opening retry published a later occurrence key"
  fi
  if [ "$kind" = refuse ]; then
    [ "$rc" -ne 0 ] || fail "matrix $label: a retry that must be refused succeeded: $out"
    assert_contains "$out" "$detail" "matrix $label: the refusal did not name its reason: $out"
    [ "$(tasks_in "$home" show "$id" --full)" = "$before_show" ] || fail "matrix $label: a refused retry mutated the task"
    [ "$(cat "$channel")" = "$before_chan" ] || fail "matrix $label: a refused retry published to the parent"
    [ "$after_open" = "$before_open" ] || fail "matrix $label: a refused retry changed the open parent keys"
    [ "$request" = absent ] || [ -f "$req_path" ] || fail "matrix $label: a refused retry retired the request"
  else
    [ "$rc" -eq 0 ] || fail "matrix $label: an exact retry or the first close of a new opening was refused: $out"
    assert_contains "$out" "reconciled: $id" "matrix $label: the accepted retry did not report success"
    assert_contains "$(tasks_in "$home" show "$id" --full)" "state: done" "matrix $label: the accepted retry left the task open"
    assert_contains "$(cat "$channel")" "resolved [key=captain-hold-$id-$detail]" \
      "matrix $label: the accepted retry did not resolve its own opening"
    [ "$after_open" = "$(printf '%s\n' "$before_open" | grep -vxF "captain-hold-$id-$detail" || true)" ] \
      || fail "matrix $label: the accepted retry closed a different opening: $after_open"
    [ ! -e "$req_path" ] || fail "matrix $label: the accepted retry left its request pending"
  fi
}

matrix_board_cell() {  # <n> <task-state> <stamp>
  local n=$1 task_state=$2 stamp=$3 id="matrix-$1" home channel out show
  matrix_home "$n"
  home=$MATRIX_HOME
  channel=$MATRIX_CHANNEL
  if [ "$stamp" = stamped ]; then
    run_captain "$home" hold "$id" --title "Board $n" --reason "board choice $n" >/dev/null
  else
    tasks_in "$home" add "$id" "Board $n" --repo sample >/dev/null
    tasks_in "$home" hold "$id" --reason "board choice $n" --kind captain >/dev/null
    printf 'needs-decision [key=captain-hold-%s-1]: captain hold %s: board choice %s\n' "$id" "$id" "$n" >> "$channel"
  fi
  request_reconciles "$home" matrix-src "$id" || fail "board $task_state/$stamp: could not file the request"
  cp "$home/state/reconcile-requests/$id.request" "$home/request.backup"
  [ "$task_state" = closed ] || : > "$home/fail-done-$id"
  run_captain "$home" reconcile close "$id" --evidence-file "$home/e1.txt" >/dev/null 2>&1 || true
  rm -f "$home/fail-done-$id"
  if [ "$task_state" = open ]; then
    # The board path takes the same exact-replay rule: a different digest is no
    # replay of the interrupted close, stacks nothing, and publishes no later key.
    show=$(tasks_in "$home" show "$id" --full)
    out=$(run_captain "$home" reconcile close "$id" --evidence-file "$home/e2.txt" 2>&1) \
      && fail "board $task_state/$stamp: a changed retry replaced an interrupted close: $out"
    assert_contains "$out" "records a different resolution for this hold" \
      "board $task_state/$stamp: the changed retry refusal did not name its reason: $out"
    [ "$(tasks_in "$home" show "$id" --full)" = "$show" ] || fail "board $task_state/$stamp: the refused changed retry mutated the task"
    assert_not_contains "$(cat "$channel")" "captain-hold-$id-2" "board $task_state/$stamp: a refused retry minted a second occurrence key"
  fi
  rm -f "$home/state/reconcile-requests/$id.request"
  out=$(run_captain "$home" reconcile close "$id" --evidence-file "$home/e1.txt" 2>&1) \
    && fail "board $task_state/$stamp: a default close retry succeeded without a pending request: $out"
  assert_contains "$out" "no pending board-created reconcile request" \
    "board $task_state/$stamp: the refusal did not name the missing request: $out"
  if [ "$task_state" = open ]; then
    cp "$home/request.backup" "$home/state/reconcile-requests/$id.request"
    run_captain "$home" reconcile close "$id" --evidence-file "$home/e1.txt" >/dev/null \
      || fail "board $task_state/$stamp: the exact retry did not finish the interrupted close"
    assert_contains "$(tasks_in "$home" show "$id" --full)" "state: done" "board $task_state/$stamp: the exact retry left the task open"
    assert_contains "$(cat "$channel")" "resolved [key=captain-hold-$id-1]" \
      "board $task_state/$stamp: the exact retry did not resolve the hold's original key"
    assert_not_contains "$(cat "$channel")" "captain-hold-$id-2" "board $task_state/$stamp: the exact retry minted a second occurrence key"
    [ -z "$(matrix_open_keys "$channel" "$id")" ] || fail "board $task_state/$stamp: the exact retry left a parent key open"
  fi
}

matrix_legacy_stacked_cell() {  # <n>
  local n=$1 id="matrix-$1" home channel out show attempt
  matrix_home "$n"
  home=$MATRIX_HOME
  channel=$MATRIX_CHANNEL
  tasks_in "$home" add "$id" "Legacy $n" --repo sample >/dev/null
  tasks_in "$home" hold "$id" --reason "legacy choice $n" --kind captain >/dev/null
  printf 'needs-decision [key=captain-hold-%s-1]: captain hold %s: legacy choice %s\n' "$id" "$id" "$n" >> "$channel"
  : > "$home/fail-done-$id"
  for attempt in one two; do
    printf 'The captain chose %s.\n' "$attempt" > "$home/decision-$attempt.txt"
    run_captain "$home" answer "$id" --decision-file "$home/decision-$attempt.txt" >/dev/null 2>&1 || true
  done
  rm -f "$home/fail-done-$id"
  show=$(tasks_in "$home" show "$id" --full)
  [ "$(printf '%s\n' "$show" | grep -o 'Resolution recorded by' | wc -l | tr -d ' ')" -eq 2 ] \
    || fail "legacy stacked: the fixture did not stack two unstamped records"
  for attempt in e1 e2; do
    out=$(run_captain "$home" reconcile close "$id" --verified-outcome answered \
      --evidence-file "$home/$attempt.txt" 2>&1) \
      && fail "legacy stacked: a close of an unidentifiable opening succeeded: $out"
    assert_contains "$out" "legacy stacked records, opening not identifiable" \
      "legacy stacked: the refusal did not name its reason: $out"
  done
  [ "$(tasks_in "$home" show "$id" --full)" = "$show" ] || fail "legacy stacked: a refused close mutated the task"
  assert_not_contains "$(cat "$channel")" "resolved [key=captain-hold-$id" "legacy stacked: a refused close published to the parent"
  assert_contains "$(matrix_open_keys "$channel" "$id")" "captain-hold-$id-1" "legacy stacked: a refused close closed the parent key"
}

test_verified_close_retry_matrix() {
  local n=0 task_state evidence outcome request stamp opening running=0 dir pid cell failed=''
  local -a cells
  dir="$TMP_ROOT/retry-matrix-results"
  mkdir -p "$dir"
  for task_state in open closed; do
    for evidence in same changed; do
      for outcome in same changed; do
        for request in present absent; do
          for stamp in stamped legacy; do
            for opening in same reopened; do
              n=$((n + 1))
              cells[n]="matrix_cell $n $task_state $evidence $outcome $request $stamp $opening"
            done
          done
        done
      done
    done
  done
  # The default board-path close keeps its request requirement in every state,
  # including as a retry of an already closed call.
  for task_state in open closed; do
    for stamp in stamped legacy; do
      n=$((n + 1))
      cells[n]="matrix_board_cell $n $task_state $stamp"
    done
  done
  n=$((n + 1))
  cells[n]="matrix_legacy_stacked_cell $n"
  cell=1
  while [ "$cell" -le "$n" ]; do
    (${cells[cell]} > "$dir/$cell.log" 2>&1; echo $? > "$dir/$cell.rc") &
    running=$((running + 1))
    if [ "$running" -ge 8 ]; then
      wait
      running=0
    fi
    cell=$((cell + 1))
  done
  wait
  for cell in $(seq 1 "$n"); do
    [ "$(cat "$dir/$cell.rc" 2>/dev/null)" = 0 ] || failed="$failed${failed:+; }cell $cell: $(tail -n 3 "$dir/$cell.log" | tr '\n' ' ')"
  done
  [ -z "$failed" ] || fail "retry matrix failures: $failed"
  pass "the close retry matrix accepts only exact replays and the first close of a new opening, and never closes a newer or unidentifiable one"
}

test_verified_closes_refuse_unanswered_or_unsupported_calls() {
  local home id outcome file show
  home=$(make_home verified-refusals)
  id=sample-unanswered
  run_captain "$home" hold "$id" --title "Unanswered captain choice" --reason "which option?" >/dev/null
  printf 'Verified source: no decision yet.\n' > "$home/evidence.txt"
  : > "$home/empty.txt"
  printf ' \t\n' > "$home/blank.txt"
  printf 'reconcile\n' > "$home/reconcile.txt"
  for outcome in active unanswered reconcile; do
    if run_captain "$home" reconcile close "$id" --verified-outcome "$outcome" \
      --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
      fail "an $outcome call closed without an answer"
    fi
  done
  if run_captain "$home" reconcile close "$id" --verified-outcome moot >/dev/null 2>&1; then
    fail "verified close mutated a hold without an evidence file"
  fi
  for file in missing empty blank reconcile; do
    if run_captain "$home" reconcile close "$id" --verified-outcome moot \
      --evidence-file "$home/$file.txt" >/dev/null 2>&1; then
      fail "verified close accepted $file evidence"
    fi
  done
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "held: yes" "refused settlement released an unanswered call"
  assert_not_contains "$show" "Resolution recorded by" "refused settlement wrote a resolution"
  # An evidence close must not mark live work complete, even when its separate
  # captain choice has already been settled elsewhere.
  printf 'kind=ship\n' > "$home/state/$id.meta"
  if run_captain "$home" reconcile close "$id" --verified-outcome answered \
    --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
    fail "verified settlement completed worker-owned work"
  fi
  tasks_in "$home" add ordinary-work "Ordinary queued work" --repo sample >/dev/null
  if run_captain "$home" reconcile close ordinary-work --verified-outcome moot \
    --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
    fail "verified settlement completed work that was never captain-held"
  fi
  pass "verified closes refuse active calls, missing or reserved evidence, and unfinished work"
}

# Closing a call on evidence alone is a decision answer, so the two standalone
# paths take the supervision role partition fm-send --resolve-key takes: main
# owns them while attended, the branch is refused, and only the away-posture
# record relocates them. The board-requested close and `answer` stay outside it.
test_standalone_closes_follow_the_supervision_role_partition() {
  local home out rc show before open held
  home=$(make_home role-partition)
  printf 'kind=secondmate\n' > "$home/state/lane.meta"
  printf 'needs-decision [key=call-a]: first operational call\nneeds-decision [key=call-b]: second operational call\n' \
    > "$home/state/lane.status"
  for held in sample-held-a sample-held-b; do
    run_captain "$home" hold "$held" --title "Held $held" --reason "answers recorded elsewhere" >/dev/null \
      || fail "could not hold the partition fixture $held"
  done
  tasks_in "$home" add sample-board-call "Captain call: moot board question?" --repo sample >/dev/null
  run_captain "$home" hold sample-board-call --reason "moot board question?" >/dev/null
  request_reconciles "$home" partition-src sample-board-call || fail "could not file the board reconcile request"
  printf 'Verified source captured.txt: the recorded answers settle this call.\n' > "$home/evidence.txt"
  before=$(cat "$home/state/lane.status")

  set +e
  out=$(FM_SUPERVISION_ACTOR=branch run_captain "$home" reconcile close sample-held-a \
    --verified-outcome answered --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 6 ] || fail "an attended branch closed a captain call on evidence (rc=$rc): $out"
  assert_contains "$out" "decision answer (captain-hold reconcile close) refused" \
    "the verified close refusal lost its partition action label: $out"
  show=$(tasks_in "$home" show sample-held-a --full)
  assert_contains "$show" "held: yes" "the refused verified close released the call"
  assert_not_contains "$show" "Resolution recorded by" "the refused verified close wrote a resolution"

  set +e
  out=$(FM_SUPERVISION_ACTOR=branch run_captain "$home" reconcile close-key lane --key call-a \
    --verified-outcome answered --evidence-file "$home/evidence.txt" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 6 ] || fail "an attended branch closed an operational key on evidence (rc=$rc): $out"
  assert_contains "$out" "decision answer (captain-hold reconcile close) refused" \
    "the key close refusal lost its partition action label: $out"
  [ "$(cat "$home/state/lane.status")" = "$before" ] || fail "the refused key close appended a status event"
  assert_absent "$home/state/reconcile-evidence" "the refused key close persisted evidence"

  # The board-requested close is the existing path and takes no partition guard.
  FM_SUPERVISION_ACTOR=branch run_captain "$home" reconcile close sample-board-call \
    --evidence-file "$home/evidence.txt" >/dev/null || fail "the board-requested close was refused for the branch"
  assert_contains "$(tasks_in "$home" show sample-board-call --full)" "state: done" \
    "the board-requested close did not complete"

  # The away-posture record relocates both paths, as it does for fm-send.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null || fail "away entry failed"
  out=$(FM_SUPERVISION_ACTOR=branch run_captain "$home" reconcile close sample-held-a \
    --verified-outcome answered --evidence-file "$home/evidence.txt" 2>&1) \
    || fail "the relocated branch could not close the call on evidence: $out"
  assert_contains "$out" "main is parked" "the relocated verified close did not announce itself"
  assert_contains "$(tasks_in "$home" show sample-held-a --full)" "state: done" \
    "the relocated verified close did not complete"
  out=$(FM_SUPERVISION_ACTOR=branch run_captain "$home" reconcile close-key lane --key call-a \
    --verified-outcome answered --evidence-file "$home/evidence.txt" 2>&1) \
    || fail "the relocated branch could not close the operational key on evidence: $out"
  assert_contains "$out" "main is parked" "the relocated key close did not announce itself"
  open=$(bash -c '. "$1/bin/fm-status-decision-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$home/state/lane.status")
  assert_not_contains "$open" "call-a" "the relocated key close left the key open"
  assert_contains "$open" "call-b" "the relocated key close closed an unrelated key"

  # An archived record is absence: the attended refusal returns for the branch.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null || fail "away archive failed"
  set +e
  FM_SUPERVISION_ACTOR=branch run_captain "$home" reconcile close sample-held-b \
    --verified-outcome answered --evidence-file "$home/evidence.txt" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 6 ] || fail "an archived away record still relocated the verified close (rc=$rc)"
  set +e
  FM_SUPERVISION_ACTOR=branch run_captain "$home" reconcile close-key lane --key call-b \
    --verified-outcome answered --evidence-file "$home/evidence.txt" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 6 ] || fail "an archived away record still relocated the key close (rc=$rc)"

  # Main never meets the partition, attended or not.
  run_captain "$home" reconcile close sample-held-b --verified-outcome answered \
    --evidence-file "$home/evidence.txt" >/dev/null || fail "main could not close the call on evidence"
  assert_contains "$(tasks_in "$home" show sample-held-b --full)" "state: done" \
    "main's verified close did not complete"
  FM_SUPERVISION_ACTOR=main run_captain "$home" reconcile close-key lane --key call-b \
    --verified-outcome answered --evidence-file "$home/evidence.txt" >/dev/null \
    || fail "main could not close the operational key on evidence"
  open=$(bash -c '. "$1/bin/fm-status-decision-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$home/state/lane.status")
  [ -z "$open" ] || fail "main's key close left decisions open: $open"
  pass "standalone evidence closes refuse the attended branch, relocate under the away record, and leave main and the board path unchanged"
}

test_close_key_leaves_a_migrated_captain_hold_to_its_owner() {
  local fixture home beads before open
  require_tasks_axi_beads "close-key against a beads-migrated hold" || return 0
  fixture=$(make_beads_home close-key-migrated)
  home=${fixture%%|*}
  beads=${fixture##*|}
  printf 'kind=secondmate\n' > "$home/state/lane.meta"
  printf 'needs-decision [key=call-a]: the captain owns the migrated call\n' > "$home/state/lane.status"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi add fm-lane-call-a "Migrated call" --repo sample) >/dev/null 2>&1 \
    || fail "could not create the migrated hold fixture"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi hold fm-lane-call-a --kind captain --reason "captain must choose") >/dev/null 2>&1 \
    || fail "could not hold the migrated fixture row"
  bdrow "$beads" note fm-lane-call-a "migrated from data/backlog.md id lane-decision-call-a on 2026-09-04" \
    >/dev/null 2>&1 || fail "could not record the migration marker note"
  printf 'Verified source captured.txt: the recorded answer settles this call.\n' > "$home/evidence.txt"
  before=$(cat "$home/state/lane.status")
  if run_captain "$home" reconcile close-key lane --key call-a --verified-outcome answered \
    --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
    fail "close-key closed a key backed by an open migrated captain hold"
  fi
  [ "$(cat "$home/state/lane.status")" = "$before" ] || fail "the refused migrated-hold close mutated the status stream"
  assert_absent "$home/state/reconcile-evidence" "the refused migrated-hold close persisted evidence"
  (cd "$home" && BEADS_ACTOR=fixture tasks-axi "done" fm-lane-call-a) >/dev/null 2>&1 \
    || fail "could not close the migrated fixture row"
  run_captain "$home" reconcile close-key lane --key call-a --verified-outcome answered \
    --evidence-file "$home/evidence.txt" >/dev/null || fail "close-key refused a key whose migrated hold is already closed"
  open=$(bash -c '. "$1/bin/fm-status-decision-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$home/state/lane.status")
  assert_not_contains "$open" "call-a" "the close left the key open once its migrated hold closed"
  pass "close-key leaves a key backed by an open migrated captain hold to its owner"
}

test_operational_key_closes_with_durable_evidence_and_replay() {
  local home key outcome out evidence before open
  home=$(make_home operational-key-close)
  printf 'kind=secondmate\n' > "$home/state/lane.meta"
  printf 'needs-decision [key=recorded]: old answer not mirrored\nblocked [key=obsolete]: obsolete prerequisite\nneeds-decision [key=still-live]: captain must choose\n' \
    > "$home/state/lane.status"
  printf 'Verified source captured-answers.txt records the answer; obsolete prerequisite no longer applies.\n' > "$home/evidence.txt"
  for key in recorded obsolete; do
    if [ "$key" = recorded ]; then outcome=answered; else outcome=moot; fi
    out=$(run_captain "$home" reconcile close-key lane --key "$key" --verified-outcome "$outcome" \
      --evidence-file "$home/evidence.txt") || fail "could not close the status-only operational key"
    evidence=$(printf '%s\n' "$out" | sed -n 's/^evidence: //p')
    [ -f "$evidence" ] || fail "operational close lost its full evidence"
    assert_contains "$(cat "$evidence")" "Verified outcome: $outcome" "operational evidence lost its disposition"
    assert_contains "$(cat "$evidence")" "captured-answers.txt" "operational evidence lost its source"
    before=$(cat "$home/state/lane.status")
    run_captain "$home" reconcile close-key lane --key "$key" --verified-outcome "$outcome" \
      --evidence-file "$home/evidence.txt" >/dev/null || fail "operational evidence replay failed"
    [ "$(cat "$home/state/lane.status")" = "$before" ] || fail "operational replay appended duplicate close events"
    printf 'Different facts.\n' > "$home/different.txt"
    if run_captain "$home" reconcile close-key lane --key "$key" --verified-outcome "$outcome" \
      --evidence-file "$home/different.txt" >/dev/null 2>&1; then
      fail "different evidence rewrote a closed operational key"
    fi
  done
  open=$(bash -c '. "$1/bin/fm-status-decision-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$home/state/lane.status")
  assert_contains "$open" "still-live" "closing operational keys lost an unrelated captain call"
  assert_not_contains "$open" "recorded" "answered operational key remained open"
  assert_not_contains "$open" "obsolete" "moot operational key remained open"
  printf 'needs-decision [key=recorded]: a new captain choice\n' >> "$home/state/lane.status"
  if run_captain "$home" reconcile close-key lane --key recorded --verified-outcome answered \
    --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
    fail "old evidence closed a reopened operational key"
  fi
  open=$(bash -c '. "$1/bin/fm-status-decision-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$home/state/lane.status")
  assert_contains "$open" "recorded" "replay refusal lost the reopened call"
  pass "status-only operational closes preserve evidence, unrelated calls, and reopened-key replay safety"
}

test_key_opening_binding_is_a_position_in_the_whole_log() {
  local home binding
  home=$(make_home key-opening-large-log)
  printf 'kind=secondmate\n' > "$home/state/lane.meta"
  # 4500 padded lines, the keyed call as line 4501, then 200 more: about 5.3 MB, past the
  # 4 MiB tail window. The staged evidence is bound to the opening's line number, which
  # the log's append-only order keeps stable for its whole life, so it must be 4501
  # however large the log is.
  perl -e 'my $pad = "p" x 1100; print "working [at=$_]: step $_ $pad\n" for 1 .. 4500; print "needs-decision [key=big-call]: captain must choose\n"; print "working [at=$_]: later step $_ $pad\n" for 1 .. 200;' \
    > "$home/state/lane.status"
  printf 'Verified source captured.txt: the answer was recorded elsewhere.\n' > "$home/evidence.txt"
  run_captain "$home" reconcile close-key lane --key big-call --verified-outcome answered \
    --evidence-file "$home/evidence.txt" >/dev/null || fail "the close of a key opened in a 5 MB log failed"
  binding=$(find "$home/state/reconcile-evidence/lane" -name 'big-call-*.opening' -type f)
  [ -f "$binding" ] || fail "the close staged no opening binding"
  [ "$(cat "$binding")" = 4501 ] || fail "the opening binding is $(cat "$binding"), not the opening's line number 4501"
  pass "a key close binds its staged evidence to the opening's true line number in a log past the tail window"
}

test_operational_key_close_refusals_and_interrupted_append() {
  local home key before open evidence
  home=$(make_home operational-key-refusals)
  printf 'kind=secondmate\n' > "$home/state/lane.meta"
  printf 'needs-decision [key=plain]: verify operational question\nneeds-decision [key=stale]: verify the second operational question\nneeds-decision [key=held-call]: captain still owns this\nneeds-decision [key=legacy]: captain owns legacy task\nneeds-decision [key=captain-hold-child-1]: captain hold child\nblocked [key=pending-reply-child]: pending-reply-missed: unavailable\n' \
    > "$home/state/lane.status"
  run_captain "$home" hold held-call --title "Held call" --reason "still needs captain" >/dev/null
  run_captain "$home" hold lane-decision-legacy --title "Legacy held call" --reason "still needs captain" >/dev/null
  printf 'Verified dependency is now available.\n' > "$home/evidence.txt"
  before=$(cat "$home/state/lane.status")
  for key in held-call legacy captain-hold-child-1 pending-reply-child; do
    if run_captain "$home" reconcile close-key lane --key "$key" --verified-outcome moot \
      --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
      fail "operational closer bypassed the owner of $key"
    fi
  done
  if run_captain "$home" reconcile close-key lane --key plain --verified-outcome active \
    --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
    fail "operational closer accepted an active call"
  fi
  if run_captain "$home" reconcile close-key lane --key plain --verified-outcome moot >/dev/null 2>&1; then
    fail "operational closer accepted no evidence"
  fi
  if run_captain "$home" reconcile close-key lane --key plain --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
    fail "operational closer inferred a disposition from prose"
  fi
  if run_captain "$home" reconcile close-key lane --key absent --verified-outcome moot \
    --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
    fail "operational closer created a close for an absent key"
  fi
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = plain ]; then
  printf 'error: fixture backend unavailable\n'
  exit 86
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  if run_captain "$home" reconcile close-key lane --key plain --verified-outcome moot \
    --evidence-file "$home/evidence.txt" >/dev/null 2>&1; then
    fail "operational closer treated an unreadable backlog as proof of no captain hold"
  fi
  rm "$home/fakebin/tasks-axi"
  [ "$(cat "$home/state/lane.status")" = "$before" ] || fail "a refused operational close mutated the status stream"
  [ ! -e "$home/state/reconcile-evidence" ] || fail "a refused operational close wrote evidence"
  # Stage evidence successfully, but force the subsequent status append to fail.
  chmod 0400 "$home/state/lane.status"
  for key in plain stale; do
    if run_captain "$home" reconcile close-key lane --key "$key" --verified-outcome moot \
      --evidence-file "$home/evidence.txt" > "$home/append.out" 2>&1; then
      fail "failed status append reported a successful close of $key"
    fi
    evidence=$(find "$home/state/reconcile-evidence" -name "$key-*.txt" -type f)
    [ -f "$evidence" ] || fail "interrupted append lost staged evidence for $key"
  done
  chmod 0600 "$home/state/lane.status"
  [ "$(cat "$home/state/lane.status")" = "$before" ] || fail "failed append changed the status stream"
  # The second call is settled elsewhere and then asked again as a new unanswered
  # choice: its staged evidence belongs to the earlier opening and must not close it.
  printf 'resolved [key=stale]: answered elsewhere\nneeds-decision [key=stale]: a new unanswered captain choice\n' \
    >> "$home/state/lane.status"
  before=$(cat "$home/state/lane.status")
  if run_captain "$home" reconcile close-key lane --key stale --verified-outcome moot \
    --evidence-file "$home/evidence.txt" > "$home/stale.out" 2>&1; then
    fail "stale staged evidence closed a reopened unanswered call"
  fi
  assert_contains "$(cat "$home/stale.out")" "earlier or unidentifiable opening" \
    "the stale staged evidence refusal did not name the opening mismatch"
  [ "$(cat "$home/state/lane.status")" = "$before" ] || fail "the refused stale retry mutated the reopened call"
  open=$(bash -c '. "$1/bin/fm-status-decision-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$home/state/lane.status")
  assert_contains "$open" "stale" "the stale retry closed the reopened call"
  # The same opening still resumes from its staged evidence.
  run_captain "$home" reconcile close-key lane --key plain --verified-outcome moot \
    --evidence-file "$home/evidence.txt" >/dev/null || fail "operational append could not retry from durable evidence"
  open=$(bash -c '. "$1/bin/fm-status-decision-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$home/state/lane.status")
  assert_not_contains "$open" "plain" "retried operational close stayed open"
  assert_contains "$open" "held-call" "operational close lost a captain-owned call"
  assert_contains "$open" "stale" "the retry of another key closed the reopened call"
  pass "operational closes enforce ownership and attestation, recover after an interrupted append, and refuse staged evidence once the call reopened"
}

test_unbound_source_closes_no_hold() {
  local home id sid artifact result out show rc
  home=$(make_home lavish-unbound)
  id=sample-unbound-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample without binding" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the unbound origin"
  write_origin_meta "$home" "$id"
  printf 'done: deck ready\n' > "$home/state/$id.status"
  printf '# Unbound review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-only-call --title "Captain call: only choice" \
    --reason "captain only choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unbound call"

  artifact="$home/data/$id/review.html"
  printf '<h1>Unbound</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the unbound source id"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the unbound review"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "2","Only choice: yes\n\nContext data:\n{\n  \"question\": \"sample-only-call\",\n  \"answer\": \"yes\"\n}","form",choice,"Only choice: yes"
EOF
  set +e
  out=$(run_captain "$home" binding "$sid" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unbound source reported a binding"
  [ -z "$out" ] || fail "an unbound source printed a binding: $out"
  show=$(tasks_in "$home" show sample-only-call --full)
  assert_contains "$show" "state: queued" "an unbound review closed a captain call"
  assert_contains "$show" "held: yes" "an unbound review released a captain call"
  pass "a channel source with no decision binding closes nothing"
}

# Everything a pre-collapse install already has keeps working: composed
# identities through the shim, short decision keys in recorded metadata, a
# concrete-origin binding, and the chat fallback for old rows.
test_legacy_identities_keep_working() {
  local home id hold out show legacy_text legacy_digest old_hold
  home=$(make_home legacy-compat)
  id=sample-legacy-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Legacy-shaped review" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"

  hold=$(run_shim "$home" id "$id" pick-one)
  [ "$hold" = "$id-decision-pick-one" ] || fail "the shim identity was not deterministic: $hold"
  out=$(run_shim "$home" hold "$id" pick-one \
    --title "Pick one" --reason "captain choice pending" --repo sample) \
    || fail "the shim hold path failed"
  [ "$out" = "$hold" ] || fail "the shim hold did not print the composed identity: $out"
  run_shim "$home" hold "$id" keep-two \
    --title "Keep two" --reason "captain second choice pending" --repo sample >/dev/null \
    || fail "the shim second hold failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "hold_kind: captain" "the shim-created row is not a plain captain-held task"

  # A pre-collapse metadata attestation records SHORT keys; verify must resolve
  # them through the legacy composed identity.
  printf 'decisions_reviewed=1\ndecision_keys=keep-two,pick-one\n' >> "$home/state/$id.meta"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "legacy short-key metadata did not verify against composed identities"

  # The shim's routed close records the routed work inside the captain decision
  # and clears the recorded edge.
  tasks_in "$home" add sample-legacy-work "Apply the legacy choice" \
    --kind ship --repo sample --blocked-by "$hold" >/dev/null
  tasks_in "$home" add sample-unrouted-work "Unrouted legacy work" \
    --kind ship --repo sample >/dev/null
  printf 'Use route north.\n' > "$home/route.txt"
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-missing-work > "$home/missing-route.out" 2> "$home/missing-route.err"; then
    fail "the shim resolve accepted a missing routed task"
  fi
  if run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-unrouted-work > "$home/unrouted.out" 2> "$home/unrouted.err"; then
    fail "the shim resolve accepted work not blocked by the legacy decision"
  fi
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: queued" "invalid shim routing closed the legacy decision"
  assert_not_contains "$show" "Resolution recorded" "invalid shim routing recorded an answer"
  run_shim "$home" resolve "$id" pick-one --decision-file "$home/route.txt" \
    --routed-to sample-legacy-work >/dev/null \
    || fail "the shim resolve path failed"
  show=$(tasks_in "$home" show "$hold" --full)
  assert_contains "$show" "state: done" "the shim resolve did not close the row"
  assert_contains "$show" "Use route north." "the shim resolve lost the captain decision"
  assert_contains "$show" "- sample-legacy-work" "the shim resolve lost the routed identities"
  show=$(tasks_in "$home" show sample-legacy-work --full)
  assert_contains "$show" "blocked: no" "the shim resolve did not release the routed work"

  old_hold=$(run_shim "$home" hold "$id" old-route \
    --title "Old routed choice" --reason "captain old route pending" --repo sample)
  tasks_in "$home" add sample-old-routed-work "Apply the old routed choice" \
    --kind ship --repo sample --blocked-by "$old_hold" >/dev/null
  printf 'Use the historical route.\n' > "$home/old-route.txt"
  legacy_text=$(cat "$home/old-route.txt")
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: sample-old-routed-work\nResolution mode: routed\n\nCaptain decision:\n%s\n\nRouted work:\n- sample-old-routed-work\n' \
    "$legacy_digest" "$legacy_text" > "$home/old-route-body.txt"
  tasks_in "$home" update "$old_hold" --body-file "$home/old-route-body.txt" --archive-body >/dev/null
  run_shim "$home" resolve "$id" old-route --decision-file "$home/old-route.txt" \
    --routed-to sample-old-routed-work >/dev/null \
    || fail "the shim did not replay a matching pre-collapse routed record"
  show=$(tasks_in "$home" show "$old_hold" --full)
  assert_contains "$show" "state: done" "the replayed legacy resolve did not close its hold"
  show=$(tasks_in "$home" show sample-old-routed-work --full)
  assert_contains "$show" "blocked_by: none" "the replayed legacy resolve did not clear its recorded edge"

  # The shim decline path maps onto the same recorded answer.
  printf 'Declined: keep the current shape.\n' > "$home/decline.txt"
  run_shim "$home" decline "$id" keep-two --decision-file "$home/decline.txt" >/dev/null \
    || fail "the shim decline path failed"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "shim-closed rows did not satisfy the completion gate"

  # A concrete-origin binding (a pre-collapse record) makes short channel keys
  # resolve through the composed identity.
  run_shim "$home" hold "$id" third-choice \
    --title "Third choice" --reason "captain third choice pending" --repo sample >/dev/null
  run_shim "$home" bind legacy-src "$id" >/dev/null || fail "the shim bind path failed"
  [ "$(run_captain "$home" binding legacy-src)" = "$id" ] \
    || fail "the concrete-origin binding was not preserved"
  printf 'third-choice\toption b\t\n' \
    | run_captain "$home" answers "$(run_captain "$home" binding legacy-src)" \
        --source "legacy channel" >/dev/null \
    || fail "a short key did not resolve through the concrete-origin binding"
  show=$(tasks_in "$home" show "$id-decision-third-choice" --full)
  assert_contains "$show" "state: done" "the legacy-keyed answer did not close its row"

  run_shim "$home" hold "$id" fourth-choice \
    --title "Fourth choice" --reason "captain fourth choice pending" --repo sample >/dev/null
  legacy_text=$(printf 'Captain answered this decision through legacy replay.\nDecision key: fourth-choice\nAnswer: option c\n')
  if command -v shasum >/dev/null 2>&1; then
    legacy_digest=$(printf '%s' "$legacy_text" | shasum -a 256 | awk '{print $1}')
  else
    legacy_digest=$(printf '%s' "$legacy_text" | sha256sum | awk '{print $1}')
  fi
  printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\nRouted identities: none\nResolution mode: answered\n\nCaptain decision:\n%s\n' \
    "$legacy_digest" "$legacy_text" > "$home/legacy-body.txt"
  tasks_in "$home" update "$id-decision-fourth-choice" --body-file "$home/legacy-body.txt" --archive-body >/dev/null
  tasks_in "$home" "done" "$id-decision-fourth-choice" >/dev/null
  out=$(printf 'fourth-choice\toption c\t\n' \
    | run_captain "$home" answers "$id" --source "legacy replay") \
    || fail "an identical pre-collapse keyed answer was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the pre-collapse keyed answer digest was treated as drift"
  out=$(printf '%s-decision-fourth-choice\toption c\t\n' "$id" \
    | run_captain "$home" answers --source "legacy replay") \
    || fail "a full legacy task-id replay without an origin was not idempotent"
  assert_contains "$out" "closed: $id-decision-fourth-choice" \
    "the origin-free legacy replay digest was treated as drift"
  pass "legacy identities, metadata, bindings, and the shim keep working"
}

# A board answer must reach the keyed-answer intake through the RUNNER, not just
# through a hand-fed `answers` call. The captain answered ten calls on a bearings
# board, the board accepted them, and nothing collected them: the source that
# collects a board is a supervised process, and while it was not running the
# board went on presenting as armed. Everything between the captured result and
# the closed task is asserted here end to end - capture, the wake that tells
# firstmate to look, and the recorded answer - because each of those was intact
# on its own while the chain as a whole delivered nothing.
test_board_answer_reaches_the_keyed_answer_intake() {
  local home sid stub out queue show
  home=$(make_home board-channel)
  sid=lavish-b0a4d0000000f1e2
  fm_test_track_procevent_home "$home" "$home/procevent-claims"

  run_captain "$home" hold sample-board-call --title "Choose the sample board route" \
    --reason "captain board route choice pending" --repo sample >/dev/null \
    || fail "could not register the board call"

  # One published Lavish poll response carrying the captain's structured answer,
  # in the shape the adapter's own reader parses: a declared field order, an
  # indented CSV row, and the versioned answer context inside its prompt.
  stub="$home/board-source.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
printf 'called\n' >> "$FM_HOME/board-source.calls"
cat <<'OUT'
session:
  status: feedback
  session_ended: false
prompts[1]{tag,text,prompt}:
  "choice","Take the north route","Context data: {\"schema\":\"fm-bearings-answer.v1\",\"question\":\"sample-board-call\",\"selection\":\"north\",\"note\":\"\"}"
OUT
SH
  chmod +x "$stub"

  run_procevent "$home" register lavish "$sid" -- "$stub" >/dev/null \
    || fail "could not register the board source"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the board source to the keyed-answer intake"

  out=$(fm_run_timed 30 env PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start "$sid" 2>&1) \
    || fail "the board source runner did not complete within 30 seconds: $out"
  assert_contains "$out" "$sid.1.result" "the board answer was never durably captured: $out"
  assert_contains "$out" "answers-fed: $sid" \
    "the captured board answer never reached the keyed-answer intake: $out"
  assert_equals called "$(cat "$home/board-source.calls")" \
    "the replayable board source must run exactly once"
  assert_absent "$home/state/procevent-inbox/$sid.2.result" \
    "the replayable board source captured the same answer twice"
  assert_absent "$home/procevent-claims/$sid.claim" \
    "the completed attached board source retained its claim"

  queue=$(cat "$home/state/.wake-queue" 2>/dev/null || true)
  assert_contains "$queue" "check: procevent lavish $sid 1" \
    "the captured board answer produced no wake: $queue"

  show=$(tasks_in "$home" show sample-board-call --full)
  assert_contains "$show" "state: done" "the board answer did not close the captain call"
  assert_contains "$show" "north" "the board answer lost the captain's selection"
  assert_contains "$show" "the captured result $sid sequence 1" \
    "the recorded answer did not name the board result that carried it"
  run_procevent "$home" retire "$sid" >/dev/null \
    || fail "could not retire the board-answer source"
  pass "a board answer reaches the keyed-answer intake and wakes firstmate"
}

# The intake is channel-agnostic, so chat must reach it the same way a captured
# review does - for a task-id key, and for a legacy composed identity.
test_chat_channel_feeds_the_same_keyed_answer_intake() {
  local home id fb show list
  home=$(make_home chat-channel)
  id=sample-chat-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review sample chat routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the chat-channel origin"
  write_origin_meta "$home" "$id" ship
  printf 'needs-decision [key=chat-choice]: pick option A or option B\n' > "$home/state/$id.status"
  printf '# Chat review\n\nTwo captain choices remain.\n' > "$home/data/$id/report.md"
  run_shim "$home" hold "$id" chat-choice \
    --title "Choose the sample chat option" --reason "captain chat choice pending" --repo sample >/dev/null \
    || fail "could not register the legacy chat row"
  run_captain "$home" hold sample-chat-followup --title "Choose the chat follow-up" \
    --reason "captain follow-up choice pending" --repo sample >/dev/null \
    || fail "could not register the task-id chat call"
  run_captain "$home" hold sample-chat-reconcile --title "Reconcile from chat" \
    --reason "captain chat reconcile pending" --repo sample >/dev/null \
    || fail "could not register the chat reconcile call"
  run_captain "$home" complete "$id" "$id-decision-chat-choice" sample-chat-followup \
    sample-chat-reconcile >/dev/null \
    || fail "completion failed for the chat calls"
  grep -F 'captain-held [key=chat-choice]' "$home/state/$id.status" >/dev/null \
    || fail "precondition: completion did not transfer the decision to its durable owner"

  fb="$home/fakebin"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key chat-choice "go with option A" >/dev/null 2>&1 \
    || fail "an answer to a transferred legacy decision was refused by the chat channel"
  # The answer rides fm-send's durable inbox plane: the record carries the
  # text while the typed channel carries only the doorbell.
  grep -qF "go with option A" "$home/state/$id.inbox/001.msg" \
    || fail "the answer text never reached the worker's durable inbox record"
  show=$(tasks_in "$home" show "$id-decision-chat-choice" --full)
  assert_contains "$show" "state: done" "a chat answer left the legacy row open"
  assert_contains "$show" "Answer: go with option A" "the chat-answered row lost the captain answer"

  : > "$home/send.log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "take the second option" >/dev/null 2>&1 \
    || fail "an answer keyed by a task id was refused by the chat channel"
  show=$(tasks_in "$home" show sample-chat-followup --full)
  assert_contains "$show" "state: done" "a chat answer left the task-id call open"
  assert_contains "$show" "Resolution mode: answered" "the chat-answered call did not record its close path"
  assert_contains "$show" "Answer: take the second option" "the chat-answered call lost the captain answer"
  assert_contains "$show" "answer sent to $id" "the chat-answered call lost its channel provenance"

  : > "$home/send.log"
  set +e
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-reconcile reconcile >/dev/null 2>&1
  set -e
  show=$(tasks_in "$home" show sample-chat-reconcile --full)
  assert_contains "$show" "state: queued" "a chat reconcile answer closed the call"
  list=$(run_captain "$home" reconcile list)
  assert_contains "$list" "reconcile-requests: 0" "a chat reconcile answer created a board request"
  printf 'Chat cannot authorize this closure.\n' > "$home/chat-reconcile.txt"
  if run_captain "$home" reconcile close sample-chat-reconcile \
    --evidence-file "$home/chat-reconcile.txt" >/dev/null 2>&1; then
    fail "a chat reconcile answer authorized evidence-backed closure"
  fi
  run_captain "$home" answer sample-chat-reconcile --decision-file "$home/chat-reconcile.txt" >/dev/null \
    || fail "could not close the chat reconcile fixture normally"

  if env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    "$ROOT/bin/fm-send.sh" "$id" --resolve-key sample-chat-followup "again" \
    > "$home/closed-key.out" 2> "$home/closed-key.err"; then
    fail "a key already closed in both ledgers was accepted"
  fi
  run_captain "$home" verify "$id" >/dev/null \
    || fail "chat-answered calls did not satisfy the completion gate"
  pass "the chat channel feeds the same keyed-answer intake a captured review does"
}

test_origin_slug_validation_precedes_path_construction() {
  local home
  home=$(make_home slug-validation)
  if run_captain "$home" complete "../escape" --none > "$home/escape.out" 2> "$home/escape.err"; then
    fail "complete accepted a path-escaping origin id"
  fi
  assert_grep "privacy-safe slug" "$home/escape.err" "the refusal must name the slug contract"
  if run_captain "$home" verify "../escape" > "$home/escape-verify.out" 2> "$home/escape-verify.err"; then
    fail "verify accepted a path-escaping origin id"
  fi
  if run_captain "$home" hold "bad id" --title "x" --reason "y" > "$home/bad-hold.out" 2> "$home/bad-hold.err"; then
    fail "hold accepted an invalid task id"
  fi
  pass "completion and verification validate origins before constructing paths"
}

# --- record divergence ------------------------------------------------------

run_drain() {  # <home>
  local home=$1
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null
}

# Reconstructs the 2026-08-06 loss with synthetic names: the answer was posted
# as a `resolved [key=...]` line and nothing else, so the status fold went quiet
# while the durable captain-held task stayed open and kept reading as if the
# captain had never spoken. Both identities that can carry a captain call must
# be caught - the collapsed one (the key IS the task id) and the legacy derived
# one a pre-collapse origin minted - and the report must reach the drain, which
# is where firstmate actually looks.
test_status_resolution_over_an_open_hold_is_signalled() {
  local home id out drain
  home=$(make_home divergence-signalled)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the collapsed-identity captain call"
  run_captain "$home" hold "$id-decision-access" \
    --title "Open or restricted sample access" --reason "captain access choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the legacy-identity captain call"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-route-call]: north or south
resolved [key=sample-route-call]: answered: north
needs-decision [key=access]: open or restricted sample access
resolved [key=access]: answered: restricted
done: report complete
EOF

  out=$(run_captain "$home" diverged) || fail "diverged failed on the reconstructed loss"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "the collapsed-identity divergence was not signalled: $out"
  printf '%s\n' "$out" | grep -F "$id-decision-access	$id	access" >/dev/null \
    || fail "the legacy-identity divergence was not signalled: $out"

  drain=$(run_drain "$home") || fail "the drain failed while reporting divergence"
  printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null \
    || fail "the divergence never reached the drain: $drain"
  printf '%s\n' "$drain" | grep -F 'sample-route-call [key=sample-route-call]' >/dev/null \
    || fail "the drain section omitted the collapsed-identity divergence: $drain"
  printf '%s\n' "$drain" | grep -F "$id-decision-access [key=access]" >/dev/null \
    || fail "the drain section omitted the legacy-identity divergence: $drain"

  # It signals; it never closes. Both records must survive the report unchanged,
  # because closing a captain call wrongly removes it from review entirely.
  assert_grep "sample-route-call" "$home/data/backlog.md" "the report must not remove the captain-held task"
  tasks_in "$home" show sample-route-call --full | grep -E '^  held: yes' >/dev/null \
    || fail "the report released or closed the captain-held task"
  [ "$(grep -c '^resolved \[key=sample-route-call\]' "$home/state/$id.status")" = 1 ] \
    || fail "the report rewrote the status log"

  # And it names BOTH reconciliation directions. A status resolution is not proof
  # the captain ruled: one of the real cases dissolved because its premise was
  # false and another was a question of fact whose first reading was wrong, so
  # the only safe instruction is "reconcile with what actually happened".
  printf '%s\n' "$drain" | grep -F 'fm-captain-hold.sh answer' >/dev/null \
    || fail "the drain section does not say how to record the captain's answer: $drain"
  printf '%s\n' "$drain" | grep -F 're-open the status decision' >/dev/null \
    || fail "the drain section does not offer the re-open direction: $drain"
  pass "a status resolution over a still-open captain-held task is signalled, not closed"
}

# `diverged` runs on every wake drain, over every lane's status log. It must never hand a
# whole log to grep, so a runaway log cannot be read again by every drain: a log past the
# read limit (bin/fm-status-cap-lib.sh) yields no key tokens and no report, and a log
# inside it is reported exactly as before. A grep stand-in on PATH records any status log
# it is handed as a file operand; the limit is set small so the fixture stays tiny.
test_diverged_never_hands_a_status_log_to_grep_and_skips_one_past_the_limit() {
  local home id out real_grep err
  home=$(make_home divergence-bounded)
  id=sample-route-review
  tasks_in "$home" add "$id" "Investigate sample routing" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north or south" --reason "captain route choice pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain call"
  printf 'needs-decision [key=sample-route-call]: north or south\nresolved [key=sample-route-call]: answered: north\n' \
    > "$home/state/$id.status"
  real_grep=$(command -v grep)
  err="$home/grep-operands.log"
  : > "$err"
  # shellcheck disable=SC2016 # The stand-in's own source is written literally.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'for a in "$@"; do case "$a" in *.status) printf "%%s\\n" "$a" >> %q ;; esac; done\n' "$err"
    printf 'exec %q "$@"\n' "$real_grep"
  } > "$home/fakebin/grep"
  chmod +x "$home/fakebin/grep"

  out=$(FM_STATUS_CAP_BYTES=2048 FM_STATUS_CAP_RESERVE_BYTES=1024 run_captain "$home" diverged) \
    || fail "diverged failed on a log inside the read limit"
  printf '%s\n' "$out" | grep -F "sample-route-call	$id	sample-route-call" >/dev/null \
    || fail "a log inside the read limit was no longer reported: $out"
  [ ! -s "$err" ] || fail "diverged handed a status log to grep as a file operand: $(cat "$err")"

  perl -e 'print "working: padding line to push the log past the limit\n" x 80' >> "$home/state/$id.status"
  [ "$(wc -c < "$home/state/$id.status" | tr -d ' ')" -gt 3072 ] || fail "the fixture log is not past the read limit"
  out=$(FM_STATUS_CAP_BYTES=2048 FM_STATUS_CAP_RESERVE_BYTES=1024 run_captain "$home" diverged) \
    || fail "diverged failed on a log past the read limit"
  [ -z "$out" ] || fail "a log past the read limit still produced a report: $out"
  [ ! -s "$err" ] || fail "diverged handed a status log past the limit to grep: $(cat "$err")"
  pass "diverged reports a log inside the read limit, skips one past it, and never hands a status log to grep"
}

# The false-signal boundary, driven by the shapes that are genuinely fine. A
# captain call whose deliverable IS the decision has no routed work item at all,
# and that is legitimate: routed work must never be part of the test. Nor may a
# verified `captain-held` transfer, a still-open status decision, an already
# answered call, or an ordinary task that merely had a keyed question answered.
test_legitimate_holds_produce_no_divergence_signal() {
  local home id out drain answer
  home=$(make_home divergence-no-false-signal)
  id=sample-systems-review
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"

  # (1) The decision IS the deliverable: held for the captain, nothing routed,
  # no status line anywhere naming it.
  run_captain "$home" hold sample-standalone-call \
    --title "Adopt the sample naming convention" --reason "captain call with no routed work" \
    --repo sample >/dev/null || fail "could not register the deliverable-is-the-decision call"
  # (2) The verified transfer: still open structurally, closed on the status side
  # by the captain-held verb command_complete writes.
  run_captain "$home" hold sample-transfer-call \
    --title "Choose the sample retention window" --reason "captain retention choice pending" \
    --repo sample >/dev/null || fail "could not register the transferred call"
  # (4) An already answered call whose status line reads resolved.
  run_captain "$home" hold sample-answered-call \
    --title "Choose the sample export format" --reason "captain export choice pending" \
    --repo sample >/dev/null || fail "could not register the answered call"
  answer="$home/answer.txt"
  printf 'Export as CSV.\n' > "$answer"
  run_captain "$home" answer sample-answered-call --decision-file "$answer" >/dev/null \
    || fail "could not record the captain answer fixture"
  # (5) An ordinary in-flight work item that is not held for the captain.
  tasks_in "$home" add sample-plain-work "Ordinary sample work" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the ordinary work fixture"

  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=sample-transfer-call]: choose the retention window
captain-held [key=sample-transfer-call]: tracked by sample-transfer-call
needs-decision [key=sample-open-call]: still open on both sides
needs-decision [key=sample-answered-call]: choose the export format
resolved [key=sample-answered-call]: answered: CSV
needs-decision [key=sample-plain-work]: worker question about the sample fixture
resolved [key=sample-plain-work]: answered: go ahead
EOF
  # (3) A still-open status decision whose structured twin is also still open.
  run_captain "$home" hold sample-open-call \
    --title "Choose the sample refresh cadence" --reason "captain cadence choice pending" \
    --repo sample >/dev/null || fail "could not register the still-open call"

  out=$(run_captain "$home" diverged) || fail "diverged failed on the legitimate shapes"
  [ -z "$out" ] || fail "legitimate captain holds produced a false divergence signal: $out"

  drain=$(run_drain "$home") || fail "the drain failed on the legitimate shapes"
  if printf '%s\n' "$drain" | grep -F 'RECORD DIVERGENCE' >/dev/null; then
    fail "the drain printed a divergence section with nothing diverging: $drain"
  fi
  printf '%s\n' "$drain" | grep -F 'sample-open-call' >/dev/null \
    || fail "setup error: the still-open decision should still reach OPEN DECISIONS: $drain"
  pass "a captain call with no routed work, a verified transfer, an open decision, and an answered call all stay silent"
}

tests=(
test_legacy_reconcile_replaces_previous_choices
test_reconcile_never_closes_through_the_keyed_answer_intake
test_normal_answers_retire_pending_reconcile_requests
test_reconcile_closes_with_evidence_or_keeps_the_call_open
test_reconcile_outcomes_retry_partial_failures_once
test_verified_close_without_board_request
test_verified_close_retries_only_its_own_hold
test_interrupted_close_retries_only_as_an_exact_replay
test_verified_close_retry_matrix
test_verified_closes_refuse_unanswered_or_unsupported_calls
test_close_key_leaves_a_migrated_captain_hold_to_its_owner
test_operational_key_closes_with_durable_evidence_and_replay
test_key_opening_binding_is_a_position_in_the_whole_log
test_operational_key_close_refusals_and_interrupted_append
test_standalone_closes_follow_the_supervision_role_partition
test_unbound_source_closes_no_hold
test_legacy_identities_keep_working
test_board_answer_reaches_the_keyed_answer_intake
test_chat_channel_feeds_the_same_keyed_answer_intake
test_origin_slug_validation_precedes_path_construction
test_status_resolution_over_an_open_hold_is_signalled
test_diverged_never_hands_a_status_log_to_grep_and_skips_one_past_the_limit
test_legitimate_holds_produce_no_divergence_signal
)
captain_hold_run_tests "$@"
