#!/usr/bin/env bash
# shellcheck disable=SC2034 # Output globals are read by the watcher tick and tests.
# fm-session-end-relaunch-lib.sh - relaunch an in-flight ship or scout whose
# SessionEnd busy record says the worker is gone.
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
#   - the current busy record is event=session-end
#   - the latest status verb is not done or failed
#   - no declared pause or captain-held status line
#   - fm_backend_agent_state is dead (pane at a shell, no agent); a missing
#     endpoint is left to the supervisor, because fm-control relaunch cannot
#     prove it gone on every backend
#   - fm-captain-hold.sh open reports no open captain call (exit 1); an open
#     call or an answer it cannot establish skips the lane
#   - state/<id>.control-exit does not name this busy generation
#   - no control lock is held, and no in-progress control-relaunch journal
#
# A refusal whose cause is deterministic until a recorded input changes (a slot refusal by name, or a
# refusal-shaped outcome the scan cannot classify) is reported once and not retried by the scan: the cause
# fingerprint it recorded (state/.session-end-refusal-<id>, durable across scanner processes) must change
# before one new attempt is allowed, and the operator's own `bin/fm-control.sh <task> relaunch` is the way to try
# again. Any other failed outcome keeps the caps and wakes below. A relaunch that starts with, or refuses
# because of, the task's own out-of-scope work carries the complete drift report in its wake line and in
# state/<id>.relaunch-drift, so the observer sees every path (bin/fm-slot-provision-lib.sh owns the report).
#
# A completed fm-control exit retires the busy record, so its session-end
# is never seen here. The control-exit marker covers the exit whose command
# was delivered but whose agent did not stop within the exit wait: that
# exit never retired the record, and its later session-end is still
# deliberate.
#
# Caps count attempt rows in state/.session-end-relaunch-<id>: at most one
# attempt per task in 30 minutes, and at most 3 per task in a day.
# Past either cap the tick does not relaunch and wakes once for that
# session-end generation. A later generation is a new episode.
# One fm-control call is bounded to the watcher's stale grace minus
# FM_SESSION_END_MARGIN seconds, and the watcher beacon is touched just
# before that call, so a live watcher blocked in a relaunch never reads as
# down. fm-control's launch wait is half that bound, at most 90 seconds, so
# a slow start ends through fm-control's own rollback rather than the bound.
# A grace too short to leave that margin runs no relaunch.
#
# fm_session_end_relaunch_scan <state-dir> [<watcher-grace-secs>] sets FM_SESSION_END_WAKE to the first check
# line that should be printed, or empty when this pass has nothing to say.
# It also appends each check row to the durable wake queue. It stops after
# the first relaunch attempt, so one watcher cycle runs at most one bounded
# fm-control call; the next cycle takes the next lane.
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
  local state=$1 id=$2 gen out r_state r_source r_event r_seq rec
  # No busy record means no session-end record: skip the read, which would only
  # answer "missing" after starting a process.
  fm_busy_record_path_to rec "$state" "$id"
  [ -f "$rec" ] || return 1
  out=$(fm_busy_record_read "$state" "$id" 2>/dev/null) || return 1
  read -r r_state r_source r_event r_seq <<< "$out"
  [ "$r_state" = idle ] && { [ "$r_event" = session-end ] || [ "$r_event" = quota-exhausted ]; } && [ -n "$r_seq" ] || return 1
  fm_busy_current_gen_to gen "$state" "$id" || return 1
  printf '%s %s\n' "$gen" "$r_seq"
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

fm_session_end_refusal_path() {  # <state-dir> <id>
  printf '%s/.session-end-refusal-%s' "$1" "$2"
}

# The reason name of a refusal-shaped relaunch outcome, or nothing for an outcome that is not a refusal.
# A refusal whose reason cannot be named is "unclassified": it is still treated as unchanged.
fm_session_end_refusal_reason() {  # <control-output>
  local text=$1 reason
  reason=$(printf '%s\n' "$text" | sed -n -e 's/.*slot adoption refused: \([a-z_]*\).*/\1/p' \
    -e 's/.*slot provisioning refused: \([a-z_]*\).*/\1/p' -e 's/.*"reason": "\([a-z_]*\)".*/\1/p' | head -n 1)
  if [ -z "$reason" ]; then
    case "$text" in
      *'slot provisioner refused'*|*'slot adoption refused'*|*'slot provisioning refused'*|*'refused relaunch of governed task'*|*'slot provisioner is missing'*|*'slot provisioner source is not'*)
        reason=unclassified ;;
    esac
  fi
  printf '%s' "$reason"
}

# The collision file a refusal names in the provisioner's own "manifest_path" form, empty when it names none.
fm_session_end_refusal_obstruction() {  # <control-output>
  printf '%s\n' "$1" | sed -n 's/.*"manifest_path": "\([^"]*\)".*/\1/p' | head -n 1
}

# A digest of the effective inputs the named refusal depends on. Neither the busy generation nor the raw HEAD is an
# input: an unrelated commit or a new generation leaves the same obstruction in place, while a real change to the
# obstruction (the uncovered paths, the tracked state of a scope path, a collision file, the manifest, the copy's dirt)
# or its clearing changes the digest and permits one new attempt.
fm_session_end_cause_fingerprint() {  # <state-dir> <id> <reason> [<obstruction-path>]
  local state=$1 id=$2 reason=$3 obstruction=${4:-} meta wt manifest base path scope marker inside
  local -a scopes=()
  meta="$state/$id.meta"
  wt=$(fm_meta_get "$meta" worktree 2>/dev/null || true)
  manifest=$(fm_meta_get "$meta" slot_manifest 2>/dev/null || true)
  while IFS= read -r scope; do scopes+=("$scope"); done < <(sed -n 's/^slot_owned_path=//p' "$meta" 2>/dev/null)
  {
    printf 'reason=%s\n' "$reason"
    grep -e '^worktree=' -e '^branch=' -e '^project=' -e '^slot_' "$meta" 2>/dev/null || true
    if [ -n "$manifest" ] && [ -f "$manifest" ]; then shasum -a 256 < "$manifest"; else printf 'no-manifest-file\n'; fi
    if [ -n "$obstruction" ]; then
      if [ -e "$obstruction" ]; then printf 'obstruction=%s\n' "$obstruction"; shasum -a 256 < "$obstruction" 2>/dev/null || true; else printf 'obstruction-gone\n'; fi
    fi
    case "$reason" in
      scope_mismatch|scope_not_tracked|scope_*)
        base=$(git -C "$wt" merge-base origin/main HEAD 2>/dev/null || true)
        printf 'base=%s\n' "$base"
        git -C "$wt" diff --name-only --no-renames -z "${base:-HEAD}" HEAD 2>/dev/null | tr '\0' '\n' | while IFS= read -r path; do
          [ -n "$path" ] || continue
          inside=0
          for scope in ${scopes[@]+"${scopes[@]}"}; do case "$path" in "${scope%/}"|"${scope%/}"/*) inside=1 ;; esac; done
          [ "$inside" = 1 ] || printf 'uncovered=%s\n' "$path"
        done | sort
        for scope in ${scopes[@]+"${scopes[@]}"}; do
          printf 'tracked-at-base=%s:%s\n' "$scope" "$(git -C "$wt" ls-tree -r --name-only "${base:-HEAD}" -- ":(literal)${scope%/}" 2>/dev/null | wc -l | tr -d ' ')"
        done ;;
      manifest_exists|repository_mismatch|manifest_*|worktree_path_mismatch|lifecycle_state_mismatch|branch_*|base_mismatch|custody_*) ;;
      dirty_worktree|operation_in_progress)
        git -C "$wt" status --porcelain=v1 -z --untracked-files=all 2>/dev/null | shasum -a 256
        for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer; do
          if [ -e "$(git -C "$wt" rev-parse --path-format=absolute --git-path "$marker" 2>/dev/null)" ]; then printf 'op=%s\n' "$marker"; fi
        done ;;
      *)
        git -C "$wt" rev-parse --verify HEAD 2>/dev/null || true
        git -C "$wt" rev-parse --verify --quiet 'origin/main^{commit}' 2>/dev/null || true
        git -C "$wt" status --porcelain=v1 -z --untracked-files=all 2>/dev/null | shasum -a 256 ;;
    esac
  } | shasum -a 256 | awk '{print $1}'
}

# Write the complete drift report from a control output to its stable durable path and print that path.
fm_session_end_write_drift() {  # <state-dir> <id> <control-output>
  local file="$1/$2.relaunch-drift"
  printf '%s\n' "$3" | sed -n -e '/^relaunch drift report for /,$p' > "$file" 2>/dev/null || true
  printf '%s' "$file"
}

# The complete drift report inside a control output, on one line: "header | entry | entry ...". Empty when the
# output carries no report or the report found nothing out of scope.
fm_session_end_drift_summary() {  # <control-output>
  local text=$1 header entries limits
  header=$(printf '%s\n' "$text" | sed -n 's/^relaunch drift report for \(.*\)$/\1/p' | head -n 1)
  case "$header" in ''|*'no out-of-scope path'*|*'could not be produced'*) ;; *)
    entries=$(printf '%s\n' "$text" | sed -n 's/^  drift: //p' | tr '\n' '|' | sed -e 's/|$//' -e 's/|/ | /g')
    limits=$(printf '%s\n' "$text" | sed -n 's/^  limitation: //p' | tr '\n' '|' | sed -e 's/|$//' -e 's/|/ | /g')
    printf '%s' "drift report: ${header#*: }: $entries${limits:+ | limitation: $limits}"
    return 0 ;;
  esac
  case "$header" in *'could not be produced'*) printf '%s' "drift report: ${header#*: }" ;; esac
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
fm_session_end_relaunch_consider() {  # <state-dir> <id>
  local state=$1 id=$2 meta kind wt backend window agent harness policy_error config
  local identity gen seq last verb hold_rc marker marker_gen
  local journal phase lock recent day handled
  local handled_gen handled_seq handled_outcome
  local bin out rc=0 reason key which quota_event busy_record
  local refusal_file r_gen r_seq r_reason r_fp r_obstruction cause drift drift_file
  FM_SESSION_END_ACTION=skip
  FM_SESSION_END_REASON=
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 0 ;;
  esac
  meta="$state/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  [ ! -e "$state/$id.backlog-close" ] && [ ! -L "$state/$id.backlog-close" ] || return 0
  fm_meta_get_to kind "$meta" kind
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship|scout) ;;
    *) return 0 ;;
  esac
  fm_meta_get_to wt "$meta" worktree
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  identity=$(fm_session_end_identity "$state" "$id") || return 0
  gen=${identity%% *}
  seq=${identity#* }
  quota_event=0
  busy_record=$(fm_busy_record_read "$state" "$id" 2>/dev/null) || return 0
  if [[ "$busy_record" == *" quota-exhausted "* ]]; then
    [ "$(fm_meta_get "$meta" harness)" = omp ] || return 0
    quota_event=1
  fi
  marker="$state/$id.control-exit"
  if [ -f "$marker" ] && [ ! -L "$marker" ]; then
    marker_gen=$(sed -n 's/^gen=//p' "$marker" | head -1)
    [ "$marker_gen" != "$gen" ] || return 0
  fi
  # A refusal this episode already reported is not retried while its cause is unchanged (Main 115): no attempt, no
  # ledger row, no blocked line and no wake. The record outlives this process, so a successor scanner sees it.
  refusal_file=$(fm_session_end_refusal_path "$state" "$id")
  if [ -f "$refusal_file" ] && [ ! -L "$refusal_file" ]; then
    r_gen='' r_seq='' r_reason='' r_fp='' r_obstruction=''
    IFS=$'\t' read -r r_gen r_seq r_reason r_fp r_obstruction < "$refusal_file" || true
    if [ -n "$r_reason" ] && [ -n "$r_fp" ]; then
      cause=$(fm_session_end_cause_fingerprint "$state" "$id" "$r_reason" "$r_obstruction") || cause=
      [ -n "$cause" ] && [ "$cause" != "$r_fp" ] || return 0
    fi
    rm -f "$refusal_file"
  fi
  recent=$(fm_session_end_count_attempts "$state" "$id" "$FM_SESSION_END_MIN_SECS") || return 1
  day=$(fm_session_end_count_attempts "$state" "$id" "$FM_SESSION_END_DAY_SECS") || return 1
  handled=$(fm_session_end_handled_path "$state" "$id")
  handled_gen='' handled_seq='' handled_outcome=''
  if [ -f "$handled" ] && [ ! -L "$handled" ]; then
    IFS=$'\t' read -r handled_gen handled_seq handled_outcome < "$handled" || true
  fi
  if [ "$handled_gen" = "$gen" ] && [ "$handled_seq" = "$seq" ] \
     && { [ "$handled_outcome" = relaunched ] || [ "$handled_outcome" = failed ]; } \
     && [ "$recent" -ge 1 ]; then
    return 0
  fi
  which=
  if [ "$recent" -ge 1 ]; then
    which=min
  elif [ "$day" -ge "$FM_SESSION_END_DAY_MAX" ]; then
    which=day
  fi
  if [ -n "$which" ] && [ "$handled_gen" = "$gen" ] && [ "$handled_seq" = "$seq" ] \
     && [ "$handled_outcome" = "capped-$which" ]; then
    return 0
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
  agent=$(fm_backend_agent_state "$backend" "$window" 2>/dev/null || printf 'unreadable')
  if [ "$quota_event" = 1 ]; then
    [ "$agent" = alive ] || return 0
  else
    [ "$agent" = dead ] || return 0
  fi
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
  fm_session_end_ledger_add "$state" "$id" attempt || return 1
  bin=$(fm_session_end_control_bin)
  rc=0
  touch "$state/.last-watcher-beat" 2>/dev/null || true
  out=$(fm_run_timed "$FM_SESSION_END_TIMEOUT" env FM_HOME="${FM_HOME:-}" FM_STATE_OVERRIDE="$state" \
    FM_CONTROL_LAUNCH_WAIT="$FM_SESSION_END_LAUNCH_WAIT" \
    "$bin" "$id" relaunch --note "$(if [ "$quota_event" = 1 ]; then printf '%s' 'The previous model exhausted its quota after native account rotation. Continue from the preserved local copy and instructions using the permitted matrix fallback.'; else fm_session_end_note; fi)" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    fm_session_end_ledger_add "$state" "$id" relaunched || return 1
    if [ "$quota_event" = 1 ]; then
      reason="check: $id auto-relaunched after quota exhaustion"
    else
      reason="check: $id auto-relaunched after session-end"
    fi
    key="session-end-relaunch-$id-$gen-$seq"
    rm -f "$refusal_file"
    drift=$(fm_session_end_drift_summary "$out")
    if [ -n "$drift" ]; then
      # The stable durable reference comes first, so the wake's length cap can only ever cut the repeated content after it.
      drift_file=$(fm_session_end_write_drift "$state" "$id" "$out")
      reason="$reason (the complete drift report is in $drift_file); $drift"
    fi
    fm_session_end_queue_wake "$key" "$reason" || return 1
    printf '%s\t%s\trelaunched\n' "$gen" "$seq" > "$handled" || return 1
    FM_SESSION_END_ACTION=relaunch
    FM_SESSION_END_REASON=$reason
    return 0
  fi
  fm_session_end_ledger_add "$state" "$id" failed || return 1
  reason="check: $id auto-relaunch failed after $(if [ "$quota_event" = 1 ]; then printf 'quota exhaustion'; else printf 'session-end'; fi)"
  drift=$(fm_session_end_drift_summary "$out")
  if [ -n "$drift" ]; then
    drift_file=$(fm_session_end_write_drift "$state" "$id" "$out")
    reason="$reason (the complete drift report is in $drift_file)"
  fi
  reason="$reason: $(fm_session_end_first_line "$out")"
  cause=$(fm_session_end_refusal_reason "$out")
  if [ -n "$cause" ]; then
    r_obstruction=$(fm_session_end_refusal_obstruction "$out")
    r_fp=$(fm_session_end_cause_fingerprint "$state" "$id" "$cause" "$r_obstruction") || r_fp=
    if [ -n "$r_fp" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$gen" "$seq" "$cause" "$r_fp" "$r_obstruction" > "$refusal_file" || return 1
      reason="$reason [refused: $cause: $(fm_session_end_first_line "$(printf '%s\n' "$out" | grep -m 1 -e 'refused')"); not retried by the scan until its cause changes; bin/fm-control.sh $id relaunch tries again]"
    fi
  fi
  [ -z "$drift" ] || reason="$reason; $drift"
  key="session-end-relaunch-failed-$id-$gen-$seq"
  fm_session_end_queue_wake "$key" "$reason" || return 1
  printf '%s\t%s\tfailed\n' "$gen" "$seq" > "$handled" || return 1
  FM_SESSION_END_ACTION=failed
  FM_SESSION_END_REASON=$reason
  return 0
}

# Scan this home's task records. Sets FM_SESSION_END_WAKE to the first
# supervisor-visible line, or empty. Returns non-zero only when a required
# write failed.
fm_session_end_relaunch_scan() {  # <state-dir> [<watcher-grace-secs>]
  local state=$1 meta id reason first=
  FM_SESSION_END_WAKE=
  [ -d "$state" ] || return 0
  fm_session_end_bounds "${2:-}" || return 0
  [ -n "${FM_WAKE_QUEUE:-}" ] || FM_WAKE_QUEUE="$state/.wake-queue"
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    if ! fm_session_end_relaunch_consider "$state" "$id"; then
      return 1
    fi
    reason=$FM_SESSION_END_REASON
    if [ -n "$reason" ] && [ -z "$first" ]; then
      first=$reason
    fi
    case "$FM_SESSION_END_ACTION" in
      relaunch|failed) break ;;
    esac
  done
  FM_SESSION_END_WAKE=$first
  return 0
}
