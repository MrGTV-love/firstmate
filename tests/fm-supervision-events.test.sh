#!/usr/bin/env bash
# tests/fm-supervision-events.test.sh - unit tests for the watcher's native
# event-wait splice (event_wait_or_sleep in bin/fm-watch.sh and
# handle_push_transition in bin/fm-push-transition-lib.sh). The watcher's source
# guard lets this file source it to load
# the functions WITHOUT acquiring the singleton lock or entering the blocking
# loop; wake/sleep and the backend dispatchers are overridden so the exemptions,
# capability memo, and fail-closed disable are asserted deterministically with no
# real herdr, watcher process, or blocking sleeps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-supervision-events)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

# Source the watcher with an isolated state/home. The guard returns before the
# lock/loop, so only the functions load.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# Production modules are independently linted canonical roots. Keep this test's
# ShellCheck context local while preserving its unchanged runtime source path.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

# Overrides: capture wake reasons and neutralize real sleeps (POLL is 15s).
WAKE_LOG="$TMP/wakes"
SLEEP_LOG="$TMP/sleeps"
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status "$STATE_DIR"/.wake-queue \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log \
    "$STATE_DIR"/.herdr-escalated-* "$TMP"/panes "$TMP"/wtcalls "$TMP"/wtcalled 2>/dev/null || true
  : > "$WAKE_LOG"
  : > "$SLEEP_LOG"
  _event_cap_key=""
  _event_cap_ok=0
  _event_cap_fails=0
}

mkrec() {  # <pane_id> <status>
  fm_transition_record "$1" "wG" "" "$2" claude
}

# --- handle_push_transition: enqueue + wake for a non-paused blocked crew -----

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
[ -e "$STATE_DIR/.wake-queue" ] || fail "handle_push_transition should enqueue a wake for a blocked crew"
grep -q 'stale' "$STATE_DIR/.wake-queue" || fail "the enqueued wake must be a stale record: $(cat "$STATE_DIR/.wake-queue")"
grep -q 'default:wG:pQ' "$STATE_DIR/.wake-queue" || fail "the stale record must name the crew's window"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
[ -s "$WAKE_LOG" ] || fail "handle_push_transition must wake the supervisor for a blocked crew"
[ -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "handle_push_transition must commit dedupe only after enqueue"
pass "handle_push_transition: a blocked crew enqueues a stale wake naming its window and wakes the supervisor"

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
(
  # shellcheck disable=SC2329 # Runtime override called by the isolated production owner.
  fm_wake_append() { return 1; }
  handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
) >/dev/null 2>&1 || true
[ ! -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "a failed durable enqueue must leave the blocked edge eligible for reconnect reconciliation"
pass "handle_push_transition: enqueue failure cannot commit the Herdr dedupe marker"

# --- handle_push_transition: absorb (no wake, no enqueue) for a declared pause -

reset_state
fm_write_meta "$STATE_DIR/tk2.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
printf 'paused: waiting on the upstream release\n' > "$STATE_DIR/tk2.status"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
if [ -e "$STATE_DIR/.wake-queue" ] && grep -q 'stale' "$STATE_DIR/.wake-queue"; then
  fail "a declared-pause crew must NOT be fast-escalated: $(cat "$STATE_DIR/.wake-queue")"
fi
[ ! -s "$WAKE_LOG" ] || fail "a declared-pause crew must not wake the supervisor from the event fast-path"
grep -q 'absorbed push' "$STATE_DIR/.watch-triage.log" 2>/dev/null || fail "the paused absorb should be logged to the triage log"
pass "handle_push_transition: a declared-pause crew is absorbed (no fast wake), left to the poll loop's long cadence"

# --- handle_push_transition: absorb for a verified captain-held transfer -------

reset_state
fm_write_meta "$STATE_DIR/tk2h.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$STATE_DIR/tk2h.status"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
if [ -e "$STATE_DIR/.wake-queue" ] && grep -q 'stale' "$STATE_DIR/.wake-queue"; then
  fail "a captain-held crew must NOT be fast-escalated: $(cat "$STATE_DIR/.wake-queue")"
fi
[ ! -s "$WAKE_LOG" ] || fail "a captain-held crew must not wake the supervisor from the event fast-path"
grep -q 'absorbed push' "$STATE_DIR/.watch-triage.log" 2>/dev/null || fail "the captain-held absorb should be logged to the triage log"
pass "handle_push_transition: a captain-held crew is absorbed (no fast wake), left to the poll loop's long cadence"

# --- event_wait_or_sleep: secondmate windows are excluded from the pane list --

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
fm_write_meta "$STATE_DIR/sm1.meta" "window=default:wA:pS" "backend=herdr" "kind=secondmate"
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { shift 4; printf '%s\n' "$*" > "$TMP/panes"; return 1; }
event_wait_or_sleep
PANES=$(cat "$TMP/panes" 2>/dev/null || true)
case "$PANES" in *"default:wG:pQ"*) : ;; *) fail "the ship window must be in the event pane list, got '$PANES'" ;; esac
case "$PANES" in *"default:wA:pS"*) fail "a kind=secondmate window must be EXCLUDED from the event pane list, got '$PANES'" ;; *) : ;; esac
pass "event_wait_or_sleep: herdr windows go on the event pane list, but kind=secondmate endpoints are excluded"

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
CAP_CALLS=0
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { CAP_CALLS=$((CAP_CALLS + 1)); return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() {
  [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" = 1 ] || fail "cached capability verdict was not passed to the wait"
  return 1
}
event_wait_or_sleep
event_wait_or_sleep
[ "$CAP_CALLS" = 1 ] || fail "capability probe must be memoized across waits, got $CAP_CALLS calls"
pass "event_wait_or_sleep: one cached capability probe owns validation across bounded waits"

# --- event_wait_or_sleep: a tmux-only home never runs the event path ----------

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"   # no backend= -> tmux
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_wait_transition() { printf 'CALLED\n' > "$TMP/wtcalled"; return 1; }
event_wait_or_sleep
[ ! -e "$TMP/wtcalled" ] || fail "a tmux-only home must never invoke the event wait path"
grep -q 'SLEEP' "$SLEEP_LOG" || fail "a tmux-only home must sleep POLL exactly as before"
pass "event_wait_or_sleep: a home with no push-capable window is inert (sleeps POLL, never touches the event path)"

# --- event_wait_or_sleep: runtime failures disable the event path (fail-closed)

reset_state
fm_write_meta "$STATE_DIR/tk5.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
export EVENT_CAP_FAIL_MAX=2
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { printf 'WT\n' >> "$TMP/wtcalls"; return 2; }
: > "$TMP/wtcalls"
event_wait_or_sleep   # fails=1
event_wait_or_sleep   # fails=2 -> disable
event_wait_or_sleep   # disabled: sleeps without calling wait_transition
WTN=$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')
[ "$WTN" = 2 ] || fail "after EVENT_CAP_FAIL_MAX connect failures the event path must be disabled for the process (expected 2 wait_transition calls, got $WTN)"
pass "event_wait_or_sleep: consecutive event-path failures disable the fast-path and revert to pure polling (fail-closed)"

(
  command -v jq >/dev/null 2>&1 || fail "reboot inspection regression requires jq"
  RECOVERY_INSPECTION="$TMP/recovery-inspection"
  RECOVERY_INSPECTION_HOME="$RECOVERY_INSPECTION/home"
  RECOVERY_INSPECTION_SESSION="fm-recovery-inspection-$$"
  mkdir -p "$RECOVERY_INSPECTION/bin" "$RECOVERY_INSPECTION/fakebin" \
    "$RECOVERY_INSPECTION_HOME/state" "$RECOVERY_INSPECTION/worktree" "$RECOVERY_INSPECTION/project"
  for RECOVERY_SOURCE in "$ROOT"/bin/*; do
    [ "${RECOVERY_SOURCE##*/}" != fm-control.sh ] || continue
    ln -s "$RECOVERY_SOURCE" "$RECOVERY_INSPECTION/bin/${RECOVERY_SOURCE##*/}"
  done
  cat > "$RECOVERY_INSPECTION/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_RECOVERY_CONTROL_LOG:?}"
exit 99
SH
  cat > "$RECOVERY_INSPECTION/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_RECOVERY_INSPECTION_LOG:?}"
case "$1 ${2:-}" in
  'pane get') printf '%s\n' '{"error":{"code":"read_unavailable"}}' ;;
  'status --json')
    case "${FM_RECOVERY_SERVER_STATE:?}" in
      running) printf '%s\n' '{"server":{"running":true}}' ;;
      unknown) printf '%s\n' '{"server":{}}' ;;
      stopped) printf '%s\n' '{"server":{"running":false}}' ;;
    esac
    ;;
  *) exit 98 ;;
esac
SH
  chmod +x "$RECOVERY_INSPECTION/bin/fm-control.sh" "$RECOVERY_INSPECTION/fakebin/herdr"
  for RECOVERY_ID in unreadable-versioned unreadable-legacy; do
    fm_write_meta "$RECOVERY_INSPECTION_HOME/state/$RECOVERY_ID.meta" \
      "window=$RECOVERY_INSPECTION_SESSION:p1" "backend=herdr" "kind=ship" \
      "worktree=$RECOVERY_INSPECTION/worktree" "project=$RECOVERY_INSPECTION/project" \
      "endpoint_task_id=$RECOVERY_ID" "herdr_session=$RECOVERY_INSPECTION_SESSION" \
      "herdr_workspace_id=w1" "herdr_tab_id=t1" "herdr_pane_id=p1"
    [ "$RECOVERY_ID" != unreadable-versioned ] \
      || printf '%s\n' "launch_proof=env-v1" >> "$RECOVERY_INSPECTION_HOME/state/$RECOVERY_ID.meta"
  done
  for RECOVERY_SERVER_STATE in running unknown stopped; do
    for RECOVERY_MODE in unbounded one; do
      RECOVERY_INSPECTION_LOG="$RECOVERY_INSPECTION/$RECOVERY_SERVER_STATE-$RECOVERY_MODE.log"
      RECOVERY_CONTROL_LOG="$RECOVERY_INSPECTION/$RECOVERY_SERVER_STATE-$RECOVERY_MODE.control"
      RECOVERY_ARGS=(recover)
      [ "$RECOVERY_MODE" != one ] || RECOVERY_ARGS+=(--one)
      RECOVERY_SCAN_RC=0
      RECOVERY_SCAN_OUT=$(PATH="$RECOVERY_INSPECTION/fakebin:$PATH" \
        FM_HOME="$RECOVERY_INSPECTION_HOME" FM_STATE_OVERRIDE="$RECOVERY_INSPECTION_HOME/state" \
        FM_RECOVERY_SERVER_STATE="$RECOVERY_SERVER_STATE" \
        FM_RECOVERY_INSPECTION_LOG="$RECOVERY_INSPECTION_LOG" FM_RECOVERY_CONTROL_LOG="$RECOVERY_CONTROL_LOG" \
        bash "$RECOVERY_INSPECTION/bin/fm-reboot-recover.sh" "${RECOVERY_ARGS[@]}" 2>&1) || RECOVERY_SCAN_RC=$?
      if [ "$RECOVERY_SERVER_STATE" = stopped ]; then
        expect_code 0 "$RECOVERY_SCAN_RC" "$RECOVERY_MODE recovery must leave positively stopped endpoints to liveness recovery"
        [ -z "$RECOVERY_SCAN_OUT" ] || fail "stopped endpoint recovery unexpectedly reported: $RECOVERY_SCAN_OUT"
      else
        expect_code 1 "$RECOVERY_SCAN_RC" "$RECOVERY_SERVER_STATE/$RECOVERY_MODE unreadable inspection must fail"
        for RECOVERY_ID in unreadable-versioned unreadable-legacy; do
          assert_contains "$RECOVERY_SCAN_OUT" \
            "REBOOT_RECOVERY: $RECOVERY_ID: agent state is unreadable; no lifecycle action taken" \
            "$RECOVERY_SERVER_STATE/$RECOVERY_MODE must report the unreadable task $RECOVERY_ID"
        done
      fi
      assert_absent "$RECOVERY_CONTROL_LOG" "$RECOVERY_SERVER_STATE/$RECOVERY_MODE inspection must not call control"
      assert_contains "$(cat "$RECOVERY_INSPECTION_LOG")" \
        "status --json --session $RECOVERY_INSPECTION_SESSION" \
        "$RECOVERY_SERVER_STATE/$RECOVERY_MODE must consult the recorded server's state"
      awk '!(($1 == "pane" && $2 == "get") || ($1 == "status" && $2 == "--json")) { bad = 1 }
        END { exit bad }' "$RECOVERY_INSPECTION_LOG" \
        || fail "$RECOVERY_SERVER_STATE/$RECOVERY_MODE inspection sent a non-read-only backend call"
    done
  done
) || fail "unreadable recovery inspection assertions failed"
pass "reboot recovery: bounded and unbounded unreadable inspections report every task without lifecycle input"

(
  # shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
  fm_run_timed() {
    case "$*" in
      *"fm-reboot-recover.sh recover --one") ;;
      *) fail "unexpected timed recovery boundary: $*" ;;
    esac
    printf '%s\n' recovery >> "$RECOVERY_CALLS"
    touch -t 200001010000 "$STATE_DIR/.reboot-recovery-tick"
    [ "$(age_of "$STATE_DIR/.reboot-recovery-tick")" -ge 60 ] \
      || fail "simulated long recovery command did not exceed the cooldown"
    printf '%s' "$RECOVERY_OUTPUT"
    return "$RECOVERY_RC"
  }
  for RECOVERY_CASE in success failure empty-success empty-failure timeout; do
    reset_state
    rm -f "$STATE_DIR/.reboot-recovery-tick"
    fm_write_meta "$STATE_DIR/recovery.meta" "backend=herdr" "kind=ship"
    RECOVERY_CALLS="$TMP/recovery-calls"
    : > "$RECOVERY_CALLS"
    RECOVERY_RC=0
    RECOVERY_OUTPUT=''
    case "$RECOVERY_CASE" in
      success)
        RECOVERY_OUTPUT=$'unknown: A state unavailable\nrecovered: B launch succeeded\nB continuation\twith detail\rretained'
        ;;
      failure)
        RECOVERY_RC=1
        RECOVERY_OUTPUT=$'unknown: A state unavailable\nfailed: B launch refused\nB continuation\twith detail\rretained'
        ;;
      empty-failure) RECOVERY_RC=1 ;;
      timeout) RECOVERY_RC=124 ;;
    esac
    reboot_recovery_tick || fail "recovery tick failed for $RECOVERY_CASE"
    [ "$(age_of "$STATE_DIR/.reboot-recovery-tick")" -lt 60 ] \
      || fail "$RECOVERY_CASE recovery did not restart its cooldown at completion"
    FM_RECOVERY_CALLS="$RECOVERY_CALLS" bash -c '
      . "$1/bin/fm-watch.sh"
      fm_run_timed() { printf "%s\n" successor-attempt >> "$FM_RECOVERY_CALLS"; return 124; }
      wake() { return 0; }
      reboot_recovery_tick
    ' _ "$ROOT" || fail "$RECOVERY_CASE successor could not observe the recovery cooldown"
    [ "$(wc -l < "$RECOVERY_CALLS" | tr -d '[:space:]')" = 1 ] \
      || fail "$RECOVERY_CASE successor attempted recovery before its completion cooldown"
    if [ "$RECOVERY_CASE" = empty-success ]; then
      [ ! -s "$WAKE_LOG" ] || fail "empty successful recovery must not wake"
      [ ! -e "$STATE_DIR/.wake-queue" ] || fail "empty successful recovery must not enqueue"
      continue
    fi
    EXPECTED_REASON="check: Herdr reboot launch recovery: "
    case "$RECOVERY_CASE" in
      success)
        EXPECTED_REASON="${EXPECTED_REASON}unknown: A state unavailable recovered: B launch succeeded B continuation with detail retained"
        ;;
      failure)
        EXPECTED_REASON="${EXPECTED_REASON}unknown: A state unavailable failed: B launch refused B continuation with detail retained (failed)"
        ;;
      empty-failure|timeout) EXPECTED_REASON="${EXPECTED_REASON} (failed)" ;;
    esac
    [ "$(cat "$WAKE_LOG")" = "$EXPECTED_REASON" ] \
      || fail "immediate $RECOVERY_CASE wake lost recovery output: $(cat "$WAKE_LOG")"
    awk -F '\t' -v expected="$EXPECTED_REASON" '
      NF != 5 || $3 != "check" || $4 !~ /^reboot-launch-recovery-/ || $5 != expected { bad = 1 }
      END { exit !(NR == 1 && !bad) }
    ' "$STATE_DIR/.wake-queue" \
      || fail "durable $RECOVERY_CASE wake must retain all output in one TSV payload: $(cat "$STATE_DIR/.wake-queue")"
  done
  reset_state
  rm -f "$STATE_DIR/.reboot-recovery-tick"
  fm_write_meta "$STATE_DIR/recovery.meta" "backend=herdr" "kind=ship"
  : > "$RECOVERY_CALLS"
  RECOVERY_RC=1
  RECOVERY_OUTPUT='REBOOT_RECOVERY: task-a: failed: launch refused'
  FAILED_REASON="check: Herdr reboot launch recovery: $RECOVERY_OUTPUT (failed)"
  reboot_recovery_tick || fail "failed recovery outcome did not enqueue"
  touch -t 200001010000 "$STATE_DIR/.reboot-recovery-tick"
  RECOVERY_RC=0
  RECOVERY_OUTPUT='REBOOT_RECOVERY: task-b: recovered: launch succeeded'
  SUCCESS_REASON="check: Herdr reboot launch recovery: $RECOVERY_OUTPUT"
  reboot_recovery_tick || fail "successful recovery outcome did not enqueue"
  RETAINED_PAYLOADS=$(fm_wake_print_deduped "$STATE_DIR/.wake-queue" | cut -f5)
  [ "$RETAINED_PAYLOADS" = "$FAILED_REASON"$'\n'"$SUCCESS_REASON" ] \
    || fail "later success replaced an independent queued failure: $RETAINED_PAYLOADS"
  [ "$(fm_wake_queued_keys check | wc -l | tr -d '[:space:]')" = 2 ] \
    || fail "independent recovery attempts reused their durable wake key"
) || fail "recovery wake transport assertions failed"
pass "reboot recovery: independent outcomes survive queue deduplication and every completed attempt cools down its successor"

echo "# fm-supervision-events.test.sh: all assertions passed"
