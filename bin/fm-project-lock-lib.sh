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
# The wait has no fixed deadline; it refuses only on a stall. Progress means
# the holder or queue head changes, the holder updates its role record, or its
# process tree consumes another CPU second (including reaped children).
# A slow holder that keeps working never expires merely because of its age.
# Missing process telemetry is uncertainty, not proof of a stalled holder.
# A dead holder is recovered by the existing identity-bound lock owner.
#
# fm_project_lock_try <project-lock> <operation>
# One nonwaiting attempt for callers that already hold other locks (recursive
# teardown preflight, home seeding, copy reassociation, relocating relaunch),
# and for the idle reaper's teardown before it has closed anything, so a busy
# project leaves that task selectable by the next sweep: waiting there would
# stretch the refusal windows of the locks they hold. Once a teardown has
# closed anything, its return stage waits instead (bin/fm-teardown.sh's
# header). It refuses while any older live ticket is queued, so it never jumps a
# waiter. Contention (a live queued ticket, or a live process other than the
# caller holding, reclaiming, or still publishing the lock, as recorded by
# fm_lock_try_acquire at its refusal in FM_LOCK_BUSY) returns
# FM_PROJECT_LOCK_BUSY_EXIT (75, try later); every other refusal, including a
# lock that cannot be taken with no live holder, returns 1 with a filesystem
# error line.
#
# fm_project_lock_release <project-lock>
# Appends "start=<epoch> end=<epoch> seconds=<n> pid=<pid> operation=<label>"
# to <project-lock>.holds before releasing, so later allowance derivations can
# use production hold observations.
#
# The default service allowance is 600 seconds without observed progress, not
# a deadline on one hold. The historical 490-second hold-age bound below
# undercounted slow acquisition and unbounded work; it no longer ends a wait.
# These historical measurements explain why hold age is not a stall signal.
# The former derivation combined bounded spawn/return steps, but omitted or
# undercounted home seeding, Orca creation, nested teardown and Docker cleanup.
# Historical samples were only 8.924s for a get at load 51-57 and a handful
# of network operations at load 10-11; they did not establish a maximum hold.
# FM_PROJECT_LOCK_SERVICE_SECS overrides the idle allowance with a positive
# integer for an explicitly chosen environment or bounded fixture.
# FM_PROJECT_LOCK_POLL_SECS changes admission sampling only (default 1 second;
# a positive decimal number). Process progress is sampled every 15 seconds,
# or a quarter allowance for short fixtures, never more often than once a second.
# Progress is printed immediately and each minute (each second for allowances
# below four seconds), naming the current operation/PID or reserved queue head.
# A refusal returns nonzero with an "fm-project-lock:" line naming its class
# (invalid input, registration failure, filesystem error, sampling error, stall
# limit); FM_PROJECT_LOCK_ERROR is empty after a stall-limit refusal and names
# the class after every other one, so a caller can tell contention from an
# error. Callers retain their existing refusal and safety checks; capacity admission
# remains inside the acquired project lock.

FM_PROJECT_LOCK_BUSY_EXIT=75

fm_project_lock_register() {  # <lock> <service-secs> <operation>
  local lock=$1 service=$2 operation=$3 queue mutex sequence=0 owner ticket
  local _fm_lock_identity_bound=identity
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
  local _fm_lock_identity_bound=identity
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

# Cumulative centiseconds for a holder and its live descendants. ps -S also
# includes reaped child CPU, so short-lived helpers do not erase real progress.
# A sampling failure returns nonzero and cannot establish a stalled holder.
fm_project_lock_cpu() {  # <holder-pid>
  (
    set -o pipefail
    LC_ALL=C ps -S -axo pid=,ppid=,time= | LC_ALL=C awk -v root="$1" '
      {
        children[$2] = children[$2] " " $1
        n = split($3, clock, "-"); seconds = n > 1 ? clock[1] * 86400 : 0
        n = split(clock[n], parts, ":"); elapsed = 0
        for (i = 1; i <= n; i++) elapsed = elapsed * 60 + parts[i]
        cpu[$1] = seconds + elapsed
      }
      END {
        if (!(root in cpu)) exit 1
        queue[1] = root; end = 1
        for (start = 1; start <= end; start++) {
          pid = queue[start]; total += cpu[pid]
          n = split(children[pid], child, " ")
          for (i = 1; i <= n; i++) if (child[i] != "") queue[++end] = child[i]
        }
        printf "%.0f\n", total * 100
      }'
  )
}

fm_project_lock_acquire() {  # <lock> <operation>
  local lock=$1 operation=$2 service=${FM_PROJECT_LOCK_SERVICE_SECS:-600}
  local poll=${FM_PROJECT_LOCK_POLL_SECS:-1} number='^[0-9]+([.][0-9]+)?$' zero='^0*([.]0*)?$'
  local ticket head='' holder='' key last_key='' since=0 stalled=0 mtime last_mtime=''
  local cpu='' last_cpu='' next_sample=0 sample_interval
  local next_message message_interval rc=1
  FM_PROJECT_LOCK_ERROR=
  case "$service" in
    ''|*[!0-9]*|0|0[0-9]*)
      FM_PROJECT_LOCK_ERROR="invalid input: FM_PROJECT_LOCK_SERVICE_SECS '$service' is not a positive integer"
      echo "fm-project-lock: $FM_PROJECT_LOCK_ERROR for $operation" >&2
      return 1 ;;
  esac
  if ! [[ $poll =~ $number ]] || [[ $poll =~ $zero ]]; then
    FM_PROJECT_LOCK_ERROR="invalid input: FM_PROJECT_LOCK_POLL_SECS '$poll' is not a positive number of seconds"
    echo "fm-project-lock: $FM_PROJECT_LOCK_ERROR for $operation" >&2
    return 1
  fi
  message_interval=60
  [ "$service" -ge 4 ] || message_interval=1
  sample_interval=$((service / 4))
  [ "$sample_interval" -le 15 ] || sample_interval=15
  [ "$sample_interval" -gt 0 ] || sample_interval=1
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
      last_cpu=''
      last_mtime=''
      next_sample=$SECONDS
    fi
    if [ -n "$holder" ] && [ "$SECONDS" -ge "$next_sample" ]; then
      next_sample=$((SECONDS + sample_interval))
      if cpu=$(fm_project_lock_cpu "$holder"); then
        if [ -z "$last_cpu" ]; then
          last_cpu=$cpu
        elif [ "$cpu" -ge $((last_cpu + 100)) ]; then
          since=$SECONDS
          last_cpu=$cpu
        fi
      else
        # An unavailable sample cannot distinguish work from a dead service.
        # Existing owner recovery still handles a holder whose death is proved.
        since=$SECONDS
      fi
      if mtime=$(fm_path_mtime "$lock/role"); then
        if [ -n "$last_mtime" ] && [ "$mtime" != "$last_mtime" ]; then
          since=$SECONDS
        fi
        last_mtime=$mtime
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
  local lock=$1 operation=$2 current='' holder=''
  FM_PROJECT_LOCK_ERROR=
  if ! fm_project_lock_head "$lock.queue"; then
    echo "fm-project-lock: $FM_PROJECT_LOCK_ERROR; $operation was not admitted" >&2
    return 1
  fi
  if [ -z "$FM_PROJECT_LOCK_HEAD" ] && ! fm_lock_try_acquire "$lock"; then
    # fm_lock_try_acquire records at its refusal whether it lost to another
    # live or still-publishing actor (FM_LOCK_BUSY). A refusal that names this
    # very process, or none, is an acquisition error, not contention.
    fm_current_pid current || current=
    if [ "$FM_LOCK_BUSY" != 1 ] || { [ -n "$current" ] && [ "$FM_LOCK_HELD_PID" = "$current" ]; }; then
      echo "fm-project-lock: filesystem error: cannot acquire $lock with no live holder or queued waiter ahead; $operation was not admitted" >&2
      return 1
    fi
    holder=busy
  fi
  if [ -n "$FM_PROJECT_LOCK_HEAD" ] || [ -n "$holder" ]; then
    fm_project_lock_describe "$lock" "$FM_PROJECT_LOCK_HEAD"
    echo "fm-project-lock: $operation does not wait; $FM_PROJECT_LOCK_DESC is ahead of it" >&2
    return "$FM_PROJECT_LOCK_BUSY_EXIT"
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
