#!/usr/bin/env bash
# fm-home-summary-refresh.sh - publish this home's structured summary ledger.
#
# Usage: fm-home-summary-refresh.sh [--best-effort | --detach]
#
# The published state/home-summary.json is the exact
# `fm-fleet-snapshot.sh --secondmate-home-summary` document for this FM_HOME.
# Its schema remains `fm-secondmate-home-summary.v1`, declares the current hold
# classifier contract, and includes both the existing generated timestamp and
# generated_epoch for freshness arithmetic.
#
# Publication is atomic: the producer writes and validates a unique mode-0600
# temporary file on the state directory's filesystem, then renames it over the
# ledger. A directory at the ledger path is rejected rather than treated as a
# successful publication into that directory. After a failed, interrupted, or
# killed refresh, an existing ledger remains complete, never torn output.
# A home-local refresh lock serializes concurrent triggers so an older in-flight
# summary cannot overwrite one computed after a later status change. The deadline
# owner retains the lock through publication and streak reset or failure accounting.
# The existing lock's steal mutex fences handoff, pending-marker consumption,
# publication, streak changes, wake appends, and release against stale-owner recovery;
# each critical section checks parent liveness and ownership while holding it.
# The shared timeout owner bounds state initialization, lock acquisition, validation,
# and publication with FM_HOME_SUMMARY_TIMEOUT (default 60 seconds).
# Failure logging, streak accounting, and owner-checked release have independent
# deadlines of 4, 10, and 4 seconds, so logging failure cannot skip the latter two.
# No reader can observe temporary output through the ledger path.
#
# With --best-effort, a failure is appended to the bounded home-local
# state/.home-summary-refresh.log when available, with stderr as the bounded
# fallback, and the command exits zero. Without it, failures are printed and
# returned to the direct caller for tests and diagnostics.
#
# With --detach, the command starts a best-effort refresh in its own detached
# process group and returns at once. Session start, spawn, and teardown use it:
# they publish only as a side effect, so none of them may wait for the summary
# to be computed. A detached refresh is single-flight (it takes the refresh lock
# only when free, so triggers never pile up behind a slow run). Every trigger
# first writes state/.home-summary-refresh.pending and the run that takes the
# lock clears it. After a successful attempt, its parent starts another refresh
# if a newer trigger left the marker behind, repeating until no marker remains;
# a burst of triggers therefore converges without a fixed follow-up cap.
#
# In best-effort mode, state/.home-summary-refresh.streak counts consecutive
# failures of attempts that acquired the refresh lock; the first successful
# publication clears it. Initialization and lock-contention failures are logged
# but cannot alter the streak without ownership; skipped detached contenders
# are not failures. Three acquired failures raise one `check: home-summary-refresh`
# wake naming the reason, the streak start, and how long the failed attempt ran.
# This threshold is fixed. A wake repeats only when the failure class changes
# or after a success ends the streak; home_summary_note_failure owns classification.
# Regression coverage: tests/fm-home-summary-refresh.test.sh and
# tests/fm-home-summary-refresh-ownership.test.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
LEDGER="$STATE/home-summary.json"
ERROR_LOG="$STATE/.home-summary-refresh.log"
REFRESH_LOCK="$STATE/.home-summary-refresh.lock"
PENDING_MARK="$STATE/.home-summary-refresh.pending"
STREAK_FILE="$STATE/.home-summary-refresh.streak"
ERROR_LOG_MAX_BYTES=${FM_HOME_SUMMARY_ERROR_LOG_MAX_BYTES:-65536}
HOME_SUMMARY_TIMEOUT=${FM_HOME_SUMMARY_TIMEOUT:-60}
HOME_SUMMARY_IF_IDLE=${FM_HOME_SUMMARY_IF_IDLE:-0}
BEST_EFFORT=0
DETACH=0
HOME_SUMMARY_MODE=parent
HOME_SUMMARY_ERROR=
HOME_SUMMARY_FAILURE_STAMP=
HOME_SUMMARY_TMP=
HOME_SUMMARY_ERR_TMP=
HOME_SUMMARY_LOCK_HELD=0
HOME_SUMMARY_FENCE_HELD=0
HOME_SUMMARY_SKIPPED_STATUS=75

# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  '') ;;
  --best-effort) BEST_EFFORT=1 ;;
  --detach) BEST_EFFORT=1; DETACH=1 ;;
  --_worker)
    HOME_SUMMARY_MODE=worker
    BEST_EFFORT=${FM_HOME_SUMMARY_WORKER_BEST_EFFORT:-0}
    ;;
  --_log-failure) HOME_SUMMARY_MODE=log-failure ;;
  --_note-failure) HOME_SUMMARY_MODE='note-failure' ;;
  --_release-lock) HOME_SUMMARY_MODE=release-lock ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
case "$ERROR_LOG_MAX_BYTES" in
  ''|*[!0-9]*|0) ERROR_LOG_MAX_BYTES=65536 ;;
esac
case "$HOME_SUMMARY_TIMEOUT" in
  ''|*[!0-9]*|0) HOME_SUMMARY_TIMEOUT=60 ;;
esac
case "$HOME_SUMMARY_IF_IDLE" in
  0|1) ;;
  *) HOME_SUMMARY_IF_IDLE=0 ;;
esac

if [ "$HOME_SUMMARY_MODE" != parent ]; then
  # shellcheck source=bin/fm-wake-lib.sh
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"
fi

# shellcheck disable=SC2329 # Invoked by the signal and EXIT traps below.
home_summary_cleanup() {
  [ -z "$HOME_SUMMARY_TMP" ] || rm -f -- "$HOME_SUMMARY_TMP" 2>/dev/null || true
  [ -z "$HOME_SUMMARY_ERR_TMP" ] || rm -f -- "$HOME_SUMMARY_ERR_TMP" 2>/dev/null || true
  if [ "$HOME_SUMMARY_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$REFRESH_LOCK" || true
    HOME_SUMMARY_LOCK_HELD=0
  fi
  home_summary_unfence
}

home_summary_fail() {
  HOME_SUMMARY_ERROR=$1
  return 1
}

home_summary_refresh_once() {
  local producer_rc producer_error worker_pid
  if ! mkdir -p "$STATE" 2>/dev/null; then
    home_summary_fail "state directory is unavailable: $STATE"
    return 1
  fi
  trap home_summary_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ "$HOME_SUMMARY_IF_IDLE" -eq 1 ]; then
    # The marker is written before the try so a trigger that loses the race to
    # an in-flight run is seen by that run's parent when it finishes.
    : > "$PENDING_MARK" 2>/dev/null || true
    fm_lock_try_acquire "$REFRESH_LOCK" || return "$HOME_SUMMARY_SKIPPED_STATUS"
  else
    fm_lock_acquire_wait "$REFRESH_LOCK" || return 1
  fi
  HOME_SUMMARY_LOCK_HELD=1
  fm_current_pid worker_pid || return 1
  home_summary_fence "$worker_pid" || return 1
  if ! printf '%s\n' "$FM_HOME_SUMMARY_PARENT_PID" > "$REFRESH_LOCK/pid" 2>/dev/null; then
    home_summary_fail "could not hand the refresh lock to its timeout owner"
    return 1
  fi
  HOME_SUMMARY_LOCK_HELD=0
  rm -f -- "$PENDING_MARK" 2>/dev/null || true
  home_summary_unfence
  HOME_SUMMARY_TMP=$(umask 077; mktemp "$STATE/.home-summary.json.XXXXXX") || {
    home_summary_fail "could not create an atomic publication file in $STATE"
    return 1
  }
  HOME_SUMMARY_ERR_TMP=$(umask 077; mktemp "$STATE/.home-summary-error.XXXXXX") || {
    home_summary_fail "could not create a producer diagnostic file in $STATE"
    return 1
  }

  if env \
    FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" \
    FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$CONFIG" \
    FM_PROJECTS_OVERRIDE="$PROJECTS" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary \
      > "$HOME_SUMMARY_TMP" 2> "$HOME_SUMMARY_ERR_TMP"; then
    producer_rc=0
  else
    producer_rc=$?
  fi
  if [ "$producer_rc" -ne 0 ]; then
    producer_error=$(tail -n 1 "$HOME_SUMMARY_ERR_TMP" 2>/dev/null \
      | tr '\t\r\n' '   ' | cut -c1-500)
    if [ -n "$producer_error" ]; then
      home_summary_fail "summary producer failed with exit $producer_rc: $producer_error"
    else
      home_summary_fail "summary producer failed with exit $producer_rc"
    fi
    return 1
  fi
  rm -f -- "$HOME_SUMMARY_ERR_TMP"
  HOME_SUMMARY_ERR_TMP=
  if ! jq -e --arg home "$FM_HOME" '
    .schema == "fm-secondmate-home-summary.v1"
    and .hold_classifier_schema == "fm-captain-hold-buckets.v1"
    and .home == $home
    and (.generated | type) == "string"
    and (.generated | length) > 0
    and (.generated_epoch | type) == "number"
    and .generated_epoch >= 0
    and (.generated_epoch | floor) == .generated_epoch
    and (.valid | type) == "boolean"
    and (.state | type) == "string"
    and (.invalidity | type) == "object"
    and (.active_children | type) == "array"
    and (.decisions_open | type) == "array"
    and (.holds | type) == "array"
    and (.queued | type) == "array"
    and (.landed | type) == "array"
    and (.endpoints | type) == "array"
    and (.counts | type) == "object"
    and (.omitted | type) == "array"
  ' "$HOME_SUMMARY_TMP" >/dev/null 2>&1; then
    home_summary_fail "summary producer returned a malformed ledger document"
    return 1
  fi
  if ! chmod 600 "$HOME_SUMMARY_TMP" 2>/dev/null; then
    home_summary_fail "could not set the publication file mode"
    return 1
  fi
  home_summary_fence || return 1
  if [ -d "$LEDGER" ]; then
    home_summary_fail "atomic ledger replacement failed: destination is a directory: $LEDGER"
    return 1
  fi
  if ! mv -f -- "$HOME_SUMMARY_TMP" "$LEDGER" 2>/dev/null; then
    home_summary_fail "atomic ledger replacement failed: $LEDGER"
    return 1
  fi
  HOME_SUMMARY_TMP=
  rm -f -- "$STREAK_FILE" 2>/dev/null || true
  home_summary_unfence
  trap - EXIT HUP INT TERM
  return 0
}

home_summary_write_streak() {  # <tmp> <count> <first> <class> <escalated>
  if printf 'count=%s\nfirst=%s\nclass=%s\nescalated=%s\n' "$2" "$3" "$4" "$5" > "$1" 2>/dev/null \
    && mv -f -- "$1" "$STREAK_FILE" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$1" 2>/dev/null || true
  return 1
}

# Count one more consecutive failure and, on reaching the threshold, wake
# firstmate once per failure class. The class is the reason with its digits
# removed, so a changed deadline or exit code stays one class while a different
# reason is a real change that earns a new wake. The streak file holds
# count=, first= (stamp of the first failure), class=, and escalated= (the class
# already woken for). It is cleared by the first successful publication.
home_summary_note_failure() {  # <reason> <stamp> <seconds-the-attempt-ran>
  local reason=$1 stamp=$2 seconds=${3:-0} count=0 first='' class escalated='' key value payload tmp
  class=$(printf '%s' "$reason" | tr -d '0-9' | cut -c1-80)
  if [ -f "$STREAK_FILE" ] && [ ! -L "$STREAK_FILE" ]; then
    while IFS='=' read -r key value; do
      case "$key" in
        count) count=$value ;;
        first) first=$value ;;
        escalated) escalated=$value ;;
      esac
    done < "$STREAK_FILE" 2>/dev/null
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  [ -n "$first" ] || first=$stamp
  tmp="$STREAK_FILE.tmp.${BASHPID:-$$}"
  home_summary_write_streak "$tmp" "$count" "$first" "$class" "$escalated" || return 0
  [ "$count" -ge 3 ] || return 0
  [ "$escalated" != "$class" ] || return 0
  payload="check: home-summary-refresh: $count consecutive refresh failures since $first; last: $reason (the failed attempt ran ${seconds}s). state/home-summary.json is not being republished; reproduce with bin/fm-home-summary-refresh.sh and read state/.home-summary-refresh.log"
  fm_wake_append check home-summary-refresh "$payload" || return 0
  home_summary_write_streak "$tmp" "$count" "$first" "$class" "$class" || true
  return 0
}

home_summary_log_failure() {
  local size stamp tmp
  stamp=$HOME_SUMMARY_FAILURE_STAMP
  [ -n "$stamp" ] || stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! printf '[%s] %s\n' "$stamp" "$HOME_SUMMARY_ERROR" >> "$ERROR_LOG" 2>/dev/null; then
    printf 'fm-home-summary-refresh: %s\n' "$HOME_SUMMARY_ERROR" >&2
    return 0
  fi
  size=$(wc -c < "$ERROR_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ "$size" -ge "$ERROR_LOG_MAX_BYTES" ]; then
    tmp="$ERROR_LOG.tmp.${BASHPID:-$$}"
    tail -n 200 "$ERROR_LOG" > "$tmp" 2>/dev/null \
      && mv -f -- "$tmp" "$ERROR_LOG" 2>/dev/null
    rm -f -- "$tmp" 2>/dev/null || true
  fi
}

home_summary_unfence() {
  if [ "$HOME_SUMMARY_FENCE_HELD" -eq 1 ]; then
    fm_lock_release "$REFRESH_LOCK.steal" || true
    HOME_SUMMARY_FENCE_HELD=0
  fi
}

home_summary_fence() {
  local parent_pid=${FM_HOME_SUMMARY_PARENT_PID:-} owner_pid=${1:-${FM_HOME_SUMMARY_PARENT_PID:-}}
  case "$parent_pid" in ''|*[!0-9]*|0) return 1 ;; esac
  while ! fm_lock_try_acquire_steal_mutex "$REFRESH_LOCK.steal"; do
    sleep 0.1
  done
  HOME_SUMMARY_FENCE_HELD=1
  if ! fm_pid_alive "$parent_pid" \
    || [ "$(cat "$REFRESH_LOCK/pid" 2>/dev/null)" != "$owner_pid" ]; then
    home_summary_unfence
    home_summary_fail "refresh lock ownership was lost"
    return 1
  fi
}

home_summary_release_parent_lock() {
  fm_run_timed 4 env FM_HOME_SUMMARY_PARENT_PID="$$" \
    "$SCRIPT_DIR/fm-home-summary-refresh.sh" --_release-lock >/dev/null 2>&1
}

if [ "$HOME_SUMMARY_MODE" = log-failure ]; then
  HOME_SUMMARY_ERROR=${FM_HOME_SUMMARY_PARENT_ERROR:-"refresh worker failed"}
  HOME_SUMMARY_FAILURE_STAMP=${FM_HOME_SUMMARY_PARENT_STAMP:-}
  home_summary_log_failure
  exit 0
fi

if [ "$HOME_SUMMARY_MODE" = note-failure ]; then
  trap home_summary_cleanup EXIT
  trap 'exit 143' HUP INT TERM
  home_summary_fence || exit 0
  home_summary_note_failure "${FM_HOME_SUMMARY_PARENT_ERROR:-refresh worker failed}" \
    "${FM_HOME_SUMMARY_PARENT_STAMP:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
    "${FM_HOME_SUMMARY_PARENT_SECONDS:-0}"
  exit 0
fi

if [ "$HOME_SUMMARY_MODE" = release-lock ]; then
  trap home_summary_cleanup EXIT
  trap 'exit 143' HUP INT TERM
  home_summary_fence || exit 0
  fm_lock_remove_path "$REFRESH_LOCK"
  exit "$?"
fi

if [ "$HOME_SUMMARY_MODE" = parent ]; then
  if [ "$DETACH" -eq 1 ]; then
    # Detached three ways, as bin/fm-startup-network.sh detaches its worker:
    # stdio to /dev/null so no caller's pipe is held open, nohup so the refresh
    # outlives the shell that launched it, and its own process group so the
    # bounded child that runs session start cannot take it down with it.
    case $- in *m*) monitor_was_on=1 ;; *) monitor_was_on=0 ;; esac
    set -m 2>/dev/null || true
    FM_HOME_SUMMARY_IF_IDLE=1 nohup "$SCRIPT_DIR/fm-home-summary-refresh.sh" --best-effort \
      >/dev/null 2>&1 </dev/null &
    [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
    exit 0
  fi
  while :; do
    attempt_stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || attempt_stamp=
    attempt_start=$SECONDS
    if worker_error=$(fm_run_timed "$HOME_SUMMARY_TIMEOUT" env \
      FM_HOME_SUMMARY_PARENT_PID="$$" \
      FM_HOME_SUMMARY_WORKER_BEST_EFFORT="$BEST_EFFORT" \
      FM_HOME_SUMMARY_IF_IDLE="$HOME_SUMMARY_IF_IDLE" \
      "$SCRIPT_DIR/fm-home-summary-refresh.sh" --_worker); then
      home_summary_release_parent_lock || exit 0
      # A trigger that found this run in flight left its marker behind. Refresh
      # once more so the published summary is not older than that trigger.
      if [ -e "$PENDING_MARK" ]; then
        HOME_SUMMARY_IF_IDLE=1
        continue
      fi
      exit 0
    else
      refresh_rc=$?
    fi
    [ "$refresh_rc" -ne "$HOME_SUMMARY_SKIPPED_STATUS" ] || exit 0
    break
  done
  if [ "$BEST_EFFORT" -eq 1 ]; then
    if [ "$refresh_rc" -eq 124 ]; then
      parent_error="refresh exceeded its ${HOME_SUMMARY_TIMEOUT}-second deadline"
    elif [ -n "$worker_error" ]; then
      parent_error=$worker_error
    else
      parent_error="refresh worker failed with exit $refresh_rc"
    fi
    attempt_seconds=$((SECONDS - attempt_start))
    fm_run_timed 4 env \
      FM_HOME_SUMMARY_PARENT_ERROR="$parent_error" \
      FM_HOME_SUMMARY_PARENT_STAMP="$attempt_stamp" \
      "$SCRIPT_DIR/fm-home-summary-refresh.sh" --_log-failure >/dev/null || true
    fm_run_timed 10 env \
      FM_HOME_SUMMARY_PARENT_ERROR="$parent_error" \
      FM_HOME_SUMMARY_PARENT_STAMP="$attempt_stamp" \
      FM_HOME_SUMMARY_PARENT_SECONDS="$attempt_seconds" \
      FM_HOME_SUMMARY_PARENT_PID="$$" \
      "$SCRIPT_DIR/fm-home-summary-refresh.sh" --_note-failure >/dev/null || true
    home_summary_release_parent_lock || true
    exit 0
  fi
  home_summary_release_parent_lock || true
  if [ "$refresh_rc" -eq 124 ]; then
    printf 'fm-home-summary-refresh: refresh exceeded its %s-second deadline\n' \
      "$HOME_SUMMARY_TIMEOUT" >&2
  fi
  exit "$refresh_rc"
fi

if home_summary_refresh_once; then
  exit 0
else
  refresh_rc=$?
fi
# Another refresh holds the lock and will see this trigger's marker: not a failure.
[ "$refresh_rc" -ne "$HOME_SUMMARY_SKIPPED_STATUS" ] || exit "$HOME_SUMMARY_SKIPPED_STATUS"
if [ "$BEST_EFFORT" -eq 1 ]; then
  printf '%s\n' "$HOME_SUMMARY_ERROR"
  exit "$refresh_rc"
fi
printf 'fm-home-summary-refresh: %s\n' "$HOME_SUMMARY_ERROR" >&2
exit "$refresh_rc"
