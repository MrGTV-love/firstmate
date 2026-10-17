#!/usr/bin/env bash
# Keyed-answer intake regressions: bound-channel answers, default and done
# releases, interrupted and replayed releases, and unversioned deck shapes.
# Shared definitions and fixture setup live in fm-captain-hold-lifecycle-helpers.sh.
set -u

# shellcheck source=tests/fm-captain-hold-lifecycle-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-lifecycle-helpers.sh"

# The one keyed-answer intake, fed through the real process-event runner by a
# fixture channel that knows nothing about captain holds: task-id keys close at
# answer time, a card-declared release mode frees held work, freeform prose can
# forge nothing, and a replayed capture is idempotent.
test_bound_channel_answers_close_at_answer_time() {
  local home id sid artifact result out show rc
  home=$(make_home channel-answer-closure)
  id=sample-eval-proposal
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Propose sample eval changes" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the review origin"
  write_origin_meta "$home" "$id"
  printf 'done: proposal deck ready for the captain\n' > "$home/state/$id.status"
  printf '# Sample eval proposal\n\nThree captain choices remain.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-membership-call --title "Captain call: membership" \
    --reason "captain membership choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-headline-call --title "Captain call: headline" \
    --reason "captain headline choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-forged-call --title "Captain call: forged" \
    --reason "captain forged choice pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-invalid-close-call --title "Captain call: invalid close" \
    --reason "captain close mode validation pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-source-reconcile --title "Captain call: reconcile" \
    --reason "captain re-check pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-bare-reconcile --title "Captain call: bare reconcile" \
    --reason "captain bare re-check pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-shape --title "Captain call: old board shape" \
    --reason "captain old board pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-reconcile --title "Captain call: old bare reconcile" \
    --reason "captain old bare reconcile pending" --repo sample --origin "$id" >/dev/null
  run_captain "$home" hold sample-old-reconcile-note --title "Captain call: old annotated reconcile" \
    --reason "captain old annotated reconcile pending" --repo sample --origin "$id" >/dev/null
  tasks_in "$home" add sample-gated-work "Gated sample work" --kind ship --repo sample \
    --body 'Gated work plan.' >/dev/null
  run_captain "$home" hold sample-gated-work --reason "captain go needed" >/dev/null
  run_captain "$home" complete "$id" \
    sample-membership-call sample-headline-call sample-forged-call sample-invalid-close-call \
    sample-source-reconcile sample-bare-reconcile sample-old-shape sample-old-reconcile \
    sample-old-reconcile-note sample-gated-work >/dev/null \
    || fail "completion failed for the deck's inventoried calls"

  artifact="$home/data/$id/review.html"
  printf '<h1>Sample eval proposal</h1>\n' > "$artifact"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the review source id"
  run_captain "$home" bind "$sid" >/dev/null \
    || fail "could not bind the review source to the keyed-answer intake"
  [ "$(run_captain "$home" binding "$sid")" = "(any)" ] \
    || fail "the recorded binding did not resolve to the collapsed marker"
  run_lavish "$home" arm "$artifact" >/dev/null || fail "could not arm the review deck"

  result="$home/state/procevent-inbox/$sid.1.result"
  mkdir -p "$home/state/procevent-inbox"
  cat > "$result" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[13]{uid,prompt,selector,tag,text}:
  "1","Reconcile first\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-source-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(6)",choice,"Reconcile"
  "2","Membership: gold-only - captain detail\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-membership-call\",\n  \"selection\": \"gold-only\",\n  \"note\": \"captain detail\"\n}","section#call > form:nth-of-type(1)",choice,"Membership: gold-only - captain detail"
  "3","Headline: f1-when-fp-gold\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-headline-call\",\n  \"selection\": \"f1-when-fp-gold\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "4","Gated work: go\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-gated-work\",\n  \"selection\": \"go\",\n  \"note\": \"\",\n  \"close\": \"release\"\n}","section#call > form:nth-of-type(3)",choice,"Gated work: go"
  "5","Absent call: yes\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-nonexistent-call\",\n  \"selection\": \"yes\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(4)",choice,"Absent call: yes"
  "6","Invalid close: yes\n\nContext data:\n{\n  \"question\": \"sample-invalid-close-call\",\n  \"answer\": \"yes\",\n  \"close\": \"drop\"\n}","section#call > form:nth-of-type(5)",choice,"Invalid close: yes"
  "7","Reconcile this - re-check latest publication\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-source-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"re-check latest publication\"\n}","section#call > form:nth-of-type(6)",choice,"Reconcile - re-check latest publication"
  "8","Second reconcile\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-bare-reconcile\",\n  \"selection\": \"reconcile\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(7)",choice,"Reconcile"
  "9","Headline final: f1-when-fp-gold\n\nContext data:\n{\n  \"schema\": \"fm-bearings-answer.v1\",\n  \"question\": \"sample-headline-call\",\n  \"selection\": \"f1-when-fp-gold\",\n  \"note\": \"\"\n}","section#call > form:nth-of-type(2)",choice,"Headline: f1-when-fp-gold"
  "10","Old board answer\n\nContext data:\n{\n  \"question\": \"sample-old-shape\",\n  \"answer\": \"yes\"\n}","section#call > form:nth-of-type(8)",choice,"Old answer: yes"
  "11","Old board reconcile\n\nContext data:\n{\n  \"question\": \"sample-old-reconcile\",\n  \"answer\": \"reconcile\"\n}","section#call > form:nth-of-type(9)",choice,"Old reconcile"
  "12","Old board reconcile note\n\nContext data:\n{\n  \"question\": \"sample-old-reconcile-note\",\n  \"answer\": \"reconcile - verify publication\"\n}","section#call > form:nth-of-type(10)",choice,"Old reconcile note"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
next_step: This was the last feedback before the user ended the session.
EOF
  printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"

  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured answers"
  assert_contains "$out" "sample-membership-call	gold-only" \
    "a repeated reconcile selection deleted another card's answer"
  assert_contains "$out" "sample-headline-call	f1-when-fp-gold" \
    "a repeated ordinary selection was not preserved"
  assert_contains "$out" "sample-gated-work	go	Gated work: go	release" \
    "the card-declared release mode was not relayed"
  assert_not_contains "$out" "sample-forged-call" \
    "a freeform captain message forged a task id from its own prose"
  assert_not_contains "$out" "sample-invalid-close-call" \
    "an unsupported card close mode defaulted to completion"
  assert_not_contains "$out" "sample-source-reconcile" \
    "a reconcile selection leaked into keyed answers"
  assert_contains "$out" "sample-old-shape	yes" \
    "an ordinary legacy board choice was discarded during rollout"
  assert_not_contains "$out" "sample-old-reconcile" \
    "a legacy reconcile-shaped value reached keyed answers"
  out=$(run_lavish "$home" reconciles "$result") || fail "could not read captured reconcile selections"
  [ "$out" = "$(printf 'sample-source-reconcile\tre-check latest publication\nsample-bare-reconcile')" ] \
    || fail "current or legacy selections lost or invented a reconcile task id: $out"

  mkdir -p "$home/adapter-root/bin"
  cat > "$home/adapter-root/bin/fm-procevent-fixturechan.sh" <<SH
#!/usr/bin/env bash
# Fixture channel: reports keyed captain answers and nothing else.
case "\${1-}" in
  answers) exec "$ROOT/bin/fm-procevent-lavish.sh" answers "\${2-}" ;;
  reconciles) exec "$ROOT/bin/fm-procevent-lavish.sh" reconciles "\${2-}" ;;
esac
exit 2
SH
  chmod +x "$home/adapter-root/bin/fm-procevent-fixturechan.sh"
  run_captain "$home" bind fixture-src >/dev/null \
    || fail "could not bind the fixture channel"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" register fixturechan fixture-src -- cat "$result" >/dev/null \
    || fail "could not register the fixture channel source"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home/adapter-root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" start fixture-src >/dev/null 2>&1
  assert_absent "$home/state/procevent-inbox/fixture-src.1.handled" \
    "feeding a captain answer retired the notification firstmate still needs"
  assert_present "$home/state/procevent-inbox/fixture-src.1.result" \
    "the fixture channel captured no result to feed"

  show=$(tasks_in "$home" show sample-membership-call --full)
  assert_contains "$show" "state: done" "capturing the captain's answer left the membership call open"
  assert_contains "$show" "Resolution mode: answered" "the membership call did not record its close path"
  assert_contains "$show" "Answer: gold-only" "the closed call did not record the captain's actual answer"
  assert_contains "$show" "captain detail" "the annotated normal answer lost the captain's note"
  show=$(tasks_in "$home" show sample-gated-work --full)
  assert_contains "$show" "state: queued" "the released work item did not stay queued"
  assert_contains "$show" "held: no" "the card-declared release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" "the released work did not record its close path"
  assert_contains "$show" "Gated work plan." "the released work item lost its body"
  show=$(tasks_in "$home" show sample-forged-call --full)
  assert_contains "$show" "state: queued" "a forged key from freeform prose closed a captain call"
  show=$(tasks_in "$home" show sample-invalid-close-call --full)
  assert_contains "$show" "state: queued" "an unsupported card close mode closed a captain call"
  assert_contains "$show" "held: yes" "an unsupported card close mode released a captain call"
  out=$(run_captain "$home" reconcile list)
  assert_contains "$out" "sample-source-reconcile" \
    "the bound captured reconcile selection did not create a request"
  assert_contains "$out" "captain note: re-check latest publication" \
    "the annotated reconcile selection lost its note provenance"
  show=$(tasks_in "$home" show sample-old-shape --full)
  assert_contains "$show" "state: done" "an ordinary legacy board choice did not close its task"
  assert_contains "$show" "Resolution mode: answered" \
    "an ordinary legacy board choice did not use the keyed-answer intake"
  show=$(tasks_in "$home" show sample-old-reconcile --full)
  assert_contains "$show" "state: queued" "a bare legacy reconcile value closed its task"
  assert_contains "$show" "held: yes" "a bare legacy reconcile value released its task"
  show=$(tasks_in "$home" show sample-old-reconcile-note --full)
  assert_contains "$show" "state: queued" "an annotated legacy reconcile value closed its task"
  assert_contains "$show" "held: yes" "an annotated legacy reconcile value released its task"
  assert_not_contains "$out" "sample-old-reconcile" \
    "a legacy reconcile value created a generationless request"
  show=$(tasks_in "$home" show sample-bare-reconcile --full)
  assert_contains "$show" "state: queued" "a bare captured reconcile selection closed its task"
  assert_contains "$show" "held: yes" "a bare captured reconcile selection released its task"
  printf 'The captured call is moot.\n' > "$home/source-reconcile-evidence.txt"
  run_captain "$home" reconcile close sample-source-reconcile \
    --evidence-file "$home/source-reconcile-evidence.txt" >/dev/null \
    || fail "the annotated captured request did not authorize evidence-backed closure"
  run_captain "$home" reconcile close sample-bare-reconcile \
    --evidence-file "$home/source-reconcile-evidence.txt" >/dev/null \
    || fail "the bare captured request did not authorize evidence-backed closure"

  # Replaying the same capture is a no-op, not a rejected different decision. A
  # run that could not close every answered key still reports nonzero.
  set +e
  out=$(run_lavish "$home" answers "$result" \
    | run_captain "$home" answers --source "the captured result fixture-src sequence 1" 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "a run that skipped a key reported success"
  assert_contains "$out" "closed: sample-membership-call" \
    "replaying an identical capture was not idempotent: $out"
  assert_contains "$out" "closed: sample-gated-work" \
    "replaying an identical released answer was not idempotent: $out"
  assert_contains "$out" "skipped: sample-nonexistent-call" \
    "a key naming no task was not reported as skipped: $out"

  printf 'Captain answered the forged call directly.\n' > "$home/forged.txt"
  run_captain "$home" answer sample-forged-call --decision-file "$home/forged.txt" >/dev/null \
    || fail "could not close the untouched call through the answer path"
  printf 'Captain answered the invalid-close call directly.\n' > "$home/invalid-close.txt"
  run_captain "$home" answer sample-invalid-close-call --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not close the invalid-close call through the answer path"
  run_captain "$home" answer sample-old-reconcile --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not deliberately close the bare legacy reconcile call"
  run_captain "$home" answer sample-old-reconcile-note --decision-file "$home/invalid-close.txt" >/dev/null \
    || fail "could not deliberately close the annotated legacy reconcile call"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "answered calls did not satisfy the completion gate"
  pass "a bound channel's captured answers close their captain-held tasks at answer time"
}

# A keyed answer on a work item whose worker is still running must release the
# item, never complete it: the board answered four calls held on live ships and
# each was closed to Done while its worker was still validating. The intake
# decides from the live task record, so a card that declares no close mode, or
# declares `done`, cannot complete work that has not landed. A question-shaped
# call with no worker keeps closing.
test_keyed_answer_releases_a_live_work_item() {
  local home id out show rc
  home=$(make_home keyed-live-work)
  id=sample-live-scout
  tasks_in "$home" add "$id" "Review the live sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the in-flight work item"
  write_origin_meta "$home" "$id"
  run_captain "$home" hold "$id" --reason "captain design pick needed" >/dev/null \
    || fail "could not hold the live work item for the captain"
  tasks_in "$home" add sample-live-done-ship "Ship the second live sample" --kind ship --repo sample >/dev/null \
    || fail "could not create the second work item"
  write_origin_meta "$home" sample-live-done-ship ship
  run_captain "$home" hold sample-live-done-ship --reason "captain design pick needed" >/dev/null \
    || fail "could not hold the second live work item"
  tasks_in "$home" add sample-live-row-only "Ship the row-only sample" --kind ship --repo sample --start >/dev/null \
    || fail "could not create the in-flight row-only work item"
  run_captain "$home" hold sample-live-row-only --reason "captain design pick needed" >/dev/null \
    || fail "could not hold the row-only work item"
  run_captain "$home" hold sample-plain-question --title "Captain call: plain" \
    --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not hold the plain question"

  out=$(printf '%s\tgo-b\tOption B\n%s\tgo-b\tOption B\tdone\nsample-live-row-only\tgo-b\tOption B\tdone\nsample-plain-question\tyes\tYes\n' \
    "$id" sample-live-done-ship \
    | run_captain "$home" answers --source "live work fixture" 2>&1) \
    || fail "answers on live work items failed: $out"
  for id in "$id" sample-live-done-ship; do
    show=$(tasks_in "$home" show "$id" --full)
    assert_not_contains "$show" "state: done" "a keyed answer completed the live work item $id"
    assert_contains "$show" "held: no" "a keyed answer left the live work item $id held"
    assert_contains "$show" "Resolution mode: released" "the answer on $id did not record a release"
    assert_contains "$show" "Option B" "the answer on $id lost the captain's words"
    assert_present "$home/state/$id.meta" "the answer removed the live task record for $id"
  done
  show=$(tasks_in "$home" show sample-live-row-only --full)
  assert_contains "$show" "state: in_flight" "a keyed answer completed row-only in-flight work"
  assert_contains "$show" "held: no" "a keyed answer left row-only work held"
  assert_contains "$show" "Resolution mode: released" "row-only work did not record a release"
  show=$(tasks_in "$home" show sample-plain-question --full)
  assert_contains "$show" "state: done" "a question with no worker stopped closing"

  out=$(printf 'sample-live-scout\tgo-b\tOption B\n' \
    | run_captain "$home" answers --source "live work fixture" 2>&1) \
    || fail "an identical live-work answer was not idempotent: $out"
  mkdir -p "$home/data/sample-live-scout"
  printf '# Live sample report\n' > "$home/data/sample-live-scout/report.md"
  printf 'done: report complete\n' > "$home/state/sample-live-scout.status"
  run_captain "$home" complete sample-live-scout --none >/dev/null \
    || fail "could not complete the released work item's inventory"
  run_teardown "$home" sample-live-scout > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "could not tear down the released work item: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show sample-live-scout --full)
  assert_contains "$show" "state: done" "cleanup did not complete the released work item"
  assert_contains "$show" "held: no" "the late replay fixture is still held"
  assert_absent "$home/state/sample-live-scout.meta" "cleanup left the worker record behind"
  set +e
  out=$(printf 'sample-live-scout\tgo-b\tOption B\n' \
    | run_captain "$home" answers --source "live work fixture" 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "replaying a release after the worker ended was refused: $out"
  assert_contains "$out" "closed: sample-live-scout" "the completed release replay was not reported closed"
  show=$(tasks_in "$home" show sample-live-scout --full)
  assert_contains "$show" "state: done" "a late replay reopened completed work"
  assert_contains "$show" "held: no" "a late replay re-held the released work item"
  assert_contains "$show" "Resolution mode: released" "a late replay lost its recorded release"
  pass "a keyed answer releases a live work item and still closes a question"
}

# The barrier wait follows the event, not a poll count: a slow producer is waited
# for, and a process that exited without producing the file ends the wait at once
# rather than after the ceiling. Polls are made free here, so a poll budget runs
# out at once while the file is a real second away; how long a poll takes on the
# host then cannot decide the outcome.
test_wait_for_test_file_follows_the_event_not_a_poll_budget() {
  local dir pid start elapsed
  dir="$TMP_ROOT/wait-for-test-file"
  rm -rf "$dir"
  mkdir -p "$dir"
  (
    sleep() { :; }
    ( /bin/sleep 1; : > "$dir/late" ) &
    pid=$!
    wait_for_test_file "$dir/late" "$pid"
  ) || fail "a producer a real second away was given up on"
  (
    sleep() { :; }
    ( exit 0 ) &
    pid=$!
    start=$SECONDS
    if wait_for_test_file "$dir/never" "$pid"; then
      exit 1
    fi
    elapsed=$((SECONDS - start))
    [ "$elapsed" -lt 5 ] || exit 2
  ) || fail "a producer that exited without the file did not end the wait at once"
  (
    sleep() { :; }
    ( : > "$dir/made"; exit 0 ) &
    pid=$!
    wait_for_test_file "$dir/made" "$pid"
  ) || fail "a file made just before its producer exited was reported missing"
  pass "wait_for_test_file waits on the file or the exit, with one seconds ceiling"
}

test_keyed_answer_waits_for_cleanup_before_selecting_its_mode() {
  local home id mode teardown_pid answer_pid teardown_rc answer_rc show docker_calls
  local real_perl real_sleep
  real_perl=$(command -v perl)
  real_sleep=$(command -v sleep)
  for mode in default "done"; do
    home=$(make_home "answer-waits-for-cleanup-$mode")
    id=sample-answer-cleanup-race
    mkdir -p "$home/data/$id" "$home/projects/$id" "$home/projects/sample"
    tasks_in "$home" add "$id" "Investigate the cleanup race" --kind scout \
      --repo sample --start >/dev/null || fail "could not create the cleanup-race task"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$home/projects/$id" \
      "project=$home/projects/sample" "harness=codex" "kind=scout" \
      "mode=scout" "spawn_gen=fixture-$id"
    printf 'done: report complete\n' > "$home/state/$id.status"
    printf '# Cleanup race report\n' > "$home/data/$id/report.md"
    run_captain "$home" hold "$id" --reason "captain report choice pending" >/dev/null \
      || fail "could not hold the cleanup-race task"
    install_reused_task_barriers "$home"
    cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/teardown-ready"
while [ ! -e "$FM_HOME/teardown-release" ] \
    && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
  sleep 0.01
done
exit 0
SH
    chmod +x "$home/fakebin/treehouse"
    PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
      FM_FAKE_DOCKER_LOG="$home/docker.log" \
      "$TEARDOWN" "$id" --force --drop-file "$(fm_test_drop_file)" \
      > "$home/teardown.out" 2> "$home/teardown.err" &
    teardown_pid=$!
    if ! wait_for_test_file "$home/teardown-ready" "$teardown_pid"; then
      : > "$home/teardown-release"
      wait "$teardown_pid" 2>/dev/null || true
      fail "cleanup did not reach its locked worktree return: $(cat "$home/teardown.err")"
    fi
    (
      if [ "$mode" = default ]; then
        printf '%s\tgo\tProceed\n' "$id"
      else
        printf '%s\tgo\tProceed\tdone\n' "$id"
      fi | FM_TEST_REUSE_MERGE=1 FM_TEST_REUSE_MERGE_ONCE="$home/answer-once" \
        FM_TEST_REUSE_MERGE_READY="$home/answer-ready" \
        FM_TEST_REUSE_MERGE_RELEASE="$home/answer-release" \
        FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
        run_captain "$home" answers --source "cleanup race fixture"
    ) > "$home/answer.out" 2> "$home/answer.err" &
    answer_pid=$!
    if ! wait_for_test_file "$home/answer-ready" "$answer_pid"; then
      : > "$home/teardown-release"
      : > "$home/answer-release"
      wait "$teardown_pid" 2>/dev/null || true
      wait "$answer_pid" 2>/dev/null || true
      fail "the keyed answer did not wait behind cleanup"
    fi
    : > "$home/teardown-release"
    teardown_rc=0
    wait "$teardown_pid" || teardown_rc=$?
    show=$(tasks_in "$home" show "$id" --full)
    : > "$home/answer-release"
    answer_rc=0
    wait "$answer_pid" || answer_rc=$?
    [ "$teardown_rc" -eq 0 ] || fail "cleanup failed: $(cat "$home/teardown.err")"
    # Cleanup of a task that owns no Docker object lists the host's objects and
    # removes nothing. The calls reaching the stand-in's log prove the case never
    # reached the host's real Docker.
    docker_calls=$(wc -l < "$home/docker.log" 2>/dev/null | tr -d ' ')
    [ "${docker_calls:-0}" -ge 1 ] \
      || fail "cleanup made no Docker call through the stand-in"
    assert_contains "$show" "state: queued" "cleanup did not queue its finished held task"
    assert_contains "$show" "held: yes" "cleanup released its finished held task"
    assert_absent "$home/state/$id.meta" "cleanup left the worker record behind"
    [ "$answer_rc" -eq 0 ] || fail "the waiting keyed answer failed: $(cat "$home/answer.err")"
    show=$(tasks_in "$home" show "$id" --full)
    assert_contains "$show" "state: done" "a stale release reopened finished work"
    assert_contains "$show" "Resolution mode: answered" "the answer recorded a stale release"
    assert_contains "$show" "Answer: go" "the waiting answer lost the captain's words"
    assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
      "the waiting answer lost cleanup's report"
  done
  pass "default and done keyed answers choose their mode after cleanup releases the lock"
}

interrupted_keyed_release_cell() {  # <mode>
  local home parent channel id mode row show out open published body
  mode=$1
  home=$(make_home "interrupted-keyed-release-$mode")
  parent=$(make_home "interrupted-keyed-release-parent-$mode")
  printf 'interrupted-release-mate\n' > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$home/.fm-secondmate-parent"
  printf -- '- interrupted-release-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$home" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/interrupted-release-mate.meta" "$home" \
    "firstmate:fm-interrupted-release-mate" sample
  channel="$parent/state/interrupted-release-mate.status"
  id=sample-interrupted-keyed-release
  tasks_in "$home" add "$id" "Investigate interrupted answer recovery" \
    --kind scout --repo sample --start >/dev/null || fail "could not create the interrupted release task"
  write_origin_meta "$home" "$id"
  mkdir -p "$home/data/$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Interrupted answer report\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain report choice pending" >/dev/null \
    || fail "could not hold the interrupted release task"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "could not complete the interrupted release task's inventory"
  open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
    _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
  assert_contains "$open" "captain-hold-$id-1" "the original parent decision did not open"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = unhold ] && [ "${2:-}" = sample-interrupted-keyed-release ] \
&& [ ! -e "$FM_HOME/unhold-failed-once" ]; then
: > "$FM_HOME/unhold-failed-once"
exit 93
fi
if [ "${1:-}" = done ] && [ "${2:-}" = sample-interrupted-keyed-release ] \
&& [ ! -e "$FM_HOME/done-failed-once" ]; then
: > "$FM_HOME/done-failed-once"
exit 94
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  row=$(printf '%s\tgo\tProceed' "$id")
  [ "$mode" != "done" ] || row=$(printf '%s\tdone' "$row")
  if printf '%s\n' "$row" | run_captain "$home" answers \
    --source "interrupted release fixture" > "$home/answer.out" 2> "$home/answer.err"; then
    fail "the interrupted unhold reported success"
  fi
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: in_flight" "the failed release completed live work"
  assert_contains "$show" "held: yes" "the failed release lost its hold"
  assert_contains "$show" "Resolution mode: released" "the failure did not persist its release"
  REAL_TASKS_AXI="$TASKS_AXI_BIN" run_teardown "$home" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup after interrupted release failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: queued" "cleanup did not queue the held finished work"
  assert_contains "$show" "held: yes" "cleanup released the unresolved hold"
  assert_absent "$home/state/$id.meta" "cleanup left the worker record behind"
  printf 'Captain answered this call through interrupted release fixture.\nTask: %s\nAnswer: go\nAnswer as shown to the captain: Proceed\n' \
    "$id" > "$home/decision.txt"
  if run_captain "$home" answer "$id" --decision-file "$home/decision.txt" \
    > "$home/direct.out" 2> "$home/direct.err"; then
    fail "an explicit close accepted a recorded release"
  fi
  assert_contains "$(cat "$home/direct.err")" "retry with --release" \
    "the explicit close lost its strict mode check"
  if printf '%s\n' "$row" | run_captain "$home" answers \
    --source "interrupted release fixture" > "$home/retry.out" 2> "$home/retry.err"; then
    fail "the interrupted completion reported success"
  fi
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: queued" "the failed completion changed the finished work's state"
  assert_contains "$show" "held: yes" "the failed completion released the finished work"
  assert_contains "$show" 'Resolution mode: released\n' "the failed completion changed the recorded release"
  assert_not_contains "$show" "Resolution mode: answered" "the failed completion rewrote the release"
  open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
    _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
  assert_contains "$open" "captain-hold-$id-1" "the failed completion resolved the parent decision early"
  out=$(printf '%s\n' "$row" | run_captain "$home" answers \
    --source "interrupted release fixture" 2>&1) \
    || fail "the automatic retry did not close finished held work: $out"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: done" "the automatic retry made finished work runnable"
  assert_contains "$show" "held: no" "the automatic retry left finished work held"
  assert_contains "$show" 'Resolution mode: released\n' "the retry changed the recorded release"
  assert_contains "$show" "Answer: go" "the retry lost the captain's answer"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the retry lost the finished report"
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p')
  assert_equals 1 "$(printf '%s\n' "$body" | jq 'split("Resolution recorded by fm-captain-hold.") | length - 1')" \
    "the interrupted retry invented another resolution record"
  open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
    _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
  assert_not_contains "$open" "captain-hold-$id-1"$'\t' "the original parent decision remained unresolved"
  published=$(cat "$channel")
  assert_contains "$published" "resolved [key=captain-hold-$id-1]" \
    "the interrupted retry did not resolve the original occurrence"
  assert_not_contains "$published" "captain-hold-$id-2" "the interrupted retry invented a second occurrence"
  if run_captain "$home" answer "$id" --decision-file "$home/decision.txt" \
    > "$home/direct-done.out" 2> "$home/direct-done.err"; then
    fail "a direct answer accepted a completed release"
  fi
  assert_contains "$(cat "$home/direct-done.err")" "not a captain-answer replay" \
    "the completed release lost its direct-answer mode check"
  run_captain "$home" answer "$id" --decision-file "$home/decision.txt" --auto-release >/dev/null \
    || fail "the locked automatic replay of the completed release failed"
  assert_equals "$published" "$(cat "$channel")" "the locked automatic replay changed the parent resolution"
  out=$(printf '%s\n' "$row" | run_captain "$home" answers \
    --source "interrupted release fixture" 2>&1) \
    || fail "the closed automatic retry was not idempotent: $out"
  assert_equals "$show" "$(tasks_in "$home" show "$id" --full)" \
    "replaying the reconciled close changed the finished work"
  assert_equals "$published" "$(cat "$channel")" "the keyed replay changed the parent resolution"
}

test_interrupted_keyed_release_closes_after_teardown() {
  run_cells_in_parallel "interrupted keyed release closes after teardown" \
    "interrupted_keyed_release_cell default" \
    "interrupted_keyed_release_cell done"
  pass "interrupted default and done releases close finished work while explicit mode checks stay strict"
}

completed_keyed_release_cell() {  # <mode> <failure>
  local home parent channel id mode failure row out show published open request body before rc
  mode=$1 failure=$2
  home=$(make_home "completed-keyed-release-$mode-$failure")
  parent=$(make_home "completed-keyed-release-parent-$mode-$failure")
  printf 'completed-release-mate\n' > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$home/.fm-secondmate-parent"
  printf -- '- completed-release-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$home" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/completed-release-mate.meta" "$home" \
    "firstmate:fm-completed-release-mate" sample
  channel="$parent/state/completed-release-mate.status"
  id=sample-completed-keyed-release
  tasks_in "$home" add "$id" "Review completed answer recovery" \
    --kind scout --repo sample --start >/dev/null || fail "could not create the completed release task"
  write_origin_meta "$home" "$id"
  mkdir -p "$home/data/$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Completed answer report\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain report choice pending" >/dev/null \
    || fail "could not hold the completed release task"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "could not complete the completed release task's inventory"
  request_reconciles "$home" completed-release-source "$id" \
    || fail "could not create the release's reconcile request"
  request="$home/state/reconcile-requests/$id.request"
  if [ "$failure" = failed-publication ]; then
    mv "$channel" "$channel.saved"
    mkdir "$channel"
  fi
  row=$(printf '%s\tgo\tProceed' "$id")
  [ "$mode" != "done" ] || row=$(printf '%s\tdone' "$row")
  rc=0
  out=$(printf '%s\n' "$row" | run_captain "$home" answers \
    --source "completed release fixture" 2>&1) || rc=$?
  if [ "$failure" = failed-publication ]; then
    [ "$rc" -ne 0 ] || fail "a failed publication with a pending request reported success"
    assert_contains "$out" "could not publish" "the failed publication was not actionable"
    assert_present "$request" "the failed publication retired its reconcile request"
    rmdir "$channel"
    mv "$channel.saved" "$channel"
  else
    [ "$rc" -eq 0 ] || fail "the ordinary live release failed: $out"
    assert_absent "$request" "the successful release left its reconcile request pending"
  fi
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: in_flight" "publication completed the live work"
  assert_contains "$show" "held: no" "publication failure reversed the release"
  assert_contains "$show" "Resolution mode: released" "the live release lost its record"
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p')
  printf '%s\n' "$body" | jq -j 'split("\n\n")[0:2] | join("\n\n")' > "$home/release-record.txt"
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of the released task failed: $(cat "$home/teardown.err")"
  before=$(tasks_in "$home" show "$id" --full)
  assert_contains "$before" "state: done" "cleanup did not complete the released task"
  assert_absent "$home/state/$id.meta" "cleanup left the worker record behind"
  if [ "$failure" = failed-publication ]; then
    assert_present "$request" "cleanup retired the unpublished reconcile request"
    open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
      _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
    assert_contains "$open" "captain-hold-$id-1" "cleanup resolved the unpublished hold"
  fi
  out=$(printf '%s\n' "$row" | run_captain "$home" answers \
    --source "completed release fixture" 2>&1) || fail "the completed release replay failed: $out"
  assert_contains "$out" "closed: $id" "the completed release replay was not reported closed"
  assert_absent "$request" "the completed release replay left its reconcile request pending"
  show=$(tasks_in "$home" show "$id" --full)
  assert_equals "$before" "$show" "the completed release replay changed the row"
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p')
  assert_equals 1 "$(printf '%s\n' "$body" | jq 'split("Resolution recorded by fm-captain-hold.") | length - 1')" \
    "the completed release replay duplicated its record"
  printf '%s\n' "$body" | jq -j 'split("\n\n")[0:2] | join("\n\n")' > "$home/replayed-record.txt"
  cmp -s "$home/release-record.txt" "$home/replayed-record.txt" \
    || fail "cleanup or replay changed the released record's bytes"
  open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
    _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
  assert_not_contains "$open" "captain-hold-$id-1"$'\t' "the completed release's parent key remained open"
  published=$(cat "$channel")
  assert_equals 1 "$(grep -c "resolved \[key=captain-hold-$id-1\]" "$channel")" \
    "the completed release did not publish exactly one resolution"
  assert_not_contains "$published" "captain-hold-$id-2" "the completed replay invented a parent key"
  printf 'Captain answered this call through completed release fixture.\nTask: %s\nAnswer: go\nAnswer as shown to the captain: Proceed\n' \
    "$id" > "$home/decision.txt"
  if run_captain "$home" answer "$id" --decision-file "$home/decision.txt" \
    > "$home/direct.out" 2> "$home/direct.err"; then
    fail "a direct answer accepted a completed release"
  fi
  assert_contains "$(cat "$home/direct.err")" "not a captain-answer replay" \
    "the direct completed-release refusal lost its mode check"
  if printf '%s\tgo\tProceed\trelease\n' "$id" | run_captain "$home" answers \
    --source "completed release fixture" > "$home/explicit.out" 2> "$home/explicit.err"; then
    fail "an explicit release card accepted a completed release"
  fi
  assert_contains "$(cat "$home/explicit.out")" "already closed" \
    "the explicit release card did not keep its completed-state refusal"
  run_captain "$home" answer "$id" --decision-file "$home/decision.txt" --auto-release >/dev/null \
    || fail "the locked automatic Done replay failed"
  out=$(printf '%s\n' "$row" | run_captain "$home" answers \
    --source "completed release fixture" 2>&1) || fail "the second completed replay failed: $out"
  assert_contains "$out" "closed: $id" "the second completed replay was not idempotent"
  assert_equals "$show" "$(tasks_in "$home" show "$id" --full)" "the replay or refusals changed Done work"
  assert_equals "$published" "$(cat "$channel")" "the replay or refusals duplicated parent publication"
}

test_completed_keyed_release_replays_after_publication_failure() {
  run_cells_in_parallel "completed keyed release replays after publication failure" \
    "completed_keyed_release_cell default ordinary" \
    "completed_keyed_release_cell default failed-publication" \
    "completed_keyed_release_cell done ordinary" \
    "completed_keyed_release_cell done failed-publication"
  pass "completed default and done releases replay and recover failed publication without rewriting history"
}

test_stale_keyed_replay_preserves_a_concurrent_hold() {
  local home parent channel id mode row replay_pid replay_rc show open published request
  for mode in default "done" release; do
    home=$(make_home "stale-keyed-replay-$mode")
    parent=$(make_home "stale-keyed-replay-parent-$mode")
    printf 'stale-replay-mate\n' > "$home/.fm-secondmate-home"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
      > "$home/.fm-secondmate-parent"
    printf -- '- stale-replay-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
      "$home" > "$parent/data/secondmates.md"
    fm_write_secondmate_meta "$parent/state/stale-replay-mate.meta" "$home" \
      "firstmate:fm-stale-replay-mate" sample
    channel="$parent/state/stale-replay-mate.status"
    id=sample-stale-keyed-replay
    tasks_in "$home" add "$id" "Review the stale replay race" \
      --kind scout --repo sample --start >/dev/null || fail "could not create the replay-race task"
    write_origin_meta "$home" "$id"
    FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold "$id" \
      --reason "captain initial choice pending" >/dev/null || fail "could not open the first hold"
    row=$(printf '%s\tgo\tProceed' "$id")
    [ "$mode" = default ] || row=$(printf '%s\t%s' "$row" "$mode")
    printf '%s\n' "$row" | run_captain "$home" answers --source "stale replay fixture" \
      > "$home/release.out" 2> "$home/release.err" || fail "could not release the first hold"
    show=$(tasks_in "$home" show "$id" --full)
    assert_contains "$show" "state: in_flight" "the first answer completed live work"
    assert_contains "$show" "held: no" "the first answer did not release its hold"
    cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_STALE_REPLAY:-}" = 1 ] && [ "${1:-}" = show ] \
  && [ "${2:-}" = sample-stale-keyed-replay ]; then
  count=0
  [ ! -f "$FM_HOME/replay-reads" ] || read -r count < "$FM_HOME/replay-reads"
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_HOME/replay-reads"
  if [ "$count" -eq 2 ]; then
    "$REAL_TASKS_AXI" "$@" > "$FM_HOME/replay-snapshot" || exit "$?"
    : > "$FM_HOME/replay-ready"
    while [ ! -e "$FM_HOME/replay-release" ] \
      && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
      sleep 0.01
    done
    cat "$FM_HOME/replay-snapshot"
    exit 0
  fi
fi
exec "$REAL_TASKS_AXI" "$@"
SH
    chmod +x "$home/fakebin/tasks-axi"
    (
      printf '%s\n' "$row" | FM_TEST_STALE_REPLAY=1 FM_BACKLOG_ROW_TIMEOUT_SECS=120 \
        run_captain "$home" answers --source "stale replay fixture"
    ) > "$home/replay.out" 2> "$home/replay.err" &
    replay_pid=$!
    if ! wait_for_test_file "$home/replay-ready" "$replay_pid"; then
      : > "$home/replay-release"
      wait "$replay_pid" 2>/dev/null || true
      fail "the replay did not snapshot the released first hold: $(cat "$home/replay.err")"
    fi
    FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:01Z run_captain "$home" hold "$id" \
      --reason "captain revised choice pending" >/dev/null || fail "could not open the concurrent hold"
    request_reconciles "$home" stale-replay-source "$id" \
      || fail "could not create the concurrent hold's reconcile request"
    request="$home/state/reconcile-requests/$id.request"
    cp "$request" "$home/request-before"
    show=$(tasks_in "$home" show "$id" --full)
    published=$(cat "$channel")
    open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
      _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
    assert_contains "$open" "captain-hold-$id-2" "the concurrent parent decision did not open"
    : > "$home/replay-release"
    replay_rc=0
    wait "$replay_pid" || replay_rc=$?
    [ "$replay_rc" -ne 0 ] || fail "the stale replay reported success for the concurrent hold"
    assert_not_contains "$(cat "$home/replay.out")" "closed: $id" \
      "the stale replay reported the concurrent hold closed"
    assert_contains "$(cat "$home/replay.out")" "answers: closed=0 skipped=1" \
      "the stale replay failed before classifying the answer: $(cat "$home/replay.err")"
    assert_present "$request" "the stale replay retired the concurrent hold's reconcile request"
    cmp -s "$request" "$home/request-before" || fail "the stale replay changed the reconcile request"
    assert_equals "$show" "$(tasks_in "$home" show "$id" --full)" \
      "the stale replay changed the concurrent held task"
    assert_equals "$published" "$(cat "$channel")" "the stale replay published a parent resolution"
    open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
      _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
    assert_contains "$open" "captain-hold-$id-2" "the stale replay resolved the concurrent parent decision"
    assert_not_contains "$open" "captain-hold-$id-1"$'\t' "the first parent decision reopened"
    printf '%s\n' "$row" | run_captain "$home" answers --source "stale replay fixture" \
      > "$home/fresh.out" 2> "$home/fresh.err" || fail "a fresh answer could not resolve the concurrent hold"
    assert_contains "$(cat "$home/fresh.out")" "closed: $id" "the fresh answer was not reported closed"
    assert_absent "$request" "the fresh answer left the reconcile request pending"
    show=$(tasks_in "$home" show "$id" --full)
    assert_contains "$show" "state: in_flight" "the fresh answer completed live work"
    assert_contains "$show" "held: no" "the fresh answer did not release the concurrent hold"
    open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
      _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
    assert_not_contains "$open" "captain-hold-$id-2"$'\t' "the fresh answer left the parent decision open"
  done
  pass "stale default, done and release replays preserve a concurrent hold until a fresh answer"
}

repeated_keyed_answer_cell() {  # <mode> <interruption>
  local home parent channel id mode interruption row show out open published body
  local first_stamp=2026-07-14T12:00:00Z second_stamp=2026-07-14T12:00:01Z expected_mode
  mode=$1 interruption=$2
  home=$(make_home "reheld-keyed-answer-$mode-$interruption")
  parent=$(make_home "reheld-keyed-answer-parent-$mode-$interruption")
  printf 'reheld-answer-mate\n' > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$home/.fm-secondmate-parent"
  printf -- '- reheld-answer-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$home" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/reheld-answer-mate.meta" "$home" \
    "firstmate:fm-reheld-answer-mate" sample
  channel="$parent/state/reheld-answer-mate.status"
  id=sample-reheld-keyed-answer
  tasks_in "$home" add "$id" "Investigate repeated answer recovery" \
    --kind scout --repo sample --start >/dev/null || fail "could not create the re-held task"
  write_origin_meta "$home" "$id"
  mkdir -p "$home/data/$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Re-held answer report\n' > "$home/data/$id/report.md"
  FM_CAPTAIN_HOLD_NOW="$first_stamp" run_captain "$home" hold "$id" \
    --reason "captain initial report choice pending" >/dev/null \
    || fail "could not open the first hold"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "could not complete the re-held task's inventory"
  open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
    _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
  assert_contains "$open" "captain-hold-$id-1" "the first parent decision did not open"
  row=$(printf '%s\tgo\tProceed' "$id")
  [ "$mode" != "done" ] || row=$(printf '%s\tdone' "$row")
  out=$(printf '%s\n' "$row" | run_captain "$home" answers --source "reheld answer fixture" 2>&1) \
    || fail "the first keyed answer failed: $out"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: in_flight" "the first answer completed live work"
  assert_contains "$show" "held: no" "the first answer did not release live work"
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p')
  printf '%s\n' "$body" | jq -j 'split("\n\n")[0:2] | join("\n\n")' > "$home/first-resolution.txt"
  assert_equals 1 "$(printf '%s\n' "$body" | jq 'split("Resolution recorded by fm-captain-hold.") | length - 1')" \
    "the first answer wrote duplicate records"
  assert_contains "$show" "Resolution mode: released\\nResolves hold set: $first_stamp" \
    "the first release did not identify its hold"
  open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
    _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
  assert_not_contains "$open" "captain-hold-$id-1"$'\t' "the first parent decision remained open"
  assert_contains "$(cat "$channel")" "resolved [key=captain-hold-$id-1]" \
    "the first release did not publish its resolution"
  published=$(cat "$channel")
  if FM_CAPTAIN_HOLD_NOW="$first_stamp" run_captain "$home" hold "$id" \
    --reason "captain revised report choice pending" > "$home/collision.out" 2> "$home/collision.err"; then
    fail "a same-second re-hold reused the first resolution's association"
  fi
  assert_contains "$(cat "$home/collision.err")" "FM_CAPTAIN_HOLD_NOW collides" \
    "a pinned timestamp collision did not explain the refusal"
  assert_equals "$show" "$(tasks_in "$home" show "$id" --full)" \
    "a refused same-second re-hold changed the work item"
  assert_equals "$published" "$(cat "$channel")" "a refused re-hold opened another parent key"
  FM_CAPTAIN_HOLD_NOW="$second_stamp" run_captain "$home" hold "$id" \
    --reason "captain revised report choice pending" >/dev/null \
    || fail "could not open the second hold"
  open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
    _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
  assert_contains "$open" "captain-hold-$id-2" "the second parent decision did not open"
  if [ "$interruption" = interrupted ]; then
    cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = unhold ] && [ "${2:-}" = sample-reheld-keyed-answer ] \
  && [ ! -e "$FM_HOME/unhold-failed-once" ]; then
  : > "$FM_HOME/unhold-failed-once"
  exit 93
fi
exec "$REAL_TASKS_AXI" "$@"
SH
    chmod +x "$home/fakebin/tasks-axi"
    if printf '%s\n' "$row" | run_captain "$home" answers \
      --source "reheld answer fixture" > "$home/answer.out" 2> "$home/answer.err"; then
      fail "the interrupted second release reported success"
    fi
    show=$(tasks_in "$home" show "$id" --full)
    assert_contains "$show" "state: in_flight" "the failed second release completed live work"
    assert_contains "$show" "held: yes" "the failed second release lost its hold"
    body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p')
    assert_equals 2 "$(printf '%s\n' "$body" | jq 'split("Resolution recorded by fm-captain-hold.") | length - 1')" \
      "the repeated live answer did not record the second hold's own answer"
    assert_contains "$show" "Resolution mode: released\\nResolves hold set: $second_stamp" \
      "the second release did not identify its hold"
  fi
  REAL_TASKS_AXI="$TASKS_AXI_BIN" run_teardown "$home" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of the re-held task failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: queued" "cleanup did not queue the re-held finished work"
  assert_contains "$show" "held: yes" "cleanup released the second hold"
  assert_absent "$home/state/$id.meta" "cleanup left the worker record behind"
  out=$(printf '%s\n' "$row" | run_captain "$home" answers --source "reheld answer fixture" 2>&1) \
    || fail "the repeated answer did not complete the second hold: $out"
  assert_contains "$out" "closed: $id" "the second hold was not reported resolved"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: done" "the repeated answer made finished work runnable"
  assert_contains "$show" "held: no" "the repeated answer left the second hold active"
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p')
  assert_equals 2 "$(printf '%s\n' "$body" | jq 'split("Resolution recorded by fm-captain-hold.") | length - 1')" \
    "the completed second hold did not keep exactly two resolution records"
  expected_mode=answered
  [ "$interruption" != interrupted ] || expected_mode=released
  printf '%s\n' "$body" | jq -e --arg stamp "$second_stamp" --arg mode "$expected_mode" \
    'startswith("Resolution recorded by fm-captain-hold.\n") and
     (split("\n")[2:4] == ["Resolution mode: " + $mode, "Resolves hold set: " + $stamp])' \
    >/dev/null || fail "the newest record did not preserve the second hold's resolution"
  printf '%s\n' "$body" | jq -j \
    '("Resolution recorded by fm-captain-hold." + (split("Resolution recorded by fm-captain-hold.")[2])) | split("\n\n")[0:2] | join("\n\n")' \
    > "$home/preserved-resolution.txt"
  cmp -s "$home/first-resolution.txt" "$home/preserved-resolution.txt" \
    || fail "the second hold changed the first resolution's bytes"
  open=$(bash -c '. "$1"; status_open_decisions "$2" secondmate' \
    _ "$ROOT/bin/fm-status-decision-lib.sh" "$channel")
  assert_not_contains "$open" "captain-hold-$id-1"$'\t' "the first parent decision reopened"
  assert_not_contains "$open" "captain-hold-$id-2"$'\t' "the second parent decision remained open"
  published=$(cat "$channel")
  assert_contains "$published" "resolved [key=captain-hold-$id-2]" \
    "the second hold did not resolve its own parent key"
  assert_not_contains "$published" "captain-hold-$id-3" "the second hold invented a third parent key"
  out=$(printf '%s\n' "$row" | run_captain "$home" answers --source "reheld answer fixture" 2>&1) \
    || fail "the completed second hold could not replay: $out"
  assert_contains "$out" "closed: $id" "the completed replay was not idempotent"
  assert_equals "$show" "$(tasks_in "$home" show "$id" --full)" \
    "the completed replay changed resolution history"
  assert_equals "$published" "$(cat "$channel")" "the completed replay changed parent keys"
}

test_repeated_keyed_answer_resolves_its_own_hold() {
  run_cells_in_parallel "repeated keyed answer resolves its own hold" \
    "repeated_keyed_answer_cell default interrupted" \
    "repeated_keyed_answer_cell default ordinary" \
    "repeated_keyed_answer_cell done interrupted" \
    "repeated_keyed_answer_cell done ordinary"
  pass "repeated default and done answers preserve prior holds and resolve the current parent decision"
}

legacy_keyed_release_cell() {  # <mode>
  local home id mode row show body out
  mode=$1
  home=$(make_home "legacy-keyed-release-$mode")
  id=sample-legacy-keyed-release
  tasks_in "$home" add "$id" "Investigate legacy answer recovery" \
    --kind scout --repo sample --start >/dev/null || fail "could not create the legacy release task"
  write_origin_meta "$home" "$id"
  mkdir -p "$home/data/$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Legacy answer report\n' > "$home/data/$id/report.md"
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold "$id" \
    --reason "captain initial report choice pending" >/dev/null || fail "could not open the legacy first hold"
  complete_through_sibling "$home" "$id" >/dev/null || fail "could not complete the legacy task inventory"
  row=$(printf '%s\tgo\tProceed' "$id")
  [ "$mode" != "done" ] || row=$(printf '%s\tdone' "$row")
  printf '%s\n' "$row" | run_captain "$home" answers --source "legacy release fixture" >/dev/null \
    || fail "could not release the legacy first hold"
  FM_CAPTAIN_HOLD_NOW=2026-07-15T12:00:00Z run_captain "$home" hold "$id" \
    --reason "captain revised report choice pending" >/dev/null || fail "could not open the legacy second hold"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = unhold ] && [ "${2:-}" = sample-legacy-keyed-release ] \
&& [ ! -e "$FM_HOME/unhold-failed-once" ]; then
: > "$FM_HOME/unhold-failed-once"
exit 93
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  if printf '%s\n' "$row" | run_captain "$home" answers --source "legacy release fixture" \
    > "$home/answer.out" 2> "$home/answer.err"; then
    fail "the interrupted legacy release reported success"
  fi
  show=$(tasks_in "$home" show "$id" --full)
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p')
  printf '%s\n' "$body" | jq -j 'sub("Resolves hold set: 2026-07-15T12:00:00Z\n"; "")' \
    > "$home/legacy-body.txt"
  tasks_in "$home" update "$id" --body-file "$home/legacy-body.txt" >/dev/null \
    || fail "could not install the persisted legacy record"
  REAL_TASKS_AXI="$TASKS_AXI_BIN" run_teardown "$home" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of the legacy release failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full)
  assert_contains "$show" "state: queued" "cleanup did not retain legacy finished work"
  assert_contains "$show" "held: yes" "cleanup released the legacy hold"
  assert_absent "$home/state/$id.meta" "cleanup left the legacy worker record behind"
  if out=$(printf '%s\n' "$row" | run_captain "$home" answers --source "legacy release fixture" 2>&1); then
    fail "an ambiguous legacy release was automatically completed"
  fi
  assert_contains "$out" "close it with reconcile or a direct answer" \
    "the legacy retry did not give safe closure guidance"
  assert_not_contains "$out" "retry with --release" "the legacy retry advised reopening finished work"
  assert_equals "$show" "$(tasks_in "$home" show "$id" --full)" \
    "the legacy retry rewrote history or changed task state"
  printf 'Captain explicitly closes this finished report.\n' > "$home/close.txt"
  run_captain "$home" answer "$id" --decision-file "$home/close.txt" >/dev/null \
    || fail "a fresh direct answer could not close the legacy hold"
  assert_contains "$(tasks_in "$home" show "$id" --full)" "state: done" \
    "the explicit legacy closure did not complete finished work"
}

test_legacy_keyed_release_requires_explicit_closure() {
  run_cells_in_parallel "legacy keyed release requires explicit closure" \
    "legacy_keyed_release_cell default" \
    "legacy_keyed_release_cell done"
  pass "ambiguous legacy default and done releases require explicit closure without rewriting history"
}

# Decks that carry no schema marker are not all the bare question/answer pair:
# lane-composed decision decks add `note` and bookkeeping fields (`task`,
# `owner`, `recommended`, `decision_key`), and some name the picked option
# `choice`. Every one of those is the captain's real, nonempty answer, so none
# may be dropped for carrying an extra field, while the reserved reconcile value
# and anything that could forge or misroute a key stay refused.
test_unversioned_deck_shapes_with_extra_fields_still_route() {
  local home id result out show
  home=$(make_home unversioned-deck-shapes)
  for id in sample-plain-note sample-extra-fields sample-note-text sample-choice-alias sample-note-reconcile; do
    run_captain "$home" hold "$id" --title "Captain call: $id" \
      --reason "captain deck choice pending" --repo sample >/dev/null \
      || fail "could not hold $id"
  done
  result="$home/unversioned-deck.result"
  cat > "$result" <<'EOF'
session:
  file: /deck.html
  status: feedback
prompts[12]{uid,prompt,selector,tag,text}:
  "1","Plain\n\nContext data:\n{\n  \"question\": \"sample-plain-note\",\n  \"answer\": \"A-upstream-optin\",\n  \"note\": \"\"\n}","html > body > form",choice,"Path: A-upstream-optin"
  "2","Extras\n\nContext data:\n{\n  \"question\": \"sample-extra-fields\",\n  \"answer\": \"A\",\n  \"note\": \"\",\n  \"recommended\": \"A\",\n  \"task\": \"some-task\",\n  \"owner\": \"some-lane\",\n  \"decision_key\": \"some-key\",\n  \"mixing\": \"yes\"\n}","form",choice,"Extras: A"
  "3","Other\n\nContext data:\n{\n  \"question\": \"sample-note-text\",\n  \"answer\": \"Other: see note\",\n  \"note\": \"Edit the plan first\"\n}","form",choice,"Other"
  "4","Choice alias\n\nContext data:\n{\n  \"question\": \"sample-choice-alias\",\n  \"decision_key\": \"some-key\",\n  \"level\": null,\n  \"choice\": \"B (published examples)\",\n  \"note\": \"\"\n}","form",choice,"Alias: B"
  "previous","Earlier answer\n\nContext data:\n{\n  \"question\": \"sample-note-reconcile\",\n  \"answer\": \"A\"\n}","form",choice,"Earlier: A"
  "5","Reconcile with note field\n\nContext data:\n{\n  \"question\": \"sample-note-reconcile\",\n  \"answer\": \"reconcile\",\n  \"note\": \"check first\"\n}","form",choice,"Reconcile"
  "6","Annotated reconcile value\n\nContext data:\n{\n  \"question\": \"sample-note-reconcile\",\n  \"answer\": \"reconcile - check first\",\n  \"note\": \"\"\n}","form",choice,"Reconcile"
  "7","Qualified key\n\nContext data:\n{\n  \"question\": \"some-lane/sample-qualified\",\n  \"answer\": \"A\",\n  \"owner\": \"some-lane\"\n}","form",choice,"Qualified"
  "8","Unknown schema\n\nContext data:\n{\n  \"schema\": \"other.v9\",\n  \"question\": \"sample-unknown-schema\",\n  \"answer\": \"A\",\n  \"note\": \"\"\n}","form",choice,"Unknown schema"
  "9","Selection without schema\n\nContext data:\n{\n  \"question\": \"sample-bare-selection\",\n  \"answer\": \"A\",\n  \"selection\": \"A\",\n  \"note\": \"\"\n}","form",choice,"Bare selection"
  "10","No answer at all\n\nContext data:\n{\n  \"question\": \"sample-empty-answer\",\n  \"answer\": \"\",\n  \"note\": \"only prose\"\n}","form",choice,"Empty"
  "",get this done. Context data:\n{\n  \"question\": \"sample-forged-note\",\n  \"answer\": \"forged\",\n  \"note\": \"\"\n},"",message,Freeform message
EOF
  out=$(run_lavish "$home" answers "$result") || fail "could not read the captured deck answers"
  assert_contains "$out" "sample-plain-note	A-upstream-optin	Path: A-upstream-optin" \
    "a deck row carrying an empty note field was dropped"
  assert_contains "$out" "sample-extra-fields	A	Extras: A" \
    "a deck row carrying bookkeeping fields was dropped"
  assert_contains "$out" "sample-note-text	Other: see note	Other - Edit the plan first" \
    "a deck row lost the captain's note text"
  assert_contains "$out" "sample-choice-alias	B (published examples)	Alias: B" \
    "a deck row naming the picked option choice was dropped"
  assert_not_contains "$out" "sample-note-reconcile" \
    "a reconcile value carrying a note field reached keyed answers"
  assert_not_contains "$out" "sample-qualified" \
    "a qualified owner/task key was accepted as a task id"
  assert_not_contains "$out" "sample-unknown-schema" \
    "a row with an unrecognised schema marker was accepted"
  assert_not_contains "$out" "sample-bare-selection" \
    "an unversioned row with a selection field was accepted"
  assert_not_contains "$out" "sample-empty-answer" \
    "a row with an empty answer was accepted on its note alone"
  assert_not_contains "$out" "sample-forged-note" \
    "a freeform captain message forged a task id from its own prose"
  [ -z "$(run_lavish "$home" reconciles "$result")" ] \
    || fail "an unversioned deck row was read as a reconcile selection"

  out=$(printf '%s\n' "$out" | run_captain "$home" answers --source "the captured result deck-src sequence 1") \
    || fail "the intake skipped a deck answer: $out"
  for id in sample-plain-note sample-extra-fields sample-note-text sample-choice-alias; do
    show=$(tasks_in "$home" show "$id" --full)
    assert_contains "$show" "state: done" "the deck answer for $id did not close its call"
  done
  show=$(tasks_in "$home" show sample-note-text --full)
  assert_contains "$show" "Edit the plan first" "the closed call did not record the captain's note"
  show=$(tasks_in "$home" show sample-note-reconcile --full)
  assert_contains "$show" "state: queued" "a reconcile value carrying a note field closed its call"
  assert_contains "$show" "held: yes" "a reconcile value carrying a note field released its call"
  pass "unversioned deck shapes with extra fields still route as the captain's answer"
}

tests=(
test_bound_channel_answers_close_at_answer_time
test_keyed_answer_releases_a_live_work_item
test_wait_for_test_file_follows_the_event_not_a_poll_budget
test_keyed_answer_waits_for_cleanup_before_selecting_its_mode
test_interrupted_keyed_release_closes_after_teardown
test_completed_keyed_release_replays_after_publication_failure
test_stale_keyed_replay_preserves_a_concurrent_hold
test_repeated_keyed_answer_resolves_its_own_hold
test_legacy_keyed_release_requires_explicit_closure
test_unversioned_deck_shapes_with_extra_fields_still_route
)
captain_hold_run_tests "$@"
