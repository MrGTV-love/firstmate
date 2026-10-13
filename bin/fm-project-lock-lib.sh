#!/usr/bin/env bash
# Fair project allocation/return admission, shared by spawn, teardown, home
# seeding, and copy reassociation. Requires bin/fm-wake-lib.sh.
#
# fm_project_lock_acquire <project-lock> <operation>
# Callers no longer need contention retry loops. A short registration mutex
# publishes monotonically numbered tickets; only the oldest live ticket may
# acquire the existing project lock. Poll frequency cannot change ticket order.
# Tickets stay registered until acquisition or timeout; an interrupted waiter
# is reclaimed using the same PID/liveness and fresh-publication proof as the
# underlying lock. Holder recovery remains fm_lock_try_acquire's responsibility:
# this is a PID-owned directory lock, not the git-file/lsof lock in fm-lock-lib.
# No live holder is removed, including at the wait deadline.
#
# The default service allowance is 80 seconds: on 2026-10-12, 27 spawn
# admission windows measured 0-8s (12 completed launches: 5-8s), and 10 pool
# teardown windows measured 5-39s (median 27s, p90 35s). Real shell/Git fixture
# paths with stubbed tmux/Treehouse were timed at one-second resolution; 40s
# covers quantization, doubled for 100% margin. This does not measure vendor
# allocation performance; remeasure and override for a slower environment.
# Each waiter gets one allowance for the current holder and
# each ticket ahead of it, fixed at registration; later arrivals cannot extend
# its deadline. FM_PROJECT_LOCK_SERVICE_SECS overrides the measured allowance
# with a positive integer for a newly measured environment or bounded fixture.
# FM_PROJECT_LOCK_POLL_SECS changes sampling only (default 1 second).
# Progress is printed immediately and each quarter service allowance (20s
# by default, minimum 1s for fixture overrides), naming the
# current holder's operation/PID or the earlier waiter whose turn is reserved.
# Timeout returns nonzero so callers retain their existing refusal and safety
# checks; capacity admission remains inside the acquired project lock.

fm_project_lock_register() {  # <lock> <service-secs> <operation>
  local lock=$1 service=$2 operation=$3 queue mutex sequence=0 owner ticket path ahead=0
  queue="$lock.queue"
  mutex="$lock.queue-lock"
  FM_PROJECT_LOCK_TICKET=
  mkdir -p "$queue" || return 1
  owner=$(fm_lock_owner_dir "$lock") || return 1
  if ! fm_lock_prepare_owner "$owner" || ! printf '%s\n' "$operation" > "$owner/role"; then
    fm_lock_discard_owner "$owner"
    return 1
  fi
  if ! fm_lock_acquire_wait_max "$mutex" "$service"; then
    fm_lock_discard_owner "$owner"
    return 1
  fi
  if [ -e "$queue/sequence" ]; then
    IFS= read -r sequence < "$queue/sequence" || sequence=invalid
  fi
  case "$sequence" in
    ''|*[!0-9]*)
      fm_lock_release "$mutex"
      fm_lock_discard_owner "$owner"
      return 1 ;;
  esac
  sequence=$((sequence + 1))
  printf -v ticket '%s/ticket-%020d' "$queue" "$sequence"
  if ! printf '%s\n' "$sequence" > "$queue/sequence.tmp" \
    || ! mv -f "$queue/sequence.tmp" "$queue/sequence" \
    || ! ln -s "$owner" "$ticket"; then
    fm_lock_release "$mutex"
    fm_lock_discard_owner "$owner"
    return 1
  fi
  for path in "$queue"/ticket-*; do
    [ -L "$path" ] || continue
    [ "$path" != "$ticket" ] || break
    ahead=$((ahead + 1))
  done
  FM_PROJECT_LOCK_TICKET=$ticket
  FM_PROJECT_LOCK_WAIT_SECS=$((service * (ahead + 1)))
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
        return 1
      fi
      continue
    fi
    FM_PROJECT_LOCK_HEAD=$path
    break
  done
}

fm_project_lock_acquire() {  # <lock> <operation>
  local lock=$1 operation=$2 service=${FM_PROJECT_LOCK_SERVICE_SECS:-80}
  local ticket deadline next_message head holder label rc=1 started=$SECONDS
  local message_interval
  case "$service" in ''|*[!0-9]*|0|0[0-9]*) return 1 ;; esac
  message_interval=$((service / 4))
  [ "$message_interval" -gt 0 ] || message_interval=1
  fm_project_lock_register "$lock" "$service" "$operation" || return 1
  ticket=$FM_PROJECT_LOCK_TICKET
  deadline=$((started + FM_PROJECT_LOCK_WAIT_SECS))
  next_message=$SECONDS
  while [ "$SECONDS" -lt "$deadline" ]; do
    fm_project_lock_head "$lock.queue" || break
    head=$FM_PROJECT_LOCK_HEAD
    [ -n "$head" ] || break
    if [ "$head" = "$ticket" ] && fm_lock_try_acquire "$lock"; then
      if printf '%s\n' "$operation" > "$lock/role"; then
        rc=0
      else
        fm_lock_release "$lock"
      fi
      break
    fi
    if [ "$SECONDS" -ge "$next_message" ]; then
      holder=$(cat "$lock/pid" 2>/dev/null || true)
      label=$(cat "$lock/role" 2>/dev/null || true)
      if [ -n "$holder" ]; then
        echo "fm-project-lock: waiting for $operation; current holder ${label:-unlabelled operation} (PID $holder); $((deadline - SECONDS))s remaining" >&2
      else
        holder=$(cat "$head/pid" 2>/dev/null || true)
        label=$(cat "$head/role" 2>/dev/null || true)
        echo "fm-project-lock: waiting for $operation; next turn ${label:-unlabelled waiter} (PID ${holder:-unknown}); $((deadline - SECONDS))s remaining" >&2
      fi
      next_message=$((SECONDS + message_interval))
    fi
    sleep "${FM_PROJECT_LOCK_POLL_SECS:-1}" || break
  done
  fm_lock_remove_path "$ticket" || true
  if [ "$rc" != 0 ]; then
    echo "fm-project-lock: wait limit reached for $operation after $((SECONDS - started))s (allowance ${FM_PROJECT_LOCK_WAIT_SECS}s); no live holder was removed" >&2
  fi
  return "$rc"
}
