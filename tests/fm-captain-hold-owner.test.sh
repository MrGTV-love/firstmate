#!/usr/bin/env bash
# Decision-owner regressions: a hold records who owns the decision it waits on,
# a call the parent firstmate owns is never held, a genuine captain call still
# closes only on the captain's words, and a hold a recorded captain ruling made
# moot is released honestly through `withdraw`. Every case runs in a temp home.
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

test_an_open_captain_call_is_never_refiled_as_the_parents() {
  local mate
  mate=$(make_mate_home captain-owned)
  tasks_in "$mate" add gated-work "Gated work" --kind ship --repo sample --body 'Gated work plan.' >/dev/null
  run_captain "$mate" hold gated-work --owner captain --reason "needs the captain's own word" >/dev/null \
    || fail "captain-owned hold failed"
  assert_contains "$(tasks_in "$mate" show gated-work --full)" "hold_kind: captain" "a captain call lost its kind"
  if run_captain "$mate" hold gated-work --owner parent --reason "move it to the parent" >/dev/null 2>&1; then
    fail "an open captain call was re-filed as the parent's"
  fi
  assert_contains "$(tasks_in "$mate" show gated-work --full)" "Decision owner: captain" "the refused re-file changed the owner"
  assert_contains "$(tasks_in "$mate" show gated-work --full)" "held: yes" "the refused re-file released the call"
  [ "$(open_status "$mate" gated-work)" = 0 ] || fail "the captain call stopped reading as open"
  pass "an open captain call is never re-filed as the parent's"
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
# parent's, so it stays the captain's: nothing releases it without a ruling,
# including a genuine captain call the parent relayed with its request on record
# and the PR 290 shape whose reason names a decision reserved to Main.
test_a_legacy_mate_hold_stays_the_captains_without_a_ruling() {
  local mate evidence show id
  mate=$(make_mate_home legacy-stays)
  evidence="$mate/evidence.txt"
  printf 'Main decided one unchanged-head retry; no captain answer or ruling exists.\n' > "$evidence"
  make_legacy_mate_hold "$mate" unproven-work "retry or fix one red CI check"
  make_legacy_mate_hold "$mate" reserved-work "retry or fix one red CI check; Main180/181 reserve ask-user decisions to Main"
  make_legacy_mate_hold "$mate" relayed-captain-call "$(relayed_reason "$mate" \
    "land or drop 18 unpublished commits" \
    "Relay to the captain: land-or-drop of 18 unpublished commits is the captain's call; do not decide it as Main.")"
  for id in unproven-work reserved-work relayed-captain-call; do
    if run_captain "$mate" withdraw "$id" --evidence-file "$evidence" 2>"$mate/refusal.err" >/dev/null; then
      fail "withdraw released the captain's legacy hold $id without a captain ruling"
    fi
    assert_contains "$(cat "$mate/refusal.err")" "needs a recorded basis" "the refusal for $id did not name the missing ruling"
    show=$(tasks_in "$mate" show "$id" --full)
    assert_contains "$show" "held: yes" "the refused withdrawal released $id"
    assert_contains "$show" "hold_kind: captain" "the refused withdrawal changed the kind of $id"
    assert_not_contains "$show" "Decision owner:" "the refused withdrawal recorded an owner on $id"
    assert_not_contains "$show" "Resolution mode:" "the refused withdrawal wrote a record on $id"
    [ "$(open_status "$mate" "$id")" = 0 ] || fail "$id stopped reading as an open captain call"
  done
  pass "a legacy mate hold, including a genuine captain call the parent relayed, stays the captain's without a ruling"
}

# Recording the owner keeps the hold's header block whole: a legacy hold that
# freezes a project and is re-held as the captain's, with an origin as the shim
# always passes, still freezes it for `frozen` and the idle reaper, and its owner
# still reads as the captain.
test_recording_the_owner_keeps_a_freeze_in_force() {
  local mate out show
  mate=$(make_mate_home owner-freeze)
  printf 'window=w:in-scope\nkind=ship\nproject=%s/projects/vernant\n' "$mate" > "$mate/state/in-scope.meta"
  tasks_in "$mate" add scout-o "Scout O" --kind scout --repo sample --start >/dev/null
  make_legacy_mate_hold "$mate" frozen-work "freeze vernant until the captain decides"
  run_captain "$mate" freeze frozen-work --project vernant >/dev/null || fail "freeze failed"
  out=$(run_captain "$mate" frozen in-scope) || fail "the legacy hold did not freeze its project"
  assert_equals frozen-work "$out" "frozen did not name the legacy hold"

  run_captain "$mate" hold frozen-work --owner captain --origin scout-o --reason "the captain's own call" >/dev/null \
    || fail "re-holding the legacy hold as the captain's failed"
  show=$(tasks_in "$mate" show frozen-work --full)
  assert_contains "$show" "Decision owner: captain" "the re-hold did not record the captain as owner"
  out=$(run_captain "$mate" frozen in-scope) || fail "recording the owner lifted the freeze"
  assert_equals frozen-work "$out" "frozen stopped naming the hold after its owner was recorded"
  out=$(
    PATH="$mate/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_CONFIG_OVERRIDE="$mate/config"
    export PATH REAL_TASKS_AXI FM_CONFIG_OVERRIDE
    . "$ROOT/bin/fm-idle-reap-lib.sh"
    fm_idle_reap_frozen "$mate" "$mate/state" "$mate/data" in-scope || exit 1
    printf '%s %s' "$IDLE_REAP_CLASS" "$IDLE_REAP_DETAIL"
  ) || fail "the idle reaper no longer sees the freeze after the owner was recorded"
  assert_contains "$out" "parked frozen by captain hold frozen-work" "the idle reaper did not name the freezing hold"

  printf 'frozen-work is moot.\n' > "$mate/ruling.txt"
  printf 'Moot under the ruling.\n' > "$mate/evidence.txt"
  run_captain "$mate" hold ruling-f --title "Ruling F" --reason "choose" --repo sample >/dev/null
  run_captain "$mate" answer ruling-f --decision-file "$mate/ruling.txt" >/dev/null || fail "could not record the ruling"
  run_captain "$mate" withdraw frozen-work --evidence-file "$mate/evidence.txt" --ruling ruling-f >/dev/null \
    || fail "withdraw refused the re-held hold"
  assert_contains "$(tasks_in "$mate" show frozen-work --full)" "Filed owner: captain" \
    "the origin write moved the owner out of the header, so the withdrawal lost it"
  pass "recording the owner keeps a freeze in force for frozen and the idle reaper, and keeps the owner beside the origin"
}

# The lifecycle readers and the completion gate know the withdrawal: a scout's
# inventory accepts the record as durable, and a withdrawal retires the board's
# reconcile request for the call it released.
test_lifecycle_readers_and_the_gate_know_withdrawn_records() {
  local mate evidence decision list
  mate=$(make_mate_home lifecycle-readers)
  evidence="$mate/evidence.txt"
  decision="$mate/decision.txt"
  printf 'Moot under the ruling.\n' > "$evidence"
  printf 'Use the demand map.\n' > "$decision"
  tasks_in "$mate" add scout-a "Scout A" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" scout-a
  make_legacy_mate_hold "$mate" legacy-w "pick the mechanism"
  [ "$(open_status "$mate" legacy-w)" = 0 ] || fail "the open predicate missed an open captain call"
  request_reconciles "$mate" lifecycle-board legacy-w || fail "could not record the board reconcile request"
  assert_contains "$(run_captain "$mate" reconcile list)" "legacy-w" "the board reconcile request was not recorded"

  run_captain "$mate" complete scout-a legacy-w >/dev/null \
    || fail "the completion gate refused an open captain call"
  run_captain "$mate" hold ruling-w --title "The mechanism for legacy-w" --reason "choose" --repo sample >/dev/null
  run_captain "$mate" answer ruling-w --decision-file "$decision" >/dev/null || fail "could not record the ruling"
  run_captain "$mate" withdraw legacy-w --evidence-file "$evidence" --ruling ruling-w >/dev/null || fail "withdraw failed"
  list=$(run_captain "$mate" reconcile list) || fail "could not list the reconcile requests"
  assert_not_contains "$list" "legacy-w" "the withdrawal left the board reconcile request for a released call"
  run_captain "$mate" verify scout-a >/dev/null \
    || fail "the completion gate refused a withdrawal as durable"
  pass "the completion gate knows withdrawals, and a withdrawal retires its reconcile request"
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

test_a_retried_withdraw_finishes_without_a_second_record() {
  local home evidence show
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
  pass "a withdraw retried after a failed release finishes it without a second record"
}

# Retention archives a question row a withdrawal closed; the gate still accepts
# it and lists it apart from the captain's answered calls.
test_the_gate_accepts_an_archived_withdrawal() {
  local mate decision evidence out
  mate=$(make_mate_home archived-withdrawal)
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
    'archive = "data/done-archive.md"' 'done_keep = 1' > "$mate/.tasks.toml"
  decision="$mate/decision.txt"
  evidence="$mate/evidence.txt"
  printf 'Ruling: q-arch is moot.\n' > "$decision"
  printf 'Moot under the ruling.\n' > "$evidence"
  tasks_in "$mate" add scout-b "Scout B" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$mate" scout-b
  FM_CAPTAIN_HOLD_NOW=$PAST_HOLD_SET make_legacy_mate_question "$mate" q-arch "retry or fix one red check"
  run_captain "$mate" complete scout-b q-arch >/dev/null || fail "the gate refused an open captain call"
  run_captain "$mate" hold ruling-q --title "Ruling Q" --reason "choose" --repo sample >/dev/null
  run_captain "$mate" answer ruling-q --decision-file "$decision" >/dev/null || fail "could not record the ruling"
  run_captain "$mate" withdraw q-arch --evidence-file "$evidence" --ruling ruling-q >/dev/null || fail "withdraw failed"
  tasks_in "$mate" add filler-b "Filler" --kind captain --repo sample >/dev/null
  tasks_in "$mate" "done" filler-b >/dev/null || fail "could not close the retention filler"
  grep -q '^- \[x\] q-arch ' "$mate/data/done-archive.md" || fail "retention did not archive the withdrawn row"
  out=$(run_captain "$mate" complete scout-b q-arch) || fail "the gate refused an archived withdrawal"
  assert_contains "$out" "[withdrawn, not a captain answer, and archived: q-arch]" \
    "the archived withdrawal was not listed under its own label"
  assert_not_contains "$out" "answered and archived" "the archived withdrawal was listed as an answered call"
  run_captain "$mate" verify scout-b >/dev/null || fail "verify refused an archived withdrawal"
  pass "the completion gate accepts an archived withdrawal and never lists it as an answer"
}

# Teardown keeps a finished work item open while its captain call is open,
# recording its deliverable. A withdrawal then closes the finished row, as an
# answer does, and never returns it to the dispatchable queue; unfinished work
# under a withdrawal is only released.
test_withdraw_closes_finished_work_teardown_retained() {
  local mate parent decision evidence id show
  mate=$(make_mate_home retained-withdraw)
  decision="$mate/decision.txt"
  evidence="$mate/evidence.txt"
  printf 'Ruling: retained-scout and open-work are moot.\n' > "$decision"
  printf 'Moot under the ruling.\n' > "$evidence"
  id=retained-scout
  mkdir -p "$mate/data/$id"
  tasks_in "$mate" add "$id" "Retained scout" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the finished work item"
  write_origin_meta "$mate" "$id"
  printf 'done: report complete\n' > "$mate/state/$id.status"
  printf '# Retained scout\n\nThe ruling settles the retry.\n' > "$mate/data/$id/report.md"
  FM_CAPTAIN_HOLD_NOW=$PAST_HOLD_SET run_captain "$mate" hold "$id" --reason "retry or fix one red check" >/dev/null \
    || fail "could not hold the finished work item"
  complete_through_sibling "$mate" "$id" >/dev/null || fail "the completion gate refused the finished work item"
  # The parent registers the mate, as it does before any child is torn down.
  parent=$(sed -n 's/^parent_home=//p' "$mate/.fm-secondmate-parent")
  printf -- '- retained-withdraw-id - synthetic scope (home: %s; scope: sample; projects: sample; added 2026-07-14)\n' \
    "$mate" > "$parent/data/secondmates.md"
  fm_write_secondmate_meta "$parent/state/retained-withdraw-id.meta" "$mate" "firstmate:fm-retained-withdraw-id" sample
  run_teardown "$mate" "$id" > "$mate/teardown.out" 2> "$mate/teardown.err" \
    || fail "teardown of the finished work item failed: $(cat "$mate/teardown.err")"
  show=$(tasks_in "$mate" show "$id" --full)
  assert_contains "$show" "state: queued" "teardown did not retain the finished row"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "teardown did not record the deliverable on the retained row"
  assert_absent "$mate/state/$id.meta" "teardown left the worker record behind"

  make_legacy_mate_hold "$mate" open-work "retry or fix one red check"
  run_captain "$mate" hold ruling-r --title "Ruling R" --reason "choose" --repo sample >/dev/null
  run_captain "$mate" answer ruling-r --decision-file "$decision" >/dev/null || fail "could not record the ruling"

  run_captain "$mate" withdraw "$id" --evidence-file "$evidence" --ruling ruling-r >/dev/null \
    || fail "withdraw refused the retained row"
  show=$(tasks_in "$mate" show "$id" --full)
  assert_contains "$show" "state: done" "withdraw returned finished work to the queue"
  assert_contains "$show" "data/$id/report.md" "withdraw closed the finished row without its deliverable"
  assert_contains "$show" "Withdrawal evidence:" "the withdrawal was not recorded on the retained row"
  assert_not_contains "$(tasks_in "$mate" ready)" "$id" "withdraw made finished work dispatchable"

  run_captain "$mate" withdraw open-work --evidence-file "$evidence" --ruling ruling-r >/dev/null \
    || fail "withdraw refused unfinished work"
  show=$(tasks_in "$mate" show open-work --full)
  assert_contains "$show" "held: no" "withdraw did not release unfinished work"
  assert_not_contains "$show" "state: done" "withdraw closed unfinished work"
  assert_contains "$(tasks_in "$mate" ready)" "open-work" "withdraw did not return unfinished work to the queue"
  pass "withdraw closes finished work teardown retained, with its deliverable, and only releases unfinished work"
}

# A dated hold whose date has passed reads `held: no` but still blocks every
# reader, so the release command must still reach it.
test_an_expired_dated_hold_is_still_withdrawn() {
  local home
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
  pass "an expired dated hold is still withdrawn"
}

# A legacy hold-set stamp that records only a date cannot order a ruling made the
# same day, so only a ruling dated a later day releases it.
test_withdraw_needs_a_ruling_a_day_after_a_date_only_stamp() {
  local home today yesterday
  home=$(make_home date-only-stamp)
  today=$(date -u +%Y-%m-%d)
  yesterday=$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%d", gmtime(time - 86400))')
  tasks_in "$home" add dated-work "Dated work" --kind ship --repo sample >/dev/null
  FM_CAPTAIN_HOLD_NOW=$PAST_HOLD_SET run_captain "$home" hold dated-work --reason "pick one" >/dev/null || fail "hold failed"
  # The persisted legacy shape: a stamp written as a bare date, set today.
  perl -pi -e "s/^  Captain hold set: \Q$PAST_HOLD_SET\E\$/  Captain hold set: $today/" "$home/data/backlog.md"
  assert_contains "$(tasks_in "$home" show dated-work --full)" "Captain hold set: $today" "the fixture did not write a date-only stamp"
  printf 'dated-work is moot.\n' > "$home/ruling.txt"
  printf 'Moot under the ruling.\n' > "$home/evidence.txt"
  run_captain "$home" hold ruling-s --title "Ruling S" --reason "choose" --repo sample >/dev/null
  run_captain "$home" answer ruling-s --decision-file "$home/ruling.txt" >/dev/null || fail "could not record the ruling"
  if run_captain "$home" withdraw dated-work --evidence-file "$home/evidence.txt" --ruling ruling-s 2>"$home/refusal.err" >/dev/null; then
    fail "withdraw accepted a ruling recorded the same day as a date-only hold-set stamp"
  fi
  assert_contains "$(cat "$home/refusal.err")" "not after this hold was set at $today" "the refusal did not name the hold-set date"
  assert_contains "$(tasks_in "$home" show dated-work --full)" "held: yes" "the refused withdrawal released the call"

  perl -pi -e "s/^  Captain hold set: \Q$today\E\$/  Captain hold set: $yesterday/" "$home/data/backlog.md"
  run_captain "$home" withdraw dated-work --evidence-file "$home/evidence.txt" --ruling ruling-s >/dev/null \
    || fail "withdraw refused a ruling recorded a day after a date-only hold-set stamp"
  assert_contains "$(tasks_in "$home" show dated-work --full)" "held: no" "the withdrawal did not release the call"
  pass "withdraw needs a ruling dated a later day than a date-only hold-set stamp"
}

tests=(
test_a_mate_home_must_declare_who_owns_each_hold
test_an_open_captain_call_is_never_refiled_as_the_parents
test_withdraw_releases_a_moot_call_on_a_recorded_captain_ruling
test_withdraw_never_releases_a_genuine_captain_call
test_withdraw_releases_a_legacy_mate_hold_on_a_captain_ruling
test_the_divergence_guard_stops_reporting_a_withdrawn_call
test_the_decision_hold_shim_refuses_a_secondmate_hold_with_no_owner
test_a_legacy_mate_hold_stays_the_captains_without_a_ruling
test_recording_the_owner_keeps_a_freeze_in_force
test_lifecycle_readers_and_the_gate_know_withdrawn_records
test_a_retried_withdraw_finishes_without_a_second_record
test_the_gate_accepts_an_archived_withdrawal
test_withdraw_closes_finished_work_teardown_retained
test_an_expired_dated_hold_is_still_withdrawn
test_withdraw_needs_a_ruling_a_day_after_a_date_only_stamp
)
captain_hold_run_tests "$@"
