#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_SUP_* verdict fields are read by the caller.
# Single owner of the supervision-liveness predicate and its reason vocabulary.
#
# Source bin/fm-supervision-lib.sh (the need counts) and bin/fm-wake-lib.sh
# (pid identity, beacon age, lock ownership, away-daemon proof, model-aware
# verdict) first, exactly as the guards already do, then source this file.
# It sources nothing itself: bin/fm-wake-lib.sh creates the state directory on
# load, and the turn-end guard must not do that inside an exempt child worktree
# before its scope check runs.
#
# Four guards ask whether supervision is live, and each used to compose the
# answer from the same beacon age, lock-owner identity, and away/quiet-daemon
# ownership test in its own words. They now branch on a verdict from this file,
# so the answer and its reason cannot drift between them. The harness-specific
# paths stay in their own guards: Claude's Stop auto-arm cooperation, the
# Cursor park, the model-aware pull tolerance, and every budget/lock carve-out
# are decisions about what to do with the verdict, not what the verdict is.
#
# Reason vocabulary (FM_SUP_REASON is always one of these stable tokens):
#   idle          nothing needs supervision, so nothing can be down
#   watcher       a live identity-matched watcher holds the home with a fresh
#                 beacon (the strict turn-end proof)
#   away-daemon   away/quiet mode owns supervision and its live daemon has a
#                 fresh poll-derived beacon (the turn-end away-mode proof)
#   healthy       the model-aware pull verdict accepts this moment, including a
#                 documented between-turns or extension hand-off
#   no-watcher    a fresh beacon exists but no live watcher owns the home
#   stale-beacon  the beacon is stale or absent
#   unreadable    the state directory cannot be read, so the source is unknown
#
# Fail direction: every caller decides what an `unknown` source means. The
# turn-end guard fails closed (it keeps blocking), the pull warning fails loud
# (it warns), exactly as each guard did before this file existed.

FM_SUP_LIVENESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_SUP_LIVE=unknown
FM_SUP_REASON=unreadable
FM_SUP_SOURCE_OK=false

# fm_supervision_state_readable <state-dir>
# True only when the state directory can actually be listed. An absent,
# permission-denied, or non-directory path is unknown, never an empty home:
# reading "no work here" out of an unreadable directory would turn a broken
# source into a quiet allow.
fm_supervision_state_readable() {
  local state=${1:-}
  [ -n "$state" ] && [ -d "$state" ] && [ -r "$state" ] && [ -x "$state" ]
}

fm_supervision_verdict_unknown() {
  FM_SUP_LIVE=unknown
  FM_SUP_REASON=unreadable
  FM_SUP_SOURCE_OK=false
}

# fm_supervision_in_flight <state-dir> [grace-seconds]
# Populate the shared need signals through bin/fm-supervision-lib.sh:
#   FM_SUP_IN_FLIGHT, FM_SUP_SOURCES, FM_SUP_CHECKS, FM_SUP_QUEUE_PENDING,
#   FM_SUP_NEEDED, FM_SUP_WATCHER_FRESH, FM_SUP_BEACON_DESC.
# Exit 0 when anything needs supervision (a task, an event source, a
# registered check, relay polling, or an unread queue), 1 when the home is idle.
fm_supervision_in_flight() {
  local state=${1:-}
  [ -n "$state" ] || state=${STATE:-}
  fm_supervision_status "$state" "${2:-${FM_GUARD_GRACE:-300}}"
  [ "$FM_SUP_NEEDED" = true ]
}

# fm_supervision_liveness <state-dir> [grace] [watch-path] [home]
# The strict turn-end verdict. Sets FM_SUP_LIVE to live, off, or unknown and
# FM_SUP_REASON to one token above. Exit 0 always; branch on the fields.
# This is the predicate bin/fm-turnend-guard.sh blocks on: only a live
# identity-matched watcher, or the away/quiet daemon with a fresh poll-derived
# beacon, lets a turn end. A leftover beacon must never satisfy it.
fm_supervision_liveness() {
  local state=${1:-} grace=${2:-${FM_GUARD_GRACE:-300}} watch=${3:-} home=${4:-}
  local away_grace age
  [ -n "$state" ] || state=${STATE:-}
  [ -n "$watch" ] || watch="$FM_SUP_LIVENESS_DIR/fm-watch.sh"
  [ -n "$home" ] || home=${FM_HOME:-}
  if ! fm_supervision_state_readable "$state"; then
    fm_supervision_verdict_unknown
    return 0
  fi
  fm_supervision_status "$state" "$grace"
  if [ "$FM_SUP_NEEDED" != true ]; then
    FM_SUP_LIVE=live
    FM_SUP_REASON=idle
    FM_SUP_SOURCE_OK=true
    return 0
  fi
  if fm_watcher_healthy "$state" "$watch" "$grace" "$home"; then
    FM_SUP_LIVE=live
    FM_SUP_REASON=watcher
    FM_SUP_SOURCE_OK=true
    return 0
  fi
  # Away/quiet mode hands the watcher between one-shot cycles, so a live
  # identity-matched daemon plus a fresh beacon is the owner proof there. It
  # uses the poll-derived grace, never the flat guard grace: the daemon starts a
  # fresh one-shot only after finishing the previous wake, and that handling can
  # legitimately outrun a fixed 300s window under load while the daemon is
  # healthy throughout (bin/fm-claude-stop-autoarm.sh uses the same derivation).
  away_grace=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
  age=$(fm_path_age "$state/.last-watcher-beat")
  case "$age" in ''|*[!0-9]*) age=999999 ;; esac
  if [ "$age" -lt "$away_grace" ] && fm_afk_daemon_owns_supervision "$state"; then
    FM_SUP_LIVE=live
    FM_SUP_REASON=away-daemon
    FM_SUP_SOURCE_OK=true
    return 0
  fi
  FM_SUP_LIVE=off
  FM_SUP_SOURCE_OK=true
  if [ "$FM_SUP_WATCHER_FRESH" = true ]; then
    FM_SUP_REASON=no-watcher
  else
    FM_SUP_REASON=stale-beacon
  fi
  return 0
}

# fm_supervision_watcher_live <state-dir> <watch-path> [grace] [home]
# The lock-owner check on its own: true only when a live pid holds this home's
# watcher lock, its identity and recorded home/watcher path match, and the
# beacon is inside grace (bin/fm-wake-lib.sh owns those primitives). Sets the
# same verdict fields as fm_supervision_liveness so a caller can branch on
# either. Callers use it where they re-check one owner mid-decision, such as the
# Cursor park's benign-close test and the Claude auto-arm cooperation.
fm_supervision_watcher_live() {
  local state=${1:-} watch=${2:-} grace=${3:-${FM_GUARD_GRACE:-300}} home=${4:-} age
  [ -n "$watch" ] || watch="$FM_SUP_LIVENESS_DIR/fm-watch.sh"
  [ -n "$home" ] || home=${FM_HOME:-}
  if ! fm_supervision_state_readable "$state"; then
    fm_supervision_verdict_unknown
    return 1
  fi
  if fm_watcher_healthy "$state" "$watch" "$grace" "$home"; then
    FM_SUP_LIVE=live
    FM_SUP_REASON=watcher
    FM_SUP_SOURCE_OK=true
    return 0
  fi
  age=$(fm_path_age "$state/.last-watcher-beat")
  case "$age" in ''|*[!0-9]*) age=999999 ;; esac
  FM_SUP_LIVE=off
  FM_SUP_SOURCE_OK=true
  if [ "$age" -lt "$grace" ]; then
    FM_SUP_REASON=no-watcher
  else
    FM_SUP_REASON=stale-beacon
  fi
  return 1
}

# fm_supervision_away_owner <state-dir> [afk-grace]
# The away/quiet-mode ownership proof on its own: true only while state/.afk
# exists, a live identity-matched daemon holds this home, and the beacon is
# inside the poll-derived grace (default max(300, FM_POLL + 60), or an explicit
# FM_GUARD_GRACE). Proves an owner, never freshness on its own, so callers that
# use it separately still supply the beacon test it performs here.
fm_supervision_away_owner() {
  local state=${1:-} grace=${2:-${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}} age
  if ! fm_supervision_state_readable "$state"; then
    fm_supervision_verdict_unknown
    return 1
  fi
  age=$(fm_path_age "$state/.last-watcher-beat")
  case "$age" in ''|*[!0-9]*) age=999999 ;; esac
  if [ "$age" -lt "$grace" ] && fm_afk_daemon_owns_supervision "$state"; then
    FM_SUP_LIVE=live
    FM_SUP_REASON=away-daemon
    FM_SUP_SOURCE_OK=true
    return 0
  fi
  FM_SUP_LIVE=off
  FM_SUP_SOURCE_OK=true
  if [ "$age" -lt "$grace" ]; then
    FM_SUP_REASON=no-watcher
  else
    FM_SUP_REASON=stale-beacon
  fi
  return 1
}

# fm_supervision_pull_liveness <state-dir> [grace] [watch-path] [home] [root]
# The model-aware pull-warning verdict. It deliberately accepts the documented
# between-turns and extension hand-offs that bin/fm-wake-lib.sh's
# fm_watcher_supervision_verdict owns, because the pull guard runs mid-turn and
# must not alarm on a healthy hand-off there.
#
# This is the one place the two verdicts differ on purpose, and it is why the
# strict verdict above is not simply reused: adding the away/quiet-daemon proof
# here would silence today's warning for a non-autoarm harness whose only owner
# is the away daemon, and adding the model tolerance to the strict verdict would
# let a turn end without the owner that can accept the continuation. Keep the
# split; the shared state read, need count, and reason vocabulary still live in
# this one file.
fm_supervision_pull_liveness() {
  local state=${1:-} grace=${2:-${FM_GUARD_GRACE:-300}} watch=${3:-} home=${4:-} root=${5:-}
  [ -n "$state" ] || state=${STATE:-}
  [ -n "$watch" ] || watch="$FM_SUP_LIVENESS_DIR/fm-watch.sh"
  [ -n "$home" ] || home=${FM_HOME:-}
  [ -n "$root" ] || root=${FM_ROOT:-$(cd "$FM_SUP_LIVENESS_DIR/.." && pwd)}
  if ! fm_supervision_state_readable "$state"; then
    fm_supervision_verdict_unknown
    return 0
  fi
  fm_supervision_status "$state" "$grace"
  if [ "$FM_SUP_NEEDED" != true ]; then
    FM_SUP_LIVE=live
    FM_SUP_REASON=idle
    FM_SUP_SOURCE_OK=true
    return 0
  fi
  fm_watcher_supervision_verdict "$state" "$watch" "$grace" "$home" "$root"
  if [ "$FM_WATCHER_VERDICT_OK" = true ]; then
    FM_SUP_LIVE=live
    FM_SUP_REASON=healthy
    FM_SUP_SOURCE_OK=true
    return 0
  fi
  FM_SUP_LIVE=off
  FM_SUP_SOURCE_OK=true
  FM_SUP_REASON=${FM_WATCHER_VERDICT_REASON:-stale-beacon}
  return 0
}
