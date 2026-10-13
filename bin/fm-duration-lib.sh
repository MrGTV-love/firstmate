#!/usr/bin/env bash
# fm-duration-lib.sh - shell adapters for bin/fm-duration.py (schema/help owner).
# fm_duration_load: print the 1-minute load average, or nothing when unavailable
# fm_duration_record <key> <milliseconds> <exit> [sample-id] [calibration: 0|1] [load-at-start] [timed-out: 0|1]
# fm_duration_record_batch: stdin rows key<TAB>ms<TAB>exit<TAB>calibration<TAB>load-start<TAB>load-end<TAB>timed-out
# fm_duration_limit <key> <existing-fallback-seconds> [95|99]
#   a fallback of 0 means the caller had no deadline: record only, never a measured kill
# fm_duration_timed <key> <existing-fallback-seconds> <command...>
# Only the owner of a limit says a timeout happened (timed-out 1); an exit of
# 124 or 137 is never inferred to be one here.
# Recording errors are visible on stderr and never replace a command's exit.
# Missing Python, a fixture copy without the helper, or a helper that cannot
# read its table preserves the existing bound with an explicit diagnostic.
# FM_DURATION_FILE=off disables recording.
FM_DURATION_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-duration.py"

fm_duration_load() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1}' /proc/loadavg
  else
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1}'
  fi
}

fm_duration_record() {
  [ "${FM_DURATION_FILE:-}" != off ] || return 0
  [ "${FM_DURATION_MANAGED_KEY:-}" != "$1" ] || return 0
  [ -r "$FM_DURATION_HELPER" ] || return 0
  local -a args
  args=(record "$1" "$2" "$3")
  [ -z "${4:-}" ] || args+=(--sample-id "$4")
  [ "${5:-1}" != 0 ] || args+=(--uncalibrated)
  [ -z "${6:-}" ] || args+=(--load-start "$6")
  [ "${7:-0}" != 1 ] || args+=(--timed-out)
  python3 "$FM_DURATION_HELPER" "${args[@]}" >&2 || {
    printf 'fm-duration: could not persist duration or file repeated timeout work for %s\n' "$1" >&2
    return 0
  }
}

fm_duration_record_batch() {
  if [ "${FM_DURATION_FILE:-}" = off ] || [ ! -r "$FM_DURATION_HELPER" ]; then
    cat >/dev/null
    return 0
  fi
  python3 "$FM_DURATION_HELPER" record-batch >&2 || {
    printf 'fm-duration: could not persist batched durations or file repeated timeout work\n' >&2
    return 0
  }
}

fm_duration_limit() {
  local bound
  if [ "${FM_DURATION_FILE:-}" = off ] || [ "$2" = 0 ]; then
    printf '%s\n' "$2"
    return 0
  fi
  if [ ! -r "$FM_DURATION_HELPER" ] || ! command -v python3 >/dev/null 2>&1; then
    printf 'fm-duration: calibration unavailable for %s; existing fallback %ss\n' "$1" "$2" >&2
    printf '%s\n' "$2"
    return 0
  fi
  if bound=$(python3 "$FM_DURATION_HELPER" limit "$1" --fallback "$2" --percentile "${3:-95}" --margin 3); then
    printf '%s\n' "$bound"
  else
    printf 'fm-duration: calibration unavailable for %s (%s); existing fallback %ss\n' "$1" "$bound" "$2" >&2
    printf '%s\n' "$2"
  fi
}

fm_duration_timed() {
  local key=$1 fallback=$2 bound started finished load_start result=0 timed_out=0
  shift 2
  bound=$(fm_duration_limit "$key" "$fallback") || return $?
  if ! declare -F fm_run_timed >/dev/null 2>&1; then
    # shellcheck source=bin/fm-timeout-lib.sh
    . "${FM_DURATION_HELPER%/*}/fm-timeout-lib.sh"
  fi
  load_start=$(fm_duration_load)
  started=$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000') || return $?
  if [ "$bound" -eq 0 ]; then
    "$@" || result=$?
  else
    fm_run_timed "$bound" "$@" || result=$?
  fi
  finished=$(perl -MTime::HiRes=time -e 'printf "%.0f", time * 1000') || return $?
  if [ "$bound" -gt 0 ] && [ "$result" -eq 124 ]; then
    timed_out=1
  fi
  fm_duration_record "$key" "$((finished - started))" "$result" '' 1 "$load_start" "$timed_out"
  return "$result"
}
