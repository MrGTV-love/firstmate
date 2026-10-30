#!/usr/bin/env bash
# Decision-owner regressions: a hold records who owns the decision it waits on,
# the parent firstmate's own calls close on its decision and never on the
# captain's words, a genuine captain call still closes only on the captain's
# words, and a hold that was never the captain's is released honestly through
# `withdraw`. Every case runs in a temp home.
# Shared definitions and fixture setup live in fm-captain-hold-lifecycle-helpers.sh.
set -u

# shellcheck source=tests/fm-captain-hold-lifecycle-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-lifecycle-helpers.sh"

# A hold-set stamp earlier than any ruling a test records afterwards, because a
# ruling must postdate the hold it withdraws and both stamps have whole seconds.
PAST_HOLD_SET=2026-01-01T00:00:00Z

# A secondmate home bound to a local parent, with a regular backlog.
make_mate_home() {  # <name>; prints the mate home, the parent is "<mate>-parent"
  local name=$1 parent mate
  parent=$(make_home "$name-parent")
  mate=$(make_home "$name")
  printf '%s\n' "$name-id" > "$mate/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
    > "$mate/.fm-secondmate-parent"
  printf '%s\n' "$mate"
}

# A request the parent firstmate relayed to the mate whose text says nothing
# about who decides, recorded by the real pending-reply library; prints a hold
# reason that carries the real correlation. A genuine captain call looks like this.
relayed_reason() {  # <mate-home> <reason> <request-text>
  local mate=$1 parent corr
  parent=$(sed -n 's/^parent_home=//p' "$mate/.fm-secondmate-parent")
  mkdir -p "$parent/state"
  corr=$(
    . "$ROOT/bin/fm-operational-input.sh"
    . "$ROOT/bin/fm-pending-reply-lib.sh"
    fm_pending_reply_create "$parent" "$parent/state" "$(cat "$mate/.fm-secondmate-home")" "$3"
  ) || fail "could not record the relayed request"
  printf '%s, relayed by the parent firstmate corr=%s' "$2" "$corr"
}

# The mate's parent channel, as the hold publishers resolve it.
mate_channel() {  # <mate-home>
  local mate=$1 parent
  parent=$(sed -n 's/^parent_home=//p' "$mate/.fm-secondmate-parent")
  printf '%s/state/%s.status\n' "$parent" "$(cat "$mate/.fm-secondmate-home")"
}

plain_channel() {  # <mate-home>: the channel with the time tags removed
  sed -E 's/ \[at=[0-9]+\]//' "$(mate_channel "$1")"
}

# Runs a command while the home has the main shape, as it had before owners
# were recorded, then restores the secondmate shape.
in_premate_home() {  # <mate-home> <command args...>
  local mate=$1 marker parent_route rc=0
  shift
  marker=$(cat "$mate/.fm-secondmate-home")
  parent_route=$(cat "$mate/.fm-secondmate-parent")
  rm -f "$mate/.fm-secondmate-home" "$mate/.fm-secondmate-parent"
  "$@" || rc=$?
  printf '%s\n' "$marker" > "$mate/.fm-secondmate-home"
  printf '%s\n' "$parent_route" > "$mate/.fm-secondmate-parent"
  return "$rc"
}

# A hold filed before owners were recorded: made in a main home, then the home
# takes on the secondmate shape, exactly as a live mate's older holds look.
make_legacy_mate_hold() {  # <mate-home> <task-id> <reason> [<channel-line>]
  local mate=$1 id=$2 reason=$3 channel_line=${4-}
  tasks_in "$mate" add "$id" "Legacy gated work $id" --kind ship --repo sample --body 'Gated work plan.' >/dev/null \
    || fail "could not create $id"
  FM_CAPTAIN_HOLD_NOW=$PAST_HOLD_SET in_premate_home "$mate" run_captain "$mate" hold "$id" --reason "$reason" >/dev/null \
    || fail "could not file the legacy hold on $id"
  [ -z "$channel_line" ] || printf '%s\n' "$channel_line" >> "$(mate_channel "$mate")"
}

# A question-shaped legacy hold: a captain-kind row that `hold --title` created
# before owners were recorded, with no work item behind it.
make_legacy_mate_question() {  # <mate-home> <task-id> <reason>
  in_premate_home "$1" run_captain "$1" hold "$2" --title "Legacy question $2" --reason "$3" --repo sample >/dev/null \
    || fail "could not file the legacy question $2"
}

# A hold whose record names the parent as its owner from filing: an external
# hold with `Decision owner: parent` beneath its hold-set stamp. `hold` never
# files one, so the fixture writes that record over an existing hold.
record_parent_owner() {  # <mate-home> <task-id>
  local until
  until=$(tasks_in "$1" show "$2" --full | sed -n 's/^  hold_until: //p' | tr -d '"')
  [ "$until" != - ] || until=
  FM_ID=$2 perl -0pi -e 's/^(- \[.\] \Q$ENV{FM_ID}\E - [^\n]*\n  Captain hold set: [^\n]*\n)/$1  Decision owner: parent\n/m' \
    "$1/data/backlog.md" || fail "could not record the parent as owner of $2"
  tasks_in "$1" hold "$2" --kind external --reason "the main firstmate decides" ${until:+--until "$until"} >/dev/null \
    || fail "could not hold $2 for the parent"
  assert_contains "$(tasks_in "$1" show "$2" --full)" "Decision owner: parent" "the fixture did not record the parent as owner of $2"
}

# The row as every reader shows it: the stored hold reason is encoded and each
# reader decodes it through the one library.
shown() {  # <home> <task-id>
  tasks_in "$1" show "$2" --full | (. "$ROOT/bin/fm-hold-reason-lib.sh"; fm_hold_reason_decode_stream)
}

open_status() {  # <home> <task-id> [<open flags>]; prints the exit code
  local home=$1 id=$2 rc=0
  shift 2
  run_captain "$home" open "$id" --distinguish-absent "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

test_a_mate_home_must_declare_who_owns_each_hold() {
  local mate main out rc=0
  mate=$(make_mate_home owner-required)
  tasks_in "$mate" add gated-work "Gated work" --kind ship --repo sample >/dev/null
  # The helper declares an owner for a mate hold, so call the script directly.
  out=$(PATH="$mate/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$mate" \
    FM_STATE_OVERRIDE="$mate/state" FM_DATA_OVERRIDE="$mate/data" FM_CONFIG_OVERRIDE="$mate/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold gated-work --reason "retry or fix the red check" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a secondmate hold with no owner was accepted"
  assert_contains "$out" "--owner is required in a secondmate home" "the refusal did not name the missing owner"
  assert_contains "$(tasks_in "$mate" show gated-work --full)" "held: no" "the refused hold still held the task"

  rc=0
  run_captain "$mate" hold gated-work --reason "bad owner" --owner main >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "an unknown owner was accepted"

  # A call the main firstmate owns is never held: the refusal names the routing.
  rc=0
  out=$(run_captain "$mate" hold gated-work --reason "retry the red check once" --owner parent 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a secondmate home held a call the main firstmate owns"
  assert_contains "$out" "never held: route it to Main as a needs-decision status line" \
    "the refusal did not name the routing to Main"
  assert_contains "$(tasks_in "$mate" show gated-work --full)" "held: no" "the refused parent hold still held the task"

  main=$(make_home owner-main)
  tasks_in "$main" add main-work "Main work" --kind ship --repo sample >/dev/null
  rc=0
  out=$(run_captain "$main" hold main-work --reason "no parent here" --owner parent 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a main home accepted a parent-owned hold"
  assert_contains "$out" "has no parent firstmate" "the main-home refusal did not say there is no parent"
  run_captain "$main" hold main-work --reason "captain choice" >/dev/null \
    || fail "a main home hold with no owner flag must keep working"
  [ "$(open_status "$main" main-work)" = 0 ] || fail "the main-home hold is not an open captain call"
  pass "a secondmate home must declare each captain hold's owner, never holds the parent's call, and a main home cannot name a parent"
}

test_a_parent_owned_call_closes_on_the_parents_decision() {
  local mate channel decision show out
  mate=$(make_mate_home parent-owned)
  channel=$(mate_channel "$mate")
  decision="$mate/parent-decision.txt"
  make_legacy_mate_hold "$mate" gated-work "retry the red check once or fix it"
  record_parent_owner "$mate" gated-work

  show=$(tasks_in "$mate" show gated-work --full)
  assert_contains "$show" "hold_kind: external" "a parent-owned call must not be a captain-kind hold"
  assert_contains "$show" "Decision owner: parent" "the owner was not recorded"
  [ "$(open_status "$mate" gated-work)" = 1 ] || fail "a parent-owned call read as an open captain call"
  [ "$(open_status "$mate" gated-work --parent-owned)" = 0 ] || fail "the parent-owned predicate missed an open call"
  if run_captain "$mate" hold gated-work --reason "retry once" --owner parent >/dev/null 2>&1; then
    fail "hold re-filed a parent-owned call as a held parent decision"
  fi

  printf 'Captain words nobody gave.\n' > "$decision"
  if run_captain "$mate" answer gated-work --decision-file "$decision" --release >/dev/null 2>&1; then
    fail "the captain's answer path released a parent-owned call"
  fi
  assert_contains "$(tasks_in "$mate" show gated-work --full)" "held: yes" "the refused captain answer still released the call"

  printf 'Retry the failing check once, unchanged head.\n' > "$decision"
  out=$(run_captain "$mate" decide gated-work --decision-file "$decision") || fail "the parent decision was refused"
  assert_equals "decided: gated-work" "$out" "decide did not report the decision"
  show=$(tasks_in "$mate" show gated-work --full)
  assert_contains "$show" "held: no" "the parent's decision did not release the hold"
  assert_not_contains "$show" "state: done" "the parent's decision completed the work item"
  assert_contains "$show" "Parent decision:" "the decision text was not recorded"
  assert_contains "$show" "Decided by: parent firstmate" "the decider was not recorded"
  assert_contains "$show" "Not a captain answer." "the record did not say it is not a captain answer"
  assert_not_contains "$show" "Captain decision:" "the parent's decision was written as the captain's words"
  assert_not_contains "$show" "Answered by:" "the parent's decision was labelled as an answer"
  assert_contains "$(plain_channel "$mate")" \
    "resolved [key=captain-hold-gated-work-1]: parent decision gated-work: decided by the parent firstmate" \
    "the decision did not close the parent channel key"
  [ "$(open_status "$mate" gated-work --parent-owned)" = 1 ] || fail "a decided call still reads as open"

  run_captain "$mate" decide gated-work --decision-file "$decision" >/dev/null \
    || fail "an exact replay of the parent decision failed"
  [ "$(grep -c 'resolved \[key=captain-hold-gated-work-1\]' "$channel")" = 1 ] \
    || fail "a replay duplicated the resolution: $(cat "$channel")"

  # A question-shaped row has no work item to resume, so the decision closes it.
  make_legacy_mate_question "$mate" retry-q "retry or fix one red check"
  record_parent_owner "$mate" retry-q
  out=$(run_captain "$mate" decide retry-q --decision-file "$decision") || fail "the parent decision on a question row was refused"
  assert_equals "decided: retry-q" "$out" "decide did not report the decision on the question row"
  show=$(tasks_in "$mate" show retry-q --full)
  assert_contains "$show" "state: done" "the parent's decision left a question-shaped row open"
  assert_contains "$show" "Parent decision:" "the decision text was not recorded on the question row"
  assert_not_contains "$show" "Captain decision:" "the question row's decision was written as the captain's words"
  assert_contains "$(plain_channel "$mate")" \
    "resolved [key=captain-hold-retry-q-1]: parent decision retry-q: decided by the parent firstmate" \
    "the decision did not close the question row's channel key"
  run_captain "$mate" decide retry-q --decision-file "$decision" >/dev/null \
    || fail "an exact replay of the decision on a closed question row failed"
  [ "$(grep -c 'resolved \[key=captain-hold-retry-q-1\]' "$channel")" = 1 ] \
    || fail "a replay on the closed question row duplicated the resolution: $(cat "$channel")"
  pass "a parent-owned call resolves on the parent's decision, never on captain words: a work item stays open and a question row closes"
}

test_a_captain_owned_call_is_not_closed_by_the_parents_decision() {
  local mate decision show
  mate=$(make_mate_home captain-owned)
  decision="$mate/parent-decision.txt"
  printf 'The parent decides this one.\n' > "$decision"
  tasks_in "$mate" add gated-work "Gated work" --kind ship --repo sample --body 'Gated work plan.' >/dev/null
  run_captain "$mate" hold gated-work --owner captain --reason "needs the captain's own word" >/dev/null \
    || fail "captain-owned hold failed"
  assert_contains "$(tasks_in "$mate" show gated-work --full)" "hold_kind: captain" "a captain call lost its kind"
  if run_captain "$mate" decide gated-work --decision-file "$decision" 2>"$mate/decide.err" >/dev/null; then
    fail "the parent's decision released a captain-owned call"
  fi
  assert_contains "$(cat "$mate/decide.err")" "not waiting on the parent firstmate" "the refusal did not say whose call it is"
  show=$(tasks_in "$mate" show gated-work --full)
  assert_contains "$show" "held: yes" "the refused decision still released the call"
  [ "$(open_status "$mate" gated-work)" = 0 ] || fail "the captain call stopped reading as open"
  if run_captain "$mate" hold gated-work --owner parent --reason "move it to the parent" >/dev/null 2>&1; then
    fail "an open captain call was re-filed as the parent's"
  fi
  assert_contains "$(tasks_in "$mate" show gated-work --full)" "hold_kind: captain" "the refused re-file changed the kind"

  # An ownerless legacy hold in a main home is the captain's, so decide refuses it too.
  local main
  main=$(make_home captain-owned-main)
  tasks_in "$main" add main-work "Main work" --kind ship --repo sample >/dev/null
  run_captain "$main" hold main-work --reason "captain choice" >/dev/null
  if run_captain "$main" decide main-work --decision-file "$decision" >/dev/null 2>&1; then
    fail "decide released a main-home captain call"
  fi
  pass "a captain-owned call is not closed by the parent's decision"
}

test_the_merge_gate_reads_each_owner_without_confusing_them() {
  local mate decision
  mate=$(make_mate_home merge-gate)
  decision="$mate/parent-decision.txt"
  printf 'Retry once.\n' > "$decision"
  make_legacy_mate_hold "$mate" parent-work "parent call"
  record_parent_owner "$mate" parent-work
  tasks_in "$mate" add captain-work "Captain work" --kind ship --repo sample >/dev/null
  run_captain "$mate" hold captain-work --owner captain --reason "captain call" >/dev/null
  [ "$(open_status "$mate" parent-work)" = 1 ] || fail "the captain predicate counted the parent's call"
  [ "$(open_status "$mate" captain-work --parent-owned)" = 1 ] || fail "the parent predicate counted a captain call"
  [ "$(open_status "$mate" captain-work)" = 0 ] || fail "the captain predicate missed the captain call"
  [ "$(open_status "$mate" absent-work --parent-owned)" = 3 ] || fail "an absent task did not read as absent"
  run_captain "$mate" decide parent-work --decision-file "$decision" >/dev/null || fail "decide failed"
  [ "$(open_status "$mate" captain-work)" = 0 ] || fail "deciding the parent's call released the captain's"
  pass "the open predicates tell the parent's call from the captain's"
}

test_withdraw_releases_a_moot_call_on_a_recorded_captain_ruling() {
  local home decision evidence show bearings
  home=$(make_home withdraw-ruling)
  decision="$home/ruling.txt"
  evidence="$home/evidence.txt"
  tasks_in "$home" add moot-work "Moot work" --kind ship --repo sample --body 'Gated work plan.' >/dev/null
  FM_CAPTAIN_HOLD_NOW=$PAST_HOLD_SET run_captain "$home" hold moot-work --reason "moot-premise-choice pending" >/dev/null || fail "hold failed"
  FM_CAPTAIN_HOLD_NOW=$PAST_HOLD_SET run_captain "$home" hold moot-q --title "Which error bound" --reason "pick the bound" --repo sample >/dev/null \
    || fail "could not file the question-shaped call"
  printf 'Ruling A: use the demand map; moot-work and moot-q are moot.\n' > "$decision"
  run_captain "$home" hold ruling-a --title "Ruling A" --reason "choose the approach" --repo sample >/dev/null
  run_captain "$home" answer ruling-a --decision-file "$decision" >/dev/null || fail "could not record the ruling"
  printf 'Main decided after ruling A: the mechanism call is moot.\n' > "$evidence"

  if run_captain "$home" withdraw moot-work --evidence-file "$evidence" >/dev/null 2>&1; then
    fail "withdraw accepted no basis"
  fi
  if run_captain "$home" withdraw moot-work --evidence-file "$evidence" --ruling absent-ruling >/dev/null 2>&1; then
    fail "withdraw accepted a ruling that does not exist"
  fi
  if run_captain "$home" withdraw moot-work --evidence-file "$evidence" --ruling moot-work >/dev/null 2>&1; then
    fail "withdraw accepted a hold as its own ruling"
  fi
  if run_captain "$home" withdraw moot-work --ruling ruling-a >/dev/null 2>&1; then
    fail "withdraw accepted no evidence file"
  fi
  if run_captain "$home" withdraw moot-work --evidence-file "$evidence" --ruling ruling-a --parent-routed >/dev/null 2>&1; then
    fail "withdraw accepted a parent-routed basis"
  fi
  assert_contains "$(tasks_in "$home" show moot-work --full)" "held: yes" "a refused withdrawal released the call"

  tasks_in "$home" add open-ruling "Open work" --kind ship --repo sample >/dev/null
  if run_captain "$home" withdraw moot-work --evidence-file "$evidence" --ruling open-ruling >/dev/null 2>&1; then
    fail "withdraw accepted an open task as a captain ruling"
  fi

  # A separate call filed with --origin moot-work carries the task only in its
  # origin lines; the captain never ruled on moot-work's own question.
  printf 'Pick option B.\n' > "$home/origin-answer.txt"
  run_captain "$home" hold origin-q --title "Which option" --reason "pick one" --repo sample --origin moot-work >/dev/null \
    || fail "could not file the origin-only call"
  run_captain "$home" answer origin-q --decision-file "$home/origin-answer.txt" >/dev/null || fail "could not answer the origin-only call"
  assert_contains "$(tasks_in "$home" show origin-q --full)" "Origin: moot-work" "the fixture call does not carry the origin line"
  if run_captain "$home" withdraw moot-work --evidence-file "$evidence" --ruling origin-q 2>"$home/refusal.err" >/dev/null; then
    fail "withdraw accepted a ruling that names the task only by its origin"
  fi
  assert_contains "$(cat "$home/refusal.err")" "does not name moot-work" "the origin-only refusal did not say what was missing"

  run_captain "$home" withdraw moot-work --evidence-file "$evidence" --ruling ruling-a >/dev/null \
    || fail "a withdrawal on a recorded captain ruling failed"
  show=$(tasks_in "$home" show moot-work --full)
  assert_contains "$show" "held: no" "the withdrawal did not release the hold"
  assert_not_contains "$show" "state: done" "the withdrawal completed the work item"
  assert_contains "$show" "Resolution mode: withdrawn" "the record did not say it was a withdrawal"
  assert_contains "$show" "Withdrawn by: moot under the recorded captain ruling ruling-a" "the basis was not recorded"
  assert_contains "$show" "Withdrawal evidence:" "the evidence was not recorded"
  assert_contains "$show" "Main decided after ruling A" "the evidence text was not recorded"
  assert_contains "$show" "Not a captain answer." "the record did not say it is not a captain answer"
  assert_not_contains "$show" "Answered by:" "the withdrawal was labelled as an answer"
  assert_not_contains "$show" "Captain decision: Main decided" "the evidence was written as the captain's words"
  [ "$(open_status "$home" moot-work)" = 1 ] || fail "the withdrawn call still reads as an open captain call"
  assert_contains "$(tasks_in "$home" ready)" "moot-work" "the withdrawn work item is not queued and dispatchable"

  # A question-shaped row has no work item to resume, so the withdrawal closes it.
  run_captain "$home" withdraw moot-q --evidence-file "$evidence" --ruling ruling-a >/dev/null \
    || fail "a withdrawal of a question-shaped call failed"
  show=$(tasks_in "$home" show moot-q --full)
  assert_contains "$show" "state: done" "the withdrawal left a question-shaped row open"
  assert_contains "$show" "Resolution mode: withdrawn" "the closed question row lost its withdrawal record"
  assert_not_contains "$show" "Answered by:" "the closed question row was labelled as an answer"
  assert_not_contains "$(tasks_in "$home" ready)" "moot-q" "the withdrawn question became dispatchable work"
  [ "$(open_status "$home" moot-q)" = 1 ] || fail "the withdrawn question still reads as an open captain call"
  assert_equals "withdrawn: moot-q" "$(run_captain "$home" withdraw moot-q --evidence-file "$evidence" --ruling ruling-a)" \
    "an exact replay on the closed question row failed"
  [ "$(tasks_in "$home" show moot-q --full | grep -o 'Resolution mode: withdrawn' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the replay on the closed question row wrote a second record"

  bearings=$(run_bearings "$home") || fail "bearings failed"
  assert_not_contains "$bearings" "moot-premise-choice pending" "Bearings still shows the withdrawn call as the captain's"

  # The lifecycle stays intact: the same work can be held again, as a new occurrence.
  run_captain "$home" hold moot-work --reason "a genuinely new captain choice" >/dev/null \
    || fail "re-holding withdrawn work failed"
  [ "$(open_status "$home" moot-work)" = 0 ] || fail "a re-held withdrawn task is not an open captain call"
  if run_captain "$home" withdraw moot-work --evidence-file "$evidence" --ruling ruling-a 2>"$home/refusal.err" >/dev/null; then
    fail "withdraw reused a ruling an earlier withdrawal cited to release a new hold"
  fi
  assert_contains "$(cat "$home/refusal.err")" "not after this hold was set" "the reuse refusal did not name the hold occurrence"
  [ "$(open_status "$home" moot-work)" = 0 ] || fail "the refused reuse released the new captain call"
  printf 'Go.\n' > "$decision"
  run_captain "$home" answer moot-work --decision-file "$decision" --release >/dev/null \
    || fail "the captain's answer on a re-held withdrawn task failed"
  pass "withdraw releases a moot call on a recorded captain ruling, keeps a work item open, and closes a question row"
}

test_withdraw_never_releases_a_genuine_captain_call() {
  local mate main evidence channel
  mate=$(make_mate_home withdraw-refusals)
  channel=$(mate_channel "$mate")
  evidence="$mate/evidence.txt"
  printf 'Main decided this was its own call.\n' > "$evidence"

  # Delivery to the parent channel proves nothing about whose call it is: a mate
  # reaches the captain only through that channel. The channel line is present
  # here and still releases nothing, for a recorded and for a legacy hold alike.
  tasks_in "$mate" add recorded-work "Recorded work" --kind ship --repo sample >/dev/null
  run_captain "$mate" hold recorded-work --owner captain --reason "needs the captain" >/dev/null
  make_legacy_mate_hold "$mate" legacy-work "land-or-drop of 18 unpublished commits" \
    'needs-decision [key=captain-hold-legacy-work-1]: captain hold legacy-work: land-or-drop of 18 unpublished commits'
  grep -q 'captain-hold-recorded-work-1' "$channel" || fail "the recorded hold did not reach the channel"
  grep -q 'captain-hold-legacy-work-1' "$channel" || fail "the legacy hold did not reach the channel"
  for id in recorded-work legacy-work; do
    if run_captain "$mate" withdraw "$id" --evidence-file "$evidence" 2>"$mate/refusal.err" >/dev/null; then
      fail "withdraw released $id with no ruling"
    fi
    assert_contains "$(cat "$mate/refusal.err")" "needs a recorded basis" "the refusal for $id did not name the missing basis"
    if run_captain "$mate" withdraw "$id" --evidence-file "$evidence" --parent-routed >/dev/null 2>&1; then
      fail "a parent-routed basis still exists and released $id"
    fi
    if run_captain "$mate" withdraw "$id" --evidence-file "$evidence" --ruling absent-ruling >/dev/null 2>&1; then
      fail "withdraw released $id on a ruling that does not exist"
    fi
    assert_contains "$(tasks_in "$mate" show "$id" --full)" "held: yes" "a refused withdrawal released $id"
    [ "$(open_status "$mate" "$id")" = 0 ] || fail "$id stopped reading as an open captain call"
  done

  # A main home has no parent, so a ruling is its only basis too.
  main=$(make_home withdraw-main)
  tasks_in "$main" add main-work "Main work" --kind ship --repo sample >/dev/null
  run_captain "$main" hold main-work --reason "captain choice" >/dev/null
  printf 'Main decided this was its own call.\n' > "$main/evidence.txt"
  if run_captain "$main" withdraw main-work --evidence-file "$main/evidence.txt" >/dev/null 2>&1; then
    fail "withdraw released a main-home captain call with no ruling"
  fi

  # A record that is not the captain's own words is not a ruling.
  tasks_in "$main" add reconciled-ruling "Reconciled" --kind ship --repo sample >/dev/null
  run_captain "$main" hold reconciled-ruling --reason "moot already" >/dev/null
  printf 'Verified moot.\n' > "$main/reconcile.txt"
  run_captain "$main" reconcile close reconciled-ruling --evidence-file "$main/reconcile.txt" --verified-outcome moot >/dev/null 2>&1 \
    || true
  if run_captain "$main" withdraw main-work --evidence-file "$main/evidence.txt" --ruling reconciled-ruling >/dev/null 2>&1; then
    fail "withdraw accepted an evidence-only close as a captain ruling"
  fi
  assert_contains "$(tasks_in "$main" show main-work --full)" "held: yes" "the refused withdrawal released the call"
  pass "withdraw refuses a captain call with no captain ruling, whatever the channel carried, and a non-captain ruling"
}

test_withdraw_releases_a_legacy_mate_hold_on_a_captain_ruling() {
  local mate evidence decision show
  mate=$(make_mate_home withdraw-legacy)
  evidence="$mate/evidence.txt"
  decision="$mate/ruling.txt"
  printf 'The captain ruled A; legacy-work is moot.\n' > "$evidence"
  printf 'Ruling A: use the demand map.\n' > "$decision"
  run_captain "$mate" hold ruling-a --title "Ruling A" --reason "choose the approach" --repo sample --owner captain >/dev/null
  run_captain "$mate" answer ruling-a --decision-file "$decision" >/dev/null || fail "could not record the ruling"
  make_legacy_mate_hold "$mate" legacy-work "retry or fix one red CI check"
  [ "$(open_status "$mate" legacy-work)" = 0 ] || fail "the legacy hold is not an open captain call"

  # A ruling whose own records never name the hold does not make it moot, even
  # when the evidence written at withdraw time names it.
  if run_captain "$mate" withdraw legacy-work --evidence-file "$evidence" --ruling ruling-a 2>"$mate/refusal.err" >/dev/null; then
    fail "withdraw released a hold on an unrelated captain ruling"
  fi
  assert_contains "$(cat "$mate/refusal.err")" "does not name legacy-work in its title, its hold reason, or its recorded captain answer" \
    "the refusal did not say what the ruling was missing"
  assert_contains "$(tasks_in "$mate" show legacy-work --full)" "held: yes" "the refused withdrawal released the hold"
  [ "$(open_status "$mate" legacy-work)" = 0 ] || fail "the refused withdrawal changed the open captain call"

  # A ruling whose recorded question names the hold makes it moot.
  printf 'Fix it; the retry is moot.\n' > "$decision"
  run_captain "$mate" hold ruling-c --title "Retry or fix for legacy-work" --reason "choose" --repo sample --owner captain >/dev/null
  run_captain "$mate" answer ruling-c --decision-file "$decision" >/dev/null || fail "could not record the naming ruling"
  run_captain "$mate" withdraw legacy-work --evidence-file "$evidence" --ruling ruling-c >/dev/null \
    || fail "withdraw refused a legacy hold named by a recorded ruling"
  show=$(tasks_in "$mate" show legacy-work --full)
  assert_contains "$show" "held: no" "the withdrawal did not release the hold"
  assert_not_contains "$show" "state: done" "the withdrawal completed the work item"
  assert_contains "$show" "Withdrawn by: moot under the recorded captain ruling ruling-c" "the basis was not recorded"
  assert_contains "$show" "Filed owner: unrecorded" "the filed owner was not recorded"
  assert_contains "$show" "Run from: secondmate home" "the home role was not derived and recorded"
  assert_contains "$show" "Not a captain answer." "the record did not say it is not a captain answer"
  assert_not_contains "$show" "Captain decision: The captain ruled" "the evidence was written as the captain's words"
  assert_contains "$(plain_channel "$mate")" "resolved [key=captain-hold-legacy-work-1]: captain hold legacy-work: withdrawn, not a captain answer" \
    "the withdrawal did not close the parent channel key"
  [ "$(open_status "$mate" legacy-work)" = 1 ] || fail "the withdrawn legacy hold still reads as open"
  pass "withdraw refuses an unrelated ruling and releases a legacy mate hold on a ruling that names it, keeping the work open"
}

test_the_divergence_guard_stops_reporting_a_withdrawn_call() {
  local mate evidence decision out
  mate=$(make_mate_home divergence)
  evidence="$mate/evidence.txt"
  decision="$mate/ruling.txt"
  printf 'Moot under the ruling.\n' > "$evidence"
  printf 'Ruling B.\n' > "$decision"
  make_legacy_mate_hold "$mate" diverged-work "retry"
  run_captain "$mate" hold ruling-b --title "Ruling B" --reason "choose; settles diverged-work" --repo sample --owner captain >/dev/null
  run_captain "$mate" answer ruling-b --decision-file "$decision" >/dev/null || fail "could not record the ruling"
  # The status log of the task reads resolved while the hold is still open: the
  # divergence shape the guard reports.
  printf 'needs-decision [key=diverged-work]: retry\nresolved [key=diverged-work]: main decided\n' > "$mate/state/divergence-origin.status"
  out=$(run_captain "$mate" diverged) || fail "diverged failed"
  assert_contains "$out" "diverged-work" "the divergence guard missed the open captain hold"
  run_captain "$mate" withdraw diverged-work --evidence-file "$evidence" --ruling ruling-b >/dev/null \
    || fail "withdraw failed"
  out=$(run_captain "$mate" diverged) || fail "diverged failed after the withdrawal"
  assert_not_contains "$out" "diverged-work" "the divergence guard still reports a withdrawn call"
  pass "the divergence guard stops reporting a call once it is withdrawn"
}

test_the_decision_hold_shim_refuses_a_secondmate_hold_with_no_owner() {
  local mate main out rc=0 show
  mate=$(make_mate_home shim-mate)
  tasks_in "$mate" add shim-origin "Shim origin" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" shim-origin
  out=$(run_shim "$mate" hold shim-origin pick --title "Pick one" --reason "captain pick pending" --repo sample 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the shim filed a secondmate hold with no owner"
  assert_contains "$out" "--owner is required in a secondmate home" "the shim refusal did not name the missing owner"
  if tasks_in "$mate" show shim-origin-decision-pick >/dev/null 2>&1; then
    fail "the refused shim hold still created a task"
  fi

  run_shim "$mate" hold shim-origin pick --title "Pick one" --reason "captain pick pending" --repo sample --owner captain >/dev/null \
    || fail "the shim hold failed in a secondmate home"
  show=$(tasks_in "$mate" show shim-origin-decision-pick --full)
  assert_contains "$show" "hold_kind: captain" "the shim hold is not a captain call"
  assert_contains "$show" "Decision owner: captain" "the shim did not keep the caller's captain owner"

  # A call the main firstmate owns is never held, through the shim either.
  if run_shim "$mate" hold shim-origin parent-pick --title "Parent pick" --reason "parent pick pending" --repo sample --owner parent >/dev/null 2>&1; then
    fail "the shim held a call the main firstmate owns"
  fi

  # A main home is left alone: no owner line is added.
  main=$(make_home shim-main)
  tasks_in "$main" add shim-origin "Shim origin" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$main" shim-origin
  run_shim "$main" hold shim-origin pick --title "Pick one" --reason "captain pick pending" --repo sample >/dev/null \
    || fail "the shim hold failed in a main home"
  assert_not_contains "$(tasks_in "$main" show shim-origin-decision-pick --full)" "Decision owner:" \
    "the shim added an owner line in a main home"
  pass "the decision-hold shim refuses an ownerless or parent-owned secondmate hold, keeps the captain owner, and leaves a main home alone"
}

# A hold filed before owners were recorded cannot prove the decision was the
# parent's, so it stays the captain's: the parent's decide refuses it, including
# a genuine captain call the parent relayed with its request on record and the
# PR 290 shape whose reason names a decision reserved to Main.
test_a_legacy_mate_hold_stays_the_captains_without_a_ruling() {
  local mate decision show id
  mate=$(make_mate_home legacy-stays)
  decision="$mate/decision.txt"
  printf 'Retry once, unchanged head.\n' > "$decision"
  make_legacy_mate_hold "$mate" unproven-work "retry or fix one red CI check"
  make_legacy_mate_hold "$mate" reserved-work "retry or fix one red CI check; Main180/181 reserve ask-user decisions to Main"
  make_legacy_mate_hold "$mate" relayed-captain-call "$(relayed_reason "$mate" \
    "land or drop 18 unpublished commits" \
    "Relay to the captain: land-or-drop of 18 unpublished commits is the captain's call; do not decide it as Main.")"
  for id in unproven-work reserved-work relayed-captain-call; do
    if run_captain "$mate" decide "$id" --decision-file "$decision" 2>"$mate/refusal.err" >/dev/null; then
      fail "decide released the captain's legacy hold $id without a captain ruling"
    fi
    assert_contains "$(cat "$mate/refusal.err")" "not waiting on the parent firstmate (recorded owner: unrecorded)" \
      "the refusal for $id did not say the hold is not the parent's"
    show=$(tasks_in "$mate" show "$id" --full)
    assert_contains "$show" "held: yes" "the refused decision released $id"
    assert_contains "$show" "hold_kind: captain" "the refused decision changed the kind of $id"
    assert_not_contains "$show" "Decision owner:" "the refused decision recorded an owner on $id"
    assert_not_contains "$show" "Parent decision:" "the refused decision was recorded on $id"
    [ "$(open_status "$mate" "$id")" = 0 ] || fail "$id stopped reading as an open captain call"
    [ "$(open_status "$mate" "$id" --parent-owned)" != 0 ] || fail "$id reads as the parent's open call"
  done
  pass "a legacy mate hold, including a genuine captain call the parent relayed, stays the captain's and decide refuses it"
}

test_a_parent_owned_hold_leaves_the_captain_surface_and_the_captain_can_take_it_back() {
  local mate decision out show
  mate=$(make_mate_home parent-readers)
  decision="$mate/captain-answer.txt"
  printf 'Go.\n' > "$decision"
  make_legacy_mate_hold "$mate" parent-work "parent-readers-reason pending"
  record_parent_owner "$mate" parent-work

  # Bearings does not list it as the captain's call.
  out=$(run_bearings "$mate") || fail "bearings failed"
  assert_not_contains "$out" "parent-readers-reason pending" "Bearings shows the parent-owned hold as the captain's call"
  # The return brief lists held rows with their kind, so the owner stays visible there.
  out=$(tasks_in "$mate" list --state held --fields hold_kind,hold_reason 2>&1 \
    | (. "$ROOT/bin/fm-hold-reason-lib.sh"; fm_hold_reason_decode_stream)) || true
  assert_contains "$out" "external" "the held listing does not show the parent-owned hold's kind"
  # The divergence check does not treat it as a captain call.
  printf 'needs-decision [key=parent-work]: retry\nresolved [key=parent-work]: main decided\n' > "$mate/state/readers-origin.status"
  out=$(run_captain "$mate" diverged) || fail "diverged failed"
  assert_not_contains "$out" "parent-work" "the divergence check reports a parent-owned hold as a captain call"

  # The captain takes it back by re-holding it as his.
  run_captain "$mate" hold parent-work --owner captain --reason "the captain wants this one" >/dev/null \
    || fail "the captain could not take the hold back by re-holding"
  show=$(tasks_in "$mate" show parent-work --full)
  assert_contains "$show" "hold_kind: captain" "the re-hold did not restore the captain hold"
  assert_contains "$show" "Decision owner: captain" "the re-hold did not record the captain as owner"
  assert_not_contains "$show" "Decision owner: parent" "the parent owner is still on the record"
  [ "$(open_status "$mate" parent-work)" = 0 ] || fail "the re-held hold is not an open captain call"
  if run_captain "$mate" decide parent-work --decision-file "$decision" >/dev/null 2>&1; then
    fail "the parent's decision released a hold the captain took back"
  fi

  # A legacy hold that is the captain's is marked so by re-holding it.
  make_legacy_mate_hold "$mate" kept-work "kept-captain-reason pending"
  run_captain "$mate" hold kept-work --owner captain --reason "this really is the captain's" >/dev/null \
    || fail "re-holding a legacy hold as the captain's failed"
  show=$(shown "$mate" kept-work)
  assert_contains "$show" "hold_kind: captain" "re-holding as the captain's changed the kind"
  assert_contains "$show" "Decision owner: captain" "re-holding did not record the captain as owner"
  assert_contains "$show" "this really is the captain's" "the hold reason does not show the re-hold reason"
  [ "$(open_status "$mate" kept-work)" = 0 ] || fail "a hold re-held as the captain's is not an open captain call"
  pass "a parent-owned hold leaves the captain's call surface, and the captain can take it back"
}

# The lifecycle readers and the completion gate know the parent's decision and
# the withdrawal: cleanup keeps a row whose parent decision is open, a scout's
# inventory accepts both records as durable, and a withdrawal retires the
# board's reconcile request for the call it released.
test_lifecycle_readers_and_the_gate_know_parent_and_withdrawn_records() {
  local mate evidence decision list
  mate=$(make_mate_home lifecycle-readers)
  evidence="$mate/evidence.txt"
  decision="$mate/decision.txt"
  printf 'Moot under the ruling.\n' > "$evidence"
  printf 'Retry once.\n' > "$decision"
  tasks_in "$mate" add scout-a "Scout A" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" scout-a
  make_legacy_mate_hold "$mate" legacy-p "retry or fix one red check"
  record_parent_owner "$mate" legacy-p
  [ "$(open_status "$mate" legacy-p --any-owner)" = 0 ] || fail "the any-owner predicate missed an open parent decision"
  [ "$(open_status "$mate" legacy-p)" = 1 ] || fail "the captain predicate counted the parent's decision"
  make_legacy_mate_hold "$mate" legacy-w "pick the mechanism"
  [ "$(open_status "$mate" legacy-w --any-owner)" = 0 ] || fail "the any-owner predicate missed an open captain call"
  request_reconciles "$mate" lifecycle-board legacy-w || fail "could not record the board reconcile request"
  assert_contains "$(run_captain "$mate" reconcile list)" "legacy-w" "the board reconcile request was not recorded"

  run_captain "$mate" complete scout-a legacy-p legacy-w >/dev/null \
    || fail "the completion gate refused an open parent decision"
  run_captain "$mate" decide legacy-p --decision-file "$decision" >/dev/null || fail "decide failed"
  [ "$(open_status "$mate" legacy-p --any-owner)" = 1 ] || fail "a decided call still reads as an open held decision"
  run_captain "$mate" hold ruling-w --title "The mechanism for legacy-w" --reason "choose" --repo sample >/dev/null
  run_captain "$mate" answer ruling-w --decision-file "$decision" >/dev/null || fail "could not record the ruling"
  run_captain "$mate" withdraw legacy-w --evidence-file "$evidence" --ruling ruling-w >/dev/null || fail "withdraw failed"
  list=$(run_captain "$mate" reconcile list) || fail "could not list the reconcile requests"
  assert_not_contains "$list" "legacy-w" "the withdrawal left the board reconcile request for a released call"
  run_captain "$mate" verify scout-a >/dev/null \
    || fail "the completion gate refused a parent decision or a withdrawal as durable"
  pass "the lifecycle readers and the completion gate know parent decisions and withdrawals, and a withdrawal retires its reconcile request"
}

# Makes the next `tasks-axi <subcommand>` in <home> fail once, so a command
# stops after writing its record and the retry must finish it.
fail_tasks_axi_once() {  # <home> <subcommand>
  local real
  real=$(command -v tasks-axi)
  cat > "$1/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "$2" ] && [ ! -e "$1/tasks-axi-failed-once" ]; then
  : > "$1/tasks-axi-failed-once"
  echo "injected $2 failure" >&2
  exit 1
fi
exec "$real" "\$@"
EOF
  chmod +x "$1/fakebin/tasks-axi"
  rm -f "$1/tasks-axi-failed-once"
}

test_a_retried_decide_or_withdraw_finishes_without_a_second_record() {
  local mate home channel decision evidence show
  mate=$(make_mate_home retry-decide)
  channel=$(mate_channel "$mate")
  decision="$mate/decision.txt"
  printf 'Retry once.\n' > "$decision"
  make_legacy_mate_hold "$mate" retry-work "retry or fix one red check"
  record_parent_owner "$mate" retry-work
  fail_tasks_axi_once "$mate" unhold
  if run_captain "$mate" decide retry-work --decision-file "$decision" >/dev/null 2>&1; then
    fail "the injected unhold failure did not stop decide"
  fi
  assert_contains "$(tasks_in "$mate" show retry-work --full)" "held: yes" "the failed decide released the hold"
  run_captain "$mate" decide retry-work --decision-file "$decision" >/dev/null || fail "the retried decide failed"
  show=$(tasks_in "$mate" show retry-work --full)
  assert_contains "$show" "held: no" "the retried decide did not release the hold"
  [ "$(printf '%s' "$show" | grep -o 'Resolution mode: decided' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the retried decide wrote a second record"
  [ "$(grep -c 'resolved \[key=captain-hold-retry-work-1\]' "$channel")" = 1 ] \
    || fail "the retried decide did not resolve key 1 once: $(cat "$channel")"
  ! grep -q 'captain-hold-retry-work-2' "$channel" || fail "the retried decide published a second key"

  home=$(make_home retry-withdraw)
  evidence="$home/evidence.txt"
  printf 'Moot under the ruling.\n' > "$evidence"
  printf 'retry-moot is moot.\n' > "$home/ruling.txt"
  tasks_in "$home" add retry-moot "Retry moot" --kind ship --repo sample >/dev/null
  FM_CAPTAIN_HOLD_NOW=$PAST_HOLD_SET run_captain "$home" hold retry-moot --reason "pick one" >/dev/null || fail "hold failed"
  run_captain "$home" hold ruling-r --title "Ruling R" --reason "choose" --repo sample >/dev/null
  run_captain "$home" answer ruling-r --decision-file "$home/ruling.txt" >/dev/null || fail "could not record the ruling"
  fail_tasks_axi_once "$home" unhold
  if run_captain "$home" withdraw retry-moot --evidence-file "$evidence" --ruling ruling-r >/dev/null 2>&1; then
    fail "the injected unhold failure did not stop withdraw"
  fi
  assert_contains "$(tasks_in "$home" show retry-moot --full)" "held: yes" "the failed withdraw released the hold"
  run_captain "$home" withdraw retry-moot --evidence-file "$evidence" --ruling ruling-r >/dev/null \
    || fail "the retried withdraw failed"
  show=$(tasks_in "$home" show retry-moot --full)
  assert_contains "$show" "held: no" "the retried withdraw did not release the hold"
  [ "$(printf '%s' "$show" | grep -o 'Resolution mode: withdrawn' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the retried withdraw wrote a second record"
  pass "a decide or withdraw retried after a failed release finishes it without a second record or key"
}

# Retention archives a question row the parent's decision closed; the gate still
# accepts it and lists it apart from the captain's answered calls.
test_the_gate_accepts_an_archived_parent_decision() {
  local mate decision out
  mate=$(make_mate_home archived-parent)
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
    'archive = "data/done-archive.md"' 'done_keep = 1' > "$mate/.tasks.toml"
  decision="$mate/decision.txt"
  printf 'Retry once.\n' > "$decision"
  tasks_in "$mate" add scout-b "Scout B" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" scout-b
  make_legacy_mate_question "$mate" q-arch "retry or fix one red check"
  record_parent_owner "$mate" q-arch
  run_captain "$mate" complete scout-b q-arch >/dev/null || fail "the gate refused an open parent decision"
  run_captain "$mate" decide q-arch --decision-file "$decision" >/dev/null || fail "decide failed"
  tasks_in "$mate" add filler-b "Filler" --kind captain --repo sample >/dev/null
  tasks_in "$mate" "done" filler-b >/dev/null || fail "could not close the retention filler"
  grep -q '^- \[x\] q-arch ' "$mate/data/done-archive.md" || fail "retention did not archive the decided row"
  out=$(run_captain "$mate" complete scout-b q-arch) || fail "the gate refused an archived parent decision"
  assert_contains "$out" "[decided by the parent or withdrawn, not a captain answer, and archived: q-arch]" \
    "the archived parent decision was not listed under its own label"
  assert_not_contains "$out" "answered and archived" "the archived parent decision was listed as an answered call"
  run_captain "$mate" verify scout-b >/dev/null || fail "verify refused an archived parent decision"
  pass "the completion gate accepts an archived parent decision and never lists it as an answer"
}

# Teardown keeps a finished work item open while the parent's decision on it is
# open, recording its deliverable. That decision then closes the finished row,
# as an answer does, and never returns it to the dispatchable queue; unfinished
# work under the same decision is only released.
test_decide_closes_finished_work_teardown_retained() {
  local mate parent decision id show
  mate=$(make_mate_home retained-decide)
  decision="$mate/decision.txt"
  printf 'Retry once, unchanged head.\n' > "$decision"
  id=retained-scout
  mkdir -p "$mate/data/$id"
  tasks_in "$mate" add "$id" "Retained scout" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the finished work item"
  write_origin_meta "$mate" "$id"
  printf 'done: report complete\n' > "$mate/state/$id.status"
  printf '# Retained scout\n\nMain decides the retry.\n' > "$mate/data/$id/report.md"
  FM_CAPTAIN_HOLD_NOW=$PAST_HOLD_SET in_premate_home "$mate" run_captain "$mate" hold "$id" \
    --reason "retry or fix one red check" >/dev/null \
    || fail "could not file the legacy hold on the finished work item"
  record_parent_owner "$mate" "$id"
  complete_through_sibling "$mate" "$id" >/dev/null || fail "the completion gate refused the finished work item"
  # The parent registers the mate, as it does before any child is torn down.
  parent=$(sed -n 's/^parent_home=//p' "$mate/.fm-secondmate-parent")
  printf -- '- retained-decide-id - synthetic scope (home: %s; scope: sample; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/retained-decide-id.meta" "$mate" "firstmate:fm-retained-decide-id" sample
  run_teardown "$mate" "$id" > "$mate/teardown.out" 2> "$mate/teardown.err" \
    || fail "teardown of the finished work item failed: $(cat "$mate/teardown.err")"
  show=$(tasks_in "$mate" show "$id" --full)
  assert_contains "$show" "state: queued" "teardown did not retain the finished row"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "teardown did not record the deliverable on the retained row"
  assert_absent "$mate/state/$id.meta" "teardown left the worker record behind"

  run_captain "$mate" decide "$id" --decision-file "$decision" >/dev/null || fail "decide refused the retained row"
  show=$(tasks_in "$mate" show "$id" --full)
  assert_contains "$show" "state: done" "decide returned finished work to the queue"
  assert_contains "$show" "data/$id/report.md" "decide closed the finished row without its deliverable"
  assert_contains "$show" "Parent decision:" "the decision text was not recorded on the retained row"
  assert_not_contains "$(tasks_in "$mate" ready)" "$id" "decide made finished work dispatchable"

  make_legacy_mate_hold "$mate" open-work "retry or fix one red check"
  record_parent_owner "$mate" open-work
  run_captain "$mate" decide open-work --decision-file "$decision" >/dev/null || fail "decide refused unfinished work"
  show=$(tasks_in "$mate" show open-work --full)
  assert_contains "$show" "held: no" "decide did not release unfinished work"
  assert_not_contains "$show" "state: done" "decide closed unfinished work"
  assert_contains "$(tasks_in "$mate" ready)" "open-work" "decide did not return unfinished work to the queue"
  pass "decide closes finished work teardown retained, with its deliverable, and only releases unfinished work"
}

# A dated hold whose date has passed reads `held: no` but still blocks every
# reader, so the release commands must still reach it; and a plain completion
# never closes a row while the parent's decision is open.
test_an_expired_dated_hold_still_releases_and_a_parent_hold_blocks_completion() {
  local mate home rc out
  mate=$(make_mate_home expired-dated)
  tasks_in "$mate" add dated-p "Dated parent" --kind ship --repo sample --body 'Gated work plan.' >/dev/null
  FM_CAPTAIN_HOLD_NOW=$PAST_HOLD_SET in_premate_home "$mate" run_captain "$mate" hold dated-p \
    --reason "retry or fix one red check" --until 2020-01-01 >/dev/null || fail "could not file the dated legacy hold"
  assert_contains "$(tasks_in "$mate" show dated-p --full)" "held: no" "the fixture hold did not expire"
  record_parent_owner "$mate" dated-p
  [ "$(open_status "$mate" dated-p --parent-owned)" = 0 ] || fail "an expired parent-owned hold stopped reading as open"
  rc=0
  out=$(PATH="$mate/fakebin:$PATH" FM_HOME="$mate" FM_STATE_OVERRIDE="$mate/state" FM_DATA_OVERRIDE="$mate/data" \
    FM_CONFIG_OVERRIDE="$mate/config" "$ROOT/bin/fm-tasks-axi.sh" "done" dated-p --note shipped 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a plain completion closed a row while the parent's decision was open"
  assert_contains "$out" "waiting on the parent firstmate's decision" "the completion refusal did not name the parent's decision"
  printf 'Retry once.\n' > "$mate/decision.txt"
  run_captain "$mate" decide dated-p --decision-file "$mate/decision.txt" >/dev/null \
    || fail "decide refused an expired parent-owned hold"
  [ "$(open_status "$mate" dated-p --parent-owned)" = 1 ] || fail "the decided expired hold still reads as open"

  home=$(make_home expired-withdraw)
  tasks_in "$home" add dated-c "Dated captain" --kind ship --repo sample >/dev/null
  FM_CAPTAIN_HOLD_NOW=$PAST_HOLD_SET run_captain "$home" hold dated-c --reason "pick later" --until 2020-01-01 >/dev/null \
    || fail "could not file the dated captain hold"
  [ "$(open_status "$home" dated-c)" = 0 ] || fail "an expired captain hold stopped reading as open"
  printf 'dated-c is moot.\n' > "$home/ruling.txt"
  printf 'Moot under the ruling.\n' > "$home/evidence.txt"
  run_captain "$home" hold ruling-d --title "Ruling D" --reason "choose" --repo sample >/dev/null
  run_captain "$home" answer ruling-d --decision-file "$home/ruling.txt" >/dev/null || fail "could not record the ruling"
  run_captain "$home" withdraw dated-c --evidence-file "$home/evidence.txt" --ruling ruling-d >/dev/null \
    || fail "withdraw refused an expired captain hold"
  [ "$(open_status "$home" dated-c)" = 1 ] || fail "the withdrawn expired hold still reads as open"
  pass "an expired dated hold is still decided or withdrawn, and a parent hold blocks a plain completion"
}

tests=(
test_a_mate_home_must_declare_who_owns_each_hold
test_a_parent_owned_call_closes_on_the_parents_decision
test_a_captain_owned_call_is_not_closed_by_the_parents_decision
test_the_merge_gate_reads_each_owner_without_confusing_them
test_withdraw_releases_a_moot_call_on_a_recorded_captain_ruling
test_withdraw_never_releases_a_genuine_captain_call
test_withdraw_releases_a_legacy_mate_hold_on_a_captain_ruling
test_the_divergence_guard_stops_reporting_a_withdrawn_call
test_the_decision_hold_shim_refuses_a_secondmate_hold_with_no_owner
test_a_legacy_mate_hold_stays_the_captains_without_a_ruling
test_a_parent_owned_hold_leaves_the_captain_surface_and_the_captain_can_take_it_back
test_lifecycle_readers_and_the_gate_know_parent_and_withdrawn_records
test_a_retried_decide_or_withdraw_finishes_without_a_second_record
test_the_gate_accepts_an_archived_parent_decision
test_decide_closes_finished_work_teardown_retained
test_an_expired_dated_hold_still_releases_and_a_parent_hold_blocks_completion
)
captain_hold_run_tests "$@"
