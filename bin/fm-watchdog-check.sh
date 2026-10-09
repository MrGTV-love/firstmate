#!/usr/bin/env bash
# fm-watchdog-check.sh - one out-of-session liveness check of this home's
# supervision, run on a short interval by the launchd user agent that
# bin/fm-watchdog-install.sh installs. docs/watchdog.md owns the operator
# contract; this header owns the order of one check.
#
# It exists for the failure where the session's own supervision dies with the
# session: the watcher and the Claude Stop-hook arm both gone, no rewake ever
# reaches the idle session, and nothing inside the session can notice. Only a
# process outside the session survives that.
#
# Usage: fm-watchdog-check.sh [--help]
#
# One check reads this home's existing evidence through bin/fm-wake-lib.sh and
# bin/fm-supervision-lib.sh and reaches exactly one verdict:
#
#   idle              no supervision is needed (fm_supervision_status), or the
#                     evidence directory is absent. Nothing to do.
#   healthy           fm_watcher_supervision_verdict accepts supervision, and
#                     the watchdog freshness policy in docs/watchdog.md holds.
#   session-missing   supervision is needed and the session lock names no live
#                     harness process (fm_harness_pid_alive).
#   dead-arm-owner    the session is live, the Claude auto-arm ledger still
#                     says outcome=arming, its owner pid is dead, and the
#                     beacon is stale: the arm died without a terminal record.
#   stale-watcher     the session is live and the beacon or watcher is stale
#                     for any other reason.
#
# The supervision model comes from FM_SUPERVISION_MODEL when set, else
# `autoarm` when state/.claude-autoarm-epoch exists (a Claude primary), else
# `persistent`. A launchd job runs outside every harness, so
# bin/fm-harness.sh cannot detect the primary here. docs/watchdog.md owns
# the ordinary beacon threshold and the separate finite cap for a bound
# rewake during a legitimate handling turn.
#
# Recovery, only for a verdict other than healthy or idle, under this home's watchdog lock:
#   1. When the watcher lock names a live pid, stop that watcher with
#      `bin/fm-watch-arm.sh --stop`, the home-scoped stop that publishes
#      downtime exactly as any watcher close does. Never pkill.
#   2. Run config/watchdog-resume, the one command that resumes the main
#      session (relaunch it when gone, wake it when idle). The repository has
#      no supported relaunch route for a main session, so the captain's own
#      launch command is the route; docs/watchdog.md owns its contract. The
#      command gets FM_HOME, FM_ROOT, and FM_WATCHDOG_REASON (the verdict).
#      An absent file makes this step a recorded no-op.
#   3. Re-read the verdict for up to FM_WATCHDOG_VERIFY_SECS (default 90).
# A recovery that restores neither healthy nor idle is a failed attempt. At
# most one attempt runs per FM_WATCHDOG_RETRY_SECS (default 240). After
# FM_WATCHDOG_ALARM_AFTER (default 2) consecutive failed attempts the check
# raises the existing wedge alarm channels (docs/wedge-alarm.md), at most once
# per FM_WATCHDOG_ALARM_INTERVAL_SECS (default 3600). A healthy or idle verdict
# clears the episode.
#
# Exit 0: healthy, idle, recovered, or waiting out the retry interval.
# Exit 1: the latest recovery attempt failed. Exit 2: usage.
# State: state/.watchdog-episode (attempt count and times), state/.watchdog.log
# (bounded), state/.watchdog.lock. Nothing outside this home is touched.
#
# Test seams, honored only when FM_TEST_SEAM=1: FM_WATCHDOG_ARM replaces
# bin/fm-watch-arm.sh and FM_WATCHDOG_NOW replaces the clock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() { sed -n '2,64p' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  '') ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# Sourcing the wake library creates its state directory, so a home that is
# gone (an unmounted volume, a removed lab) must be refused before that.
if [ ! -d "${FM_STATE_OVERRIDE:-$FM_HOME/state}" ]; then
  echo "watchdog: idle - no state directory at ${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  exit 0
fi

export FM_HOME FM_ROOT
export FM_STATE_OVERRIDE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
STATE=$FM_STATE_OVERRIDE
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

positive_int() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*|0) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

STALE_SECS=$(positive_int "${FM_WATCHDOG_STALE_SECS:-}" 900)
MIDTURN_STALE_SECS=3600
VERIFY_SECS=$(positive_int "${FM_WATCHDOG_VERIFY_SECS:-}" 90)
RETRY_SECS=$(positive_int "${FM_WATCHDOG_RETRY_SECS:-}" 240)
ALARM_AFTER=$(positive_int "${FM_WATCHDOG_ALARM_AFTER:-}" 2)
ALARM_INTERVAL=$(positive_int "${FM_WATCHDOG_ALARM_INTERVAL_SECS:-}" 3600)
STEP_BOUND=$(positive_int "${FM_WATCHDOG_STEP_SECS:-}" 60)
LOG="$STATE/.watchdog.log"
EPISODE="$STATE/.watchdog-episode"
LOCKDIR="$STATE/.watchdog.lock"
WATCH="$SCRIPT_DIR/fm-watch.sh"
ARM="$SCRIPT_DIR/fm-watch-arm.sh"
if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_WATCHDOG_ARM:-}" ]; then
  ARM=$FM_WATCHDOG_ARM
fi

now() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_WATCHDOG_NOW:-}" ]; then
    printf '%s\n' "$FM_WATCHDOG_NOW"
  else
    date +%s
  fi
}

log() {
  local size
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG" 2>/dev/null || return 0
  size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "${size:-0}" -ge 262144 ]; then
    tail -n 500 "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv -f "$LOG.tmp.$$" "$LOG" 2>/dev/null
    rm -f "$LOG.tmp.$$" 2>/dev/null
  fi
  return 0
}

if [ -z "${FM_SUPERVISION_MODEL:-}" ]; then
  if [ -e "$STATE/.claude-autoarm-epoch" ]; then
    FM_SUPERVISION_MODEL=autoarm
  else
    FM_SUPERVISION_MODEL=persistent
  fi
  export FM_SUPERVISION_MODEL
fi

WATCHDOG_VERDICT=
watchdog_verdict() {
  local lock_pid age
  WATCHDOG_VERDICT=healthy
  fm_supervision_status "$STATE" "$STALE_SECS"
  if [ "$FM_SUP_NEEDED" != true ]; then
    WATCHDOG_VERDICT=idle
    return 0
  fi
  lock_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
  if [ -z "$lock_pid" ] || ! fm_harness_pid_alive "$lock_pid"; then
    WATCHDOG_VERDICT="session-missing"
    return 0
  fi
  fm_watcher_supervision_verdict "$STATE" "$WATCH" "$STALE_SECS" "$FM_HOME" "$FM_ROOT"
  if [ "$FM_WATCHER_VERDICT_OK" = true ]; then
    age=$(fm_path_age "$STATE/.last-watcher-beat")
    if [ "$FM_SUPERVISION_MODEL" = autoarm ] \
      && fm_autoarm_midturn_healthy "$STATE"; then
      [ "$age" -lt "$MIDTURN_STALE_SECS" ] && return 0
    elif [ "$age" -lt "$STALE_SECS" ]; then
      return 0
    fi
  fi
  WATCHDOG_VERDICT="stale-watcher"
  if fm_autoarm_ledger_read "$STATE" \
    && [ "$FM_AUTOARM_OUTCOME" = arming ] \
    && ! fm_pid_alive "$FM_AUTOARM_OWNER"; then
    WATCHDOG_VERDICT="dead-arm-owner"
  fi
  return 0
}

# Episode record: line 1 "attempts=<n> last_attempt=<epoch> last_alarm=<epoch>".
EP_ATTEMPTS=0
EP_LAST_ATTEMPT=0
EP_LAST_ALARM=0
episode_read() {
  local line tok
  EP_ATTEMPTS=0
  EP_LAST_ATTEMPT=0
  EP_LAST_ALARM=0
  [ -f "$EPISODE" ] || return 0
  IFS= read -r line < "$EPISODE" 2>/dev/null || return 0
  for tok in $line; do
    case "$tok" in
      attempts=*) EP_ATTEMPTS=$(positive_int "${tok#*=}" 0) ;;
      last_attempt=*) EP_LAST_ATTEMPT=$(positive_int "${tok#*=}" 0) ;;
      last_alarm=*) EP_LAST_ALARM=$(positive_int "${tok#*=}" 0) ;;
    esac
  done
}
episode_write() {
  printf 'attempts=%s last_attempt=%s last_alarm=%s\n' "$EP_ATTEMPTS" "$EP_LAST_ATTEMPT" "$EP_LAST_ALARM" \
    > "$EPISODE.tmp.$$" 2>/dev/null && mv -f "$EPISODE.tmp.$$" "$EPISODE" 2>/dev/null
  rm -f "$EPISODE.tmp.$$" 2>/dev/null
  return 0
}

# Raise the wedge-alarm channels (docs/wedge-alarm.md). The daemon owns the
# channel dispatch; sourcing it is its supported library mode, which defaults
# the notifier seam to "discard" so tests cannot post. Production must fire the
# real channels, so the default the source just set is withdrawn unless the
# caller wired a seam itself.
raise_alarm() {  # <summary>
  local summary=$1 seam_set=0 seam_value=
  if [ -n "${FM_WEDGE_ALARM_EXEC:-}" ]; then
    seam_set=1
    seam_value=$FM_WEDGE_ALARM_EXEC
  fi
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$SCRIPT_DIR/fm-supervise-daemon.sh"
  if [ "$seam_set" -eq 1 ]; then
    FM_WEDGE_ALARM_EXEC=$seam_value
  else
    unset FM_WEDGE_ALARM_EXEC
  fi
  wedge_alarm_notify "$summary" "$LOG"
}

stop_stale_watcher() {
  local pid
  pid=$(cat "$STATE/.watch.lock/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 0
  log "stopping the stale watcher pid=$pid through $(basename "$ARM") --stop"
  fm_run_timed "$STEP_BOUND" "$ARM" --stop >> "$LOG" 2>&1 \
    || log "watcher stop reported a failure"
}

run_resume() {  # <reason>
  local file="$CONFIG/watchdog-resume" cmd
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    log "no config/watchdog-resume; the session cannot be resumed from here"
    return 0
  fi
  cmd=$(grep -v '^[[:space:]]*#' "$file" | sed '/^[[:space:]]*$/d' | head -n 1)
  if [ -z "$cmd" ]; then
    log "config/watchdog-resume holds no command"
    return 0
  fi
  log "running config/watchdog-resume for $1"
  FM_WATCHDOG_REASON=$1 fm_run_timed "$STEP_BOUND" sh -c "$cmd" >> "$LOG" 2>&1 \
    || log "config/watchdog-resume exited non-zero"
}

wait_healthy() {
  local deadline=$((SECONDS + VERIFY_SECS))
  while :; do
    watchdog_verdict
    case "$WATCHDOG_VERDICT" in healthy|idle) return 0 ;; esac
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 2
  done
}

watchdog_main() {
  local first now_epoch
  watchdog_verdict
  first=$WATCHDOG_VERDICT
  case "$first" in
    healthy|idle)
      if [ -e "$EPISODE" ]; then
        log "verdict $first; episode cleared"
        rm -f "$EPISODE" 2>/dev/null
      fi
      echo "watchdog: $first"
      return 0 ;;
  esac
  episode_read
  now_epoch=$(now)
  if [ "$EP_LAST_ATTEMPT" -gt 0 ] && [ $((now_epoch - EP_LAST_ATTEMPT)) -lt "$RETRY_SECS" ]; then
    echo "watchdog: $first - waiting out the retry interval"
    return 0
  fi
  log "verdict $first; recovery attempt $((EP_ATTEMPTS + 1))"
  stop_stale_watcher
  run_resume "$first"
  EP_LAST_ATTEMPT=$now_epoch
  if wait_healthy; then
    log "recovered from $first"
    rm -f "$EPISODE" 2>/dev/null
    echo "watchdog: recovered from $first"
    return 0
  fi
  EP_ATTEMPTS=$((EP_ATTEMPTS + 1))
  log "recovery attempt $EP_ATTEMPTS failed; verdict now $WATCHDOG_VERDICT"
  if [ "$EP_ATTEMPTS" -ge "$ALARM_AFTER" ] \
    && { [ "$EP_LAST_ALARM" -eq 0 ] || [ $((now_epoch - EP_LAST_ALARM)) -ge "$ALARM_INTERVAL" ]; }; then
    EP_LAST_ALARM=$now_epoch
    raise_alarm "firstmate supervision is down ($first) and $EP_ATTEMPTS automatic recoveries failed - see $LOG"
  fi
  episode_write
  echo "watchdog: $first - recovery failed (attempt $EP_ATTEMPTS)"
  return 1
}

if ! fm_lock_try_acquire "$LOCKDIR" identity; then
  echo "watchdog: another check is running"
  exit 0
fi
trap 'fm_lock_release "$LOCKDIR"' EXIT
watchdog_main
