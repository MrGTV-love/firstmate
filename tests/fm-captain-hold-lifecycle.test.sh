#!/usr/bin/env bash
# Hold, origin, inventory, completion-gate, answer, release, deferral, and
# secondmate parent-channel regressions.
# Shared definitions and fixture setup live in fm-captain-hold-lifecycle-helpers.sh.
set -u

# shellcheck source=tests/fm-captain-hold-lifecycle-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-lifecycle-helpers.sh"

# Reproduces the loss exactly with privacy-safe synthetic names: the investigation
# and visual review have ended, the only genuine unresolved captain call is report
# prose, no held backlog item or open status exists, and the authoritative
# Bearings view correctly omits it. Completion must now refuse before teardown can
# erase the source.
test_uninventoried_report_decision_refuses_completion() {
  local home id json rc
  home=$(make_home omitted-decision)
  id=sample-route-review
  mkdir -p "$home/data/$id"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] $id - Investigate sample routing (repo: sample) (kind: scout) (since 2026-07-14)

## Queued

## Done
EOF
  write_origin_meta "$home" "$id"
  printf 'done: report and visual review complete\n' > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample route review

The evidence is complete.
The captain still needs to choose route north or route south before follow-up work starts.
EOF

  json=$(run_bearings "$home") || fail "Bearings failed for unresolved-call regression"
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 0
      and (.gates | length) == 0
      and (.reports | any(.id == "sample-route-review"))
  ' >/dev/null || fail "the pre-policy omission shape was not reproduced: $json"

  set +e
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "completed investigation teardown erased a report-only unresolved captain call"
  assert_present "$home/state/$id.meta" "refused completion must preserve investigation metadata"
  assert_grep "REFUSED" "$home/teardown.err" "refusal must be explicit"
  pass "report-only unresolved captain call is reproduced and completion refuses before loss"
}

# The completion gate on the collapsed primitive: an origin with open keyed
# status decisions refuses --none, refuses an inventory naming absent tasks,
# attests a verified inventory of captain-held task ids, and transfers every
# still-open status decision to that durable inventory.
test_completion_gate_attests_and_transfers() {
  local home id json open before after
  home=$(make_home completion-gate)
  id=sample-systems-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample systems" --kind scout --repo sample --start >/dev/null \
    || fail "could not create investigation backlog fixture"
  write_origin_meta "$home" "$id"
  cat > "$home/state/$id.status" <<'EOF'
working: report drafted
needs-decision [key=route]: choose route north or route south
needs-decision [key=access]: choose open or restricted sample access
EOF
  cat > "$home/data/$id/report.md" <<'EOF'
# Sample systems review

Two choices remain unresolved: the route and the sample access level.
A separate recommendation is already resolved and requires no captain action.
EOF

  if run_captain "$home" complete "$id" --none > "$home/none.out" 2> "$home/none.err"; then
    fail "--none attested while captain calls were still open in the status stream"
  fi
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "failed completion recorded a false completion attestation"
  if run_captain "$home" complete "$id" sample-route-call > "$home/absent.out" 2> "$home/absent.err"; then
    fail "completion accepted an inventory entry that names no task"
  fi

  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" hold sample-route-call \
    --title "Choose route: north, south" --reason "captain route and access choices pending" \
    --repo sample >/dev/null \
    || fail "idempotent hold retry failed"
  [ "$(grep -cE "^- \[ \] sample-route-call -" "$home/data/backlog.md")" = 1 ] \
    || fail "idempotent retry duplicated the captain-held task"
  if run_captain "$home" hold sample-route-call --title "A different title" \
    --reason "captain route and access choices pending" > "$home/title.out" 2> "$home/title.err"; then
    fail "hold accepted a changed title on an existing task"
  fi

  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "could not prime the announced decision baseline"
  run_captain "$home" complete "$id" sample-route-call >/dev/null \
    || fail "shared investigation completion gate failed"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"; fm_wake_signal_seen_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state" "$home/state/$id.status" \
    || fail "captain-held bookkeeping closes re-woke their own home"
  assert_grep "decisions_reviewed=1" "$home/state/$id.meta" "completion attestation missing"
  assert_grep "decision_keys=sample-route-call" "$home/state/$id.meta" "inventory was not recorded as task ids"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "captain-held transfer did not close the live status decisions: $open"
  sed -E 's/ \[at=[0-9]+\]//' "$home/state/$id.status" | grep -F 'captain-held [key=route]: tracked by sample-route-call' >/dev/null \
    || fail "the transfer line does not name the tracking inventory"

  before=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  json=$(run_bearings "$home") || fail "Bearings failed with a captain-held task"
  after=$(shasum -a 256 "$home/data/backlog.md" | awk '{print $1}')
  [ "$before" = "$after" ] || fail "Bearings mutated the authoritative backlog"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold" and .owner == "(main)"))
      and (.gates | any(.id == "sample-route-call") | not)
  ' >/dev/null || fail "Bearings did not surface the captain-held task: $json"

  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "reviewed investigation teardown failed: $(cat "$home/teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null \
    || fail "could not archive completed investigation"
  json=$(run_bearings "$home") || fail "Bearings failed after source teardown and archival"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-route-call" and .verb == "captain-hold"))
      and (.in_flight | any(.id == "sample-systems-review") | not)
  ' >/dev/null || fail "teardown or archival erased a captain-held task: $json"
  pass "the completion gate attests captain-held inventory and transfers open status decisions"
}

# The recorded-answer rule: answering closes with the captain's exact words, an
# exact retry is idempotent, a drifted retry is rejected, dependent work routed
# behind the answered task is released by the close, and the completion gate is
# satisfied only by a recorded answer.
test_answer_records_and_closes() {
  local home id json show
  home=$(make_home answer-close)
  id=sample-guard-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Guard the answer path" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the answer-guard origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Guard review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-guard-call \
    --title "Choose the guard option" --reason "captain guard choice pending" --repo sample >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-guard-call >/dev/null \
    || fail "completion failed for the held inventory"
  tasks_in "$home" add sample-guard-work "Apply the guard option" \
    --kind ship --repo sample --blocked-by sample-guard-call >/dev/null \
    || fail "could not route work behind the captain-held task"

  printf '' > "$home/empty.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/empty.txt" \
    > "$home/empty-answer.out" 2> "$home/empty-answer.err"; then
    fail "answer accepted an empty captain decision"
  fi
  if run_captain "$home" answer sample-guard-call > "$home/bare-answer.out" 2> "$home/bare-answer.err"; then
    fail "answer accepted a close with no captain decision file at all"
  fi
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-absent-call --decision-file "$home/invented.txt" \
    > "$home/absent-answer.out" 2> "$home/absent-answer.err"; then
    fail "answer invented a resolution for a task that does not exist"
  fi
  if run_captain "$home" answer sample-guard-work --decision-file "$home/invented.txt" \
    > "$home/unheld-answer.out" 2> "$home/unheld-answer.err"; then
    fail "answer closed a task that is not held for the captain"
  fi
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: queued" "a refused answer closed the captain-held task"
  assert_contains "$show" "held: yes" "a refused answer released the captain-held task"

  printf 'Captain chose the guard option.\n' > "$home/guard-decision.txt"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  show=$(tasks_in "$home" show sample-guard-call --full)
  assert_contains "$show" "state: done" "an answered captain-held task did not close"
  assert_contains "$show" "Resolution recorded by fm-captain-hold" "the answered task lost the decision record"
  assert_contains "$show" "Resolution mode: answered" "the answered task did not record its close path"
  assert_contains "$show" "Captain chose the guard option." \
    "the answered task did not record the captain decision text"
  run_captain "$home" answer sample-guard-call --decision-file "$home/guard-decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  printf 'Captain chose something else entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-guard-call --decision-file "$home/drifted.txt" \
    > "$home/drifted-answer.out" 2> "$home/drifted-answer.err"; then
    fail "answer retry accepted a different captain decision"
  fi
  # The answered call releases the work routed behind it: a Done blocker reads
  # as resolved everywhere.
  show=$(tasks_in "$home" show sample-guard-work --full)
  assert_contains "$show" "blocked: no" "the recorded answer did not release dependent work"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "an answered captain call did not satisfy the completion gate"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-guard-call") | not)
      and (.gates | any(.id == "sample-guard-call") | not)
      and (.landed | any(.id == "sample-guard-call") | not)
  ' >/dev/null || fail "an answered captain call still renders somewhere it should not: $json"
  pass "answer records the captain's words, closes idempotently, and releases routed work"
}

# --release lifts the hold instead of closing, preserving the work item's own
# body under the record; a re-held task later accepts a new answer.
test_release_frees_held_work() {
  local home show out snap
  home=$(make_home release-work)
  cat > "$home/widget-body.txt" <<'EOF'
The widget plan body. Literal escape: \n. Unicode: café.
Captain hold set: 2025-01-02T03:04:05Z
EOF
  tasks_in "$home" add sample-widget "Ship the sample widget" --kind ship --repo sample \
    --body-file "$home/widget-body.txt" >/dev/null \
    || fail "could not create the held work item"
  FM_CAPTAIN_HOLD_NOW=2026-06-01T12:00:00Z run_captain "$home" hold sample-widget \
    --reason "captain go needed before shipping" >/dev/null \
    || fail "could not hold the work item for the captain"
  printf 'Not urgent; ship it as planned.\n' > "$home/go.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "answer --release failed on the held work item"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a released work item did not stay queued"
  assert_contains "$show" "held: no" "a released work item kept its hold"
  assert_contains "$show" "Resolution mode: released" "the release did not record its close path"
  assert_contains "$show" "Not urgent; ship it as planned." "the release lost the captain's words"
  assert_contains "$show" "The widget plan body." "the release destroyed the work item body"
  assert_contains "$show" 'Literal escape: \\n. Unicode: café.' \
    "the release corrupted escaped or Unicode body text"
  assert_contains "$show" "Captain hold set: 2025-01-02T03:04:05Z" \
    "hold stamping deleted matching user content outside the leading stamp"
  run_captain "$home" answer sample-widget --decision-file "$home/go.txt" --release >/dev/null \
    || fail "identical release retry was not idempotent"
  if run_captain "$home" answer sample-widget --decision-file "$home/go.txt" \
    > "$home/wrong-mode.out" 2> "$home/wrong-mode.err"; then
    fail "a released answer replay without --release reported completion"
  fi
  assert_grep "mode released" "$home/wrong-mode.err" \
    "the mismatched replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: queued" "a mismatched release replay closed the work item"
  assert_contains "$show" "held: no" "a mismatched release replay re-held the work item"

  tasks_in "$home" add sample-empty-label-widget "Ship without a display label" \
    --kind ship --repo sample >/dev/null
  run_captain "$home" hold sample-empty-label-widget --reason "captain go needed" >/dev/null
  out=$(printf 'sample-empty-label-widget\tgo\t\trelease\n' \
    | run_captain "$home" answers --source "empty-label release fixture") \
    || fail "an empty answer label shifted the release close mode"
  assert_contains "$out" "closed: sample-empty-label-widget" \
    "the empty-label release was not accepted"
  show=$(tasks_in "$home" show sample-empty-label-widget --full)
  assert_contains "$show" "state: queued" "an empty-label release completed its work item"
  assert_contains "$show" "held: no" "an empty-label release did not lift the hold"
  assert_contains "$show" "Resolution mode: released" \
    "an empty-label release recorded the wrong close mode"

  # A NEW captain gate on the same task later takes a NEW answer.
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-widget \
    --reason "captain pricing call needed" >/dev/null \
    || fail "could not re-hold the released work item"
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed after re-hold"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "sample-widget")
    | .hold_set == "2026-07-14T12:00:00Z"
      and .hold_age_days == 0
      and .hold_bucket == "live"
  ' >/dev/null || fail "a new hold lifecycle reused historical timestamp or answer text: $snap"
  printf 'Price it at nine dollars.\n' > "$home/price.txt"
  run_captain "$home" answer sample-widget --decision-file "$home/price.txt" --release >/dev/null \
    || fail "a re-held task refused a new answer"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "Price it at nine dollars." "the new answer was not recorded"
  assert_contains "$show" "Not urgent; ship it as planned." "the new answer erased the earlier record"

  tasks_in "$home" "done" sample-widget >/dev/null \
    || fail "could not complete the released work item normally"
  if run_captain "$home" answer sample-widget --decision-file "$home/price.txt" \
    > "$home/closed-wrong-mode.out" 2> "$home/closed-wrong-mode.err"; then
    fail "a completed release replay without --release reported an answer"
  fi
  assert_grep "mode released" "$home/closed-wrong-mode.err" \
    "the completed replay did not name the recorded release mode"
  show=$(tasks_in "$home" show sample-widget --full)
  assert_contains "$show" "state: done" "a refused completed replay changed task state"
  pass "release frees held work with the captain's words recorded and the body preserved"
}

# The hold-set stamp must be durable before the captain hold becomes visible.
# A wrapper observes the real tasks-axi hold boundary, and a forced stamp-write
# failure proves the command never publishes the hold without its timestamp.
test_hold_stamp_precedes_hold_visibility() {
  local home show
  home=$(make_home hold-stamp-order)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-old-call - Existing old task (repo: sample) (kind: ship) (since 2026-01-01)
- [ ] sample-stamp-failure - Existing task whose stamp fails (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = update ] && [ "${2:-}" = sample-stamp-failure ]; then
  exit 92
fi
if [ "${1:-}" = hold ] && [ "${2:-}" = sample-old-call ]; then
  show=$("$REAL_TASKS_AXI" show "$2" --full) || exit 93
  printf '%s\n' "$show" | grep -F 'Captain hold set: 2026-07-14T12:00:00Z' >/dev/null || exit 94
  : > "$FM_HOME/hold-observed-after-stamp"
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-old-call \
    --reason "captain route choice pending" >/dev/null \
    || fail "hold was published before its hold-set stamp"
  assert_present "$home/hold-observed-after-stamp" \
    "the tasks-axi hold boundary was not observed"
  show=$(tasks_in "$home" show sample-old-call --full)
  assert_contains "$show" "hold_kind: captain" "the stamped task was not captain-held"
  assert_contains "$show" "Captain hold set: 2026-07-14T12:00:00Z" \
    "the visible captain hold lost its timestamp"

  if FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-stamp-failure \
    --reason "captain route choice pending" > "$home/stamp-failure.out" 2> "$home/stamp-failure.err"; then
    fail "hold succeeded after its timestamp update failed"
  fi
  show=$(tasks_in "$home" show sample-stamp-failure --full)
  assert_contains "$show" "held: no" "a failed timestamp update still published the hold"
  assert_contains "$show" 'hold_kind: "-"' "a failed timestamp update retained captain-hold provenance"
  pass "captain holds become visible only after their hold-set timestamp is durable"
}

test_interrupted_answer_preserves_hold_age() {
  local home snap show
  home=$(make_home interrupted-answer-age)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-interrupted-call - Existing old task (repo: sample) (kind: ship) (since 2026-01-01)

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-interrupted-call \
    --reason "captain route choice pending" >/dev/null \
    || fail "could not hold the interrupted-answer fixture"
  printf 'Not urgent in the historical answer.\n' > "$home/interrupted-answer.txt"
  mkdir -p "$home/at-close"
  cat > "$home/fakebin/tasks-axi" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = done ] && [ "${2:-}" = sample-interrupted-call ] \
  && [ ! -e "$FM_HOME/close-failed-once" ]; then
  cp "$FM_HOME/data/backlog.md" "$FM_HOME/at-close/backlog.md" || exit 93
  : > "$FM_HOME/close-failed-once"
  exit 92
fi
if [ "${1:-}" = update ] && [ "${2:-}" = sample-interrupted-call ] \
  && [ ! -e "$FM_HOME/normalize-failed-once" ]; then
  state=$("$REAL_TASKS_AXI" show "$2" --full | sed -n 's/^  state: //p' | head -1)
  if [ "$state" = done ]; then
    : > "$FM_HOME/normalize-failed-once"
    exit 94
  fi
fi
exec "$REAL_TASKS_AXI" "$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"

  if run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" > "$home/answer.out" 2> "$home/answer.err"; then
    fail "the forced answer close failure reported success"
  fi
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/at-close" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at interrupted close boundary"
  printf '%s' "$snap" | jq -e '
    .backlog.records[] | select(.id == "sample-interrupted-call")
    | .captain_actionable == true
      and .hold_set == "2026-07-14T12:00:00Z"
      and .hold_age_days == 0
      and .hold_bucket == "live"
  ' >/dev/null || fail "an interrupted answer lost the fresh hold age basis: $snap"

  if run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" > "$home/normalize.out" 2> "$home/normalize.err"; then
    fail "the forced post-close normalization failure reported success"
  fi
  show=$(tasks_in "$home" show sample-interrupted-call --full)
  assert_contains "$show" "state: done" "the normalization failure undid the successful close"
  run_captain "$home" answer sample-interrupted-call \
    --decision-file "$home/interrupted-answer.txt" >/dev/null \
    || fail "the closed answer could not normalize on retry"
  show=$(tasks_in "$home" show sample-interrupted-call --full)
  assert_contains "$show" 'body: "Resolution recorded by fm-captain-hold.' \
    "the matching done retry did not restore resolution-first body ordering"
  pass "an interrupted answer preserves its hold age until close retry"
}

# Deferral is a date, not a live card: hold --until keeps the task out of
# captain_actionable until due, tasks-axi's own date-gate expiry keeps the task
# answerable, and Bearings renders the wait as a dated gate.
test_deferral_leaves_captains_call_until_due() {
  local home json snap show
  home=$(make_home deferral)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] sample-existing-call - Decide an existing sample task (repo: sample) (kind: captain) (since 2026-06-01)
- [ ] sample-near-marker - Decide a deferred sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: choose the sample route) (hold-kind: captain)
  Captain hold set: 2026-07-14T12:00:00Z
  abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij DEFERRED
- [ ] sample-late-marker - Decide a documented sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: choose the sample route) (hold-kind: captain)
  This deliberately long decision context fills the bounded display excerpt without changing the durable classification contract. Additional synthetic context keeps extending the body beyond that display boundary while remaining ordinary task prose. More synthetic context places the presentation marker after the excerpt cutoff. DEFERRED

## Done
EOF
  FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run_captain "$home" hold sample-existing-call \
    --reason "captain choice on existing work" >/dev/null \
    || fail "could not hold the existing task"
  FM_CAPTAIN_HOLD_NOW=2026-07-20T12:00:00Z run_captain "$home" hold sample-existing-call \
    --reason "captain choice on existing work" >/dev/null \
    || fail "could not repeat the existing task hold"
  run_captain "$home" hold sample-later-call --title "Revisit the sample plan" \
    --reason "captain deferred revisit later" --repo sample --until 2026-08-01 >/dev/null \
    || fail "could not register the deferred captain call"
  run_captain "$home" hold sample-now-call --title "Decide the sample cut" \
    --reason "captain cut choice pending" --repo sample >/dev/null \
    || fail "could not register the live captain call"
  if run_captain "$home" hold sample-bad-date --title "Bad date" \
    --reason "captain choice" --until 2026-8-1 > "$home/bad-date.out" 2> "$home/bad-date.err"; then
    fail "hold accepted a malformed --until date"
  fi

  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-07-14T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-now-call")][0]) as $now
    | ([.backlog.records[] | select(.id == "sample-existing-call")][0]) as $existing
    | $later.captain_actionable == false and $later.hold_until == "2026-08-01"
      and $now.captain_actionable == true and $now.hold_until == null
      and $existing.since == "2026-06-01" and $existing.hold_set == "2026-07-14T12:00:00Z"
      and $existing.hold_age_days == 0 and $existing.hold_bucket == "live"
      and ([.backlog.records[] | select(.id == "sample-near-marker")][0].hold_bucket == "live")
      and ([.backlog.records[] | select(.id == "sample-late-marker")][0].hold_bucket == "live")
      and ($later.title | contains("hold-until") | not)
  ' >/dev/null || fail "the due gate, hold-set age, or hold-until parsing is wrong: $snap"

  json=$(run_bearings "$home") || fail "Bearings failed with a deferred call"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "sample-now-call"))
      and (.decisions_open | any(.id == "sample-existing-call"))
      and (.decisions_open | any(.id == "sample-later-call") | not)
      and (.gates | any(.id == "sample-later-call" and (.reason | startswith("until 2026-08-01"))))
  ' >/dev/null || fail "the deferred call did not render as a dated gate: $json"

  # On its date the call is due again - and still answerable even though
  # tasks-axi reports the expired hold as no longer held.
  snap=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_SNAPSHOT_NOW=2026-08-01T12:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed at the due date"
  printf '%s' "$snap" | jq -e '
    ([.backlog.records[] | select(.id == "sample-later-call")][0]) as $later
    | ([.backlog.records[] | select(.id == "sample-existing-call")][0]) as $existing
    | $later.captain_actionable == true
      and $existing.hold_age_days == 18 and $existing.hold_bucket == "aged"
  ' >/dev/null || fail "a due deferral did not resurface or a stamped hold did not age from its hold date"
  show=$(tasks_in "$home" show sample-later-call --full)
  assert_contains "$show" "hold_kind: captain" "the expired deferral lost its captain-hold annotations"
  printf 'Answered on the due date.\n' > "$home/due.txt"
  run_captain "$home" answer sample-later-call --decision-file "$home/due.txt" >/dev/null \
    || fail "an expired deferral was not answerable"
  pass "a deferred captain call leaves the live Captain's Call until its date and stays answerable"
}

# The recorded-answer guard survives an out-of-band close: a bare tasks-axi done
# fails verify until answer records the captain's word, and an ordinary finished
# task can never be dressed up as an answered captain call.
test_out_of_band_close_is_recordable() {
  local home id show
  home=$(make_home out-of-band)
  id=sample-fullrun-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample full run" --kind scout --repo sample --start >/dev/null \
    || fail "could not create out-of-band origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample full run review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-submission-call --title "Choose the sample submission" \
    --reason "captain submission choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-submission-call >/dev/null \
    || fail "completion failed before the out-of-band close"

  tasks_in "$home" "done" sample-submission-call >/dev/null \
    || fail "could not reproduce the direct out-of-band close"
  if run_captain "$home" verify "$id" > "$home/broken-verify.out" 2> "$home/broken-verify.err"; then
    fail "verification passed a captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/broken-teardown.out" 2> "$home/broken-teardown.err"; then
    fail "teardown proceeded while a captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  printf 'Declined: do not submit the sample full run upstream.\n' > "$home/submission.txt"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "answer could not record the missing captain decision on the closed task"
  show=$(tasks_in "$home" show sample-submission-call --full)
  assert_contains "$show" "state: done" "recording the answer reopened the closed task"
  assert_contains "$show" "Resolution mode: repaired" "the retroactive record did not name its path"
  assert_contains "$show" "Declined: do not submit the sample full run upstream." \
    "the retroactive record lost the captain decision text"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the recorded answer did not satisfy the completion gate"
  run_captain "$home" answer sample-submission-call --decision-file "$home/submission.txt" >/dev/null \
    || fail "identical retroactive retry was not idempotent"
  printf 'A different answer entirely.\n' > "$home/drifted.txt"
  if run_captain "$home" answer sample-submission-call --decision-file "$home/drifted.txt" \
    > "$home/drifted.out" 2> "$home/drifted.err"; then
    fail "a drifted retry overwrote the recorded captain decision"
  fi
  run_teardown "$home" "$id" >/dev/null 2> "$home/teardown.err" \
    || fail "teardown still refused after the answer was recorded: $(cat "$home/teardown.err")"

  # An ordinary finished task was never the captain's item; recording an
  # invented answer on it must be refused.
  tasks_in "$home" add sample-ordinary-work "Ordinary finished work" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" sample-ordinary-work >/dev/null
  printf 'An answer the captain never gave.\n' > "$home/invented.txt"
  if run_captain "$home" answer sample-ordinary-work --decision-file "$home/invented.txt" \
    > "$home/never-held.out" 2> "$home/never-held.err"; then
    fail "an ordinary finished task was dressed up as an answered captain call"
  fi
  assert_grep "never held for the captain" "$home/never-held.err" \
    "the refusal must say the task carries no captain-hold provenance"
  pass "an out-of-band close is recordable with the captain's word and nothing else"
}

# A post-teardown visual review completes against the surviving report and
# durable tasks, with no volatile task metadata and no second decision database.
test_visual_review_uses_shared_completion_owner() {
  local home id json
  home=$(make_home visual-review)
  id=sample-board-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review the sample board" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: investigation complete\n' > "$home/state/$id.status"
  printf '# Sample board investigation\n\nThe initial findings need no captain choice.\n' > "$home/data/$id/report.md"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "initial investigation could not pass the shared completion owner"
  run_teardown "$home" "$id" >/dev/null 2> "$home/visual-teardown.err" \
    || fail "completed investigation teardown failed: $(cat "$home/visual-teardown.err")"
  tasks_in "$home" "done" "$id" --report "data/$id/report.md" --keep 0 >/dev/null

  mkdir -p "$home/.lavish"
  printf '<html><body>Synthetic sample board</body></html>\n' > "$home/.lavish/sample-board.html"
  run_captain "$home" hold sample-layout-call --title "Choose the sample layout" \
    --reason "captain layout choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "post-teardown visual review could not use the shared hold owner"
  run_captain "$home" complete "$id" sample-layout-call >/dev/null \
    || fail "post-teardown visual review could not use the shared completion owner"
  json=$(run_bearings "$home") || fail "Bearings failed after the ended visual review"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.id == "sample-layout-call" and .verb == "captain-hold")
  ' >/dev/null || fail "ended visual review did not leave its durable Captain Call: $json"
  [ ! -e "$home/data/visual-review-decisions.json" ] \
    || fail "visual review created a second decision database"
  pass "ended visual review follows the same captain-hold completion owner"
}

test_none_inventory_and_resolved_prose_do_not_create_holds() {
  local home id json
  home=$(make_home no-false-holds)
  id=sample-resolved-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a resolved sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'resolved [key=old-choice]: the sample choice was already recorded\ndone: report complete\n' \
    > "$home/state/$id.status"
  cat > "$home/data/$id/report.md" <<'EOF'
# Resolved sample finding

Decision record: the earlier choice is resolved.
The recommendation is informational and needs no captain action.
EOF
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "explicit no-call inventory failed"
  json=$(run_bearings "$home") || fail "Bearings failed for no-call inventory"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id | startswith("sample-resolved-review")) | not)
  ' >/dev/null || fail "resolved findings or decision-like prose created a false captain call: $json"
  pass "resolved findings and decision-like prose do not create captain-held tasks"
}

test_terminal_single_owner_status_decision_does_not_block_empty_inventory() {
  local home id open secondmate
  home=$(make_home stale-terminal-decision)
  id=sample-terminal-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Review a terminal sample finding" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'blocked [key=access]: waiting\ndone: report complete\nnote: cleanup complete\n' \
    > "$home/state/$id.status"
  printf '# Terminal sample review\n\nNo unresolved captain choice remains.\n' > "$home/data/$id/report.md"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$home/state/$id.status")
  [ -z "$open" ] || fail "the shared fold retained a pre-terminal blocker"
  run_captain "$home" complete "$id" --none >/dev/null \
    || fail "terminal single-owner stale status decision blocked empty inventory completion"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "terminal single-owner stale status decision blocked inventory verification"
  printf 'blocked [key=access]: reopened\nnote: more cleanup\n' >> "$home/state/$id.status"
  if run_captain "$home" complete "$id" --none > "$home/reopened.out" 2> "$home/reopened.err"; then
    fail "completion accepted a genuinely reopened post-terminal decision"
  fi
  if run_captain "$home" verify "$id" > "$home/reopened-verify.out" 2> "$home/reopened-verify.err"; then
    fail "verification accepted a genuinely reopened post-terminal decision"
  fi
  printf 'resolved [key=access]: answered\nfailed: investigation ended\nnote: final cleanup\n' >> "$home/state/$id.status"
  run_captain "$home" complete "$id" --none >/dev/null || fail "resolved reopening blocked completion"
  run_captain "$home" verify "$id" >/dev/null || fail "resolved reopening blocked verification"
  run_teardown "$home" "$id" >/dev/null 2> "$home/terminal-teardown.err" \
    || fail "terminal single-owner stale status decision blocked teardown: $(cat "$home/terminal-teardown.err")"

  secondmate=sample-secondmate
  write_origin_meta "$home" "$secondmate" secondmate
  printf 'blocked [key=route]: waiting\ndone: heartbeat complete\nnote: cleanup complete\n' \
    > "$home/state/$secondmate.status"
  if run_captain "$home" complete "$secondmate" --none \
    > "$home/secondmate-terminal.out" 2> "$home/secondmate-terminal.err"; then
    fail "secondmate terminal status decision was incorrectly cleared"
  fi
  pass "terminal single-owner stale status decisions do not block empty inventory"
}

test_secondmate_hold_stays_in_authoritative_home() {
  local parent mate fakebin origin json
  parent=$(make_home main-routing)
  mate="$TMP_ROOT/sample-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  fm_test_tasks_toml "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'sample-mate\n' > "$mate/.fm-secondmate-home"
  # A seeded home always carries its parent binding; teardown delivers the
  # scout's final line through it before removing the record.
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  origin=sample-mate-review
  mkdir -p "$mate/data/$origin"
  tasks_in "$mate" add "$origin" "Investigate secondmate sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" "$origin"
  printf 'done: report and visual review complete\n' > "$mate/state/$origin.status"
  printf '# Sample secondmate review\n\nOne captain choice remains.\n' > "$mate/data/$origin/report.md"
  run_captain "$mate" hold sample-release-call --title "Choose the sample release" \
    --reason "captain release choice pending" --repo sample --origin "$origin" >/dev/null \
    || fail "secondmate-owned hold creation failed"
  run_captain "$mate" complete "$origin" sample-release-call >/dev/null \
    || fail "secondmate-owned completion failed"
  # The parent registers the mate before its children are ever torn down;
  # teardown resolves that registration to deliver the scout's final line.
  printf -- '- sample-mate - synthetic scope (home: %s; scope: sample reviews; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/sample-mate.meta" "$mate" \
    "firstmate:fm-sample-mate" sample
  run_teardown "$mate" "$origin" >/dev/null 2> "$mate/teardown.err" \
    || fail "secondmate investigation teardown failed: $(cat "$mate/teardown.err")"
  tasks_in "$mate" "done" "$origin" --report "data/$origin/report.md" --keep 0 >/dev/null
  grep -Eq "^done \\[key=child-outcome-$origin-done-[0-9a-f]{8}\\] \\[at=[0-9]+\\]: child $origin done: report and visual review complete mode=scout report=data/$origin/report.md$" \
    "$parent/state/sample-mate.status" \
    || fail "the scout's final line did not reach the parent at teardown"

  json=$(run_bearings "$parent") || fail "parent Bearings could not read the secondmate captain call"
  printf '%s' "$json" | jq -e '
    .decisions_open | any(.owner == "sample-mate" and .verb == "captain-hold"
      and (.id | endswith("sample-release-call")))
  ' >/dev/null || fail "secondmate captain call did not surface with authoritative owner: $json"
  assert_no_grep "sample-release-call" "$parent/data/backlog.md" "secondmate call leaked into the main backlog"
  assert_grep "sample-release-call" "$mate/data/backlog.md" "secondmate call left its authoritative backlog"
  pass "main-home and secondmate-home captain calls remain correctly routed"
}

# Inside a secondmate home a hold and its answer reach the parent channel from
# the script itself, keyed per hold occurrence, so a re-held task opens and
# closes a distinct parent decision and a retry never duplicates a line. A main
# home publishes nothing anywhere.
test_secondmate_home_publishes_holds_and_answers() {
  local parent mate fakebin channel decision out
  parent=$(make_home parent-channel)
  mate="$TMP_ROOT/channel-mate-home"
  mkdir -p "$mate/data" "$mate/state" "$mate/config" "$mate/projects"
  fm_test_tasks_toml "$mate/.tasks.toml"
  printf '# Synthetic secondmate home\n' > "$mate/AGENTS.md"
  printf 'channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$mate")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  channel="$parent/state/channel-mate.status"
  decision="$mate/decision.txt"

  tasks_in "$mate" add quoted-record-call "Choose quoted record handling" --kind ship --repo sample \
    --body 'Documentation quote: Resolution recorded by fm-captain-hold.' >/dev/null \
    || fail "could not create quoted-record captain call"
  run_captain "$mate" hold quoted-record-call --reason "quoted record choice pending" \
    --origin quoted-origin >/dev/null || fail "quoted-record hold failed"
  assert_grep 'needs-decision [key=captain-hold-quoted-record-call-1]: captain hold quoted-record-call: quoted record choice pending' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "body prose was incorrectly counted as a resolution record"

  run_captain "$mate" hold mate-call --title "Choose the mate release" \
    --reason "release choice pending" --repo sample >/dev/null \
    || fail "mate hold failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-1]: captain hold mate-call: release choice pending' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the mate's hold did not reach the parent channel"
  run_captain "$mate" hold mate-call --reason "release choice pending" >/dev/null \
    || fail "repeated mate hold failed"
  [ "$(grep -c 'captain-hold-mate-call-1' "$channel")" = 1 ] \
    || fail "a repeated hold duplicated the parent decision: $(cat "$channel")"

  printf 'ship it later\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" --release >/dev/null \
    || fail "mate release answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-1]: captain hold mate-call: released' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the released answer did not close the parent decision"

  run_captain "$mate" hold mate-call --reason "second release choice" >/dev/null \
    || fail "re-hold after release failed"
  assert_grep 'needs-decision [key=captain-hold-mate-call-2]: captain hold mate-call: second release choice' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "a re-held task did not open a distinct parent decision"
  printf 'ship it\n' > "$decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "mate close answer failed"
  assert_grep 'resolved [key=captain-hold-mate-call-2]: captain hold mate-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel") "the closing answer did not close the second parent decision"
  run_captain "$mate" answer mate-call --decision-file "$decision" >/dev/null \
    || fail "idempotent answer retry failed"
  [ "$(grep -c 'captain-hold-mate-call-2' "$channel")" = 2 ] \
    || fail "an answer retry duplicated a parent line: $(cat "$channel")"
  [ "$(grep -c 'captain-hold-mate-call' "$channel")" = 4 ] \
    || fail "unexpected parent channel contents: $(cat "$channel")"

  run_captain "$mate" hold batch-call --title "Choose the batch release" \
    --reason "batch choice pending" --repo sample >/dev/null \
    || fail "batch hold failed"
  mv "$channel" "$channel.saved"
  mkdir "$channel"
  out=$(printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" 2>&1) \
    || fail "batch answer did not preserve its durable close: $out"
  printf '%s\n' "$out" | grep -Fq 'actionable:' \
    || fail "failed batch parent delivery was not actionable: $out"
  rmdir "$channel"
  mv "$channel.saved" "$channel"
  printf 'batch-call\tship now\t\n' \
    | run_captain "$mate" answers --source "batch retry fixture" >/dev/null \
    || fail "idempotent batch answer retry failed"
  [ "$(grep -c 'resolved \[key=captain-hold-batch-call-1\]' "$channel")" = 1 ] \
    || fail "batch retry did not restore exactly one parent resolution: $(cat "$channel")"

  run_captain "$parent" hold main-call --title "Choose the main release" \
    --reason "main choice pending" --repo sample >/dev/null || fail "main hold failed"
  [ ! -e "$parent/state/parent-replies.status" ] || fail "a main home wrote a parent reply"
  assert_no_grep 'captain-hold-main-call' "$channel" "a main home's hold leaked onto a mate channel"
  pass "a secondmate home publishes each hold occurrence and its answer on the parent channel"
}

test_secondmate_reconcile_publishes_before_request_retirement() {
  local parent mate channel evidence out show rc request
  parent=$(make_home reconcile-parent-channel)
  mate=$(make_home reconcile-channel-mate)
  printf 'reconcile-channel-mate\n' > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  channel="$parent/state/reconcile-channel-mate.status"
  evidence="$mate/reconcile-evidence.txt"

  tasks_in "$mate" add reconcile-channel-call "Verify the mate call" --kind ship --repo sample >/dev/null \
    || fail "could not create the reconcile channel call"
  run_captain "$mate" hold reconcile-channel-call --reason "verify current release state" >/dev/null \
    || fail "could not hold the reconcile channel call"
  request_reconciles "$mate" reconcile-board reconcile-channel-call \
    || fail "could not request the channel reconciliation"
  printf 'The release has already landed.\n' > "$evidence"
  request="$mate/state/reconcile-requests/reconcile-channel-call.request"

  chmod 0500 "$mate/state/reconcile-requests"
  set +e
  out=$(run_captain "$mate" reconcile close reconcile-channel-call \
    --evidence-file "$evidence" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$mate/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "failed reconcile request retirement reported success"
  assert_contains "$out" "reconcile-channel-call" \
    "the reconcile retirement failure did not name its task: $out"
  show=$(tasks_in "$mate" show reconcile-channel-call --full)
  assert_contains "$show" "state: done" "request retirement failure reversed the reconciled close"
  assert_contains "$show" "Resolution mode: reconciled" \
    "request retirement failure lost the reconciled resolution mode"
  [ -f "$request" ] || fail "the request retired despite its forced retirement failure"
  [ "$(grep -c 'resolved \[key=captain-hold-reconcile-channel-call-1\]: captain hold reconcile-channel-call: reconciled' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the parent resolution was not published before retirement failed: $(cat "$channel")"

  run_captain "$mate" reconcile close reconcile-channel-call --evidence-file "$evidence" >/dev/null \
    || fail "the closed reconciliation could not finish publication and retirement"
  [ ! -e "$request" ] || fail "the retry did not retire the published reconcile request"
  [ "$(grep -c 'resolved \[key=captain-hold-reconcile-channel-call-1\]: captain hold reconcile-channel-call: reconciled' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the reconciliation retry duplicated or changed its parent resolution: $(cat "$channel")"
  tasks_in "$mate" add answer-channel-call "Answer the mate call" --kind ship --repo sample >/dev/null \
    || fail "could not create the normal-answer channel call"
  run_captain "$mate" hold answer-channel-call --reason "captain answer needed" >/dev/null \
    || fail "could not hold the normal-answer channel call"
  request_reconciles "$mate" reconcile-board answer-channel-call \
    || fail "could not create the normal-answer retry trigger"
  printf 'Proceed with the release.\n' > "$mate/answer.txt"
  request="$mate/state/reconcile-requests/answer-channel-call.request"
  chmod 0500 "$mate/state/reconcile-requests"
  set +e
  out=$(run_captain "$mate" answer answer-channel-call --decision-file "$mate/answer.txt" 2>&1)
  rc=$?
  set -e
  chmod 0700 "$mate/state/reconcile-requests"
  [ "$rc" -ne 0 ] || fail "failed normal-answer request retirement reported success"
  show=$(tasks_in "$mate" show answer-channel-call --full)
  assert_contains "$show" "state: done" "request retirement failure reversed the captain answer"
  [ -f "$request" ] || fail "the normal-answer retry trigger retired after its forced failure"
  [ "$(grep -c 'resolved \[key=captain-hold-answer-channel-call-1\]: captain hold answer-channel-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the normal answer did not publish before retirement failed: $(cat "$channel")"
  run_captain "$mate" answer answer-channel-call --decision-file "$mate/answer.txt" >/dev/null \
    || fail "the normal-answer retry could not finish request retirement"
  [ ! -e "$request" ] || fail "the normal-answer retry left its request pending"
  [ "$(grep -c 'resolved \[key=captain-hold-answer-channel-call-1\]: captain hold answer-channel-call: answered' \
    <(sed -E 's/ \[at=[0-9]+\]//' "$channel"))" -eq 1 ] \
    || fail "the normal-answer retry duplicated its parent resolution: $(cat "$channel")"
  pass "secondmate resolutions publish before retiring durable retry triggers"
}

# A shown scalar field is a JSON-encoded bare string, and JSON::PP accepts one
# only when allow_nonref is on. Recent releases default it on, so this case
# forces the older default back off for every perl the command spawns - the same
# rejection a host with JSON::PP 2.27202 produces - then drives both paths that
# read a body back: holding a task for the captain, and the cleanup that retains
# a captain-held row with its deliverable.
test_hold_decodes_a_bare_scalar_body_without_the_nonref_default() {
  local home shim id show probe scout
  home=$(make_home nonref-default)
  shim="$home/no-nonref-default"
  mkdir -p "$shim"
  cat > "$shim/FmNoNonrefDefault.pm" <<'PM'
package FmNoNonrefDefault;
require JSON::PP;
my $new = \&JSON::PP::new;
{
  no warnings 'redefine';
  *JSON::PP::new = sub { my $self = $new->(@_); $self->allow_nonref(0); $self };
}
1;
PM

  # Without this the case would pass on any decode path at all, including the
  # one this regression exists to catch.
  probe=$(printf '%s' '"probe"' | PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    perl -MJSON::PP -e 'local $/; eval { decode_json(<STDIN>) };
      print $@ ? "rejects" : "accepts";')
  [ "$probe" = rejects ] \
    || fail "the simulated older default still accepted a bare scalar"

  id=sample-nonref-body
  tasks_in "$home" add "$id" "Work carrying a body" --kind ship --repo sample \
    --body 'First line of the plan.' >/dev/null \
    || fail "could not create the task carrying a body"
  PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    run_captain "$home" hold "$id" --reason "captain go needed" >/dev/null \
    || fail "a captain hold failed where allow_nonref is not on by default"
  show=$(tasks_in "$home" show "$id" --full) || fail "the held row disappeared"
  assert_contains "$show" "hold_kind: captain" "the hold lost its captain kind"
  assert_contains "$show" "Captain hold set:" "the hold lost its hold-set stamp"
  assert_contains "$show" "First line of the plan." "the hold lost the original body"

  # Cleanup reads the same body back to append the finished work's deliverable.
  scout=sample-nonref-scout
  mkdir -p "$home/data/$scout"
  tasks_in "$home" add "$scout" "Investigate the sample body decode" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$scout"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Sample body decode\n\nOne captain choice remains.\n' \
    > "$home/data/$scout/report.md"
  run_captain "$home" hold "$scout" --reason "captain must choose" >/dev/null \
    || fail "could not hold the investigation for the captain"
  complete_through_sibling "$home" "$scout" >/dev/null \
    || fail "the completion gate failed with the origin as its own captain call"
  PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    run_teardown "$home" "$scout" > "$home/nonref.out" 2> "$home/nonref.err" \
    || fail "cleanup of a captain-held row failed where allow_nonref is not on by default: $(cat "$home/nonref.err")"
  show=$(tasks_in "$home" show "$scout" --full) || fail "the retained row disappeared"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$scout/report.md" \
    "cleanup lost the deliverable it could not decode a body to append to"
  assert_contains "$show" "Captain hold set:" "cleanup lost the hold-set stamp"
  pass "both body-decoding paths work without the allow_nonref default"
}

# Cleanup rewrites a captain-held row's body to append the finished work's
# deliverable, so every byte of that body has to survive the decode. The
# assertions below are on bytes, not characters: a decoder that prints a
# character string to a stream with no :raw layer emits a codepoint at or below
# U+00FF as one latin-1 byte, which is not valid UTF-8, and the comparison of
# decoded strings would not notice.
#
# The two characters go in separate rows on purpose. A string that holds any
# character above U+00FF is printed as UTF-8 whatever the layer, so mixing them
# in one body hides the latin-1 case entirely.

# Take one captain-held row carrying <body> all the way through cleanup, which
# is the path that reads the body back to append the deliverable.
retain_row_with_body() {  # <home> <id> <body>
  local home=$1 id=$2 body=$3
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the sample body bytes" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the fixture for $id"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample body bytes\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  tasks_in "$home" update "$id" --body "$body" >/dev/null \
    || fail "could not give $id a body carrying non-ASCII characters"
  run_captain "$home" hold "$id" --reason "captain must choose" >/dev/null \
    || fail "could not hold $id for the captain"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "the completion gate failed for $id"
  run_teardown "$home" "$id" > "$home/$id.out" 2> "$home/$id.err" \
    || fail "cleanup of captain-held $id failed: $(cat "$home/$id.err")"
}

test_retained_body_keeps_its_utf8_bytes() {
  local home accented wide narrow_id wide_id stored
  home=$(make_home retain-utf8)
  # Built from escapes so this file stays ASCII and the intended bytes are
  # explicit: U+00E9 is the latin-1-representable case, U+2014 the wider one.
  accented=$(printf 'caf\xc3\xa9')
  wide=$(printf '\xe2\x80\x94')
  stored="$home/data/backlog.md"

  # A body whose characters are all at or below U+00FF.
  narrow_id=sample-utf8-narrow
  retain_row_with_body "$home" "$narrow_id" "Serve the $accented black, no sugar."
  # data/backlog.md is the markdown backend's own persisted artifact, read here
  # for its bytes because the shown field re-encodes them.
  assert_grep "Deliverable of the finished work: report data/$narrow_id/report.md" "$stored" \
    "cleanup did not rewrite the retained body, so nothing decoded it"
  LC_ALL=C grep -qF "$accented" "$stored" \
    || fail "the retained body lost the UTF-8 bytes of a character at or below U+00FF"
  ! LC_ALL=C grep -q "$(printf '[\xe9]')" "$stored" \
    || fail "the retained body holds a lone latin-1 byte, so it is no longer valid UTF-8"

  # A body carrying a character above U+00FF keeps its bytes and stays quiet.
  wide_id=sample-utf8-wide
  retain_row_with_body "$home" "$wide_id" "Serve it $wide black, no sugar."
  LC_ALL=C grep -qF "$wide" "$stored" \
    || fail "the retained body lost the UTF-8 bytes of a character above U+00FF"
  assert_no_grep "Wide character" "$home/$wide_id.err" \
    "cleanup warned about a wide character instead of writing raw bytes"

  pass "cleanup preserves every byte of a retained body's non-ASCII characters"
}

# A refused hold must never read as a recorded one. The gate used to accept the
# origin as its own inventory whenever the origin row looked durable, so a hold
# that failed just before `complete <origin> <origin>` left a satisfied gate
# with no captain call recorded.
test_origin_is_never_its_own_inventory_entry() {
  local home id
  home=$(make_home origin-self-inventory)
  id=sample-self-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample self review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  if run_captain "$home" hold "$id" --reason "" >/dev/null 2> "$home/hold.err"; then
    fail "hold accepted an empty reason"
  fi
  if run_captain "$home" complete "$id" "$id" > "$home/self.out" 2> "$home/self.err"; then
    fail "complete accepted the origin as its own inventory after a failed hold"
  fi
  assert_grep "cannot be its own captain-call inventory entry" "$home/self.err" \
    "the refusal does not say why the origin was rejected"
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "the refused completion recorded an inventory attestation"

  # Holding the origin row itself must not let it vouch for itself either.
  run_captain "$home" hold "$id" --reason "captain must choose" >/dev/null \
    || fail "could not hold the origin row"
  if run_captain "$home" complete "$id" "$id" > "$home/held.out" 2> "$home/held.err"; then
    fail "complete accepted a held origin row as its own inventory"
  fi
  pass "complete refuses the origin as its own captain-call inventory"
}

# `hold --origin` records which origin a call was held for, and `complete`
# refuses a task held for a different origin. A hold recorded before that
# record existed, or without --origin, still verifies and is flagged.
test_complete_refuses_an_entry_held_for_another_origin() {
  local home id other o out
  home=$(make_home origin-mismatch)
  id=sample-first-review
  other=sample-second-review
  for o in "$id" "$other"; do
    mkdir -p "$home/data/$o"
    tasks_in "$home" add "$o" "Investigate $o" --kind scout --repo sample --start >/dev/null \
      || fail "could not create the $o fixture"
    write_origin_meta "$home" "$o"
    printf 'done: report complete\n' > "$home/state/$o.status"
  done
  run_captain "$home" hold sample-other-call --title "Call for the second review" \
    --reason "captain must decide" --repo sample --origin "$other" >/dev/null \
    || fail "could not hold the call recorded for the second review"
  if run_captain "$home" complete "$id" sample-other-call > "$home/mismatch.out" 2> "$home/mismatch.err"; then
    fail "complete accepted an entry held for a different origin"
  fi
  assert_grep "was held for origin $other, not $id" "$home/mismatch.err" \
    "the refusal does not name both origins"
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "the refused completion recorded an inventory attestation"

  run_captain "$home" hold sample-own-call --title "Call for the first review" \
    --reason "captain must decide" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the call recorded for the first review"
  out=$(run_captain "$home" complete "$id" sample-own-call) \
    || fail "complete refused an entry held for its own origin"
  assert_not_contains "$out" "no recorded origin" \
    "an entry with a recorded origin was flagged as unrecorded"

  tasks_in "$home" add sample-old-call "Call held before origins were recorded" --kind captain --repo sample >/dev/null \
    || fail "could not create the older call"
  tasks_in "$home" hold sample-old-call --reason "captain must decide" --kind captain >/dev/null \
    || fail "could not hold the older call"
  out=$(run_captain "$home" complete "$other" sample-old-call) \
    || fail "complete refused an older hold with no recorded origin"
  assert_contains "$out" "no recorded origin on: sample-old-call" \
    "an older hold with no recorded origin was not flagged"
  pass "complete refuses an entry held for another origin and flags one with none recorded"
}

hold_origin_cell() {  # <phase> <timing>
  local home phase timing failure id shown origin until_args=()
  phase=$1 timing=$2
  home=$(make_home "origin-failure-$phase-$timing")
  id=sample-call
  for origin in origin-a origin-b; do
    tasks_in "$home" add "$origin" "Review $origin" --kind scout --repo sample >/dev/null \
      || fail "could not create $origin"
    write_origin_meta "$home" "$origin"
  done
  if [ "$phase" != new ]; then
    run_captain "$home" hold "$id" --title "Separate call" --reason "Choose for A" \
      --origin origin-a >/dev/null || fail "could not establish the original association"
  fi
  if [ "$phase" = released ]; then
    printf 'Release this work.\n' > "$home/answer.txt"
    run_captain "$home" answer "$id" --release --decision-file "$home/answer.txt" >/dev/null \
      || fail "could not release the original hold"
  fi
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = origin-b ] && [ -f "$FM_HOME/fail-lookup" ]; then
  : > "$FM_HOME/lookup-refused"
  printf 'error: origin read failed\ncode: READ_FAILED\n' >&2
  exit 2
fi
if [ "${1:-}" = update ] && [ -f "$FM_HOME/fail-write" ]; then
  previous=''
  for arg in "$@"; do
if [ "$previous" = --body-file ] && grep -qx 'Captain hold origin: origin-b' "$arg"; then
  : > "$FM_HOME/write-refused"
  exit 9
fi
previous=$arg
  done
fi
if [ "${1:-}" = hold ] && [ "${2:-}" != --help ]; then
  "$REAL_TASKS_AXI" show "$2" --full > "$FM_HOME/before-backend-hold" || exit $?
  if [ -f "$FM_HOME/fail-hold" ]; then
: > "$FM_HOME/hold-refused"
exit 9
  fi
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  until_args=()
  [ "$timing" != dated ] || until_args=(--until 2099-01-01)
  for failure in lookup write hold; do
    : > "$home/fail-$failure"
    if run_captain "$home" hold "$id" --title "Separate call" --reason "Choose for B" \
      --origin origin-b ${until_args[@]+"${until_args[@]}"} > "$home/hold.out" 2> "$home/hold.err"; then
      fail "$phase $timing hold succeeded despite an origin $failure failure"
    fi
    assert_present "$home/$failure-refused" "the failure did not reach the origin $failure"
    if [ "$failure" = hold ]; then
      assert_present "$home/before-backend-hold" "$phase $timing failure never reached the backend hold"
      assert_grep 'Captain hold origin: origin-b' "$home/before-backend-hold" \
        "the failed backend hold did not see the new association"
      rm "$home/before-backend-hold"
    else
      assert_absent "$home/before-backend-hold" "$phase $timing origin $failure failure reached the backend hold"
    fi
    shown=$(tasks_in "$home" show "$id" --full)
    assert_not_contains "$shown" 'Captain hold origin: origin-b' \
      "$phase $timing origin $failure failure published the new association"
    if [ "$phase" = active ]; then
      assert_contains "$shown" 'held: yes' "an origin $failure failure lifted an existing hold"
    else
      assert_contains "$shown" 'held: no' "$phase $timing origin $failure failure left the task held"
    fi
    if [ "$phase" != new ]; then
      assert_contains "$shown" 'Captain hold origin: origin-a' \
        "$phase $timing origin $failure failure lost the original association"
    fi
    rm "$home/fail-$failure"
    if [ "$phase" = new ] && run_captain "$home" complete origin-a "$id" \
      > "$home/unrelated.out" 2> "$home/unrelated.err"; then
      fail "$timing origin $failure failure satisfied an unrelated inventory"
    fi
    if run_captain "$home" complete origin-b "$id" > "$home/complete.out" 2> "$home/complete.err"; then
      fail "$phase $timing origin $failure failure satisfied completion for B"
    fi
    printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$id" >> "$home/state/origin-b.meta"
    if run_captain "$home" verify origin-b > "$home/verify.out" 2> "$home/verify.err"; then
      fail "$phase $timing origin $failure failure verified an inventory for B"
    fi
    if [ "$phase" != new ]; then
      run_captain "$home" complete origin-a "$id" >/dev/null \
        || fail "$phase $timing origin $failure failure invalidated completion for A"
      run_captain "$home" verify origin-a >/dev/null \
        || fail "$phase $timing origin $failure failure invalidated verification for A"
    fi
  done
  run_captain "$home" hold "$id" --reason "Choose for B" --origin origin-b \
    ${until_args[@]+"${until_args[@]}"} >/dev/null || fail "$phase $timing successful retry failed"
  assert_present "$home/before-backend-hold" "the successful retry did not reach the backend hold"
  shown=$(cat "$home/before-backend-hold")
  assert_contains "$shown" 'Captain hold origin: origin-b' "the backend hold ran before the new origin was recorded"
  assert_not_contains "$shown" 'Captain hold origin: origin-a' "the backend hold ran with the old association"
  shown=$(tasks_in "$home" show "$id" --full)
  assert_contains "$shown" 'held: yes' "the successful retry did not hold the task"
  assert_contains "$shown" 'Captain hold origin: origin-b' "a successful hold lost its association"
  assert_not_contains "$shown" 'Captain hold origin: origin-a' "a successful hold retained the old association"
  run_captain "$home" complete origin-b "$id" >/dev/null \
    || fail "a successful hold could not complete B"
  run_captain "$home" verify origin-b >/dev/null || fail "a successful hold could not verify B"
  if run_captain "$home" complete origin-a "$id" >/dev/null 2> "$home/old-origin.err"; then
    fail "a successful reassociation still certified A"
  fi
}

test_hold_origins_precede_backend_holds() {
  run_cells_in_parallel "hold origins precede backend holds" \
    "hold_origin_cell new plain" \
    "hold_origin_cell new dated" \
    "hold_origin_cell active plain" \
    "hold_origin_cell active dated" \
    "hold_origin_cell released plain" \
    "hold_origin_cell released dated"
  pass "new, active, and released holds require the origin first with and without deferral"
}

test_historical_self_inventory_has_workable_repair() {
  local home origin=sample-review keep=retained-call replacement=repair-call meta before out
  home=$(make_home historical-self-inventory)
  run_captain "$home" hold "$origin" --title "Old review call" --reason "Choose" >/dev/null \
    || fail "could not create the historical origin"
  write_origin_meta "$home" "$origin"
  for out in "$keep" "$replacement"; do
    run_captain "$home" hold "$out" --title "Call $out" --reason "Choose" --origin "$origin" >/dev/null \
      || fail "could not create $out"
  done
  meta="$home/state/$origin.meta"
  printf 'decisions_reviewed=1\ndecision_keys=%s,%s\n' "$origin" "$keep" >> "$meta"
  before=$(cat "$meta")
  for out in "$replacement" --none; do
    if run_captain "$home" complete "$origin" "$out" > "$home/complete.out" 2> "$home/complete.err"; then
      fail "complete accepted the historical self-inventory"
    fi
    assert_grep "historical decision_keys in $meta still contains $origin" "$home/complete.err" \
      "the historical refusal did not identify the persisted entry"
    assert_grep 'replace only' "$home/complete.err" "the refusal omitted the repair instruction"
  done
  if run_captain "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
    fail "verify accepted the historical self-inventory"
  fi
  assert_grep "historical decision_keys in $meta still contains $origin" "$home/verify.err" \
    "verify omitted the historical repair instruction"
  assert_equals "$before" "$(cat "$meta")" "refusing a historical inventory changed it"
  sed "s/^decision_keys=$origin,$keep$/decision_keys=$replacement,$keep/" "$meta" > "$meta.repaired"
  mv "$meta.repaired" "$meta"
  run_captain "$home" complete "$origin" "$replacement" >/dev/null \
    || fail "the documented historical repair did not allow completion"
  run_captain "$home" verify "$origin" >/dev/null || fail "the repaired inventory did not verify"
  assert_equals "decision_keys=$replacement,$keep" "$(grep '^decision_keys=' "$meta" | tail -1)" \
    "repair lost a sibling inventory entry"
  if run_captain "$home" complete "$origin" "$origin" >/dev/null 2> "$home/self.err"; then
    fail "repair allowed a new self-inventory"
  fi
  pass "historical self-inventories name a workable repair that preserves sibling entries"
}

test_inventory_compares_backend_identities() {
  local home origin entry shown before
  home=$(make_home backend-identities)
  run_captain "$home" hold fm-o --title "Origin" --reason "Choose" >/dev/null \
    || fail "could not create the canonical origin"
  tasks_in "$home" add fm-other "Other origin" --kind scout --repo sample >/dev/null \
    || fail "could not create the other origin"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = o ] && [ -f "$FM_HOME/fail-identity" ]; then
  printf 'error: origin read failed\ncode: READ_FAILED\n' >&2
  exit 2
fi
if [ "$#" -ge 2 ]; then
  case "$2" in
    o|call|other) set -- "$1" "fm-$2" "${@:3}" ;;
  esac
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  for origin in fm-o o; do
    for entry in fm-o o; do
      write_origin_meta "$home" "$origin"
      if run_captain "$home" complete "$origin" "$entry" > "$home/self.out" 2> "$home/self.err"; then
        fail "complete accepted aliased self-inventory $origin/$entry"
      fi
      assert_grep 'cannot be its own captain-call inventory entry' "$home/self.err" \
        "the alias refusal did not identify self-inventory"
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$entry" >> "$home/state/$origin.meta"
      if run_captain "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
        fail "verify accepted aliased self-inventory $origin/$entry"
      fi
      assert_grep 'historical decision_keys' "$home/verify.err" "the alias repair diagnostic was missing"
    done
    write_origin_meta "$home" "$origin"
  done
  run_captain "$home" hold fm-call --title "Separate call" --reason "Choose" --origin o >/dev/null \
    || fail "could not hold a call using the origin alias"
  shown=$(tasks_in "$home" show fm-call --full)
  assert_contains "$shown" 'Captain hold origin: fm-o' "hold did not store the backend origin identity"
  printf '%s\n' "$shown" | sed -n 's/^  body: //p' | jq -r . \
    | sed 's/^Captain hold origin: fm-o$/Captain hold origin: o/' > "$home/legacy-origin.txt"
  tasks_in "$home" update fm-call --body-file "$home/legacy-origin.txt" >/dev/null \
    || fail "could not create a legacy stored alias"
  for origin in fm-o o; do
    for entry in fm-call call; do
      run_captain "$home" complete "$origin" "$entry" >/dev/null \
        || fail "complete refused equivalent origin spellings for $origin/$entry"
      run_captain "$home" verify "$origin" >/dev/null \
        || fail "verify refused equivalent origin spellings for $origin/$entry"
    done
  done
  for origin in fm-other other; do
    write_origin_meta "$home" "$origin"
    if run_captain "$home" complete "$origin" call > "$home/other.out" 2> "$home/other.err"; then
      fail "complete accepted another origin through $origin"
    fi
    assert_grep "was held for origin o, not $origin" "$home/other.err" "the alias mismatch was not identified"
    printf 'decisions_reviewed=1\ndecision_keys=call\n' >> "$home/state/$origin.meta"
    if run_captain "$home" verify "$origin" >/dev/null 2> "$home/other-verify.err"; then
      fail "verify accepted another origin through $origin"
    fi
  done
  : > "$home/fail-identity"
  before=$(cat "$home/state/o.meta")
  if run_captain "$home" complete o fm-call >/dev/null 2> "$home/read.err"; then
    fail "an unreadable backend identity was treated as an absent origin"
  fi
  assert_grep 'could not resolve the backend identity of o' "$home/read.err" "the identity read failure was hidden"
  assert_equals "$before" "$(cat "$home/state/o.meta")" "a failed identity read changed the inventory"
  rm "$home/fail-identity"
  write_origin_meta "$home" report-only
  run_captain "$home" hold report-call --title "Report call" --reason "Choose" --origin report-only >/dev/null \
    || fail "an origin with metadata but no backlog row could not record a call"
  run_captain "$home" complete report-only report-call >/dev/null \
    || fail "an origin with metadata but no backlog row could not complete"
  run_captain "$home" verify report-only >/dev/null \
    || fail "an origin with metadata but no backlog row could not verify"
  pass "completion and verification compare backend identities for entries and current or stored origins"
}

# tasks-axi refuses parentheses and line breaks in a hold reason and stores the
# rest on one markdown line. The reason is encoded where it is written and
# decoded wherever it is shown, so prose with every awkward character survives.
test_hold_reason_round_trips_awkward_characters() {
  local home id reason stored json shown start verb fields out raw rc raw_rc mode
  local title legacy body quoted_reason quoted_title quoted_legacy expected_reason until_args=()
  local malformed index=0 malformed_reasons=(
    'fm-hold-v1:/w==' 'fm-hold-v1:bm9ydGg=$' 'fm-hold-v1:bm9ydGg' 'fm-hold-v1:Zh=='
  )
  home=$(make_home reason-round-trip)
  title='Investigate literal %28, "fm-hold-v1:bm9ydGg="'
  legacy='Visit https://example.test/%28literal%29 and %0A; fm-hold-v1:bm9ydGg='
  body=$'fm-hold-v1:bm9ydGg=\n  hold_reason: "%28"\n'
  quoted_title=$(jq -cn --arg value "$title" '$value')
  quoted_legacy=$(jq -cn --arg value "$legacy" '$value')
  tasks_in "$home" add sample-legacy-call "$title" --kind captain --repo sample >/dev/null \
    || fail "could not create the legacy call"
  tasks_in "$home" hold sample-legacy-call --reason "$legacy" --kind captain >/dev/null \
    || fail "could not hold the legacy call"
  printf '%s' "$body" > "$home/legacy-body.txt"
  tasks_in "$home" update sample-legacy-call --body-file "$home/legacy-body.txt" >/dev/null \
    || fail "could not write the legacy body"

  # Historical literal reasons are persisted input, not encoder output.
  for malformed in "${malformed_reasons[@]}"; do
    id="sample-malformed-$index"
    index=$((index + 1))
    tasks_in "$home" add "$id" "Historical reason $index" --kind captain --repo sample >/dev/null \
      || fail "could not create $id"
    tasks_in "$home" hold "$id" --reason "$malformed" --kind captain >/dev/null \
      || fail "could not store the historical literal reason"
    for verb in show view; do
      out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$verb" "$id" --full) \
        || fail "public $verb failed on historical literal $malformed"
      raw=$(tasks_in "$home" "$verb" "$id" --full)
      assert_equals "$raw" "$out" "public $verb changed historical literal $malformed"
    done
  done

  for id in sample-reason-call sample-dated-call; do
    until_args=()
    reason=$'  Pick route (north); say "yes" or \'no\' - 100% sure %28x%29, café\t\\slash\r\nSecond line\n\n'
    if [ "$id" = sample-dated-call ]; then
      until_args=(--until 2099-01-01)
      reason='fm-hold-v1:bm9ydGg='
    fi
    quoted_reason=$(jq -cn --arg value "$reason" '$value')
    run_captain "$home" hold "$id" --title "$title" --reason "$reason" \
      --repo sample ${until_args[@]+"${until_args[@]}"} >/dev/null \
      || fail "hold refused the reason for $id"
    stored=$(grep "^- \[ \] $id " "$home/data/backlog.md") \
      || fail "the held row is not on one backlog line"
    assert_contains "$stored" "(hold: fm-hold-v1:" "the persisted reason has no encoding marker"
    assert_contains "$stored" "(hold-kind: captain)" "the reason broke the hold-kind tag"

    for verb in show view; do
      out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$verb" "$id") \
        || fail "public $verb failed for $id"
      shown=$(printf '%s\n' "$out" | sed -n 's/^  hold_reason: //p')
      printf '%s\n' "$shown" | jq -e --arg reason "$reason" '. == $reason' >/dev/null \
        || fail "public $verb changed the reason for $id"
      assert_contains "$out" "  title: $quoted_title" "public $verb changed the title"
    done
    for fields in hold_reason,body body,hold_reason,hold_until; do
      out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" list --fields "$fields") \
        || fail "public list failed with $fields"
      assert_contains "$out" "$quoted_reason" "public list changed the reason with $fields"
      assert_contains "$out" "$quoted_title" "public list changed the title with $fields"
      raw=$(tasks_in "$home" list --fields "$fields" | grep '^  sample-legacy-call,')
      shown=$(printf '%s\n' "$out" | grep '^  sample-legacy-call,')
      assert_equals "$raw" "$shown" "public list changed legacy or unrelated fields"
      for malformed in "${malformed_reasons[@]}"; do
        assert_contains "$out" "$malformed" "public list changed historical literal $malformed"
      done
    done
    json=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "fleet snapshot failed"
    printf '%s' "$json" | jq -e --arg id "$id" --arg reason "$reason" --arg title "$title" \
      '.backlog.records[] | select(.id == $id) | .hold_reason == $reason and .title == $title' >/dev/null \
      || fail "fleet changed the reason or title for $id"
    printf '%s' "$json" | jq -e --arg reason "$legacy" --arg title "$title" \
      '.backlog.records[] | select(.id == "sample-legacy-call") |
       .hold_reason == $reason and .title == $title and .body_lines[0] == "fm-hold-v1:bm9ydGg="' >/dev/null \
      || fail "fleet changed legacy or unrelated fields"
    for malformed in "${malformed_reasons[@]}"; do
      printf '%s' "$json" | jq -e --arg reason "$malformed" \
        'any(.backlog.records[]; .hold_reason == $reason)' >/dev/null \
        || fail "fleet changed historical literal $malformed"
    done
  done

  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show sample-legacy-call --full)
  raw=$(tasks_in "$home" show sample-legacy-call --full)
  assert_equals "$raw" "$out" "public show changed legacy or unrelated fields"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" list)
  raw=$(tasks_in "$home" list)
  assert_equals "$raw" "$out" "public list changed output with no reason column"
  for verb in show list; do
    out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" "$verb" --help)
    raw=$(tasks_in "$home" "$verb" --help)
    assert_equals "$raw" "$out" "public $verb changed help output"
  done
  out=$(FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" show nonexistent-call 2>&1)
  rc=$?
  raw=$(tasks_in "$home" show nonexistent-call 2>&1)
  raw_rc=$?
  [ "$raw_rc" -ne 0 ] || fail "the missing-task fixture unexpectedly exists"
  expect_code "$raw_rc" "$rc" "public show missing task"
  assert_equals "$raw" "$out" "public show changed a read error"

  expected_reason=$'  Pick route (north); say "yes" or \'no\' - 100% sure %28x%29, café\t\\slash\r\nSecond line\n\n'
  quoted_reason=$(jq -cn --arg value "$expected_reason" '$value')
  for mode in tool manual fallback; do
    case "$mode" in
      manual) printf 'manual\n' > "$home/config/backlog-backend" ;;
      fallback)
        rm "$home/config/backlog-backend"
        cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list ]; then
  printf 'read failed: literal %%28 and fm-hold-v1:bm9ydGg=\n' >&2
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
SH
        chmod +x "$home/fakebin/tasks-axi"
        ;;
    esac
    start=$(PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_BOOTSTRAP_NETWORK=skip "$ROOT/bin/fm-session-start.sh" 2>&1 || true)
    assert_contains "$start" "$quoted_reason" "startup $mode changed the encoded reason"
    assert_contains "$start" 'Investigate literal %28' "startup $mode changed the title"
    assert_contains "$start" "$legacy" "startup $mode changed the legacy reason"
    assert_contains "$start" '"fm-hold-v1:bm9ydGg="' "startup $mode decoded a reason twice"
    for malformed in "${malformed_reasons[@]}"; do
      assert_contains "$start" "$malformed" "startup $mode changed historical literal $malformed"
    done
    if [ "$mode" = fallback ]; then
      assert_contains "$start" 'read failed: literal %28 and fm-hold-v1:bm9ydGg=' \
        "startup changed unrelated error text"
    fi
  done
  rm "$home/fakebin/tasks-axi"
  out=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-afk-return.sh" check 2>&1 || true)
  assert_contains "$out" "$quoted_reason" "return brief changed the encoded reason"
  assert_contains "$out" "$quoted_title" "return brief changed the title"
  assert_contains "$out" "$quoted_legacy" "return brief changed the legacy reason"
  for malformed in "${malformed_reasons[@]}"; do
    assert_contains "$out" "$malformed" "return brief changed historical literal $malformed"
  done
  pass "marked hold reasons round-trip through public reads, fleet, startup, and return without changing other fields"
}

test_internal_retention_preserves_active_drop_provenance() (
  local home id stored before
  home=$(make_home retain-drop-provenance)
  id=retained-drop
  tasks_in "$home" add "$id" "retained captain disposition" --kind scout --start >/dev/null \
    || fail "could not create retained drop fixture"
  printf '%s\n' 'Body café 航海' 'dropped' 'Deliverable of the finished work: dropped' \
    'Question: which route?' > "$home/body.txt"
  tasks_in "$home" update "$id" --body-file "$home/body.txt" >/dev/null \
    || fail "could not attach retained body"
  tasks_in "$home" hold "$id" --kind captain --reason "which route?" >/dev/null \
    || fail "could not hold retained drop fixture"
  mkdir -p "$home/data/$id"
  printf 'Exact captain words café 航海\n' > "$home/data/$id/captain-drop.md"
  cp "$home/data/$id/captain-drop.md" "$home/words-before"
  . "$ROOT/bin/fm-tasks-axi-lib.sh"
  . "$ROOT/bin/fm-backlog-transition-lib.sh"
  before=$(cat "$home/data/backlog.md")
  fm_backlog_relaunch_admission "$home/config" "$home/data" scout "$id" 1 \
    || fail "read-only reconciliation admission failed: $FM_BACKLOG_TRANSITION_ERROR"
  assert_equals "$before" "$(cat "$home/data/backlog.md")" "read-only admission changed active provenance"
  fm_backlog_retain "$home/data" "$id" --note dropped \
    || fail "internal retain failed: $FM_BACKLOG_TRANSITION_ERROR"
  stored=$(tasks_in "$home" show "$id" --full) || fail "retained row disappeared"
  assert_contains "$stored" "state: queued" "internal retain did not reopen the row"
  assert_contains "$stored" "hold_kind: captain" "internal retain lost captain classification"
  assert_contains "$stored" "Deliverable of the finished work: dropped" "internal retain retired active deliverable"
  assert_not_contains "$stored" "Historical captain disposition:" "internal retain retired active disposition"
  assert_not_contains "$stored" "Historical deliverable of the finished work:" "internal retain retired active deliverable"
  assert_contains "$stored" "Body café 航海" "internal retain changed Unicode bytes"
  assert_contains "$stored" "Question: which route?" "internal retain changed the question"
  cmp -s "$home/words-before" "$home/data/$id/captain-drop.md" || fail "internal retain changed captain words"
  pass "internal retention and read-only admission preserve active captain drop classification"
)

# The resolution record carries the UTC time it was written and who answered,
# derived by the script; a replay of the same answer rewrites neither.
test_resolution_record_states_when_and_who_answered() {
  local home id show before after at
  home=$(make_home resolution-time)
  id=sample-time-call
  run_captain "$home" hold "$id" --title "Choose the time option" --reason "captain time choice pending" \
    --repo sample >/dev/null || fail "could not hold the call"
  printf 'Captain chose option two.\n' > "$home/decision.txt"
  before=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  run_captain "$home" answer "$id" --decision-file "$home/decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  after=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  show=$(tasks_in "$home" show "$id" --full)
  at=$(printf '%s\n' "$show" | grep -oE 'Resolved at: [0-9T:Z-]+' | head -1 | sed 's/^Resolved at: //')
  case "$at" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) fail "the record carries no UTC resolution time: $show" ;;
  esac
  [[ ! "$at" < "$before" && ! "$at" > "$after" ]] || fail "resolution time $at is outside $before .. $after"
  assert_contains "$show" "Resolution mode: answered" "the existing mode field changed"
  assert_contains "$show" "Decision digest: " "the existing digest field changed"
  assert_contains "$show" "Answered by: main" "a direct answer names no source, so the sending home's role answered it"

  sleep 1
  run_captain "$home" answer "$id" --decision-file "$home/decision.txt" >/dev/null \
    || fail "identical answer retry was not idempotent"
  assert_equals "$at" "$(tasks_in "$home" show "$id" --full | grep -oE 'Resolved at: [0-9T:Z-]+' | head -1 | sed 's/^Resolved at: //')" \
    "a replayed answer must keep the first resolution time"
  assert_equals 1 "$(tasks_in "$home" show "$id" --full | grep -c 'Resolved at: ')" "resolution times after a replay"
  pass "a captain-hold resolution records its UTC time and the answering home's role, and a replay changes neither"
}

# answered_by is read from the recorded source, never typed: two exact prefixes
# name a captured result or a firstmate send (this home's role); a direct answer
# with no recorded source also takes this home's role; anything else is unknown.
test_answered_by_is_derived_from_the_recorded_source() {
  local home id source want
  home=$(make_home answered-by)
  while IFS='|' read -r id source want; do
    run_captain "$home" hold "$id" --title "Call $id" --reason "captain choice pending" --repo sample >/dev/null \
      || fail "could not hold $id"
    printf '%s\tyes\t\n' "$id" | run_captain "$home" answers --any-origin --source "$source" >/dev/null \
      || fail "the keyed answer for $id was not accepted"
    assert_contains "$(tasks_in "$home" show "$id" --full)" "Answered by: $want" \
      "source '$source' should record answered_by $want"
  done <<'SOURCES'
call-page|the captured result some-task sequence 3|page
call-lavish|the captain's Lavish review page|unknown
call-board|a bearings board card|unknown
call-chat|the captain's chat message|unknown
call-policy|a standing policy|unknown
call-caps|The Captured Result some-task sequence 3|unknown
call-send-main|a firstmate answer sent to some-task|main
call-other|a carrier pigeon|unknown
SOURCES
  run_captain "$home" hold call-direct --title "Call direct" --reason "captain choice pending" --repo sample >/dev/null
  printf 'Captain chose.\n' > "$home/direct.txt"
  run_captain "$home" answer call-direct --decision-file "$home/direct.txt" >/dev/null
  assert_contains "$(tasks_in "$home" show call-direct --full)" "Answered by: main" "a direct answer should take the home's role"
  : > "$home/state/.afk"
  run_captain "$home" hold call-flag-only --title "Call flag" --reason "captain choice pending" --repo sample >/dev/null
  printf 'call-flag-only\tyes\t\n' | run_captain "$home" answers --any-origin --source "a firstmate answer sent to some-task" >/dev/null
  assert_contains "$(tasks_in "$home" show call-flag-only --full)" "Answered by: main" "the away daemon's flag file is not the away record"
  rm -f "$home/state/.afk"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null || fail "away entry failed"
  run_captain "$home" hold call-send-afk --title "Call afk" --reason "captain choice pending" --repo sample >/dev/null
  printf 'call-send-afk\tyes\t\n' | run_captain "$home" answers --any-origin --source "a firstmate answer sent to some-task" >/dev/null
  assert_contains "$(tasks_in "$home" show call-send-afk --full)" "Answered by: main-afk" "the away posture was not recorded"
  run_captain "$home" hold call-direct-afk --title "Call direct afk" --reason "captain choice pending" --repo sample >/dev/null
  run_captain "$home" answer call-direct-afk --decision-file "$home/direct.txt" >/dev/null
  assert_contains "$(tasks_in "$home" show call-direct-afk --full)" "Answered by: main-afk" "a direct answer should take the away role"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null || fail "away archive failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null || fail "quiet entry failed"
  run_captain "$home" hold call-send-quiet --title "Call quiet" --reason "captain choice pending" --repo sample >/dev/null
  printf 'call-send-quiet\tyes\t\n' | run_captain "$home" answers --any-origin --source "a firstmate answer sent to some-task" >/dev/null
  assert_contains "$(tasks_in "$home" show call-send-quiet --full)" "Answered by: main" "a quiet record is a present captain, not away"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null || fail "quiet archive failed"
  printf 'secondmate-id\n' > "$home/.fm-secondmate-home"
  run_captain "$home" hold call-send-mate --title "Call mate" --reason "captain choice pending" --repo sample >/dev/null 2>&1
  printf 'call-send-mate\tyes\t\n' | run_captain "$home" answers --any-origin --source "a firstmate answer sent to some-task" >/dev/null 2>&1
  assert_contains "$(tasks_in "$home" show call-send-mate --full)" "Answered by: secondmate" "a secondmate home was not recorded"
  pass "answered_by comes from two exact source prefixes or this home's role, and is unknown otherwise"
}

# Opt-in fleet ledger: a recorded answer appends one task.answered; a replay
# appends none; an unwritable ledger never changes the answer.
test_hold_answer_records_task_answered_in_the_ledger() {
  local home id rows rc=0
  home=$(make_home answer-ledger)
  id=sample-ledger-call
  : > "$home/config/fleet-ledger"
  run_captain "$home" hold "$id" --title "Ledger call" --reason "captain choice pending" --repo sample >/dev/null
  printf '%s\tyes\t\n' "$id" | run_captain "$home" answers --any-origin --source "the captured result sample-ledger-call sequence 1" >/dev/null \
    || fail "keyed answer failed with the ledger on"
  printf '%s\tyes\t\n' "$id" | run_captain "$home" answers --any-origin --source "the captured result sample-ledger-call sequence 1" >/dev/null \
    || fail "keyed answer replay failed with the ledger on"
  rows=$(jq -c 'select(.event == "task.answered") | [.task, .via, .key, .answered_by, (.at | test("Z$"))]' "$home/state/fleet-ledger.jsonl")
  assert_equals "[\"$id\",\"hold\",\"$id\",\"page\",true]" "$rows" "task.answered records after an answer and its replay"

  run_captain "$home" hold sample-failing-call --title "Failing ledger call" --reason "captain choice pending" --repo sample >/dev/null
  printf 'Captain chose.\n' > "$home/failing.txt"
  rm -f "$home/state/fleet-ledger.jsonl"
  mkdir "$home/state/fleet-ledger.jsonl"
  run_captain "$home" answer sample-failing-call --decision-file "$home/failing.txt" > "$home/failing.out" 2> "$home/failing.err" || rc=$?
  assert_equals 0 "$rc" "answer exit status with an unwritable ledger"
  assert_equals "answered: sample-failing-call" "$(cat "$home/failing.out")" "answer stdout with an unwritable ledger"
  assert_equals 1 "$(grep -c 'fm-fleet-ledger: could not record answered' "$home/failing.err")" "ledger failure lines on stderr"
  assert_contains "$(tasks_in "$home" show sample-failing-call --full)" "state: done" "the answer was not recorded when the ledger failed"
  pass "ledger on: a recorded answer appends one task.answered, a replay none, and an unwritable ledger costs one stderr line"
}

# Opt-in fleet ledger: every path that creates, answers, or reconciles a
# captain call is recorded once, with who answered it.
test_hold_ledger_records_creation_direct_answer_and_reconcile() {
  local home rows
  home=$(make_home hold-ledger-paths)
  : > "$home/config/fleet-ledger"
  run_captain "$home" hold made-call --title "Made call" --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not create and hold a call"
  run_captain "$home" hold made-call --title "Made call" --reason "captain choice pending" >/dev/null \
    || fail "could not hold the existing call again"
  tasks_in "$home" add existing-call "Existing call" --kind ship --repo sample >/dev/null || fail "could not add the existing item"
  run_captain "$home" hold existing-call --reason "captain choice pending" >/dev/null || fail "could not hold the existing item"

  printf 'Captain chose.\n' > "$home/direct.txt"
  run_captain "$home" answer made-call --decision-file "$home/direct.txt" >/dev/null || fail "direct answer failed"
  run_captain "$home" answer made-call --decision-file "$home/direct.txt" >/dev/null || fail "direct answer replay failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-contract.sh" enter >/dev/null || fail "away entry failed"
  run_captain "$home" hold away-call --title "Away call" --reason "captain choice pending" --repo sample >/dev/null
  run_captain "$home" answer away-call --decision-file "$home/direct.txt" >/dev/null || fail "direct answer under away failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null || fail "away archive failed"

  run_captain "$home" hold moot-call --title "Moot call" --reason "captain choice pending" --repo sample >/dev/null
  printf 'Nothing is pending. No captain answer was given.\n' > "$home/evidence.txt"
  run_captain "$home" reconcile close moot-call --evidence-file "$home/evidence.txt" --verified-outcome moot >/dev/null \
    || fail "reconcile close failed"
  run_captain "$home" reconcile close moot-call --evidence-file "$home/evidence.txt" --verified-outcome moot >/dev/null \
    || fail "reconcile close replay failed"
  assert_contains "$(tasks_in "$home" show moot-call --full)" "state: done" "the call was not closed by reconciliation"

  rows=$(jq -c '[.event, .task, (.repo // .via), (.kind // .key), .answered_by, .priority, (.at | test("Z$"))]' "$home/state/fleet-ledger.jsonl")
  assert_equals "$(printf '%s\n' \
    '["task.filed","made-call","sample","captain",null,null,true]' \
    '["task.answered","made-call","hold","made-call","main",null,true]' \
    '["task.filed","away-call","sample","captain",null,null,true]' \
    '["task.answered","away-call","hold","away-call","main-afk",null,true]' \
    '["task.filed","moot-call","sample","captain",null,null,true]' \
    '["task.answered","moot-call","hold","moot-call","unknown",null,true]')" "$rows" \
    "ledger records for a created call, direct answers, and a reconciliation"
  pass "ledger on: a created call, a direct answer, and a reconciliation each write one record; an existing item or a replay writes none"
}

tests=(
test_hold_reason_round_trips_awkward_characters
test_hold_origins_precede_backend_holds
test_historical_self_inventory_has_workable_repair
test_inventory_compares_backend_identities
test_origin_is_never_its_own_inventory_entry
test_complete_refuses_an_entry_held_for_another_origin
test_uninventoried_report_decision_refuses_completion
test_internal_retention_preserves_active_drop_provenance
test_hold_decodes_a_bare_scalar_body_without_the_nonref_default
test_retained_body_keeps_its_utf8_bytes
test_completion_gate_attests_and_transfers
test_answer_records_and_closes
test_release_frees_held_work
test_hold_stamp_precedes_hold_visibility
test_interrupted_answer_preserves_hold_age
test_deferral_leaves_captains_call_until_due
test_out_of_band_close_is_recordable
test_visual_review_uses_shared_completion_owner
test_none_inventory_and_resolved_prose_do_not_create_holds
test_terminal_single_owner_status_decision_does_not_block_empty_inventory
test_secondmate_hold_stays_in_authoritative_home
test_secondmate_home_publishes_holds_and_answers
test_secondmate_reconcile_publishes_before_request_retirement
test_resolution_record_states_when_and_who_answered
test_answered_by_is_derived_from_the_recorded_source
test_hold_answer_records_task_answered_in_the_ledger
test_hold_ledger_records_creation_direct_answer_and_reconcile
)
captain_hold_run_tests "$@"
