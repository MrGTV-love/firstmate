#!/usr/bin/env bash
# fm-mem-guard.sh - local memory diagnostic and measured macOS work admission.
# Usage: fm-mem-guard.sh [legacy diagnostic flags]
#        fm-mem-guard.sh sample|baseline|admit|probe
#        fm-mem-guard.sh run -- <new-run command...>
# Legacy flags retain the fail-open diagnostic contract in the engine header.
# baseline records one known-healthy non-fleet RSS envelope, without replacing
# an existing baseline; sample records facts only; admit returns 75 if native
# pressure is high, an explicit operating cap is exceeded, or facts/baseline are
# unreadable. No new work runs after that return, and no existing work is stopped.
# run checks once and execs a NEW run only; reattach/respond directly so pressure
# cannot prevent supervising existing work. probe queues identifying check wakes
# through fm-wake-lib.sh. Alarms dedupe by process identity until it drops below
# the baseline. A baseline outlier is not a leak diagnosis or restart authority.
# The root local home's state owns .memory-baseline.json, memory-readings.jsonl,
# and .memory-alarmed. Source metrics/derivation live in the engine header.
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
memory_state="$root/state"
[ "$root" != "$FM_HOME" ] || memory_state="$STATE"
engine_mode=$mode
[ "$mode" != run ] || engine_mode=admit
rc=0
reading=$(FM_MEMORY_FLEET_ROOT="$root" python3 "$SCRIPT_DIR/fm-mem-guard.py" "$engine_mode" --state "$memory_state") || rc=$?
[ -n "$reading" ] || exit 75
# Use the existing queue owner, not a second notification transport. Queue before
# recording suppression; a crash may duplicate a notification but never loses it.
if [ "$mode" = probe ] || [ "$mode" = admit ] || [ "$mode" = run ]; then
  marker="$memory_state/.memory-alarmed"
  fm_lock_acquire_wait "$marker.lock" || exit 75
  trap 'fm_lock_release "$marker.lock"' EXIT
  previous=$(cat "$marker" 2>/dev/null || true)
  active=
  if [ "$(jq '.errors | length' <<<"$reading")" -ne 0 ] || [ "$(jq -r '.baseline == null' <<<"$reading")" = true ]; then
    active+='unavailable'$'\n'
    if ! printf '%s\n' "$previous" | grep -Fx unavailable >/dev/null; then
      FM_WAKE_QUEUE="$memory_state/.wake-queue" FM_WAKE_QUEUE_LOCK="$memory_state/.wake-queue.lock" \
        fm_wake_append check memory-health-unavailable "check: memory-health: admission measurements or the healthy RSS baseline are unavailable; new work is deferred, existing work is unchanged. Read $memory_state/memory-readings.jsonl and the fm-mem-guard.sh baseline help before measuring a known-healthy workload." || exit 75
    fi
  fi
  while IFS= read -r alarm; do
    [ -n "$alarm" ] || continue
    key=$(jq -r '[.kind, .pid, .started] | @json' <<<"$alarm")
    active+="$key"$'\n'
    if ! printf '%s\n' "$previous" | grep -Fx -- "$key" >/dev/null; then
      detail=$(jq -r '"\(.kind) process \(.comm) PID \(.pid) RSS \(.rss_bytes) bytes exceeds measured boundary \(.boundary_bytes) bytes"' <<<"$alarm")
      # Override the queue only for this publication, so a secondmate's health
      # reading reports to the local root without changing unrelated wake state.
      FM_WAKE_QUEUE="$memory_state/.wake-queue" FM_WAKE_QUEUE_LOCK="$memory_state/.wake-queue.lock" \
        fm_wake_append check memory-health "check: memory-health: $detail; see $memory_state/memory-readings.jsonl. This is an observation, not a leak diagnosis; restarting any system daemon requires the captain's decision." || exit 75
    fi
  done < <(jq -c '.alarms[]' <<<"$reading")
  # An unreadable observation cannot prove an alarm episode has recovered.
  if [ "$(jq '(.errors | length) + (.rss_unreadable_pids // [] | length)' <<<"$reading")" -ne 0 ]; then
    active="$previous"$'\n'"$active"
  fi
  printf '%s' "$active" | sort -u > "$marker.next.$$"
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
