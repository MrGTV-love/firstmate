#!/usr/bin/env bash
# fm-guard-event.sh - the single writer of guard decision events.
#
# One JSON line per decision, appended to one log per home. The event exists so
# the retirement rule in docs/guard-spec.md can be computed from measurements
# instead of from a static cost estimate. bin/fm-guard-metrics.sh is the single
# reader and owns the rule.
#
# Usage:
#   fm-guard-event.sh <guard-id> <decision> [options]
#   fm-guard-event.sh --help
#
# Decisions: deny, warn, allow, error. A guard emits one event per decision it
# takes, including allow, because opportunities - not fires - are the
# denominator: a guard that never fires across thirty decisions is the cut case.
#
# Options:
#   --source-ok true|false   whether the authoritative source was readable
#                            (default true; a deny from an unreadable source is
#                            still a decision, and marks the fail direction)
#   --elapsed-ms <n>         milliseconds the guard spent deciding (default 0)
#   --cleared-by <word>      what cleared a preceding deny: retry, captain,
#                            waiver, env, or any short caller-owned token
#   --repeat <n>             this guard's decision count in the same session,
#                            including this one (default 1)
#   --override               a human or environment escape was used; the
#                            strongest false-positive signal available for free
#   --system <name>          firstmate (default) or vernant
#   --guard-version <v>      the registry version of the guard (default 1)
#   --session <id>           session identifier; defaults to the live task id,
#                            else FM_SESSION_ID, else this shell's parent pid
#   --log <path>             append here instead of the home's log
#
# Log path: $FM_GUARD_EVENT_LOG, else ${FM_HOME:-$FM_ROOT}/state/guard-events.jsonl.
#
# Exit: always 0, including on a malformed argument or an unwritable log. A
# guard must never change its own decision because telemetry failed, and a
# telemetry error must never be a new way for a turn to fail. The writer is
# silent except for --help and a log-open failure, which it reports once on
# stderr so a broken log is visible without being fatal.
set -u

usage() { sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'; }

if [ $# -eq 0 ]; then usage >&2; exit 0; fi
case "${1:-}" in -h|--help) usage; exit 0 ;; esac

GUARD=${1:-}; DECISION=${2:-}
[ -n "$GUARD" ] || { echo "fm-guard-event: missing guard id" >&2; exit 0; }
case "$DECISION" in deny|warn|allow|error) ;; *)
  echo "fm-guard-event: unknown decision '$DECISION'" >&2; exit 0 ;;
esac
shift 2 2>/dev/null || shift $#

SOURCE_OK=true
ELAPSED_MS=0
CLEARED_BY=''
REPEAT=1
OVERRIDE=false
SYSTEM=firstmate
GUARD_VERSION=1
SESSION=''
LOG=''

while [ $# -gt 0 ]; do
  case "$1" in
    --source-ok) [ $# -ge 2 ] && SOURCE_OK=$2; shift 2 ;;
    --elapsed-ms) [ $# -ge 2 ] && ELAPSED_MS=$2; shift 2 ;;
    --cleared-by) [ $# -ge 2 ] && CLEARED_BY=$2; shift 2 ;;
    --repeat) [ $# -ge 2 ] && REPEAT=$2; shift 2 ;;
    --override) OVERRIDE=true; shift ;;
    --system) [ $# -ge 2 ] && SYSTEM=$2; shift 2 ;;
    --guard-version) [ $# -ge 2 ] && GUARD_VERSION=$2; shift 2 ;;
    --session) [ $# -ge 2 ] && SESSION=$2; shift 2 ;;
    --log) [ $# -ge 2 ] && LOG=$2; shift 2 ;;
    *) shift ;;
  esac
done

case "$SOURCE_OK" in true|false) ;; *) SOURCE_OK=false ;; esac
case "$ELAPSED_MS" in ''|*[!0-9]*) ELAPSED_MS=0 ;; esac
case "$REPEAT" in ''|*[!0-9]*|0) REPEAT=1 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -z "$LOG" ]; then
  LOG=${FM_GUARD_EVENT_LOG:-}
fi
if [ -z "$LOG" ]; then
  LOG="${FM_HOME:-${FM_ROOT:-$ROOT}}/state/guard-events.jsonl"
fi

if [ -z "$SESSION" ]; then
  SESSION=${FM_TASK_ID:-${FM_SESSION_ID:-}}
fi
if [ -z "$SESSION" ]; then
  SESSION="pid-$$"
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

json_string() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/\\t/g"
}

LINE=$(printf '{"ts":"%s","guard":"%s","version":"%s","system":"%s","session":"%s","decision":"%s","source_ok":%s,"elapsed_ms":%s,"cleared_by":"%s","repeat":%s,"override":%s}' \
  "$TS" "$(json_string "$GUARD")" "$(json_string "$GUARD_VERSION")" "$(json_string "$SYSTEM")" \
  "$(json_string "$SESSION")" "$DECISION" "$SOURCE_OK" "$ELAPSED_MS" \
  "$(json_string "$CLEARED_BY")" "$REPEAT" "$OVERRIDE")

LOG_DIR=${LOG%/*}
[ "$LOG_DIR" = "$LOG" ] && LOG_DIR=.
if ! { mkdir -p "$LOG_DIR" 2>/dev/null && printf '%s\n' "$LINE" >>"$LOG" 2>/dev/null; }; then
  echo "fm-guard-event: cannot append to $LOG" >&2
fi
exit 0
