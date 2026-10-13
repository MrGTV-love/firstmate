#!/usr/bin/env bash
# Fair project allocation/return admission, shared by spawn, teardown, home
# seeding, and copy reassociation. Requires bin/fm-wake-lib.sh.
#
# fm_project_lock_acquire <project-lock> <operation>
# Waiting admission for fresh spawn and ordinary teardown, so their callers no
# longer need contention retry loops. A short registration mutex publishes
# monotonically numbered tickets; only the oldest live ticket may acquire the
# existing project lock. Poll frequency cannot change ticket order.
# Tickets stay registered until acquisition or refusal; an interrupted waiter
# is reclaimed using the same PID/liveness and fresh-publication proof as the
# underlying lock. Holder recovery remains fm_lock_try_acquire's responsibility:
# this is a PID-owned directory lock, not the git-file/lsof lock in fm-lock-lib.
# No live holder is removed, including at a refusal.
#
# The wait has no fixed deadline; it refuses only on a stall. A stall is the
# current holder keeping the lock for one service allowance, measured from
# that holder's acquisition, or, with no holder, the queue head staying
# unchanged for one allowance. Every waiter measures the same holder from the
# same acquisition time, so a later ticket cannot outlast an earlier one behind
# it, and a queue that keeps progressing never refuses however long it is.
#
# fm_project_lock_try <project-lock> <operation>
# One nonwaiting attempt for callers that already hold other locks (recursive
# teardown preflight, home seeding, copy reassociation, relocating relaunch):
# waiting there would stretch the refusal windows of the locks they hold. It
# refuses while any older live ticket is queued, so it never jumps a waiter.
#
# fm_project_lock_release <project-lock>
# Appends "start=<epoch> end=<epoch> seconds=<n> pid=<pid> operation=<label>"
# to <project-lock>.holds before releasing, so later allowance derivations can
# use production hold observations.
#
# The default service allowance is 162 seconds, the stall limit for one hold.
# measured: 2026-10-13T01:02:48Z (2026-10-12 local), load 51-57 on 18 CPUs,
# Treehouse v2.3.1-fm.e58947de, one run each in a disposable clone with an
# isolated pool: `treehouse get --lease` 8.924s, `treehouse return --force`
# 1.628s (evidence: the fm-project-lock-fair-wait task data,
# real-provider-measurement/). Poll budgets run under the spawn lock in
# bin/fm-spawn.sh: the treehouse get entry wait, 60 x 1s (lines 5140 and 5155),
# and the worker path check, 20 x 0.5s (lines 4700 and 4705). Harness readiness
# and delivery polls run after the lock is released and are not counted.
# 60 + 10 + 8.924 + 1.628 = 80.552s, rounded up to 81s, doubled for a 100%
# margin. FM_PROJECT_LOCK_SERVICE_SECS overrides it with a positive integer for
# a newly measured environment or bounded fixture.
# FM_PROJECT_LOCK_POLL_SECS changes sampling only (default 1 second; a positive
# decimal number of seconds).
# Progress is printed immediately and each quarter service allowance (40s
# by default, minimum 1s for fixture overrides), naming the
# current holder's operation/PID or the earlier waiter whose turn is reserved.
# A refusal returns nonzero with an "fm-project-lock:" line naming its class
# (invalid input, registration failure, filesystem error, stall limit), so
# callers retain their existing refusal and safety checks; capacity admission
# remains inside the acquired project lock.

fm_project_lock_register() {  # <lock> <service-secs> <operation>
  local lock=$1 service=$2 operation=$3 queue mutex sequence=0 owner ticket
  queue="$lock.queue"
  mutex="$lock.queue-lock"
  FM_PROJECT_LOCK_TICKET=
  if ! mkdir -p "$queue" || ! owner=$(fm_lock_owner_dir "$lock"); then
    FM_PROJECT_LOCK_ERROR="filesystem error: cannot create a ticket owner beside $lock"
    return 1
  fi
  if ! fm_lock_prepare_owner "$owner" || ! printf '%s\n' "$operation" > "$owner/role"; then
    fm_lock_discard_owner "$owner"
    FM_PROJECT_LOCK_ERROR="filesystem error: cannot record ticket owner $owner"
    return 1
  fi
  if ! fm_lock_acquire_wait_max "$mutex" "$service"; then
    fm_lock_discard_owner "$owner"
    FM_PROJECT_LOCK_ERROR="registration failure: queue mutex $mutex stayed held for ${service}s"
    return 1
  fi
  if [ -e "$queue/sequence" ]; then
    IFS= read -r sequence < "$queue/sequence" || sequence=invalid
  fi
  case "$sequence" in
    ''|*[!0-9]*)
      fm_lock_release "$mutex"
      fm_lock_discard_owner "$owner"
      FM_PROJECT_LOCK_ERROR="registration failure: unreadable queue sequence $queue/sequence"
      return 1 ;;
  esac
  sequence=$((sequence + 1))
  printf -v ticket '%s/ticket-%020d' "$queue" "$sequence"
  if ! printf '%s\n' "$sequence" > "$queue/sequence.tmp" \
    || ! mv -f "$queue/sequence.tmp" "$queue/sequence" \
    || ! ln -s "$owner" "$ticket"; then
    fm_lock_release "$mutex"
    fm_lock_discard_owner "$owner"
    FM_PROJECT_LOCK_ERROR="filesystem error: cannot publish ticket $ticket"
    return 1
  fi
  FM_PROJECT_LOCK_TICKET=$ticket
  fm_lock_release "$mutex"
}

fm_project_lock_head() {  # <queue>
  local path pid owner
  FM_PROJECT_LOCK_HEAD=
  for path in "$1"/ticket-*; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    pid=$(cat "$path/pid" 2>/dev/null || true)
    owner=$(fm_lock_link_owner "$path" 2>/dev/null || true)
    if fm_lock_recheck_stale_owner "$path" "$owner" "$pid"; then
      # Another reader or the acquiring waiter can retire this immutable
      # ticket between the snapshot and removal; absence is already success.
      if ! fm_lock_remove_path "$path" && { [ -e "$path" ] || [ -L "$path" ]; }; then
        FM_PROJECT_LOCK_ERROR="filesystem error: cannot retire dead ticket $path"
        return 1
      fi
      continue
    fi
    FM_PROJECT_LOCK_HEAD=$path
    break
  done
}

fm_project_lock_describe() {  # <lock> <head>
  local pid label
  pid=$(cat "$1/pid" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    label=$(cat "$1/role" 2>/dev/null || true)
    FM_PROJECT_LOCK_DESC="current holder ${label:-unlabelled operation} (PID $pid)"
    return 0
  fi
  pid=$(cat "$2/pid" 2>/dev/null || true)
  label=$(cat "$2/role" 2>/dev/null || true)
  FM_PROJECT_LOCK_DESC="next turn ${label:-unlabelled waiter} (PID ${pid:-unknown})"
}

fm_project_lock_acquire() {  # <lock> <operation>
  local lock=$1 operation=$2 service=${FM_PROJECT_LOCK_SERVICE_SECS:-162}
  local poll=${FM_PROJECT_LOCK_POLL_SECS:-1} number='^[0-9]+([.][0-9]+)?$' zero='^0*([.]0*)?$'
  local ticket head='' holder='' key last_key='' since=0 stalled=0 mtime now
  local next_message message_interval rc=1
  case "$service" in
    ''|*[!0-9]*|0|0[0-9]*)
      echo "fm-project-lock: invalid input for $operation: FM_PROJECT_LOCK_SERVICE_SECS '$service' is not a positive integer" >&2
      return 1 ;;
  esac
  if ! [[ $poll =~ $number ]] || [[ $poll =~ $zero ]]; then
    echo "fm-project-lock: invalid input for $operation: FM_PROJECT_LOCK_POLL_SECS '$poll' is not a positive number of seconds" >&2
    return 1
  fi
  message_interval=$((service / 4))
  [ "$message_interval" -gt 0 ] || message_interval=1
  FM_PROJECT_LOCK_ERROR=
  if ! fm_project_lock_register "$lock" "$service" "$operation"; then
    echo "fm-project-lock: $FM_PROJECT_LOCK_ERROR; $operation was not queued" >&2
    return 1
  fi
  ticket=$FM_PROJECT_LOCK_TICKET
  next_message=$SECONDS
  while :; do
    fm_project_lock_head "$lock.queue" || break
    head=$FM_PROJECT_LOCK_HEAD
    if [ ! -L "$ticket" ]; then
      FM_PROJECT_LOCK_ERROR="filesystem error: this waiter's ticket $ticket disappeared"
      break
    fi
    if [ "$head" = "$ticket" ] && fm_lock_try_acquire "$lock"; then
      if printf '%s\n' "$operation" > "$lock/role"; then
        rc=0
      else
        fm_lock_release "$lock"
        FM_PROJECT_LOCK_ERROR="filesystem error: cannot label acquired lock $lock"
      fi
      break
    fi
    holder=$(cat "$lock/pid" 2>/dev/null || true)
    key="$(readlink "$lock" 2>/dev/null || true):$holder|$head"
    if [ "$key" != "$last_key" ]; then
      last_key=$key
      since=$SECONDS
      if [ -n "$holder" ] && mtime=$(fm_path_mtime "$lock/role"); then
        fm_epoch_seconds_to now
        [ "$now" -lt "$mtime" ] || since=$((SECONDS - (now - mtime)))
      fi
    fi
    stalled=$((SECONDS - since))
    [ "$stalled" -lt "$service" ] || break
    if [ "$SECONDS" -ge "$next_message" ]; then
      fm_project_lock_describe "$lock" "$head"
      echo "fm-project-lock: waiting for $operation; $FM_PROJECT_LOCK_DESC; $((service - stalled))s left before the stall limit" >&2
      next_message=$((SECONDS + message_interval))
    fi
    if ! sleep "$poll"; then
      FM_PROJECT_LOCK_ERROR="sampling error: sleep $poll failed"
      break
    fi
  done
  fm_lock_remove_path "$ticket" || true
  [ "$rc" != 0 ] || return 0
  if [ -n "$FM_PROJECT_LOCK_ERROR" ]; then
    echo "fm-project-lock: $FM_PROJECT_LOCK_ERROR; $operation was not admitted" >&2
  else
    fm_project_lock_describe "$lock" "$head"
    echo "fm-project-lock: stall limit reached for $operation: $FM_PROJECT_LOCK_DESC made no progress for ${stalled}s (allowance ${service}s); no live holder was removed" >&2
  fi
  return 1
}

fm_project_lock_try() {  # <lock> <operation>
  local lock=$1 operation=$2
  FM_PROJECT_LOCK_ERROR=
  if ! fm_project_lock_head "$lock.queue"; then
    echo "fm-project-lock: $FM_PROJECT_LOCK_ERROR; $operation was not admitted" >&2
    return 1
  fi
  if [ -n "$FM_PROJECT_LOCK_HEAD" ] || ! fm_lock_try_acquire "$lock"; then
    fm_project_lock_describe "$lock" "$FM_PROJECT_LOCK_HEAD"
    echo "fm-project-lock: $operation holds other locks, so it does not wait; $FM_PROJECT_LOCK_DESC is ahead of it" >&2
    return 1
  fi
  if ! printf '%s\n' "$operation" > "$lock/role"; then
    fm_lock_release "$lock"
    echo "fm-project-lock: filesystem error: cannot label acquired lock $lock; $operation was not admitted" >&2
    return 1
  fi
}

fm_project_lock_release() {  # <lock>
  local lock=$1 pid current label mtime now
  fm_current_pid current || return 1
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  if [ "$pid" = "$current" ] && mtime=$(fm_path_mtime "$lock/role"); then
    label=$(cat "$lock/role" 2>/dev/null || true)
    fm_epoch_seconds_to now
    printf 'start=%s end=%s seconds=%s pid=%s operation=%s\n' \
      "$mtime" "$now" "$((now - mtime))" "$pid" "$label" >> "$lock.holds" 2>/dev/null || true
  fi
  fm_lock_release "$lock"
}
