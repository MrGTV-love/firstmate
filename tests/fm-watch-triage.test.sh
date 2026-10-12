#!/usr/bin/env bash
# tests/fm-watch-triage.test.sh - Status signals, late-signal routing, delivery failures, and bounded maintenance deferrals.
set -u

# shellcheck source=tests/fm-watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-watch-triage-helpers.sh"


test_working_note_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # A non-no-mistakes crew (no run) whose pane went idle: fm-crew-state falls back
  # to the stale working: status-log line. That is NOT positive evidence, so the
  # wake must surface - these users must never be left hanging.
  export FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a working: note whose crew has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the surfaced working: signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced working: note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  pass "a no-verb working: note whose crew is idle with no running pipeline is surfaced"
}


test_secondmate_status_note_surfaced_despite_busy_agent() {
  local dir state fakebin out drain_out pid
  dir=$(make_case secondmate-note-surfaced); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  printf 'kind=secondmate\n' > "$state/mate.meta"
  printf 'note: routed reply landed in the parent stream\n' > "$state/mate.status"
  # Busy evidence that absorbs routine progress must not absorb a secondmate's
  # parent-directed note: its status stream is the routed-reply channel.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · running'
  FM_CONFIG_OVERRIDE="$(churn_config "$dir")" watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a busy secondmate's routed status note"
  grep -F "signal: $state/mate.status" "$out" >/dev/null \
    || fail "watcher did not print the surfaced secondmate note"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/mate.status" >/dev/null \
    || fail "surfaced secondmate note was not queued"
  pass "a secondmate's status note surfaces even while its own agent is busy"
}


test_secondmate_routine_progress_absorbed_then_note_surfaced() {
  local dir state fakebin out pid
  dir=$(make_case secondmate-routine-absorbed); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  printf 'kind=secondmate\n' > "$state/mate.meta"
  printf 'working: step 2 of 5\n' > "$state/mate.status"
  # A provably working mate's unmarked routine progress is absorbed exactly like
  # an ordinary crewmate's (no exit, no durable wake, suppressor advanced)...
  export FM_FAKE_CREW_STATE='state: working · source: run-step · running'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher surfaced a busy secondmate's routine working: progress: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "routine secondmate progress printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "routine secondmate progress enqueued a durable wake"; }
  [ -s "$state/.seen-mate_status" ] || { reap "$pid"; fail "absorbed secondmate progress did not advance its .seen-* suppressor"; }
  # ...while a note: from the SAME still-busy mate surfaces on the next append.
  printf 'note: routed reply for the parent\n' >> "$state/mate.status"
  wait_for_exit "$pid" 100 || fail "watcher absorbed a busy secondmate's note after absorbing its routine progress"
  grep -F "signal: $state/mate.status" "$out" >/dev/null \
    || fail "watcher did not print the surfaced secondmate note"
  grep -F "$state/mate.status" "$state/.wake-queue" >/dev/null \
    || fail "surfaced secondmate note was not durably queued"
  pass "a busy secondmate's routine working: is absorbed while its later note: still surfaces"
}


test_secondmate_buried_block_wakes_despite_busy_agent() {
  local dir state fakebin out suffix pid
  for suffix in '' 'note: unrelated progress' 'resolved [key=other]: unrelated answer'; do
    dir=$(make_case "secondmate-buried-block-${#suffix}"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"
    printf 'kind=secondmate\n' > "$state/mate.meta"
    printf 'blocked [key=access]: need release access\n%s\n' "$suffix" > "$state/mate.status"
    [ "$(status_line_verb "$(status_current_line "$state/mate.status" secondmate)")" = blocked ] \
      || fail "unrelated '$suffix' hid an open blocker from current-state resolution"
    export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
    watch_bg "$state" "$fakebin" "$out"
    pid=$!
    wait_for_exit "$pid" 100 || fail "busy secondmate's blocker did not wake after '$suffix'"
    grep -F "signal: $state/mate.status" "$out" >/dev/null \
      || fail "busy secondmate's blocker was not surfaced"
    grep -F "$state/mate.status" "$state/.wake-queue" >/dev/null \
      || fail "busy secondmate's blocker was not durably queued"
  done
  pass "a secondmate blocker wakes despite busy evidence and later unrelated appends"
}


test_self_announced_close_does_not_rewake_but_next_note_does() {
  local dir state fakebin out status_file pid rc
  dir=$(make_case self-close-quiet); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'needs-decision [key=k1]: pick one\n' > "$status_file"
  prime_status_seen "$state" "$status_file" || fail "could not prime the announced baseline"
  # The home's own bookkeeping close, written through the guarded
  # self-announced append this home's answerers use.
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_status_append_self_announced "$2" "$3" "resolved [key=k1]: answered: closed by this home"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$status_file" || rc=$?
  [ "$rc" -eq 0 ] || fail "the bookkeeping close was not self-announced (rc=$rc)"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle worker'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the home's own bookkeeping close re-woke its own watcher: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "self-announced close printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "self-announced close enqueued a durable wake"; }
  # A later, different note on the SAME task still wakes: dedup is keyed on the
  # exact announced bytes, never on task identity.
  printf 'needs-decision [key=k2]: a genuinely new decision\n' >> "$status_file"
  wait_for_exit "$pid" 100 || fail "a later different note after a self-announced close was swallowed"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "the later note did not surface as a signal"
  pass "a self-announced close never wakes its own home, and the next real note still does"
}


test_self_announced_close_after_open_decisions_fold_does_not_rewake() {
  local dir state fakebin out status_file pid rc
  dir=$(make_case self-close-after-fold); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'needs-decision [key=k1]: pick one\n' > "$status_file"
  # Session-start drain folds OPEN DECISIONS without writing a watcher seen
  # marker. That is the issue 4767 path: the supervisor then closes the listed
  # decision and must not get a signal wake of its own resolved line.
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    status_open_decisions_incremental "$2" >/dev/null
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$status_file" \
    || fail "could not fold the open decision"
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_status_append_self_announced "$2" "$3" "resolved [key=k1]: answered: closed after fold"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$status_file" || rc=$?
  [ "$rc" -eq 0 ] || fail "the bookkeeping close after OPEN DECISIONS fold was not self-announced (rc=$rc)"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle worker'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a close after OPEN DECISIONS fold re-woke its own watcher: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "folded close printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "folded close enqueued a durable wake"; }
  printf 'blocked: worker still needs help\n' >> "$status_file"
  wait_for_exit "$pid" 100 || fail "a later worker line after a folded close was swallowed"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "the later worker line did not surface as a signal"
  pass "a close after OPEN DECISIONS fold never wakes its own home, and the next real note still does"
}


# Any actor's drain folds OPEN DECISIONS, including a Pi branch drain, so a
# fold is no proof the watcher's owner saw the line. A fresh worker decision the
# fold already read must still wake when this home appended nothing.
test_folded_worker_decision_without_home_append_still_wakes() {
  local dir state fakebin out status_file pid
  dir=$(make_case folded-decision-wakes); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: building\n' > "$status_file"
  prime_status_seen "$state" "$status_file" || fail "could not prime the announced baseline"
  printf 'needs-decision [key=k3]: pick a region\n' >> "$status_file"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$dir/fold.err" \
    || fail "the OPEN DECISIONS fold drain failed"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle worker'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "a folded worker decision with no home append was swallowed"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "the folded worker decision did not surface as a signal: $(cat "$out")"
  pass "a folded worker decision with no home append still wakes"
}


# Two distinct --resolve-key answers to decisions the watcher never classified
# leave the marker alone, since a fold is no proof the watcher's owner saw them.
# That costs one wake for the worker's decisions, not one per answer, because
# both answers ride inside the same surfaced span; the watcher's own commit
# then covers them, so the next cycle is quiet and the next real note still
# wakes. The ledger's separate job - vouching for owned bytes the watcher has
# NOT classified - is pinned at library level by
# test_separate_self_announced_answers_after_fold_are_owned.
test_separate_self_announced_answers_after_fold_wake_once() {
  local dir state fakebin out status_file pid rc answer
  dir=$(make_case multi-answer-fold); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  {
    printf 'needs-decision [key=k1]: pick REST or RPC\n'
    printf 'needs-decision [key=k2]: pick us-east or eu-west\n'
  } > "$status_file"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>"$dir/fold.err" \
    || fail "the OPEN DECISIONS fold drain failed"
  for answer in 'resolved [key=k1]: answered: REST' 'resolved [key=k2]: answered: eu-west'; do
    rc=0
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"; fm_wake_status_append_self_announced "$2" "$3" "$4"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$status_file" "$answer" || rc=$?
    [ "$rc" -eq 1 ] || fail "an answer over unclassified worker decisions did not fail toward waking (rc=$rc)"
  done
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle worker'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the unclassified worker decisions were swallowed"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "the worker decisions did not surface as a signal: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not handle the worker decisions' wake"
  : > "$out"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the owned answers re-woke the watcher: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "the owned answers printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "the owned answers enqueued another durable wake"; }
  printf 'blocked: need staging credentials\n' >> "$status_file"
  wait_for_exit "$pid" 100 || fail "a later worker line after two owned answers was swallowed"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "the later worker line did not surface as a signal"
  pass "separate answers over unclassified decisions wake once, and the next real note still does"
}


test_self_announced_close_after_fold_still_surfaces_folded_worker_failure() {
  local dir state fakebin out status_file pid rc
  dir=$(make_case self-close-folded-failure); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'needs-decision [key=budget]: approve spend?\n' > "$status_file"
  prime_status_seen "$state" "$status_file" || fail "could not prime the announced baseline"
  # While no watcher runs, the worker reports a failure and moves on. The
  # session-start fold reads through both lines but lists only the open
  # decision, so the supervisor's close must not hide the failure.
  printf 'failed: crew c3 hit an unrecoverable migration error\nworking: retrying c3 in a fresh worktree\n' \
    >> "$status_file"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    status_open_decisions_incremental "$2" >/dev/null
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$status_file" \
    || fail "could not fold the open decision"
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_status_append_self_announced "$2" "$3" "resolved [key=budget]: answered: approved"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$status_file" || rc=$?
  [ "$rc" -eq 1 ] || fail "a close over a folded worker failure was self-announced (rc=$rc)"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle worker'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the folded worker failure was swallowed by the supervisor's close"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "the folded worker failure did not surface as a signal: $(cat "$out")"
  pass "a close after OPEN DECISIONS fold still surfaces a worker failure inside the folded span"
}


test_self_announced_close_after_fold_still_surfaces_folded_secondmate_lines() {
  local dir state fakebin out status_file pid rc lagging n=0
  # A secondmate's note carries no captain verb, and a decision the mate
  # raised and closed itself is never listed as open; the fold shows neither,
  # yet both are parent-directed content and must still wake.
  for lagging in 'note: vendor quote arrived, holding it for the parent' \
    $'needs-decision [key=vendor]: vendor A or B?\nresolved [key=vendor]: picked vendor B myself, cheaper'; do
    n=$((n + 1))
    dir=$(make_case "self-close-folded-mate-$n"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
    status_file="$state/mate.status"
    printf 'kind=secondmate\n' > "$state/mate.meta"
    printf 'needs-decision [key=budget]: approve spend?\n' > "$status_file"
    prime_status_seen "$state" "$status_file" || fail "could not prime the announced baseline"
    printf '%s\n' "$lagging" >> "$status_file"
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      status_open_decisions_incremental "$2" >/dev/null
    ' _ "$ROOT/bin/fm-classify-lib.sh" "$status_file" \
      || fail "could not fold the open decision"
    rc=0
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"
      fm_wake_status_append_self_announced "$2" "$3" "resolved [key=budget]: answered: approved"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$status_file" || rc=$?
    [ "$rc" -eq 1 ] || fail "a close over folded secondmate lines was self-announced (rc=$rc): $lagging"
    export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
    watch_bg "$state" "$fakebin" "$out"
    pid=$!
    wait_for_exit "$pid" 100 || fail "the supervisor's close swallowed folded secondmate lines: $lagging"
    grep -F "signal: $status_file" "$out" >/dev/null \
      || fail "folded secondmate lines did not surface as a signal: $(cat "$out")"
  done
  pass "a close after OPEN DECISIONS fold still surfaces unlisted secondmate lines inside the folded span"
}


# --- actionable wakes are surfaced (queue + exit) ---------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "captain-relevant signal is surfaced (queue + exit) and marked surfaced"
}


# A signal that lands while the watcher is mid-cycle, a signal that landed while
# no watcher ran, and a keyed decision all surface as a signal wake on the first
# classification pass. These pin the two shapes the missed-done report named
# (written between cycles, written during a cycle) plus the keyed lines, so a
# regression in the baseline or the span classifier is caught where it starts.
test_done_and_keyed_lines_surface_between_and_during_cycles() {
  local dir state fakebin out status_file pid kind line
  for kind in between during; do
    for line in 'done [at=1791490597]: finished the triage' \
      'needs-decision [key=pick-one] [at=1791488659]: choose A or B' \
      'blocked [key=shared-prereq] [at=1791488660]: waiting on the shared service'; do
      dir=$(make_case "late-signal-$kind-${line%% *}"); state="$dir/state"; fakebin="$dir/fakebin"
      out="$dir/watch.out"; status_file="$state/task.status"
      mkdir -p "$dir/approved"
      printf 'project=%s/approved\nkind=scout\n' "$dir" > "$state/task.meta"
      printf 'working: setup\n' > "$status_file"
      prime_status_seen "$state" "$status_file"
      if [ "$kind" = between ]; then
        printf '%s\n' "$line" >> "$status_file"
        watch_bg "$state" "$fakebin" "$out"
        pid=$!
      else
        watch_bg "$state" "$fakebin" "$out"
        pid=$!
        wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher never completed a quiet cycle ($kind/${line%% *})"; }
        printf '%s\n' "$line" >> "$status_file"
      fi
      wait_for_exit "$pid" 300 || fail "watcher did not signal a ${line%% *} line written $kind cycles"
      grep -F "signal: $status_file" "$out" >/dev/null \
        || fail "watcher exited for ${line%% *} written $kind cycles without a signal reason: $(cat "$out")"
      case "$line" in
        needs-decision*) assert_watch_offer "$state" "$out" 0 0 '' ;;
        *) assert_watch_offer "$state" "$out" 1 0 task ;;
      esac
    done
  done
  pass "done, keyed needs-decision, and keyed blocked lines surface whether written between cycles or during one"
}



test_signal_not_held_behind_a_blocked_check() {
  local dir state fakebin out status_file pid line result tasks next_out
  for result in quiet actionable; do
    for line in 'done [at=1791490597]: finished during the check' \
      'needs-decision [key=pick-one] [at=1791488659]: choose A or B' \
      'blocked [key=shared-prereq] [at=1791488660]: waiting on the shared service'; do
      dir=$(make_case "signal-in-check-$result-${line%% *}"); state="$dir/state"; fakebin="$dir/fakebin"
      out="$dir/watch.out"; status_file="$state/task.status"
      mkdir -p "$dir/approved"
      printf 'project=%s/approved\nkind=ship\n' "$dir" > "$state/task.meta"
      printf 'working: setup\n' > "$status_file"
      prime_status_seen "$state" "$status_file" || fail "could not prime the status fixture"
      cat > "$state/slow.check.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_STATE_OVERRIDE/check-started"
n=0
while [ ! -e "$FM_STATE_OVERRIDE/check-release" ] && [ "$n" -lt $(( ${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120} * 10 )) ]; do
  sleep 0.1
  n=$((n + 1))
done
[ "$FM_TEST_CHECK_RESULT" = quiet ] || printf 'check completed\n'
SH
      chmod 0700 "$state/slow.check.sh"
      FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" slow >/dev/null \
        || fail "could not register the blocked check"
      watch_bg "$state" "$fakebin" "$out" env FM_CHECK_TIMEOUT=120 FM_CHECK_INTERVAL=1 FM_TEST_CHECK_RESULT="$result"
      pid=$!
      wait_numeric_file "$state/check-started" 300 \
        || { reap "$pid"; fail "the check never started: $(cat "$out")"; }
      printf '%s\n' "$line" >> "$status_file"
      touch "$state/check-release"
      wait_for_exit "$pid" 300 \
        || { reap "$pid"; fail "${line%% *} appended during a $result check was not delivered"; }
      grep -F "$(printf 'signal\ttask.status\t')" "$state/.wake-queue" >/dev/null \
        || fail "the $result check exited without queuing ${line%% *}: $(cat "$out")"
      if [ "$result" = actionable ]; then
        grep -F 'check completed' "$out" >/dev/null \
          || fail "the actionable check result was lost: $(cat "$out")"
        grep -F "$(printf 'check\t%s\t' "$state/slow.check.sh")" "$state/.wake-queue" >/dev/null \
          || fail "the check result was not queued alongside the signal"
      else
        grep -F "signal: $status_file" "$out" >/dev/null \
          || fail "the quiet check did not yield a signal wake: $(cat "$out")"
      fi
      tasks=task
      case "$line" in needs-decision*) tasks='' ;; esac
      if [ "$result" = actionable ]; then
        assert_watch_offer "$state" "$out" 0 0 "$tasks"
        next_out="$dir/follow-up.out"
        watch_bg "$state" "$fakebin" "$next_out" env FM_WATCH_HANDLING_SUCCESSOR=1
        pid=$!
        wait_for_exit "$pid" 300 || { reap "$pid"; fail "check signal follow-up did not deliver"; }
        [ "$(cat "$next_out")" = "signal: $status_file" ] || fail "check follow-up lost its signal headline"
        assert_watch_offer "$state" "$next_out" "$(( ${#tasks} > 0 ))" 0 "$tasks"
      else
        assert_watch_offer "$state" "$out" "$(( ${#tasks} > 0 ))" 0 "$tasks"
      fi
      [ ! -e "$state/.watch-late-signals" ] || fail "delivered check signal retained a follow-up marker"
    done
  done
  pass "done and keyed decision signals appended during quiet and actionable checks are delivered"
}


test_flushed_signals_preserve_main_owned_routing() {
  local dir state fakebin out pid mode ownership id line expected window key decision tasks next_out quiet_out
  for mode in two-checks stale stale-main; do
    for ownership in decision routine ship-blocked mate-blocked mate-blocked-unkeyed mate-resolution \
      mate-reference mate-held mate-routine host-open host-closed; do
      [ "$mode" != stale-main ] || [ "$ownership" = routine ] || continue
      dir=$(make_case "flushed-routing-$mode-$ownership"); state="$dir/state"; fakebin="$dir/fakebin"
      out="$dir/watch.out"; window=test:fm-b; key=test_fm-b
      mkdir -p "$dir/approved" "$dir/config"
      for id in a b; do
        printf 'project=%s/approved\nwindow=test:fm-%s\nkind=ship\n' "$dir" "$id" > "$state/$id.meta"
        printf 'working: setup\n' > "$state/$id.status"
      done
      case "$ownership" in
        decision) line='needs-decision [key=pick-one]: choose A or B' ;;
        routine|host-open|host-closed) line='done: first task completed' ;;
        mate-blocked|ship-blocked) line='blocked [key=access]: need access' ;;
        mate-blocked-unkeyed) line='blocked: need access' ;;
        mate-resolution) line='resolved [key=access]: access granted' ;;
        mate-reference) line='note [key=access]: access request updated' ;;
        mate-held) line='captain-held [key=access]: awaiting the captain' ;;
        mate-routine) line='note: parent update after the decision closed' ;;
      esac
      case "$ownership" in
        mate-*) printf 'project=%s/approved\nwindow=test:fm-a\nkind=secondmate\n' "$dir" > "$state/a.meta" ;;
      esac
      case "$ownership" in
        mate-resolution|host-open|host-closed|mate-routine)
          printf 'needs-decision [key=access]: need access\n' >> "$state/a.status" ;;
        mate-reference)
          printf 'blocked [key=access]: need access\n' >> "$state/a.status" ;;
      esac
      case "$ownership" in
        host-closed|mate-routine)
          printf 'resolved [key=access]: access granted\n' >> "$state/a.status" ;;
      esac
      if [ "$mode" = stale-main ]; then
        printf 'needs-decision [key=budget]: approve the budget\n' >> "$state/b.status"
      fi
      for id in a b; do
        prime_status_seen "$state" "$state/$id.status" || fail "could not prime signal $id"
        printf '%s\t%s\t%s\t\n' "$id" "$(_fm_open_decisions_file_ident "$state/$id.status")" \
          "$(size_of "$state/$id.status")" >> "$state/.status-presentation-cursor"
      done
      if [ "$mode" = two-checks ]; then
        for id in a b; do
          printf '#!/usr/bin/env bash\nid=%s\n' "$id" > "$state/$id.check.sh"
          cat >> "$state/$id.check.sh" <<'SH'
printf '%s\n' "$$" > "$FM_STATE_OVERRIDE/check-started-$id"
n=0
while [ ! -e "$FM_STATE_OVERRIDE/check-release-$id" ] && [ "$n" -lt 1200 ]; do
  sleep 0.1
  n=$((n + 1))
done
SH
          chmod 0700 "$state/$id.check.sh"
          FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
            || fail "could not register check $id"
        done
        watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
          FM_CHECK_TIMEOUT=120 FM_CHECK_INTERVAL=1
        pid=$!
        wait_numeric_file "$state/check-started-a" 300 \
          || { reap "$pid"; fail "first check never started"; }
        printf '%s\n' "$line" >> "$state/a.status"
        touch "$state/check-release-a"
        wait_numeric_file "$state/check-started-b" 300 \
          || { reap "$pid"; fail "second check never started"; }
        printf 'done: second task completed\n' >> "$state/b.status"
        touch "$state/check-release-b"
        expected="signal: $state/a.status $state/b.status"
      else
        printf 'idle prompt, finished' > "$dir/pane.txt"
        printf '%s' "$(hash_text 'idle prompt, finished')" > "$state/.hash-$key"
        printf '1\n' > "$state/.count-$key"
        cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = b ] && [ "$(cat "$FM_STATE_OVERRIDE/.count-test_fm-b" 2>/dev/null)" = 2 ] \
  && [ ! -e "$FM_STATE_OVERRIDE/routing-appended" ]; then
  touch "$FM_STATE_OVERRIDE/routing-appended"
  printf '%s\n' "$FM_TEST_ROUTING_LINE" >> "$FM_STATE_OVERRIDE/a.status"
fi
printf 'state: unknown · source: none · no running pipeline\n'
SH
        watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
          FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_TEST_ROUTING_LINE="$line"
        pid=$!
        expected="stale: $window"
      fi
      wait_for_exit "$pid" 300 || { reap "$pid"; fail "$mode/$ownership watcher did not deliver"; }
      [ "$(cat "$out")" = "$expected" ] \
        || fail "$mode/$ownership emitted the wrong routing trigger: $(cat "$out")"
      if [ "$mode" != two-checks ]; then
        grep -F "$(printf 'stale\t%s\tstale: %s' "$window" "$window")" "$state/.wake-queue" >/dev/null \
          || fail "the original stale wake was not preserved"
      fi
      decision=0
      case "$ownership" in
        decision|mate-blocked|mate-blocked-unkeyed|mate-resolution|mate-reference|mate-held|host-open) decision=1 ;;
      esac
      tasks=b
      [ "$mode" != stale-main ] || tasks=''
      [ "$decision" -eq 1 ] || tasks="a${tasks:+ $tasks}"
      if [ "$mode" = stale-main ] || { [ "$mode" = two-checks ] && [ "$decision" -eq 1 ]; }; then
        assert_watch_offer "$state" "$out" 0 0 "$tasks"
      else
        assert_watch_offer "$state" "$out" 1 0 "$tasks"
      fi
      if [ "$mode" != two-checks ]; then
        [ -s "$state/.watch-late-signals" ] || fail "late signal follow-up was not persisted"
        next_out="$dir/follow-up.out"
        watch_bg "$state" "$fakebin" "$next_out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
          FM_WATCH_HANDLING_SUCCESSOR=1
        pid=$!
        wait_for_exit "$pid" 300 || { reap "$pid"; fail "$mode/$ownership follow-up did not deliver"; }
        [ "$(cat "$next_out")" = "signal: $state/a.status" ] \
          || fail "$mode/$ownership lost its independent signal headline: $(cat "$next_out")"
        assert_watch_offer "$state" "$next_out" "$((1 - decision))" 0 "$tasks"
      fi
      [ ! -e "$state/.watch-late-signals" ] || fail "delivered signal retained its follow-up marker"
      if [ "$ownership" = routine ]; then
        quiet_out="$dir/quiet.out"
        watch_bg "$state" "$fakebin" "$quiet_out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
          FM_WATCH_HANDLING_SUCCESSOR=1
        pid=$!
        wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "$mode/$ownership follow-up loop: $(cat "$quiet_out")"; }
        [ ! -s "$quiet_out" ] || { reap "$pid"; fail "an unchanged unread batch woke again"; }
        reap "$pid"
      fi
    done
  done
  pass "late signals keep original stale routing and wake once independently, including Main-owned stale rows"
}


test_heartbeat_late_signal_retains_fleet_scope() {
  local dir state fakebin out next_out quiet_out pid id real_touch
  dir=$(make_case heartbeat-late-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  mkdir -p "$dir/approved" "$dir/config"
  for id in a b; do
    printf 'project=%s/approved\nkind=ship\n' "$dir" > "$state/$id.meta"
  done
  printf 'working: setup\n' > "$state/a.status"
  prime_status_seen "$state" "$state/a.status" || fail "could not prime the late heartbeat signal"
  printf 'done: missed by the per-signal path\n' > "$state/b.status"
  printf '%s' "$(seen_sig "$state/b.status")" > "$state/.seen-b_status"
  touch "$state/.last-heartbeat"
  set_mtime "$(( $(date +%s) - 60 ))" "$state/.last-heartbeat"
  real_touch=$(command -v touch)
  printf '#!/usr/bin/env bash\nreal_touch=%q\n' "$real_touch" > "$fakebin/touch"
  cat >> "$fakebin/touch" <<'SH'
if [ "${1:-}" = "$FM_STATE_OVERRIDE/.last-heartbeat" ] && [ ! -e "$FM_STATE_OVERRIDE/heartbeat-appended" ]; then
  "$real_touch" "$FM_STATE_OVERRIDE/heartbeat-appended"
  printf 'done: finished during heartbeat publication\n' >> "$FM_STATE_OVERRIDE/a.status"
fi
exec "$real_touch" "$@"
SH
  chmod 0700 "$fakebin/touch"
  watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_HEARTBEAT=1
  pid=$!
  wait_for_exit "$pid" 300 || { reap "$pid"; fail "heartbeat with a late signal did not deliver"; }
  [ "$(cat "$out")" = heartbeat ] || fail "late routine signal replaced heartbeat scope: $(cat "$out")"
  [ "$(cat "$state/.heartbeat-streak")" = 1 ] || fail "heartbeat delivery lost its cadence"
  grep -F "$(printf 'signal\ta.status\t')" "$state/.wake-queue" >/dev/null || fail "heartbeat omitted the late signal row"
  assert_watch_offer "$state" "$out" 1 1 a
  next_out="$dir/follow-up.out"
  watch_bg "$state" "$fakebin" "$next_out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" FM_WATCH_HANDLING_SUCCESSOR=1
  pid=$!
  wait_for_exit "$pid" 300 || { reap "$pid"; fail "heartbeat signal follow-up did not deliver"; }
  [ "$(cat "$next_out")" = "signal: $state/a.status" ] || fail "heartbeat follow-up lost its signal headline"
  assert_watch_offer "$state" "$next_out" 1 0 a
  [ ! -e "$state/.watch-late-signals" ] || fail "heartbeat follow-up retained its marker"
  quiet_out="$dir/quiet.out"
  watch_bg "$state" "$fakebin" "$quiet_out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" FM_WATCH_HANDLING_SUCCESSOR=1
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "heartbeat signal follow-up looped: $(cat "$quiet_out")"; }
  [ ! -s "$quiet_out" ] || { reap "$pid"; fail "heartbeat batch woke twice"; }
  reap "$pid"
  pass "a late routine signal preserves heartbeat fleet scope and gets one task-scoped follow-up"
}


test_late_signal_follow_up_filters_drained_rows() {
  local dir state fakebin out next_out quiet_out pid id consume seq
  for consume in all partial unwritable; do
    dir=$(make_case "late-signal-consumed-$consume"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
    mkdir -p "$dir/approved" "$dir/config"
    for id in a b; do
      printf 'project=%s/approved\nkind=ship\n' "$dir" > "$state/$id.meta"
      printf 'working: setup\n' > "$state/$id.status"
      prime_status_seen "$state" "$state/$id.status" || fail "could not prime late signal $id"
    done
    cat > "$state/late.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'run\n' >> "$FM_STATE_OVERRIDE/late-check-runs"
[ ! -e "$FM_STATE_OVERRIDE/late-check-injected" ] || exit 0
touch "$FM_STATE_OVERRIDE/late-check-injected"
printf 'needs-decision [key=access]: need access\n' >> "$FM_STATE_OVERRIDE/a.status"
printf 'done: routine task completed\n' >> "$FM_STATE_OVERRIDE/b.status"
[ ! -e "$FM_STATE_OVERRIDE/late-marker-unwritable" ] || mkdir "$FM_STATE_OVERRIDE/.watch-late-signals"
printf 'late check completed\n'
SH
    chmod 0700 "$state/late.check.sh"
    FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" late >/dev/null || fail "could not register late signal check"
    [ "$consume" != unwritable ] || touch "$state/late-marker-unwritable"
    watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" FM_CHECK_INTERVAL=1 \
      FM_WATCH_HANDLING_SUCCESSOR=1
    pid=$!
    if [ "$consume" = unwritable ]; then
      wait_for_exit "$pid" 300 || { reap "$pid"; fail "marker-store failure did not deliver its queued signals"; }
      [ "$(cat "$out")" = "signal: $state/a.status $state/b.status" ] \
        || fail "marker-store failure lost its accumulated signal headline: $(cat "$out")"
      assert_watch_offer "$state" "$out" 0 0 b
      [ "$(cat "$state/.prelude-progress")" = 10 ] || fail "signal fallback skipped unfinished checks"
      [ "$(grep -Fc "$(printf 'check\t%s\tcheck: %s: late check completed' "$state/late.check.sh" "$state/late.check.sh")" "$state/.wake-queue")" -eq 1 ] \
        || fail "marker-store failure lost the completed one-shot check row"
      rmdir "$state/.watch-late-signals"
      next_out="$dir/recovery.out"
      watch_bg "$state" "$fakebin" "$next_out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
        FM_WATCH_HANDLING_SUCCESSOR=1 FM_CHECK_INTERVAL=1
      pid=$!
      wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "successor did not finish the interrupted checks: $(cat "$next_out")"; }
      [ ! -s "$next_out" ] || { reap "$pid"; fail "marker failure caused a duplicate signal wake"; }
      [ ! -e "$state/.prelude-progress" ] || { reap "$pid"; fail "successor left completed maintenance owed"; }
      [ "$(wc -l < "$state/late-check-runs" | tr -d '[:space:]')" -ge 2 ] \
        || { reap "$pid"; fail "successor did not rerun the one-shot check"; }
      [ "$(grep -Fc "$(printf 'check\t%s\tcheck: %s: late check completed' "$state/late.check.sh" "$state/late.check.sh")" "$state/.wake-queue")" -eq 1 ] \
        || { reap "$pid"; fail "successor duplicated or lost the one-shot check row"; }
      reap "$pid"
      continue
    fi
    wait_for_exit "$pid" 300 || { reap "$pid"; fail "late signal check did not deliver"; }
    case "$(cat "$out")" in check:*'late check completed'*) ;; *) fail "late signals changed the check headline" ;; esac
    assert_watch_offer "$state" "$out" 0 0 b
    [ -s "$state/.watch-late-signals" ] || fail "check omitted its durable follow-up"
    if [ "$consume" = partial ]; then
      # shellcheck disable=SC2016 # template literal expands in node, not the shell.
      seq=$(STATE="$state" node --input-type=module -e 'import { readFileSync } from "node:fs"; console.log(readFileSync(`${process.env.STATE}/.wake-queue`, "utf8").split("\n").map(line => line.split("\t")).find(row => row[2] === "signal" && row[3] === "b.status")[1]);')
      FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" activate "$$" late-signal-test || fail "could not reserve the routine signal"
      FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" publish late-signal-test "$seq" || fail "could not grant the routine signal"
    fi
    ack_stopped_cycle "$state" || fail "Main could not drain the late signals"
    if [ "$consume" = partial ]; then
      FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" deactivate "$$" late-signal-test || fail "could not release the routine signal"
    fi
    next_out="$dir/follow-up.out"
    watch_bg "$state" "$fakebin" "$next_out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" FM_WATCH_HANDLING_SUCCESSOR=1
    pid=$!
    if [ "$consume" = partial ]; then
      wait_for_exit "$pid" 300 || { reap "$pid"; fail "remaining late signal was not delivered"; }
      [ "$(cat "$next_out")" = "signal: $state/b.status" ] || fail "follow-up included an already-drained signal"
      assert_watch_offer "$state" "$next_out" 1 0 b
      quiet_out="$dir/quiet.out"
      watch_bg "$state" "$fakebin" "$quiet_out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" FM_WATCH_HANDLING_SUCCESSOR=1
      pid=$!
    else
      quiet_out=$next_out
    fi
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "drained late signal follow-up was not skipped: $(cat "$quiet_out")"; }
    [ ! -s "$quiet_out" ] || { reap "$pid"; fail "consumed late signal woke again"; }
    [ ! -e "$state/.watch-late-signals" ] || { reap "$pid"; fail "consumed late signal marker remained"; }
    reap "$pid"
  done
  pass "follow-ups filter drained rows and marker-store failures preserve one-shot check results in successor posture"
}


test_late_signal_output_failure_retries() {
  local dir state fakebin out next_out quiet_out fifo pid reader rc mode queue
  for mode in follow-up prelude; do
    dir=$(make_case "late-signal-output-failure-$mode"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; fifo="$dir/output.fifo"
    mkdir -p "$dir/approved" "$dir/config"
    printf 'project=%s/approved\nkind=ship\n' "$dir" > "$state/task.meta"
    printf 'working: setup\n' > "$state/task.status"
    prime_status_seen "$state" "$state/task.status" || fail "could not prime output-failure signal"
    cat > "$state/late.check.sh" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FM_STATE_OVERRIDE/late-check-injected" ] || exit 0
touch "$FM_STATE_OVERRIDE/late-check-injected"
printf 'done: finished during the check\n' >> "$FM_STATE_OVERRIDE/task.status"
[ "$FM_TEST_CHECK_RESULT" = quiet ] || printf 'late check completed\n'
SH
    chmod 0700 "$state/late.check.sh"
    FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" late >/dev/null \
      || fail "could not register output-failure check"
    if [ "$mode" = follow-up ]; then
      watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
        FM_WATCH_HANDLING_SUCCESSOR=1 FM_CHECK_INTERVAL=1 FM_TEST_CHECK_RESULT=actionable
      pid=$!
      wait_for_exit "$pid" 300 || { reap "$pid"; fail "initial check did not deliver"; }
      case "$(cat "$out")" in check:*'late check completed') ;; *) fail "initial check lost its headline" ;; esac
      assert_watch_offer "$state" "$out" 0 0 task
      [ -s "$state/.watch-late-signals" ] || fail "initial check omitted the follow-up marker"
      printf '10\n' > "$state/.prelude-progress"
      queue=$(cat "$state/.wake-queue")
    fi
    mkfifo "$fifo"
    sh -c ': < "$1"' _ "$fifo" & reader=$!
    watch_bg "$state" "$fakebin" "$fifo" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_WATCH_HANDLING_SUCCESSOR=1 FM_CHECK_INTERVAL=1 FM_TEST_CHECK_RESULT=quiet \
      bash -c 'trap "" PIPE; exec "$@"' _ 2> "$dir/failed-output.err"
    pid=$!
    wait "$reader" || fail "failed-output reader did not close"
    rc=0
    wait_for_exit "$pid" 300 || rc=$?
    [ "$rc" -eq 1 ] || fail "$mode did not report an output-write failure (rc=$rc)"
    [ -s "$state/.watch-late-signals" ] || fail "$mode consumed its marker before successful output"
    grep -F "$(printf 'signal\ttask.status\t')" "$state/.wake-queue" >/dev/null \
      || fail "$mode lost its durable signal row"
    if [ "$mode" = follow-up ]; then
      [ "$(cat "$state/.wake-queue")" = "$queue" ] || fail "failed follow-up changed its durable batch"
    fi
    queue=$(cat "$state/.wake-queue")
    if [ "$mode" = follow-up ]; then
      [ "$(cat "$state/.prelude-progress")" = 10 ] || fail "failed follow-up advanced interrupted maintenance"
    fi
    next_out="$dir/retry.out"
    watch_bg "$state" "$fakebin" "$next_out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_WATCH_HANDLING_SUCCESSOR=1 FM_CHECK_INTERVAL=1 FM_TEST_CHECK_RESULT=quiet
    pid=$!
    wait_for_exit "$pid" 300 || { reap "$pid"; fail "$mode did not ring after output recovered"; }
    [ "$(cat "$next_out")" = "signal: $state/task.status" ] || fail "$mode retry lost its signal headline"
    assert_watch_offer "$state" "$next_out" 1 0 task
    [ ! -e "$state/.watch-late-signals" ] || fail "$mode successful retry retained its marker"
    [ "$(cat "$state/.wake-queue")" = "$queue" ] || fail "$mode retry changed its durable batch"
    if [ "$mode" = follow-up ]; then
      [ "$(cat "$state/.prelude-progress")" = 10 ] || fail "successful follow-up skipped interrupted maintenance"
    fi
    quiet_out="$dir/quiet.out"
    watch_bg "$state" "$fakebin" "$quiet_out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_WATCH_HANDLING_SUCCESSOR=1 FM_CHECK_INTERVAL=1 FM_TEST_CHECK_RESULT=quiet
    pid=$!
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "$mode repeated its delivered signal"; }
    [ ! -s "$quiet_out" ] || { reap "$pid"; fail "$mode successful retry caused a follow-up loop"; }
    [ ! -e "$state/.prelude-progress" ] || { reap "$pid"; fail "$mode did not finish owed maintenance"; }
    [ "$(cat "$state/.wake-queue")" = "$queue" ] \
      || { reap "$pid"; fail "$mode retry duplicated or lost a queued row"; }
    reap "$pid"
  done
  pass "follow-up and end-of-prelude output failures preserve signal markers until one successful successor ring"
}



test_late_signal_marker_failure_before_procevent() {
  local dir state fakebin out next_out pid fault real_mv marker
  for fault in directory write rename; do
    dir=$(make_case "late-marker-procevent-$fault"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
    mkdir -p "$dir/approved" "$dir/config"
    printf 'project=%s/approved\nkind=ship\n' "$dir" > "$state/a.meta"
    printf 'working: setup\n' > "$state/a.status"
    prime_status_seen "$state" "$state/a.status" || fail "could not prime process-event late signal"
    append_wake "$state" check procevent:late-marker:1 'check: process-event fixture' \
      || fail "could not queue process-event fixture"
    printf '6\n' > "$state/.prelude-progress"
    printf '%s\n' "$fault" > "$state/late-marker-fault"
    real_mv=$(command -v mv)
    printf '#!/usr/bin/env bash\nreal_mv=%q\n' "$real_mv" > "$fakebin/mv"
    cat >> "$fakebin/mv" <<'SH'
dest=${!#}
if [ "$dest" = "$FM_STATE_OVERRIDE/.prelude-progress" ] \
  && [ ! -e "$FM_STATE_OVERRIDE/late-signal-injected" ]; then
  "$real_mv" "$@" || exit
  [ "$(cat "$dest")" = 7 ] || exit 0
  touch "$FM_STATE_OVERRIDE/late-signal-injected"
  printf 'done: finished before process-event delivery\n' >> "$FM_STATE_OVERRIDE/a.status"
  case "$(cat "$FM_STATE_OVERRIDE/late-marker-fault")" in
    directory) mkdir "$FM_STATE_OVERRIDE/.watch-late-signals" ;;
    write) mkdir "$FM_STATE_OVERRIDE/.watch-late-signals.tmp.$(cat "$FM_STATE_OVERRIDE/.watch.lock/pid")" ;;
  esac
  exit 0
fi
if [ "$dest" = "$FM_STATE_OVERRIDE/.watch-late-signals" ] \
  && [ "$(cat "$FM_STATE_OVERRIDE/late-marker-fault" 2>/dev/null)" = rename ]; then
  exit 1
fi
exec "$real_mv" "$@"
SH
    chmod 0700 "$fakebin/mv"
    watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_WATCH_HANDLING_SUCCESSOR=1
    pid=$!
    wait_for_exit "$pid" 300 || { reap "$pid"; fail "$fault marker failure lost the queued signal"; }
    [ "$(cat "$out")" = "signal: $state/a.status" ] \
      || fail "$fault marker failure emitted the wrong headline: $(cat "$out")"
    assert_watch_offer "$state" "$out" 1 0 a
    [ "$(cat "$state/.prelude-progress")" = 7 ] || fail "signal fallback advanced process-event maintenance"
    for marker in "$state"/.seen-procevent-*; do
      [ ! -e "$marker" ] || fail "signal fallback marked the process-event headline delivered"
    done
    [ ! -e "$state/.wake-queue.lock" ] || fail "signal fallback retained the process-event queue lock"
    case "$fault" in
      directory) rmdir "$state/.watch-late-signals" ;;
      write) rmdir "$state/.watch-late-signals.tmp.$pid" ;;
    esac
    rm -f "$state/late-marker-fault"
    next_out="$dir/follow-up.out"
    watch_bg "$state" "$fakebin" "$next_out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_WATCH_HANDLING_SUCCESSOR=1
    pid=$!
    wait_for_exit "$pid" 300 || { reap "$pid"; fail "$fault marker failure lost the interrupted process-event wake"; }
    [ "$(cat "$next_out")" = 'check: process-event result captured: procevent:late-marker:1' ] \
      || fail "successor did not deliver the interrupted process-event headline: $(cat "$next_out")"
    [ "$(cat "$state/.prelude-progress")" = 8 ] || fail "successful process-event delivery did not advance maintenance"
    [ ! -e "$state/.wake-queue.lock" ] || fail "process-event delivery retained its queue lock"
  done
  pass "late marker failures deliver signals and leave interrupted process-event wakes owed"
}


# A process-event wake prints while it holds the wake-queue lock, and the scan
# before every non-signal wake lingers one grace period on a fresh status line.
# That linger must never run under the lock: every other queue writer and the
# drain would wait on it. A sleep shim records whether the queue lock is held
# each time the grace sleep starts, so the proof does not depend on host load.
test_procevent_wake_never_lingers_under_the_queue_lock() {
  local dir state fakebin out next_out pid shape real_bin hook real_sleep grace_log
  for shape in before-lock under-lock; do
    dir=$(make_case "procevent-grace-lock-$shape"); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
    mkdir -p "$dir/approved" "$dir/config"
    printf 'project=%s/approved\nkind=ship\n' "$dir" > "$state/a.meta"
    printf 'working: setup\n' > "$state/a.status"
    prime_status_seen "$state" "$state/a.status" || fail "could not prime $shape status"
    append_wake "$state" check procevent:grace-lock:1 'check: process-event fixture' \
      || fail "could not queue $shape process-event fixture"
    printf '6\n' > "$state/.prelude-progress"
    case "$shape" in
      before-lock) hook="mv" ;;
      under-lock) hook="ln" ;;
    esac
    real_bin=$(command -v "$hook")
    printf '#!/usr/bin/env bash\nreal_bin=%q\nhook=%q\n' "$real_bin" "$hook" > "$fakebin/$hook"
    cat >> "$fakebin/$hook" <<'SH'
dest=${!#}
inject() {
  [ ! -e "$FM_STATE_OVERRIDE/late-signal-injected" ] || return 0
  [ "$(cat "$FM_STATE_OVERRIDE/.prelude-progress" 2>/dev/null)" = 7 ] || return 0
  printf 'done: finished beside process-event delivery\n' >> "$FM_STATE_OVERRIDE/a.status"
  touch "$FM_STATE_OVERRIDE/late-signal-injected"
}
if [ "$hook" = mv ] && [ "$dest" = "$FM_STATE_OVERRIDE/.prelude-progress" ]; then
  "$real_bin" "$@" || exit
  inject
  exit 0
fi
if [ "$hook" = ln ] && [ "$dest" = "$FM_STATE_OVERRIDE/.wake-queue.lock" ]; then
  inject
fi
exec "$real_bin" "$@"
SH
    chmod 0700 "$fakebin/$hook"
    # The grace is 7s, a value no other watcher sleep uses.
    grace_log="$dir/grace-sleeps"
    real_sleep=$(type -P sleep)
    printf '#!/usr/bin/env bash\nreal_sleep=%q\ngrace_log=%q\n' "$real_sleep" "$grace_log" > "$fakebin/sleep"
    cat >> "$fakebin/sleep" <<'SH'
if [ "$*" = 7 ]; then
  if [ -e "$FM_STATE_OVERRIDE/.wake-queue.lock" ] || [ -L "$FM_STATE_OVERRIDE/.wake-queue.lock" ]; then
    printf 'held\n' >> "$grace_log"
  else
    printf 'free\n' >> "$grace_log"
  fi
fi
exec "$real_sleep" "$@"
SH
    chmod 0700 "$fakebin/sleep"
    watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_WATCH_HANDLING_SUCCESSOR=1 FM_SIGNAL_GRACE=7
    pid=$!
    wait_for_exit "$pid" 600 || { reap "$pid"; fail "$shape process-event wake never exited"; }
    [ -e "$state/late-signal-injected" ] || fail "$shape status line was never appended"
    ! grep -qx held "$grace_log" 2>/dev/null \
      || fail "$shape slept the signal grace while holding the wake-queue lock"
    case "$shape" in
      before-lock)
        [ "$(cat "$grace_log" 2>/dev/null)" = free ] \
          || fail "before-lock did not linger once outside the queue lock: $(cat "$grace_log" 2>/dev/null)"
        ;;
      under-lock)
        [ ! -e "$grace_log" ] || fail "under-lock lingered on the signal grace: $(cat "$grace_log")"
        ;;
    esac
    [ "$(cat "$out")" = 'check: process-event result captured: procevent:grace-lock:1' ] \
      || fail "$shape emitted the wrong headline: $(cat "$out")"
    awk -F '\t' '$3 == "signal" && $4 == "a.status" { found = 1 } END { exit !found }' "$state/.wake-queue" \
      || fail "$shape status line was not queued as a signal"
    [ ! -e "$state/.wake-queue.lock" ] || fail "$shape process-event wake retained the queue lock"
    next_out="$dir/follow-up.out"
    watch_bg "$state" "$fakebin" "$next_out" env FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_WATCH_HANDLING_SUCCESSOR=1
    pid=$!
    wait_for_exit "$pid" 300 || { reap "$pid"; fail "$shape successor never delivered the signal"; }
    [ "$(cat "$next_out")" = "signal: $state/a.status" ] \
      || fail "$shape successor emitted the wrong headline: $(cat "$next_out")"
  done
  pass "a process-event wake never holds the queue lock across the signal grace and still delivers the signal"
}


# A low-priority wake used to pre-empt the signal scan: an overdue-ledger wake
# exited the cycle first, so a done line waited for one more firstmate round trip.
# The signal wake goes first; the ledger row still surfaces on the next cycle.
test_signal_not_preempted_by_an_overdue_ledger() {
  local dir state fakebin out status_file pid second_out
  dir=$(make_case signal-before-ledger); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; second_out="$dir/watch2.out"; status_file="$state/task.status"
  printf 'working: setup\n' > "$status_file"
  prime_status_seen "$state" "$status_file"
  write_overdue_ledger "$state"
  printf 'done [at=1791490597]: finished behind an overdue ledger\n' >> "$status_file"
  watch_bg "$state" "$fakebin" "$out" env FM_OPEN_LOOPS_INTERVAL=999999
  pid=$!
  wait_for_exit "$pid" 300 || fail "watcher did not exit for a done line behind an overdue ledger"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "an overdue ledger pre-empted the done signal: $(cat "$out")"
  ack_stopped_cycle "$state" || fail "could not acknowledge the signal wake"
  watch_bg "$state" "$fakebin" "$second_out" env FM_OPEN_LOOPS_INTERVAL=999999
  pid=$!
  wait_for_exit "$pid" 300 || fail "the overdue ledger never surfaced after the signal wake"
  grep -F 'check: open-loop-ledger' "$second_out" >/dev/null \
    || fail "the ledger wake did not follow the signal wake: $(cat "$second_out")"
  pass "the signal wake goes first and the overdue ledger surfaces on the next cycle"
}


test_cycle_work_runs_after_bounded_signal_deferrals() {
  local dir state fakebin status_file pid n out order='' id
  dir=$(make_case bounded-signal-deferral); state="$dir/state"; fakebin="$dir/fakebin"
  status_file="$state/task.status"
  printf 'working: setup\n' > "$status_file"
  prime_status_seen "$state" "$status_file"
  write_overdue_ledger "$state"
  for id in a b; do
    cat > "$state/$id.check.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "$FM_STATE_OVERRIDE/checks-ran"
printf 'maintenance completed\n'
SH
    chmod 0700 "$state/$id.check.sh"
    FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
      || fail "could not register maintenance check $id"
  done
  for n in 1 2 3 4 5 6 7 8; do
    write_overdue_ledger "$state" "lost-launcher-$n"
    if [ "$n" -eq 5 ]; then
      for id in a b; do
        mkdir -p "$dir/mate-$id/state"
        printf 'mate-%s\n' "$id" > "$dir/mate-$id/.fm-secondmate-home"
        printf 'kind=secondmate\nhome=%s\n' "$dir/mate-$id" > "$state/mate-$id.meta"
        printf '100\t7\tcheck\tmaintenance\tcheck: unfinished maintenance\n' > "$dir/mate-$id/state/.wake-queue"
        printf '%s\t100-7\n' "$(( $(date +%s) - 100 ))" > "$state/.secondmate-wake-progress-mate-$id"
      done
    fi
    if [ "$n" -eq 6 ]; then
      append_wake "$state" check procevent:maintenance:captured:1 "check: process-event maintenance completed" \
        || fail "could not queue the process-event fixture"
    fi
    printf 'done [at=%s]: chatty finish %s\n' "$((1791490000 + n))" "$n" >> "$status_file"
    out="$dir/watch-$n.out"
    watch_bg "$state" "$fakebin" "$out" env FM_OPEN_LOOPS_INTERVAL=999999 FM_CHECK_INTERVAL=999999 FM_SECONDMATE_LIVENESS_SECS=1 FM_SECONDMATE_WAKE_STALL_SECS=1
    pid=$!
    wait_for_exit "$pid" 300 || fail "watcher $n did not exit under a chatty fleet: $(cat "$out")"
    case "$(cat "$out")" in
      signal:*) order="$order signal" ;;
      'check: open-loop-ledger'*) order="$order ledger" ;;
      'check: secondmate wake-loop stalled:'*) order="$order stall" ;;
      'check: process-event'*) order="$order procevent" ;;
      *'maintenance completed'*) order="$order checks" ;;
      *) order="$order other" ;;
    esac
    case "$n" in
      4|5|6)
        [ -e "$state/.prelude-deferred" ] && [ -e "$state/.prelude-progress" ] \
          || fail "early wake $n cleared unfinished maintenance debt"
        if [ "$n" -eq 5 ]; then
          for id in a b; do
            grep -F "$(printf 'check\tsecondmate-wake-loop-mate-%s-100-7\t' "$id")" "$state/.wake-queue" >/dev/null \
              || fail "the first stalled mate skipped sibling mate $id"
          done
        fi
        ;;
      7)
        [ -e "$state/.secondmate-liveness-tick" ] || fail "liveness never ran after the ledger wake"
        [ "$(wc -l < "$state/checks-ran" | tr -d '[:space:]')" -eq 2 ] \
          || fail "one actionable check skipped its sibling"
        for id in a b; do
          grep -F "$(printf 'check\t%s\t' "$state/$id.check.sh")" "$state/.wake-queue" >/dev/null \
            || fail "maintenance check $id was not delivered"
        done
        [ ! -e "$state/.prelude-deferred" ] && [ ! -e "$state/.prelude-progress" ] \
          || fail "completed maintenance retained its debt"
        ;;
    esac
    ack_stopped_cycle "$state" || fail "could not acknowledge wake $n"
  done
  [ "$order" = ' signal signal signal ledger stall procevent checks signal' ] \
    || fail "bounded deferral order was:$order"
  pass "maintenance debt survives early wakes until both stalled mates, process-events, and every due check run"
}


# A bad deferral marker must fall back to the previous order, never starve signals
# or hide the cycle's other work.
test_invalid_prelude_deferral_marker_restores_the_previous_order() {
  local dir state fakebin out status_file pid
  dir=$(make_case invalid-deferral-marker); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"
  printf 'working: setup\n' > "$status_file"
  prime_status_seen "$state" "$status_file"
  write_overdue_ledger "$state"
  printf 'not-a-number\n' > "$state/.prelude-deferred"
  printf 'done [at=1791490597]: finished\n' >> "$status_file"
  watch_bg "$state" "$fakebin" "$out" env FM_OPEN_LOOPS_INTERVAL=999999
  pid=$!
  wait_for_exit "$pid" 300 || fail "watcher did not exit with an invalid deferral marker"
  grep -F 'check: open-loop-ledger' "$out" >/dev/null \
    || fail "an invalid deferral marker did not restore the previous order: $(cat "$out")"
  grep -F "$(printf 'signal\ttask.status\t')" "$state/.wake-queue" >/dev/null \
    || fail "an owed ledger wake omitted the pending done signal"
  pass "an invalid deferral marker restores the previous cycle order"
}


# A needs-decision status append surfaced through this actionable signal path
# must skip the Pi supervision branch and reach main directly
# (docs/pi-supervision-branch.md "Autonomy"). The row still
# queues as an ordinary signal-kind wake - fm-branch-dispatch.ts's
# scopeForUnreadWake tells it apart from a routine signal by this payload
# marker, not by kind.
test_needs_decision_signal_payload_marked_for_branch_exclusion() {
  local dir state fakebin out status_file pid
  dir=$(make_case needs-decision-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a needs-decision signal row was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a needs-decision signal row's queued payload is marked needs-decision: for branch exclusion"
}


# A needs-decision whose key transition was rejected by the reserved-key
# vocabulary is reported as a "reconciliation-required: " wrapped event
# (fm-classify-lib.sh's status_span_first_actionable_record), but it is still a
# needs-decision signal that this path routes directly to main - the payload
# marker must not be fooled by that wrapper.
test_needs_decision_reconciliation_required_still_marked() {
  local dir state fakebin out status_file pid
  dir=$(make_case needs-decision-reconciliation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'needs-decision [key=pending-reply-x]: unrelated request\nworking: awaiting reconciliation\n' \
    > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for a rejected-reserved-key needs-decision"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a reconciliation-required needs-decision row was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a reconciliation-required needs-decision row's queued payload is still marked needs-decision:"
}


# A captain-held declaration is itself actionable. Positive evidence that the
# crew is still working must not absorb the signal before its main-only marker
# can be delivered.
test_captain_held_signal_payload_marked_for_branch_exclusion() {
  local dir state fakebin out status_file pid
  dir=$(make_case captain-held-signal-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'captain-held [key=route]: awaiting the captain\n' > "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · still wrapping up'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a captain-held signal while the crew was still working"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "a captain-held signal changed its wake reason: $(cat "$out")"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a captain-held signal was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a captain-held signal stays actionable while the crew is still working"
}


test_pending_reply_escalation_signal_payload_marked_for_branch_exclusion() {
  local dir state fakebin out status_file pid corr
  dir=$(make_case pending-reply-escalation-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  corr=0123456789abcdef
  printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=task pending-reply-id=%s request=finish report\n' \
    "$corr" "$corr" > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for a pending-reply escalation"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a pending-reply escalation was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a pending-reply second-mate escalation is marked for main-only routing"
}


test_ordinary_blocked_signal_payload_remains_branch_eligible() {
  local dir state fakebin out status_file pid
  dir=$(make_case ordinary-blocked-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'blocked [key=dependency]: waiting for an upstream release\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an ordinary blocked event"
  grep -F "$(printf 'signal\ttask.status\tsignal:')" "$state/.wake-queue" >/dev/null \
    || fail "an ordinary blocked event lost branch-eligible routing: $(cat "$state/.wake-queue")"
  if grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null; then
    fail "an ordinary blocked event was marked as a second-mate escalation"
  fi
  pass "an ordinary blocked event remains branch-eligible"
}


# A routine (non-needs-decision) captain-relevant event must keep its ordinary
# payload: only a genuine needs-decision gets the exclusion marker.
test_routine_signal_payload_not_marked_needs_decision() {
  local dir state fakebin out status_file pid
  dir=$(make_case routine-signal-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: setup\ndone: migration complete ; needs-decision: documented in follow-up\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an actionable done signal"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    && fail "a routine done signal was incorrectly payload-marked needs-decision: $(cat "$state/.wake-queue")"
  grep -F "$(printf 'signal\ttask.status\tsignal:')" "$state/.wake-queue" >/dev/null \
    || fail "a routine signal lost its ordinary payload: $(cat "$state/.wake-queue")"
  pass "a routine event containing a needs-decision phrase keeps its ordinary payload, unmarked"
}


# The reported bug, end to end through a real watcher: a crew reports something
# the captain must act on and then keeps appending routine progress, which is
# ordinary while the watcher lingers its signal grace window to coalesce a status
# write with the same turn's turn-end. Classifying only the last line reads the
# batch as routine, and because the crew IS provably working the no-verb fallback
# absorbs it too - the .seen-* suppressor then advances and nothing ever re-reads
# the event, so the work stalls with the captain never told.
test_actionable_signal_survives_a_later_routine_append() {
  local dir state fakebin out drain_out status_file sig pid
  dir=$(make_case actionable-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  # Everything through "working: setup" was already classified, so this asserts
  # the newly appended span, not merely a whole-file re-read.
  printf 'working: setup\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'needs-decision: pick A or B\nworking: still tidying the branch\n' >> "$status_file"
  # Positive evidence the crew is still working, so the no-verb fallback cannot
  # rescue the wake: only reading the event itself can surface it.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "watcher absorbed a needs-decision hidden behind a later working: line"; }
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the masked signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "the masked actionable signal was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a captain event hidden behind a later routine append is still surfaced (queue + exit)"
}


# A status log only grows: a remote second mate's mirrored parent channel passes a
# megabyte and thousands of keyed decisions. Deciding whether a newly appended
# keyed decision is still open must cost the new span, not the log's lifetime.
# Re-folding the whole log on every such signal made one poll take minutes on a
# main home, so its liveness beacon aged past the guard's grace. Every read this
# classification makes goes through the span-reader seam, so recording those
# reads pins the bound independently of machine speed.
test_keyed_decision_signal_reads_only_the_new_span() {
  local dir state fakebin out status_file reader reads sig prior appended i pid start length
  dir=$(make_case keyed-span-bound); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; reads="$dir/span-reads"; reader="$dir/recording-span-reader"
  status_file="$state/task.status"
  i=0
  while [ "$i" -lt 60 ]; do
    i=$((i + 1))
    printf 'needs-decision [key=q%s]: choose option %s\nresolved [key=q%s]: took the first option\n' "$i" "$i" "$i"
  done > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  prior=$(size_of "$status_file")
  printf 'needs-decision [key=fresh]: pick the rollout window\nworking: preparing both windows\n' >> "$status_file"
  appended=$(( $(size_of "$status_file") - prior ))
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$2" "$3" >> "$FM_TEST_SPAN_READS"
exec perl -e 'open my $f, "<", $ARGV[0] or exit 1; seek $f, $ARGV[1], 0 or exit 1; defined(read $f, my $b, $ARGV[2]) or exit 1; print $b or exit 1' "$1" "$2" "$3"
SH
  chmod +x "$reader"
  export FM_STATUS_SPAN_READER="$reader" FM_TEST_SPAN_READS="$reads"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "watcher did not surface a keyed decision appended to a long decision history"; }
  unset FM_STATUS_SPAN_READER FM_TEST_SPAN_READS
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "the still-open keyed decision was not queued as a needs-decision: $(cat "$state/.wake-queue")"
  [ -s "$reads" ] || fail "the classification made no read through the span reader, so the bound was not exercised"
  while IFS=$(printf '\t') read -r start length; do
    [ "$start" -ge "$prior" ] && [ "$length" -le "$appended" ] \
      || fail "classifying a ${appended}-byte span read ${length} bytes from offset ${start} of a ${prior}-byte history"
  done < "$reads"
  pass "a keyed decision signal reads only the newly appended span, not the whole log"
}


# The captain-reported completion shape of the same masking, end to end.
test_release_completion_survives_a_later_routine_append() {
  local dir state fakebin out drain_out status_file sig pid
  dir=$(make_case release-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: publishing\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'done: release 1.4.0 published and installed\nworking: cleaning the build dir\n' >> "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "watcher absorbed a release/install completion hidden behind later cleanup chatter"; }
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the masked completion failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "the masked completion was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a finished release reported before routine cleanup chatter is still surfaced"
}


# The other direction: the fix must not turn ordinary progress into wakes.
test_routine_appends_after_a_classified_event_stay_absorbed() {
  local dir state fakebin out status_file sig pid
  dir=$(make_case actionable-classified); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  # The decision is BEHIND the classified position, so only the new routine line
  # is in the span. A supervisor that re-read the whole log would wake again here.
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'working: still tidying the branch\n' >> "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher re-surfaced a decision it had already classified: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a routine append after a classified decision enqueued a wake"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a routine append after an already-classified event is absorbed (no re-wake)"
}


test_unreadable_status_reports_once_per_file_state() {
  local dir state fakebin out status_file target marker sig pid
  dir=$(make_case unreadable-status); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"; target="$dir/missing-status-target"
  ln -s "$target" "$status_file"
  marker="$state/.seen-task_status"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a dangling status symlink was not reported"; }
  grep -Fx "signal: $status_file" "$out" >/dev/null \
    || fail "a dangling status symlink did not use the immediate signal path: $(cat "$out")"
  sig=$(status_observed_signature "$status_file")
  status_presentation_marker_reported_matches "$marker" "$sig" \
    || fail "the unreadable status report did not advance its wake signature"
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || fail "the unreadable status report advanced its classification position"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first unreadable-status wake"
  touch "$state/.last-check" "$state/.last-heartbeat"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "an unchanged unreadable status reported again after restart: $(cat "$out")"; }
  reap "$pid"

  printf 'blocked: changed target state with a longer path\n' > "$dir/status-target-two-longer"
  ln -snf "$dir/status-target-two-longer" "$status_file"
  target="$dir/status-target-two-longer"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a changed unreadable status did not report again"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || fail "a changed unreadable status advanced its classification position"
  ack_stopped_cycle "$state" || fail "could not acknowledge the changed unreadable-status wake"

  rm -f "$status_file"
  cp "$target" "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a readable replacement did not surface preserved content"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = "$(size_of "$status_file")" ] \
    || fail "readable recovery did not classify content written before the failure"
  pass "unreadable status reports are bounded without advancing classification"
}


test_permission_recovery_surfaces_preserved_status() {
  local dir state fakebin out status_file marker before_ident after_ident pid
  dir=$(make_case permission-recovery); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"; marker="$state/.seen-task_status"
  printf 'blocked: release approval required\nworking: preserving context\n' > "$status_file"
  before_ident=$(_fm_open_decisions_file_ident "$status_file")
  chmod 000 "$status_file"
  if [ -r "$status_file" ]; then
    chmod 600 "$status_file"
    pass "permission recovery skipped because permissions cannot deny reads"
    return
  fi

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; chmod 600 "$status_file"; fail "an unreadable regular status was not reported"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || { chmod 600 "$status_file"; fail "an unreadable regular status advanced its classification position"; }
  ack_stopped_cycle "$state" || { chmod 600 "$status_file"; fail "could not acknowledge the unreadable regular-status wake"; }
  touch "$state/.last-check" "$state/.last-heartbeat"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; chmod 600 "$status_file"; fail "an unchanged unreadable regular status reported again"; }

  chmod 600 "$status_file"
  after_ident=$(_fm_open_decisions_file_ident "$status_file")
  [ "$after_ident" = "$before_ident" ] || { reap "$pid"; fail "the permission-only recovery changed file identity"; }
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "readability recovery did not surface preserved content"; }
  grep -Fx "signal: $status_file" "$out" >/dev/null \
    || fail "readability recovery did not use the actionable signal path: $(cat "$out")"
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = "$(size_of "$status_file")" ] \
    || fail "readability recovery did not classify from the unadvanced position"
  pass "permission recovery surfaces content from the unadvanced position"
}

test_working_note_not_working_surfaced
test_secondmate_status_note_surfaced_despite_busy_agent
test_secondmate_routine_progress_absorbed_then_note_surfaced
test_secondmate_buried_block_wakes_despite_busy_agent
test_self_announced_close_does_not_rewake_but_next_note_does
test_self_announced_close_after_open_decisions_fold_does_not_rewake
test_folded_worker_decision_without_home_append_still_wakes
test_separate_self_announced_answers_after_fold_wake_once
test_self_announced_close_after_fold_still_surfaces_folded_worker_failure
test_self_announced_close_after_fold_still_surfaces_folded_secondmate_lines
test_actionable_signal_surfaced
test_done_and_keyed_lines_surface_between_and_during_cycles
test_signal_not_held_behind_a_blocked_check
test_flushed_signals_preserve_main_owned_routing
test_heartbeat_late_signal_retains_fleet_scope
test_late_signal_follow_up_filters_drained_rows
test_late_signal_output_failure_retries
test_late_signal_marker_failure_before_procevent
test_procevent_wake_never_lingers_under_the_queue_lock
test_signal_not_preempted_by_an_overdue_ledger
test_cycle_work_runs_after_bounded_signal_deferrals
test_invalid_prelude_deferral_marker_restores_the_previous_order
test_needs_decision_signal_payload_marked_for_branch_exclusion
test_needs_decision_reconciliation_required_still_marked
test_captain_held_signal_payload_marked_for_branch_exclusion
test_pending_reply_escalation_signal_payload_marked_for_branch_exclusion
test_ordinary_blocked_signal_payload_remains_branch_eligible
test_routine_signal_payload_not_marked_needs_decision
test_actionable_signal_survives_a_later_routine_append
test_keyed_decision_signal_reads_only_the_new_span
test_release_completion_survives_a_later_routine_append
test_routine_appends_after_a_classified_event_stay_absorbed
test_unreadable_status_reports_once_per_file_state
test_permission_recovery_surfaces_preserved_status
