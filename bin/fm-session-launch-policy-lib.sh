#!/usr/bin/env bash
# Session launch policy shared by spawning, recovery, and supervision engines.
# docs/configuration.md "Session launch policy" owns the opt-in schema.
# Absent configuration preserves existing behavior; a restriction never maps
# a recorded harness or model to another profile. Opaque raw commands refuse.
# No runtime is executed by this check. tc run requires its verified native
# launcher contract to land; a proxy wrapper that execs claude is not tc run.
# Automatic refusal receipts live in state/.session-launch-refused-<id>:
# the first line names the refused generation; subsequent lines retain its
# notified policy keys after wake acknowledgement, without recovery accounting.

# shellcheck source=bin/fm-config-inherit-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-config-inherit-lib.sh"

fm_session_launch_policy_enabled() {  # <config-dir>; prints 0 or 1
  local file="$1/session-launch-policy" present value
  present=$(fm_config_source_present "$file") || return 1
  if [ "$present" = 0 ]; then
    printf '0\n'
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'error: config/session-launch-policy must be a readable regular file containing omp-or-tc\n' >&2
    return 1
  fi
  value=$(jq -Rrs '. == "omp-or-tc" or . == "omp-or-tc\n"' "$file") || return 1
  if [ "$value" != true ]; then
    printf 'error: config/session-launch-policy must contain exactly omp-or-tc (with an optional trailing newline)\n' >&2
    return 1
  fi
  printf '1\n'
}

fm_session_launch_policy_check() {  # <config-dir> <harness> [raw=0|1]
  local enabled harness=$2 raw=${3:-0}
  enabled=$(fm_session_launch_policy_enabled "$1") || return 1
  [ "$enabled" = 1 ] || return 0
  if [ "$raw" = 0 ] && [ "$harness" = omp ]; then
    return 0
  fi
  printf "error: config/session-launch-policy=omp-or-tc refuses launch '%s'; only the canonical omp adapter is currently supported under this policy; tc run requires a verified native launcher, not plain claude or a proxy wrapper\n" "$harness" >&2
  printf 'help: select an explicit allowed dispatch profile; for recovery use bin/fm-control.sh <id> relaunch --harness omp --model <omp-model-id> --effort <level> --note "<progress>"; no previous agent or work needs to be discarded\n' >&2
  return 1
}

fm_session_launch_policy_refusal_notify() {
  local state=$1 id=$2 generation=$3 reason=$4 error=$5 file fingerprint key notified
  shift 5
  FM_SESSION_LAUNCH_REFUSAL_WAKE=
  if ! declare -F fm_wake_append_locked >/dev/null 2>&1; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-wake-lib.sh"
  fi
  fingerprint=$(
    {
      printf '%s\n' "$error"
      for file in "$@"; do
        printf '%s\n' "$file"
        if [ -f "$file" ] && [ -r "$file" ]; then
          cat "$file"
        else
          printf 'unreadable-or-absent\n'
        fi
        printf '\n'
      done
    } | cksum
  ) || return 1
  key="session-launch-refused-$id-$generation-${fingerprint// /-}"
  notified=$(
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1
    trap 'fm_lock_release "$FM_WAKE_QUEUE_LOCK"' EXIT
    marker="$state/.session-launch-refused-$id"
    marker_generation=
    if [ -e "$marker" ] || [ -L "$marker" ]; then
      [ -f "$marker" ] && [ ! -L "$marker" ] && [ -r "$marker" ] || exit 1
      IFS= read -r marker_generation < "$marker" || exit 1
      if [ "$marker_generation" = "$generation" ] && grep -Fx -- "$key" "$marker" >/dev/null; then
        exit 0
      fi
    fi
    queued=$(fm_wake_queued_keys_locked check)
    new=0
    if ! printf '%s\n' "$queued" | grep -Fx -- "$key" >/dev/null; then
      fm_wake_append_locked check "$key" "$reason" || exit 1
      new=1
    fi
    if [ "$marker_generation" != "$generation" ]; then
      printf '%s\n' "$generation" > "$marker" || exit 1
    fi
    printf '%s\n' "$key" >> "$marker" || exit 1
    [ "$new" = 0 ] || printf '%s' "$reason"
  ) || return 1
  FM_SESSION_LAUNCH_REFUSAL_WAKE=$notified
  return 0
}

fm_session_launch_policy_check_child() {
  local enabled child_enabled
  enabled=$(fm_session_launch_policy_enabled "$1") || return 1
  [ "$enabled" = 1 ] || return 0
  child_enabled=$(fm_session_launch_policy_enabled "$2") || return 1
  [ "$child_enabled" = 1 ] && return 0
  printf 'error: secondmate config/session-launch-policy must be enabled at %s before launch\n' "$2" >&2
  return 1
}

fm_session_launch_policy_converge_child() (
  local config=$1 home=$2 id=$3 enabled lock dir
  enabled=$(fm_session_launch_policy_enabled "$config") || return 1
  [ "$enabled" = 1 ] || return 0
  if [ "${FM_SKIP_SECONDMATE_INHERIT:-0}" != 1 ]; then
    if [ -z "$home" ] || [ "$(cat "$home/.fm-secondmate-home" 2>/dev/null)" != "$id" ]; then
      printf 'error: cannot converge session-launch-policy into an unseeded secondmate home: %s\n' "$home" >&2
      return 1
    fi
    if [ ! -d "$home/state" ]; then
      printf 'error: cannot converge session-launch-policy without secondmate state directory: %s\n' "$home" >&2
      return 1
    fi
    for dir in "$home/state" "$home/config"; do
      if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
        printf 'error: cannot converge session-launch-policy through an unsafe secondmate directory: %s\n' "$dir" >&2
        return 1
      fi
    done
    lock=$(fm_config_inherit_lock_path "$home") || return 1
    fm_lock_try_acquire "$lock" || {
      printf 'error: cannot acquire secondmate session-launch-policy inheritance lock: %s\n' "$home" >&2
      return 1
    }
    trap 'fm_lock_release "$lock" || true' EXIT
    FM_INHERITABLE_CONFIG=session-launch-policy \
      propagate_inheritable_config "$config" "$home/config" ||
      printf 'warning: secondmate %s session-launch-policy inheritance failed for %s\n' "$id" "$home" >&2
  fi
  fm_session_launch_policy_check_child "$config" "$home/config"
)
