#!/usr/bin/env bash
# fm-mem-guard.sh - local memory diagnostic and measured macOS work admission.
# Usage: fm-mem-guard.sh [legacy diagnostic flags]
#        fm-mem-guard.sh sample|baseline|admit|probe
#        fm-mem-guard.sh run -- <new-run command...>
# Legacy flags retain the fail-open diagnostic contract in the engine header.
# sample records facts only; admit returns 75 if native pressure is 2 or higher,
# required facts are unreadable, or this host's recorded run peaks and pressured
# readings show that available memory minus one run's peak is below the margin.
# No new work runs after that return, and no existing work is stopped. The
# non-fleet RSS alarm baseline never affects that result. baseline derives the
# alarm envelope from recorded healthy readings; the engine header owns every
# record's contents and derivation.
# run checks once and execs a NEW run only; reattach/respond directly so pressure
# cannot prevent supervising existing work. admit, run and sample only record a
# reading in the invoking home's state.
# probe is the root local home's periodic host observation; elsewhere it does
# nothing. It records the host's run and pressure calibration and queues
# identifying check wakes through fm-wake-lib.sh in the root home's own queue.
# An alarm episode is keyed by process name; an outlier is not a leak diagnosis
# or restart authority. Unavailable facts and unavailable alarm or headroom
# calibration each wake once per episode; a reading with errors cannot end one.
# The invoking home's state owns memory-readings.jsonl; the root local home's
# state owns .memory-alarmed, .memory-calibration.json, and the one host
# .memory-baseline.json, which only the baseline command writes.
# FM_MEMORY_FIXTURE_DIR supplies sysctl, vm_stat and processes.json native facts
# for isolated tests; every fixture reading is explicitly marked in the log.
# Non-macOS admission is unchanged; its legacy diagnostic remains available.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --help ] || [ "${2:-}" = --help ]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exec python3 "$SCRIPT_DIR/fm-mem-guard.py" --help
fi
case "${1:-}" in
  sample|baseline|admit|probe|run) mode=$1; shift ;;
  *) exec python3 "$SCRIPT_DIR/fm-mem-guard.py" "$@" ;;
esac
if [ "$mode" = run ]; then
  [ "${1:-}" = -- ] && [ "$#" -gt 1 ] || { echo 'usage: fm-mem-guard.sh run -- <new-run command...>' >&2; exit 2; }
  shift
else
  [ "$#" -eq 0 ] || { echo 'unexpected memory guard arguments' >&2; exit 2; }
fi
if [ "$(uname -s)" != Darwin ] && [ -z "${FM_MEMORY_FIXTURE_DIR:-}" ]; then
  if [ "$mode" = run ]; then exec "$@"; fi
  exit 0
fi
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
root=$(fm_firstmate_root_home "$FM_HOME") || exit 75
host_state="$root/state"
if [ "$root" = "$(cd "$FM_HOME" && pwd -P)" ]; then
  host_state="$STATE"
elif [ "$mode" = probe ]; then
  exit 0
fi
engine_mode=$mode
[ "$mode" != run ] || engine_mode=admit
rc=0
reading=$(FM_MEMORY_FLEET_ROOT="$root" python3 "$SCRIPT_DIR/fm-mem-guard.py" "$engine_mode" \
  --state "$STATE" --baseline "$host_state/.memory-baseline.json" \
  --calibration "$host_state/.memory-calibration.json") || rc=$?
[ -n "$reading" ] || exit 75
# Use the existing queue owner, not a second notification transport. Queue before
# recording suppression; a crash may duplicate a notification but never loses it.
if [ "$mode" = probe ]; then
  marker="$STATE/.memory-alarmed"
  fm_lock_acquire_wait "$marker.lock" || exit 75
  trap 'fm_lock_release "$marker.lock"' EXIT
  previous=$(cat "$marker" 2>/dev/null || true)
  active=
  errors=$(jq -r '.errors | join("; ")' <<<"$reading")
  if [ -n "$errors" ]; then
    active+='unavailable'$'\n'"$previous"$'\n'
    if ! printf '%s\n' "$previous" | grep -Fx unavailable >/dev/null; then
      fm_wake_append check memory-health-unavailable "check: memory-health: admission measurements are unavailable ($errors); new work is deferred, existing work is unchanged. Read $STATE/memory-readings.jsonl." || exit 75
    fi
  else
    calibration=$(jq -r '.calibration // empty' <<<"$reading")
    if [ -n "$calibration" ]; then
      active+='uncalibrated'$'\n'
      if ! printf '%s\n' "$previous" | grep -Fx uncalibrated >/dev/null; then
        fm_wake_append check memory-health-uncalibrated "check: memory-health: the non-fleet RSS alarm is uncalibrated ($calibration); admission is unaffected. Record healthy readings, then read fm-mem-guard.sh --help before running its baseline command in $root." || exit 75
      fi
    fi
    headroom_calibration=$(jq -r '.headroom_calibration // empty' <<<"$reading")
    if [ -n "$headroom_calibration" ]; then
      active+='headroom-uncalibrated'$'\n'
      if ! printf '%s\n' "$previous" | grep -Fx headroom-uncalibrated >/dev/null; then
        fm_wake_append check memory-health-headroom-uncalibrated "check: memory-health: the admission headroom test is uncalibrated ($headroom_calibration); new work is admitted on native pressure and readable facts alone until real runs and a pressured reading are recorded. See docs/configuration.md \"Host memory admission\"." || exit 75
      fi
    fi
    while IFS= read -r alarm; do
      [ -n "$alarm" ] || continue
      key="alarm:$(jq -r '.comm' <<<"$alarm")"
      active+="$key"$'\n'
      if ! printf '%s\n' "$previous" | grep -Fx -- "$key" >/dev/null; then
        detail=$(jq -r '"non-fleet process \(.comm) PID \(.pid) RSS \(.rss_bytes) bytes exceeds the largest non-fleet RSS observed across \(.samples) healthy readings (\(.boundary_bytes) bytes)"' <<<"$alarm")
        fm_wake_append check memory-health "check: memory-health: $detail; see $STATE/memory-readings.jsonl. This is an observation, not a leak diagnosis; restarting any system daemon requires the captain's decision." || exit 75
      fi
    done < <(jq -c '.alarms[]' <<<"$reading")
    # An episode holds while the process stays above the low end of the measured
    # healthy variation; unreadable RSS cannot prove that it has ended.
    while IFS= read -r comm; do
      if printf '%s\n' "$previous" | grep -Fx -- "alarm:$comm" >/dev/null; then
        active+="alarm:$comm"$'\n'
      fi
    done < <(jq -r '.alarm_hold[]' <<<"$reading")
    if [ "$(jq '.rss_unreadable_pids // [] | length' <<<"$reading")" -ne 0 ]; then
      active+=$(printf '%s\n' "$previous" | grep '^alarm:' || true)
    fi
  fi
  printf '%s\n' "$active" | sed '/^$/d' | sort -u > "$marker.next.$$"
  mv -f "$marker.next.$$" "$marker"
  fm_lock_release "$marker.lock"
  trap - EXIT
fi
if [ "$mode" = run ]; then
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$reading" >&2; exit "$rc"; fi
  exec "$@"
fi
printf '%s\n' "$reading"
exit "$rc"
