#!/usr/bin/env bash

FM_IDLE_REAP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$FM_IDLE_REAP_LIB_DIR/fm-wake-lib.sh"
. "$FM_IDLE_REAP_LIB_DIR/fm-classify-lib.sh"
. "$FM_IDLE_REAP_LIB_DIR/fm-backend.sh"
. "$FM_IDLE_REAP_LIB_DIR/fm-busy-lib.sh"
. "$FM_IDLE_REAP_LIB_DIR/fm-pr-lib.sh"

fm_idle_reap_terminal_age() {
  local line=$1 evidence=$2 now=$3 at m newest
  if ! at=$(status_line_at_epoch "$line" 2>/dev/null) || [ -z "$at" ] \
    || ! m=$(fm_path_mtime "$evidence") || [ -z "$m" ]; then
    printf '0'
    return 0
  fi
  newest=$at
  [ "$m" -le "$newest" ] || newest=$m
  if [ "$newest" -le 0 ] || [ "$newest" -gt "$now" ]; then
    printf '0'
  else
    printf '%s' $((now - newest))
  fi
}

fm_idle_reap_refusal_stands() {
  local memo=$1 line=$2 now=$3 version at fingerprint reason
  [ -f "$memo" ] && [ ! -L "$memo" ] || return 1
  { IFS= read -r version && IFS= read -r at && IFS= read -r fingerprint && IFS= read -r reason; } < "$memo" 2>/dev/null || return 1
  [ "$version" = fm-idle-reap-refused-v1 ] || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ "$fingerprint" = "$line" ] || return 1
  [ $((now - at)) -lt 21600 ] || return 1
  IDLE_REAP_DETAIL=$reason
}

fm_idle_reap_classify() {
  local home=$1 state=$2 data=$3 id=$4 meta="$2/$4.meta" pr remote busy verb note status msg evidence open age now hold_rc=0
  IDLE_REAP_CLASS=active
  IDLE_REAP_KIND=-
  IDLE_REAP_AGE=-
  IDLE_REAP_DETAIL="missing or unreadable metadata"
  IDLE_REAP_LAST=
  [ -f "$meta" ] && [ ! -L "$meta" ] && [ -r "$meta" ] || return 0
  IDLE_REAP_KIND=$(fm_meta_get "$meta" kind)
  [ -n "$IDLE_REAP_KIND" ] || IDLE_REAP_KIND=ship
  pr=$(fm_meta_get "$meta" pr)
  remote=$(fm_meta_get "$meta" remote_host)
  if [ "$IDLE_REAP_KIND" = secondmate ]; then
    IDLE_REAP_CLASS=secondmate
    IDLE_REAP_DETAIL="persistent; never reaped here"
    return 0
  fi
  if [ -n "$remote" ]; then
    IDLE_REAP_CLASS=remote
    IDLE_REAP_DETAIL="remote task on $remote; its host owns cleanup"
    return 0
  fi
  case "$IDLE_REAP_KIND" in
    ship|scout) ;;
    *) IDLE_REAP_CLASS=parked; IDLE_REAP_DETAIL="not an ordinary ship or scout"; return 0 ;;
  esac
  busy=$(fm_busy_classify_meta "$meta" "$id" "$state")
  if [ "${busy%% *}" != idle ]; then
    IDLE_REAP_DETAIL="busy state $busy"
    return 0
  fi
  for msg in "$state/$id.inbox"/*.msg; do
    if [ -e "$msg" ]; then
      IDLE_REAP_CLASS=steer-pending
      IDLE_REAP_DETAIL="unhandled instruction ${msg##*/}"
      return 0
    fi
  done
  status="$state/$id.status"
  IDLE_REAP_LAST=$(last_status_line "$status")
  if [ -z "$IDLE_REAP_LAST" ]; then
    IDLE_REAP_CLASS=idle-unreported
    IDLE_REAP_DETAIL="idle with no status event"
    return 0
  fi
  status_line_verb "$IDLE_REAP_LAST" verb
  note=$(status_line_note "$IDLE_REAP_LAST")
  case "$verb" in
    done) ;;
    paused|blocked|needs-decision|failed|captain-held)
      IDLE_REAP_CLASS=parked; IDLE_REAP_DETAIL="$verb: $note"; return 0 ;;
    *) IDLE_REAP_CLASS=idle-unreported; IDLE_REAP_DETAIL="idle after $verb: $note"; return 0 ;;
  esac
  FM_HOME="$home" FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" \
    "$FM_IDLE_REAP_LIB_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1 || hold_rc=$?
  if [ "$hold_rc" != 1 ]; then
    IDLE_REAP_CLASS=parked
    if [ "$hold_rc" = 0 ]; then
      IDLE_REAP_DETAIL="captain-held: waiting for captain answer"
    else
      IDLE_REAP_DETAIL="captain hold unreadable; cleanup ineligible"
    fi
    return 0
  fi
  open=$(status_open_decisions "$status" "$IDLE_REAP_KIND")
  if [ -n "$open" ]; then
    IDLE_REAP_CLASS=parked
    IDLE_REAP_DETAIL="open decision: ${open%%$'\n'*}"
    return 0
  fi
  if [ "$IDLE_REAP_KIND" = scout ]; then
    evidence="$data/$id/report.md"
    if [ ! -f "$evidence" ] || [ -L "$evidence" ] || [ ! -s "$evidence" ]; then
      IDLE_REAP_CLASS=scout-noreport
      IDLE_REAP_DETAIL="done without a nonempty data/$id/report.md"
      return 0
    fi
  else
    if [ -z "$pr" ]; then
      IDLE_REAP_CLASS=awaiting-pipeline
      IDLE_REAP_DETAIL="done; no pull request recorded yet"
      return 0
    fi
    evidence="$state/$id.pr-poll-merge-notified"
    if ! fm_pr_url_parse "$pr" || ! fm_pr_poll_merge_already_notified "$state" "$id" \
      "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
      IDLE_REAP_CLASS=awaiting-merge
      IDLE_REAP_DETAIL="done; $pr not recorded merged"
      return 0
    fi
  fi
  fm_epoch_seconds_to now
  age=$(fm_idle_reap_terminal_age "$IDLE_REAP_LAST" "$evidence" "$now")
  IDLE_REAP_AGE=$age
  if [ "$age" -lt 1800 ]; then
    IDLE_REAP_CLASS=wait-grace
    IDLE_REAP_DETAIL="finished ${age}s ago; grace is 1800s"
    return 0
  fi
  if fm_idle_reap_refusal_stands "$state/.idle-reap/$id.refused" "$IDLE_REAP_LAST" "$now"; then
    IDLE_REAP_CLASS=refused
    return 0
  fi
  IDLE_REAP_CLASS=reap
  IDLE_REAP_DETAIL="finished and idle"
}
