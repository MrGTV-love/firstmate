#!/usr/bin/env bash
# fm-mem-guard.sh - local memory diagnostic and measured macOS work admission.
# Usage: fm-mem-guard.sh [legacy diagnostic flags]
#        fm-mem-guard.sh sample|baseline|probe
#        fm-mem-guard.sh admit [--kind task|no-mistakes]
#        fm-mem-guard.sh run [--kind task|no-mistakes] -- <new-run command...>
#        fm-mem-guard.sh calibrate --kind task|no-mistakes -- <representative command...>
# Legacy flags retain the fail-open diagnostic contract in the engine header.
# sample records facts only; admit returns 75 if the harm itself is measured
# (the run's projected resident size does not fit in available memory minus the
# reserve, or swap used or the compressor grew since the last probe reading),
# if that cannot be judged (the reading says why and how the record is filled;
# the one bootstrap admit is a host with no fleet run running and more available
# memory than the largest run peak recorded for any kind, and a host with no
# peak recorded admits nothing), or if required facts are unreadable. The
# kernel pressure level is recorded,
# never judged. No new work
# runs after that return, and no existing work is stopped. Neither the recorded
# one-run peak and headroom margin shown in each reading nor the non-fleet RSS
# alarm baseline affects that result. baseline derives the alarm envelope from
# recorded healthy root probe readings; the engine header owns every record's
# contents, the harm test and every derivation. --kind names the run being
# admitted; run defaults it to no-mistakes, and admit without it needs both
# kinds' projections and judges fit against the larger.
# calibrate is the one-time operator run that gets a first measurement: it runs
# the given representative command once, measures the largest resident size of
# its process tree, and records it as a run of --kind in the root home's
# calibration, so the next admit sees it. It starts only when the facts are
# readable, swap and the compressor are not growing, and more memory is
# available than the largest recorded peak (or, with none recorded, no fleet
# run is running); one calibration measures at a time.
# run checks once and execs a NEW run only; reattach/respond directly so a measured overload
# cannot prevent supervising existing work. admit, run and sample only record a reading in the
# invoking home's state. After that check, run hands COMMAND to
# fm-cpu-pass.py pipeline-start --only-fresh: a command that begins a new
# no-mistakes run (its engine's fresh_pipeline_start) queues there in class
# other; any other command runs with only the engine's exec interception added
# first on PATH, which admits a fresh no-mistakes the command itself reaches.
# probe is the root local home's periodic host observation; elsewhere it does
# nothing. It records the host's run and pressure calibration and queues
# identifying check wakes through fm-wake-lib.sh in the root home's own queue.
# An alarm episode is keyed by process name; an outlier is not a leak diagnosis
# or restart authority. Unavailable facts and unavailable alarm calibration
# each wake once per episode; a reading with errors cannot end one.
# The invoking home's state owns memory-readings.jsonl; the root local home's
# state owns .memory-alarmed, .memory-calibration.json, and the one host
# .memory-baseline.json, which only the baseline command writes.
# FM_MEMORY_FIXTURE_DIR supplies sysctl, vm_stat and processes.json native facts
# for isolated tests; every fixture reading is explicitly marked in the log.
# Off macOS, run takes no memory reading and hands COMMAND straight to
# pipeline-start --only-fresh; its legacy diagnostic remains available.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --help ] || [ "${2:-}" = --help ]; then
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
  exec python3 "$SCRIPT_DIR/fm-mem-guard.py" --help
fi
case "${1:-}" in
  sample|baseline|admit|probe|run|calibrate) mode=$1; shift ;;
  *) exec python3 "$SCRIPT_DIR/fm-mem-guard.py" "$@" ;;
esac
kind=
if [ "$mode" = admit ] || [ "$mode" = run ] || [ "$mode" = calibrate ]; then
  if [ "${1:-}" = --kind ]; then
    case "${2:-}" in
      task|no-mistakes) kind=$2; shift 2 ;;
      *) echo 'usage: --kind task|no-mistakes' >&2; exit 2 ;;
    esac
  fi
fi
if [ "$mode" = calibrate ]; then
  [ -n "$kind" ] && [ "${1:-}" = -- ] && [ "$#" -gt 1 ] || { echo 'usage: fm-mem-guard.sh calibrate --kind task|no-mistakes -- <representative command...>' >&2; exit 2; }
  shift
elif [ "$mode" = run ]; then
  [ "${1:-}" = -- ] && [ "$#" -gt 1 ] || { echo 'usage: fm-mem-guard.sh run [--kind task|no-mistakes] -- <new-run command...>' >&2; exit 2; }
  shift
  [ -n "$kind" ] || kind=no-mistakes
else
  [ "$#" -eq 0 ] || { echo 'unexpected memory guard arguments' >&2; exit 2; }
fi
if [ "$(uname -s)" != Darwin ] && [ -z "${FM_MEMORY_FIXTURE_DIR:-}" ]; then
  if [ "$mode" = run ]; then
    # Without python3 the base's direct exec stands (Main 4938): no reading and no pipeline-start admission here.
    command -v python3 >/dev/null 2>&1 || exec "$@"
    exec python3 "$SCRIPT_DIR/fm-cpu-pass.py" pipeline-start --only-fresh -- "$@"
  fi
  if [ "$mode" = calibrate ]; then exec "$@"; fi
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
if [ "$mode" = calibrate ]; then
  FM_MEMORY_FLEET_ROOT="$root" exec python3 "$SCRIPT_DIR/fm-mem-guard.py" calibrate --state "$STATE" \
    --calibration "$host_state/.memory-calibration.json" --kind "$kind" -- "$@"
fi
engine_mode=$mode
[ "$mode" != run ] || engine_mode=admit
rc=0
kind_args=()
[ -z "$kind" ] || kind_args=(--kind "$kind")
reading=$(FM_MEMORY_FLEET_ROOT="$root" python3 "$SCRIPT_DIR/fm-mem-guard.py" "$engine_mode" \
  --state "$STATE" --baseline "$host_state/.memory-baseline.json" \
  --calibration "$host_state/.memory-calibration.json" ${kind_args[@]+"${kind_args[@]}"}) || rc=$?
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
  exec python3 "$SCRIPT_DIR/fm-cpu-pass.py" pipeline-start --only-fresh -- "$@"
fi
printf '%s\n' "$reading"
exit "$rc"
