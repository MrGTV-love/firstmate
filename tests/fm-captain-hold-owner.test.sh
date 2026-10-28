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

# The mate's parent channel, as the hold publishers resolve it.
mate_channel() {  # <mate-home>
  local mate=$1 parent
  parent=$(sed -n 's/^parent_home=//p' "$mate/.fm-secondmate-parent")
  printf '%s/state/%s.status\n' "$parent" "$(cat "$mate/.fm-secondmate-home")"
}

plain_channel() {  # <mate-home>: the channel with the time tags removed
  sed -E 's/ \[at=[0-9]+\]//' "$(mate_channel "$1")"
}

# A hold filed before owners were recorded: made in a main home, then the home
# takes on the secondmate shape, exactly as a live mate's older holds look.
make_legacy_mate_hold() {  # <mate-home> <task-id> <reason> [<channel-line>]
  local mate=$1 id=$2 reason=$3 channel_line=${4-} marker parent_route
  marker=$(cat "$mate/.fm-secondmate-home")
  parent_route=$(cat "$mate/.fm-secondmate-parent")
  rm -f "$mate/.fm-secondmate-home" "$mate/.fm-secondmate-parent"
  tasks_in "$mate" add "$id" "Legacy gated work $id" --kind ship --repo sample --body 'Gated work plan.' >/dev/null \
    || fail "could not create $id"
  run_captain "$mate" hold "$id" --reason "$reason" >/dev/null \
    || fail "could not file the legacy hold on $id"
  printf '%s\n' "$marker" > "$mate/.fm-secondmate-home"
  printf '%s\n' "$parent_route" > "$mate/.fm-secondmate-parent"
  [ -z "$channel_line" ] || printf '%s\n' "$channel_line" >> "$(mate_channel "$mate")"
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

  main=$(make_home owner-main)
  tasks_in "$main" add main-work "Main work" --kind ship --repo sample >/dev/null
  rc=0
  out=$(run_captain "$main" hold main-work --reason "no parent here" --owner parent 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a main home accepted a parent-owned hold"
  assert_contains "$out" "has no parent firstmate" "the main-home refusal did not say there is no parent"
  run_captain "$main" hold main-work --reason "captain choice" >/dev/null \
    || fail "a main home hold with no owner flag must keep working"
  [ "$(open_status "$main" main-work)" = 0 ] || fail "the main-home hold is not an open captain call"
  pass "a secondmate home must declare each hold's owner and a main home cannot name a parent"
}

test_a_parent_owned_call_closes_on_the_parents_decision() {
  local mate channel decision show out
  mate=$(make_mate_home parent-owned)
  channel=$(mate_channel "$mate")
  decision="$mate/parent-decision.txt"
  tasks_in "$mate" add gated-work "Gated work" --kind ship --repo sample --body 'Gated work plan.' >/dev/null
  run_captain "$mate" hold gated-work --owner parent \
    --reason "retry the red check once or fix it" >/dev/null || fail "parent-owned hold failed"

  show=$(tasks_in "$mate" show gated-work --full)
  assert_contains "$show" "hold_kind: external" "a parent-owned call must not be a captain-kind hold"
  assert_contains "$show" "Decision owner: parent" "the owner was not recorded at filing"
  assert_contains "$(plain_channel "$mate")" \
    "needs-decision [key=captain-hold-gated-work-1]: parent decision gated-work: retry the red check once or fix it" \
    "the parent decision did not reach the parent channel"
  [ "$(open_status "$mate" gated-work)" = 1 ] || fail "a parent-owned call read as an open captain call"
  [ "$(open_status "$mate" gated-work --parent-owned)" = 0 ] || fail "the parent-owned predicate missed an open call"

  run_captain "$mate" hold gated-work --reason "retry the red check once or fix it" --owner parent >/dev/null \
    || fail "an idempotent re-hold failed"
  [ "$(grep -c 'captain-hold-gated-work-1' "$channel")" = 1 ] \
    || fail "a repeated parent-owned hold duplicated its channel line: $(cat "$channel")"
  if run_captain "$mate" hold gated-work --reason "now the captain" --owner captain >/dev/null 2>&1; then
    fail "an open parent-owned call was re-filed as the captain's"
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
  pass "a parent-owned call closes on the parent's decision, never on captain words, and the work stays open"
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
  tasks_in "$mate" add parent-work "Parent work" --kind ship --repo sample >/dev/null
  tasks_in "$mate" add captain-work "Captain work" --kind ship --repo sample >/dev/null
  run_captain "$mate" hold parent-work --owner parent --reason "parent call" >/dev/null
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
  run_captain "$home" hold moot-work --reason "moot-premise-choice pending" >/dev/null || fail "hold failed"
  printf 'Ruling A: use the demand map.\n' > "$decision"
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
    fail "withdraw accepted two bases"
  fi
  assert_contains "$(tasks_in "$home" show moot-work --full)" "held: yes" "a refused withdrawal released the call"

  tasks_in "$home" add open-ruling "Open work" --kind ship --repo sample >/dev/null
  if run_captain "$home" withdraw moot-work --evidence-file "$evidence" --ruling open-ruling >/dev/null 2>&1; then
    fail "withdraw accepted an open task as a captain ruling"
  fi

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

  bearings=$(run_bearings "$home") || fail "bearings failed"
  assert_not_contains "$bearings" "moot-premise-choice pending" "Bearings still shows the withdrawn call as the captain's"

  # The lifecycle stays intact: the same work can be held again, as a new occurrence.
  run_captain "$home" hold moot-work --reason "a genuinely new captain choice" >/dev/null \
    || fail "re-holding withdrawn work failed"
  [ "$(open_status "$home" moot-work)" = 0 ] || fail "a re-held withdrawn task is not an open captain call"
  printf 'Go.\n' > "$decision"
  run_captain "$home" answer moot-work --decision-file "$decision" --release >/dev/null \
    || fail "the captain's answer on a re-held withdrawn task failed"
  pass "withdraw releases a moot call on a recorded captain ruling and keeps the work open"
}

test_withdraw_never_releases_a_genuine_captain_call() {
  local mate main evidence channel
  mate=$(make_mate_home withdraw-refusals)
  channel=$(mate_channel "$mate")
  evidence="$mate/evidence.txt"
  printf 'Main decided this was its own call.\n' > "$evidence"

  # A captain-owned hold recorded as such is never the parent's.
  tasks_in "$mate" add recorded-work "Recorded work" --kind ship --repo sample >/dev/null
  run_captain "$mate" hold recorded-work --owner captain --reason "needs the captain" >/dev/null
  printf 'needs-decision [key=captain-hold-recorded-work-1]: captain hold recorded-work: needs the captain\n' >> "$channel"
  if run_captain "$mate" withdraw recorded-work --evidence-file "$evidence" --parent-routed 2>"$mate/refusal.err" >/dev/null; then
    fail "withdraw released a hold recorded as the captain's on the parent-routed basis"
  fi
  assert_contains "$(cat "$mate/refusal.err")" "records its owner as captain" "the refusal did not name the recorded owner"
  assert_contains "$(tasks_in "$mate" show recorded-work --full)" "held: yes" "the refused withdrawal released the call"

  # A legacy hold whose call never reached the parent channel cannot be shown to be the parent's.
  make_legacy_mate_hold "$mate" undelivered-work "undelivered choice"
  if run_captain "$mate" withdraw undelivered-work --evidence-file "$evidence" --parent-routed 2>"$mate/refusal.err" >/dev/null; then
    fail "withdraw released a legacy hold that never reached the parent channel"
  fi
  assert_contains "$(cat "$mate/refusal.err")" "carries no needs-decision line" "the refusal did not name the missing delivery"
  assert_contains "$(tasks_in "$mate" show undelivered-work --full)" "held: yes" "the refused withdrawal released the call"

  # A main home has no parent, so the parent-routed basis does not exist there.
  main=$(make_home withdraw-main)
  tasks_in "$main" add main-work "Main work" --kind ship --repo sample >/dev/null
  run_captain "$main" hold main-work --reason "captain choice" >/dev/null
  printf 'Main decided this was its own call.\n' > "$main/evidence.txt"
  if run_captain "$main" withdraw main-work --evidence-file "$main/evidence.txt" --parent-routed 2>"$main/refusal.err" >/dev/null; then
    fail "withdraw released a main-home captain call on the parent-routed basis"
  fi
  assert_contains "$(cat "$main/refusal.err")" "has no parent firstmate" "the refusal did not say there is no parent"

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
  pass "withdraw refuses a recorded captain call, an undelivered legacy call, a main home, and a non-captain ruling"
}

test_withdraw_releases_a_legacy_mate_hold_the_parent_owned() {
  local mate channel evidence show line
  mate=$(make_mate_home withdraw-legacy)
  channel=$(mate_channel "$mate")
  evidence="$mate/evidence.txt"
  printf 'Main decided one unchanged-head retry; CI went green; the question was Main'"'"'s.\n' > "$evidence"
  line='needs-decision [key=captain-hold-legacy-work-1]: captain hold legacy-work: Main reserves ask-user decisions'
  make_legacy_mate_hold "$mate" legacy-work "retry or fix one red CI check" "$line"
  [ "$(open_status "$mate" legacy-work)" = 0 ] || fail "the legacy hold is not an open captain call"

  run_captain "$mate" withdraw legacy-work --evidence-file "$evidence" --parent-routed >/dev/null \
    || fail "withdraw refused a delivered legacy hold"
  show=$(tasks_in "$mate" show legacy-work --full)
  assert_contains "$show" "held: no" "the withdrawal did not release the hold"
  assert_not_contains "$show" "state: done" "the withdrawal completed the work item"
  assert_contains "$show" "Withdrawn by: the parent firstmate" "the decider was not recorded"
  assert_contains "$show" "Filed owner: unrecorded" "the filed owner was not recorded"
  assert_contains "$show" "Run from: secondmate home" "the home role was not derived and recorded"
  assert_contains "$show" "Not a captain answer." "the record did not say it is not a captain answer"
  assert_not_contains "$show" "Captain decision:" "the withdrawal was written as the captain's words"
  assert_contains "$(plain_channel "$mate")" "resolved [key=captain-hold-legacy-work-1]: captain hold legacy-work: withdrawn, not a captain call" \
    "the withdrawal did not close the parent channel key"
  [ "$(open_status "$mate" legacy-work)" = 1 ] || fail "the withdrawn legacy hold still reads as open"
  pass "withdraw releases a legacy mate hold whose call the parent channel carried"
}

test_the_divergence_guard_and_readers_do_not_show_a_withdrawal_as_a_captain_answer() {
  local mate evidence line out
  mate=$(make_mate_home divergence)
  evidence="$mate/evidence.txt"
  printf 'Main decided; not the captain.\n' > "$evidence"
  line='needs-decision [key=captain-hold-diverged-work-1]: captain hold diverged-work: retry'
  make_legacy_mate_hold "$mate" diverged-work "retry" "$line"
  # The status log of the task reads resolved while the hold is still open: the
  # divergence shape the guard reports.
  printf 'needs-decision [key=diverged-work]: retry\nresolved [key=diverged-work]: main decided\n' > "$mate/state/divergence-origin.status"
  out=$(run_captain "$mate" diverged) || fail "diverged failed"
  assert_contains "$out" "diverged-work" "the divergence guard missed the open captain hold"
  run_captain "$mate" withdraw diverged-work --evidence-file "$evidence" --parent-routed >/dev/null \
    || fail "withdraw failed"
  out=$(run_captain "$mate" diverged) || fail "diverged failed after the withdrawal"
  assert_not_contains "$out" "diverged-work" "the divergence guard still reports a withdrawn call"
  if run_captain "$mate" verify divergence-origin >/dev/null 2>&1; then :; fi
  pass "the divergence guard stops reporting a call once it is withdrawn"
}

tests=(
test_a_mate_home_must_declare_who_owns_each_hold
test_a_parent_owned_call_closes_on_the_parents_decision
test_a_captain_owned_call_is_not_closed_by_the_parents_decision
test_the_merge_gate_reads_each_owner_without_confusing_them
test_withdraw_releases_a_moot_call_on_a_recorded_captain_ruling
test_withdraw_never_releases_a_genuine_captain_call
test_withdraw_releases_a_legacy_mate_hold_the_parent_owned
test_the_divergence_guard_and_readers_do_not_show_a_withdrawal_as_a_captain_answer
)
captain_hold_run_tests "$@"
