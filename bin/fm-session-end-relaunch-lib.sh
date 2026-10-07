#!/usr/bin/env bash
# shellcheck disable=SC2034 # Output globals are read by the watcher tick and tests.
# fm-session-end-relaunch-lib.sh - relaunch an in-flight ship or scout after
# SessionEnd or OMP quota exhaustion.
#
# The watcher tick is the only driver. This is not a supervisor, daemon, or
# state machine. Eligibility, the deliberate-exit skip, the pause and hold
# skip, and the attempt caps live here. Replacement goes through
# bin/fm-control.sh relaunch, which keeps the recorded worktree and does not
# discard uncommitted work.
#
# A task is eligible when all of these hold:
#   - kind is ship or scout (a secondmate keeps its own liveness path)
#   - state/<id>.meta and the recorded worktree still exist, and
#     state/<id>.backlog-close is absent
#   - the current busy record is event=session-end or quota-exhausted for omp
#   - the latest status verb is not done or failed
#   - no declared pause or captain-held status line
#   - fm_backend_agent_state is dead for session-end,
#     or alive for a current quota event; missing endpoints are not retried here
#   - fm-captain-hold.sh open reports no open captain call (exit 1); an open
#     call or an answer it cannot establish skips the lane
#   - state/<id>.control-exit does not name this busy generation
#   - no control lock is held, and no in-progress control-relaunch journal
#
# Ordinary session-end caps count attempt rows in state/.session-end-relaunch-<id>:
# at most one attempt per task in 30 minutes, and at most 3 per task in a day.
# Past either cap the tick does not relaunch and wakes once for that
# session-end generation. Omp quota recovery bypasses these caps, but a failed
# quota generation is not attempted again.
# Relaunch calls share the watcher's stale grace minus FM_SESSION_END_MARGIN
# seconds, and the watcher beacon is touched just before each call, so a live
# watcher blocked in a relaunch never reads as down. fm-control's launch wait
# is half the remaining bound, at most 90 seconds, so a slow start ends
# through fm-control's own rollback rather than the bound. A grace too short
# to leave that margin runs no relaunch.
#
# fm_session_end_relaunch_scan <state-dir> [<watcher-grace-secs>] sets FM_SESSION_END_WAKE to the first check
# line that should be printed, or empty when this pass has nothing to say.
# It also appends each check row to the durable wake queue. Failed attempts
# advance to later lanes within the shared bound unless a replacement was
# confirmed or published alive, even when control reports failure.
# A successful relaunch also stops the scan, so one cycle replaces at most one worker.
#
# FM_SESSION_END_CONTROL overrides the control binary only when FM_TEST_SEAM=1.
set -u

_FM_SESSION_END_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
if ! declare -F fm_wake_append >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_SESSION_END_DIR/fm-wake-lib.sh"
fi
if ! declare -F fm_meta_get >/dev/null 2>&1; then
  # shellcheck source=bin/fm-backend.sh
  . "$_FM_SESSION_END_DIR/fm-backend.sh"
fi
if ! declare -F fm_busy_record_read >/dev/null 2>&1; then
  # shellcheck source=bin/fm-busy-lib.sh
  . "$_FM_SESSION_END_DIR/fm-busy-lib.sh"
fi
if ! declare -F last_status_line >/dev/null 2>&1; then
  # shellcheck source=bin/fm-classify-lib.sh
  . "$_FM_SESSION_END_DIR/fm-classify-lib.sh"
fi
if ! declare -F fm_run_timed >/dev/null 2>&1; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$_FM_SESSION_END_DIR/fm-timeout-lib.sh"
fi
if ! declare -F fm_session_launch_policy_check >/dev/null 2>&1; then
  # shellcheck source=bin/fm-session-launch-policy-lib.sh
  . "$_FM_SESSION_END_DIR/fm-session-launch-policy-lib.sh"
fi

FM_SESSION_END_MIN_SECS=1800
FM_SESSION_END_DAY_SECS=86400
FM_SESSION_END_DAY_MAX=3
FM_SESSION_END_MARGIN=60
FM_SESSION_END_LAUNCH_WAIT_MAX=90
FM_SESSION_END_LAUNCH_WAIT=
FM_SESSION_END_TIMEOUT=

# Set FM_SESSION_END_TIMEOUT and FM_SESSION_END_LAUNCH_WAIT from the watcher's
# stale grace, or the poll-derived default. Non-zero when the grace leaves no
# room for a launch wait inside the margin.
fm_session_end_bounds() {  # [<watcher-grace-secs>]
  local grace=${1:-}
  case "$grace" in
    ''|*[!0-9]*) grace=$(fm_poll_derived_grace) ;;
  esac
  FM_SESSION_END_TIMEOUT=$((10#$grace - FM_SESSION_END_MARGIN))
  FM_SESSION_END_LAUNCH_WAIT=$((FM_SESSION_END_TIMEOUT / 2))
  [ "$FM_SESSION_END_LAUNCH_WAIT" -le "$FM_SESSION_END_LAUNCH_WAIT_MAX" ] \
    || FM_SESSION_END_LAUNCH_WAIT=$FM_SESSION_END_LAUNCH_WAIT_MAX
  [ "$FM_SESSION_END_LAUNCH_WAIT" -ge 1 ]
}

fm_session_end_control_bin() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_SESSION_END_CONTROL:-}" ]; then
    printf '%s' "$FM_SESSION_END_CONTROL"
    return 0
  fi
  printf '%s' "$_FM_SESSION_END_DIR/fm-control.sh"
}

fm_session_end_ledger_path() {  # <state-dir> <id>
  printf '%s/.session-end-relaunch-%s' "$1" "$2"
}

fm_session_end_handled_path() {  # <state-dir> <id>
  printf '%s/.session-end-handled-%s' "$1" "$2"
}

# Count attempt rows no older than <window-secs>. Prints a number. Non-zero
# when the ledger cannot be read.
fm_session_end_count_attempts() {  # <state-dir> <id> <window-secs>
  local state=$1 id=$2 window=$3 ledger now cutoff n=0 epoch kind
  ledger=$(fm_session_end_ledger_path "$state" "$id")
  if [ ! -e "$ledger" ] && [ ! -L "$ledger" ]; then
    printf '0\n'
    return 0
  fi
  [ -f "$ledger" ] && [ ! -L "$ledger" ] && [ -r "$ledger" ] || return 1
  now=$(date +%s) || return 1
  cutoff=$((now - window))
  while IFS=$'\t' read -r epoch kind || [ -n "$epoch" ]; do
    [ "$kind" = attempt ] || continue
    case "$epoch" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$epoch" -ge "$cutoff" ] || continue
    n=$((n + 1))
  done < "$ledger"
  printf '%s\n' "$n"
}

fm_session_end_ledger_add() {  # <state-dir> <id> <attempt|relaunched|failed>
  local ledger
  ledger=$(fm_session_end_ledger_path "$1" "$2")
  printf '%s\t%s\n' "$(date +%s)" "$3" >> "$ledger" 2>/dev/null
}

# A current session-end record. Prints "gen seq" or nothing.
fm_session_end_identity() {  # <state-dir> <id>
  local state=$1 id=$2 gen out r_state r_source r_event r_seq
  out=$(fm_busy_record_read "$state" "$id" 2>/dev/null) || return 1
  read -r r_state r_source r_event r_seq <<< "$out"
  [ "$r_state" = idle ] && { [ "$r_event" = session-end ] || [ "$r_event" = quota-exhausted ]; } && [ -n "$r_seq" ] || return 1
  gen=$(fm_busy_current_gen "$state" "$id") || return 1
  printf '%s %s\n' "$gen" "$r_seq"
}

fm_session_end_exit_cancelled() {
  local origin_gen=$3 marker="$1/$2.control-exit" marker_gen
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  marker_gen=$(fm_meta_get "$marker" gen)
  fm_busy_token_valid "$marker_gen" || return 1
  fm_busy_token_valid "$origin_gen" && [ "$marker_gen" = "$origin_gen" ]
}

fm_session_end_replacement_bound() {
  local id=$2 prior_tx=$3 wt=$4 kind=$5
  local journal="$1/$2.control-relaunch" meta="$1/$2.meta" tx meta_kind
  [ -f "$journal" ] && [ ! -L "$journal" ] \
    && [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  tx=$(fm_meta_get "$journal" relaunch_tx)
  [ -n "$tx" ] && [ "$tx" != "$prior_tx" ] \
    && [ "$tx" = "$(fm_meta_get "$meta" control_relaunch_tx)" ] || return 1
  [ "$(fm_meta_get "$journal" task)" = "$id" ] \
    && [ "$(fm_meta_get "$journal" worktree)" = "$wt" ] \
    && [ "$(fm_meta_get "$meta" worktree)" = "$wt" ] \
    && [ "$(fm_meta_get "$journal" kind)" = "$kind" ] || return 1
  meta_kind=$(fm_meta_get "$meta" kind)
  [ "${meta_kind:-ship}" = "$kind" ] || return 1
  [ "$(fm_meta_get "$journal" rollback)" != none-new-agent-confirmed ] || return 0
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 1
  [ "$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET" 2>/dev/null)" = alive ]
}

fm_session_end_note() {
  printf '%s' "The previous worker session ended while this task was still open. The local copy and every uncommitted change were left as the previous worker left them. Continue from the instructions and the instruction inbox."
}

fm_session_end_first_line() {  # <text>
  local line
  line=$(printf '%s\n' "$1" | head -1)
  line=${line//$'\t'/ }
  printf '%s' "${line:0:180}"
}

fm_session_end_queue_wake() {  # <key> <reason>
  local queued
  [ -n "${FM_WAKE_QUEUE:-}" ] || FM_WAKE_QUEUE="$STATE/.wake-queue"
  queued=$(fm_wake_queued_keys check 2>/dev/null || true)
  if printf '%s\n' "$queued" | grep -Fx "$1" >/dev/null 2>&1; then
    return 0
  fi
  fm_wake_append check "$1" "$2"
}

# Decide and, when eligible, relaunch. Sets FM_SESSION_END_ACTION to
# relaunch, failed, capped, or skip, and FM_SESSION_END_REASON to a check
# line or empty. Returns 0 for a completed decision, 1 when a required
# ledger or wake row could not be written.
fm_session_end_relaunch_consider() {  # <state-dir> <id> [<deadline-epoch>]
  local state=$1 id=$2 meta kind wt backend window agent harness policy_error config
  local identity gen seq last verb hold_rc
  local journal phase lock recent day handled prior_tx
  local handled_gen handled_seq handled_outcome
  local bin out rc=0 reason key which quota_event busy_record
  local timeout=$FM_SESSION_END_TIMEOUT launch_wait=$FM_SESSION_END_LAUNCH_WAIT
  FM_SESSION_END_ACTION=skip
  FM_SESSION_END_REASON=
  FM_SESSION_END_REPLACEMENT_BOUND=0
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  [ ! -e "$state/$id.backlog-close" ] && [ ! -L "$state/$id.backlog-close" ] || return 0
  kind=$(fm_meta_get "$meta" kind 2>/dev/null || true)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship|scout) ;;
    *) return 0 ;;
  esac
  wt=$(fm_meta_get "$meta" worktree 2>/dev/null || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  handled=$(fm_session_end_handled_path "$state" "$id")
  handled_gen='' handled_seq='' handled_outcome=''
  if [ -f "$handled" ] && [ ! -L "$handled" ]; then
    IFS=$'\t' read -r handled_gen handled_seq handled_outcome < "$handled" || true
  fi
  quota_event=0
  if { [ "$handled_outcome" = quota-attempted ] || [ "$handled_outcome" = quota-failed ]; } \
       && fm_busy_token_valid "$handled_gen" \
       && [ "$(fm_meta_get "$meta" harness)" = omp ] \
       && [ ! -L "$state/$id.busy-gen" ] \
       && [ "$handled_gen" = "$(fm_busy_current_gen "$state" "$id" 2>/dev/null)" ] \
       && [[ -n "$handled_seq" && "$handled_seq" != *[!0-9]* ]]; then
    identity="$handled_gen $handled_seq"
    quota_event=1
  else
    identity=$(fm_session_end_identity "$state" "$id") || return 0
    busy_record=$(fm_busy_record_read "$state" "$id" 2>/dev/null) || return 0
    if [[ "$busy_record" == *" quota-exhausted "* ]]; then
      [ "$(fm_meta_get "$meta" harness)" = omp ] || return 0
      quota_event=1
    fi
  fi
  gen=${identity%% *}
  seq=${identity#* }
  fm_session_end_exit_cancelled "$state" "$id" "$gen" && return 0
  recent=0 day=0
  if [ "$quota_event" = 0 ]; then
    recent=$(fm_session_end_count_attempts "$state" "$id" "$FM_SESSION_END_MIN_SECS") || return 1
    day=$(fm_session_end_count_attempts "$state" "$id" "$FM_SESSION_END_DAY_SECS") || return 1
  fi
  if [ "$handled_gen" = "$gen" ]; then
    case "$handled_outcome" in
      quota-failed) return 0 ;;
    esac
  fi
  if [ "$handled_gen" = "$gen" ] && [ "$handled_seq" = "$seq" ]; then
    if [ "$handled_outcome" = relaunched ] \
       && { [ "$quota_event" = 1 ] || [ "$recent" -ge 1 ]; }; then
      return 0
    fi
    if [ "$quota_event" = 0 ] && [ "$handled_outcome" = failed ] && [ "$recent" -ge 1 ]; then
      return 0
    fi
  fi
  which=
  if [ "$quota_event" = 0 ]; then
    if [ "$recent" -ge 1 ]; then
      which=min
    elif [ "$day" -ge "$FM_SESSION_END_DAY_MAX" ]; then
      which=day
    fi
    if [ -n "$which" ] && [ "$handled_gen" = "$gen" ] && [ "$handled_seq" = "$seq" ] \
       && [ "$handled_outcome" = "capped-$which" ]; then
      return 0
    fi
  fi
  last=$(last_status_line "$state/$id.status" 2>/dev/null || true)
  verb=$(status_line_verb "$last" 2>/dev/null || true)
  case "$verb" in
    done|failed) return 0 ;;
  esac
  if [ -n "$(status_declared_wait_line "$state/$id.status" 2>/dev/null || true)" ]; then
    return 0
  fi
  backend=$(fm_meta_get "$meta" backend 2>/dev/null || true)
  [ -n "$backend" ] || backend=tmux
  window=$(fm_meta_get "$meta" window 2>/dev/null || true)
  [ -n "$window" ] || return 0
  if [ -n "${FM_HOME:-}" ] && [ -x "$_FM_SESSION_END_DIR/fm-captain-hold.sh" ]; then
    hold_rc=0
    FM_HOME="$FM_HOME" "$_FM_SESSION_END_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1 || hold_rc=$?
    [ "$hold_rc" -eq 1 ] || return 0
  fi
  lock="$state/.control-$id.lock"
  if [ -e "$lock" ] || [ -L "$lock" ]; then
    if ! fm_lock_try_acquire "$lock"; then
      return 0
    fi
    fm_lock_release "$lock" || return 1
  fi
  journal="$state/$id.control-relaunch"
  if [ -f "$journal" ] && [ ! -L "$journal" ]; then
    phase=$(sed -n 's/^phase=//p' "$journal" | head -1)
    case "$phase" in
      ''|complete|failed:*) ;;
      *) return 0 ;;
    esac
  fi
  harness=$(fm_meta_get "$meta" harness 2>/dev/null || true)
  config=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  if ! policy_error=$(fm_session_launch_policy_check "$config" "$harness" 2>&1); then
    reason="check: $id auto-relaunch refused after session-end: $(fm_session_end_first_line "$policy_error")"
    fm_session_launch_policy_refusal_notify "$state" "$id" "$gen" "$reason" "$policy_error" \
      "$config/session-launch-policy" || return 1
    FM_SESSION_END_REASON=$FM_SESSION_LAUNCH_REFUSAL_WAKE
    return 0
  fi
  if [ "$handled_gen" = "$gen" ] && [ "$handled_outcome" = quota-attempted ]; then
    reason="check: $id auto-relaunch failed after quota exhaustion: interrupted automatic attempt; use a fresh spawn with known capacity or a manual relaunch profile"
    key="session-end-relaunch-failed-$id-$gen-$handled_seq"
    fm_session_end_queue_wake "$key" "$reason" || return 1
    fm_session_end_ledger_add "$state" "$id" failed || return 1
    printf '%s\t%s\tquota-failed\n' "$gen" "$handled_seq" > "$handled" || return 1
    FM_SESSION_END_ACTION=failed
    FM_SESSION_END_REASON=$reason
    return 0
  fi
  agent=$(fm_backend_agent_state "$backend" "$window" 2>/dev/null || printf 'unreadable')
  if [ "$quota_event" = 1 ]; then
    [ "$agent" = alive ] || return 0
  else
    [ "$agent" = dead ] || return 0
  fi
  if [ -n "$which" ]; then
    if [ "$which" = min ]; then
      reason="check: $id auto-relaunch paused after 1 attempt in ${FM_SESSION_END_MIN_SECS}s; session-end still recorded"
    else
      reason="check: $id auto-relaunch paused after $FM_SESSION_END_DAY_MAX attempts in ${FM_SESSION_END_DAY_SECS}s; session-end still recorded"
    fi
    key="session-end-relaunch-capped-$id-$gen-$seq-$which"
    fm_session_end_queue_wake "$key" "$reason" || return 1
    printf '%s\t%s\tcapped-%s\n' "$gen" "$seq" "$which" > "$handled" || return 1
    FM_SESSION_END_ACTION=capped
    FM_SESSION_END_REASON=$reason
    return 0
  fi
  if [ -n "${3:-}" ]; then
    timeout=$(( $3 - $(date +%s) ))
    launch_wait=$((timeout / 2))
    [ "$launch_wait" -le "$FM_SESSION_END_LAUNCH_WAIT_MAX" ] \
      || launch_wait=$FM_SESSION_END_LAUNCH_WAIT_MAX
    [ "$launch_wait" -ge 1 ] || return 0
  fi
  fm_session_end_ledger_add "$state" "$id" attempt || return 1
  if [ "$quota_event" = 1 ]; then
    printf '%s\t%s\tquota-attempted\n' "$gen" "$seq" > "$handled" || return 1
  fi
  bin=$(fm_session_end_control_bin)
  rc=0
  prior_tx=$(fm_meta_get "$journal" relaunch_tx)
  touch "$state/.last-watcher-beat" 2>/dev/null || true
  out=$(fm_run_timed "$timeout" env FM_HOME="${FM_HOME:-}" FM_STATE_OVERRIDE="$state" \
    FM_CONTROL_LAUNCH_WAIT="$launch_wait" \
    FM_CONTROL_QUOTA_GEN="$(if [ "$quota_event" = 1 ]; then printf '%s' "$gen"; fi)" \
    FM_CONTROL_QUOTA_SEQ="$(if [ "$quota_event" = 1 ]; then printf '%s' "$seq"; fi)" \
    "$bin" "$id" relaunch --note "$(if [ "$quota_event" = 1 ]; then printf '%s' 'The previous model exhausted its quota after native recovery ended. Continue from the preserved local copy and instructions.'; else fm_session_end_note; fi)" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    FM_SESSION_END_REPLACEMENT_BOUND=1
    FM_SESSION_END_ACTION=relaunch
    fm_session_end_ledger_add "$state" "$id" relaunched || return 1
    if [ "$quota_event" = 1 ]; then
      reason="check: $id auto-relaunched after quota exhaustion harness=$(fm_meta_get "$meta" harness) model=$(fm_meta_get "$meta" model) effort=$(fm_meta_get "$meta" effort)"
    else
      reason="check: $id auto-relaunched after session-end"
    fi
    key="session-end-relaunch-$id-$gen-$seq"
    fm_session_end_queue_wake "$key" "$reason" || return 1
    printf '%s\t%s\trelaunched\n' "$gen" "$seq" > "$handled" || return 1
    FM_SESSION_END_REASON=$reason
    return 0
  fi
  if fm_session_end_replacement_bound "$state" "$id" "$prior_tx" "$wt" "$kind"; then
    FM_SESSION_END_REPLACEMENT_BOUND=1
  fi
  FM_SESSION_END_ACTION=failed
  fm_session_end_ledger_add "$state" "$id" failed || return 1
  reason="check: $id auto-relaunch failed after $(if [ "$quota_event" = 1 ]; then printf 'quota exhaustion'; else printf 'session-end'; fi): $(fm_session_end_first_line "$out")"
  key="session-end-relaunch-failed-$id-$gen-$seq"
  fm_session_end_queue_wake "$key" "$reason" || return 1
  printf '%s\t%s\t%s\n' "$gen" "$seq" \
    "$(if [ "$quota_event" = 1 ]; then printf quota-failed; else printf failed; fi)" > "$handled" || return 1
  FM_SESSION_END_REASON=$reason
  return 0
}

# Scan this home's task records. Sets FM_SESSION_END_WAKE to the first
# supervisor-visible line, or empty. Returns non-zero only when a required
# write failed.
fm_session_end_relaunch_scan() {  # <state-dir> [<watcher-grace-secs>]
  local state=$1 meta id reason first='' deadline last_attempt attempts epoch kind ledger
  FM_SESSION_END_WAKE=
  [ -d "$state" ] || return 0
  fm_session_end_bounds "${2:-}" || return 0
  deadline=$(( $(date +%s) + FM_SESSION_END_TIMEOUT ))
  [ -n "${FM_WAKE_QUEUE:-}" ] || FM_WAKE_QUEUE="$state/.wake-queue"
  while IFS=$'\t' read -r last_attempt attempts meta; do
    [ "$((deadline - $(date +%s)))" -ge 2 ] || break
    id=${meta##*/}
    id=${id%.meta}
    if ! fm_session_end_relaunch_consider "$state" "$id" "$deadline"; then
      return 1
    fi
    reason=$FM_SESSION_END_REASON
    if [ -n "$reason" ] && [ -z "$first" ]; then
      first=$reason
    fi
    [ "$FM_SESSION_END_REPLACEMENT_BOUND" = 0 ] || break
  done < <(
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      id=${meta##*/}
      id=${id%.meta}
      ledger=$(fm_session_end_ledger_path "$state" "$id")
      last_attempt=0
      attempts=0
      if [ -f "$ledger" ] && [ ! -L "$ledger" ] && [ -r "$ledger" ]; then
        while IFS=$'\t' read -r epoch kind || [ -n "$epoch" ]; do
          [ "$kind" = attempt ] || continue
          [[ -n "$epoch" && "$epoch" != *[!0-9]* ]] || continue
          attempts=$((attempts + 1))
          [ "$epoch" -le "$last_attempt" ] || last_attempt=$epoch
        done < "$ledger"
      fi
      printf '%s\t%s\t%s\n' "$last_attempt" "$attempts" "$meta"
    done | LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3
  )
  FM_SESSION_END_WAKE=$first
  return 0
}
