#!/usr/bin/env bash
# Shared "is this git lock file provably abandoned?" decision procedure.
#
# ONE owner for the staleness proof that fm-teardown.sh (a worktree index.lock)
# and fm-fleet-sync.sh (a clone's .git/packed-refs.lock) both rely on: a lock is
# provably stale iff ALL of the following hold -
#   1. the lock file still exists;
#   2. no live process holds the lock file open, and no Git process (kernel
#      command basename git or git-*) holds the companion directory (the
#      worktree, or the repo's .git dir) open as cwd or an fd. This covers Git's
#      native executable and dashed helpers, not shells whose argv mentions git.
#      lsof's c field is the kernel command ("cgit" encodes command "git").
#      Git's close_lock_file_gently()
#      can close its descriptor BEFORE commit/rollback, so directory-held Git
#      processes still veto removal. Non-Git cwd/fd holders (idle pane shells,
#      treehouse, etc.) cannot own that Git transaction and do not veto it;
#      ANY process holding the lock itself still vetoes removal, regardless
#      of its command. Unknown/malformed directory-holder output vetoes too;
#   3. its mtime age is at least a caller-supplied threshold - a freshly created
#      lock might belong to a process lsof has not yet reflected.
# ANY uncertainty - lsof missing, an lsof error, an unreadable mtime - returns
# non-zero (NOT stale): fail safe, never remove a lock that cannot be proven dead.
# Diagnostics print to stderr prefixed by ${FM_LOCK_LOG_PREFIX:-fm-lock} so each
# caller's output stays recognizable.

fm_lock_log() {
  echo "${FM_LOCK_LOG_PREFIX:-fm-lock}: $*" >&2
}

# Portable mtime in epoch seconds. Kept self-contained so this leaf lib drags in
# no wake-queue machinery when a caller only needs the staleness proof.
_FM_LOCK_UNAME=${_FM_UNAME:-$(uname 2>/dev/null)}
fm_lock_path_mtime() {
  # Read the name again when the variable did not come along (an exported-function runner).
  [ -n "$_FM_LOCK_UNAME" ] || _FM_LOCK_UNAME=$(uname 2>/dev/null)
  if [ "$_FM_LOCK_UNAME" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_lock_lsof_holder <target> [git-only]: 0 a relevant process holds it,
# 1 provably none, 2 lsof errored or returned unclassifiable data (cannot tell).
# Use command fields, not lsof's truncated human-readable COMMAND column.
# The lock-file query deliberately has no command filter.
fm_lock_lsof_holder() {
  local target=$1 mode=${2:-all} output status line command pid='' command_seen=0 valid=0
  local -a args=()
  [ "$mode" != git-only ] || args=(+c 0 -F pc)
  if output=$(lsof ${args[@]+"${args[@]}"} -- "$target" 2>&1); then
    [ "$mode" = git-only ] || return 0
    while IFS= read -r line; do
      valid=0
      case "$line" in
        p*)
          # Every process must have an identifiable command before ignoring it.
          [ -z "$pid" ] || [ "$command_seen" -eq 1 ] || break
          pid=${line#p}
          case "$pid" in ''|*[!0-9]*) break ;; esac
          command_seen=0
          ;;
        c*)
          [ -n "$pid" ] && [ "$command_seen" -eq 0 ] || break
          command=${line#c}
          [ -n "$command" ] || break
          case "${command##*/}" in git|git-*) return 0 ;; esac
          command_seen=1
          ;;
        f*)
          # lsof includes descriptor fields even when only p/c were requested.
          [ "$command_seen" -eq 1 ] || break
          ;;
        *) break ;;
      esac
      valid=1
    done <<< "$output"
    if [ "$valid" -eq 1 ] && [ -n "$pid" ] && [ "$command_seen" -eq 1 ]; then
      return 1
    fi
    fm_lock_log "cannot classify lsof directory holders for $target; leaving the lock in place"
    return 2
  else
    status=$?
  fi
  if [ "$status" -eq 1 ] && [ -z "$output" ]; then
    return 1
  fi
  if [ -n "$output" ]; then
    while IFS= read -r line; do
      fm_lock_log "lsof check failed: $line"
    done <<< "$output"
  else
    fm_lock_log "lsof check failed for $target with exit $status"
  fi
  return 2
}

# fm_lock_has_live_holder <lock> <dir>: 0 if ANY process holds $lock, a Git
# process holds companion $dir, or the answer is uncertain (assume live).
# Returns 1 only when both queries rule out the owners defined in the header.
fm_lock_has_live_holder() {
  local lock=$1 dir=$2 status
  command -v lsof >/dev/null 2>&1 || return 0
  if [ -n "$lock" ]; then
    if fm_lock_lsof_holder "$lock"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  if [ -n "$dir" ]; then
    if fm_lock_lsof_holder "$dir" git-only; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  return 1
}

# fm_lock_age <lock>: prints the lock's mtime age in whole seconds, or fails.
fm_lock_age() {
  local lock=$1 m now
  m=$(fm_lock_path_mtime "$lock") || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( now - m ))"
}

# fm_lock_is_provably_stale <lock> <dir> <min_age_secs>: THE proof. Returns 0 iff
# the lock exists, has no live holder, and its mtime age is at least
# <min_age_secs>. Returns non-zero on any uncertainty - never remove a lock this
# returns non-zero for.
fm_lock_is_provably_stale() {
  local lock=$1 dir=$2 min_age=$3 age
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  fm_lock_has_live_holder "$lock" "$dir" && return 1
  if ! age=$(fm_lock_age "$lock"); then
    fm_lock_log "cannot read mtime for git lock $lock; leaving it in place"
    return 1
  fi
  [ "$age" -ge "$min_age" ]
}
