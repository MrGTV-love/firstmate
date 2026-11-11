#!/usr/bin/env bash
# Send an unattended instruction through fm-send's existing data plane.
# Usage: fm-send-unattended.sh <task-selector> [fm-send text options...] <text...>
# Ordinary sends, transport failures and reply recovery keep fm-send's outcome.
# An ownership or declared-input refusal is handed to Firstmate in the target's
# existing status log, with the designated owner/cause and shell-quoted original
# argv. A note event holds only this unattended sender until Firstmate appends
# resolved [key=unattended-steer]; it is not an open decision and does not hold
# the worker's reply recovery, retry ring or check-in. No new queue, relay,
# delivery identity, received reply, restart, timer or resend is introduced.
# This is for autonomous callers only; attended sends continue using fm-send.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || exec "$SCRIPT_DIR/fm-send.sh" "$@"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

[ "$#" -gt 0 ] || exec "$SCRIPT_DIR/fm-send.sh" "$@"
STATE=${FM_STATE_OVERRIDE:-${FM_HOME:-}/state}
TASK=$(fm_backend_task_id_for_selector "$1" "$STATE" 2>/dev/null || true)
# The underlying sender owns selector errors. Only a single safe task-id
# component may select the status file this caller adds after a refusal.
case "$TASK" in ''|.*|*[!A-Za-z0-9._-]*) exec "$SCRIPT_DIR/fm-send.sh" "$@" ;; esac
STATUS="$STATE/$TASK.status"
HOLD=0
RESOLVE=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
if [ -f "$STATUS" ]; then
  EVENTS=$(fm_status_cat "$STATUS" | _fm_status_lines_with note "$RESOLVE"; exit "${PIPESTATUS[0]}") || exit 1
  while IFS= read -r line; do
    KEY=$(_fm_decision_key "$line" '') || continue
    [ "$KEY" = unattended-steer ] || continue
    VERB=$(status_line_verb "$line")
    case "$VERB" in
      note)
        NOTE=$(status_line_note "$line")
        case "$NOTE" in unattended-refusal:*) HOLD=1 ;; esac ;;
      "$RESOLVE") HOLD=0 ;;
    esac
  done <<< "$EVENTS"
fi
OPEN=$(status_open_decisions "$STATUS") || exit 1
while IFS=$'\t' read -r key _; do
  [ "$key" != unattended-steer ] || HOLD=1
done <<< "$OPEN"
if [ "$HOLD" = 1 ]; then
  "$SCRIPT_DIR/fm-guard-event.sh" send-task-prerequisites warn --rule unattended-hold --task "$TASK" 2>/dev/null || true
  printf 'notice: unattended steer to %s awaits Firstmate handling of %s [key=unattended-steer]; no send attempted\n' "$TASK" "$STATUS" >&2
  exit 1
fi

RC=0
OUT=$("$SCRIPT_DIR/fm-send.sh" "$@" 2>&1) || RC=$?
[ -z "$OUT" ] || printf '%s\n' "$OUT" >&2
[ "$RC" -ne 0 ] || exit 0
REFUSAL=''
while IFS= read -r line; do
  case "$line" in
    'error: refused task '*|'error: refused required input '*)
      REFUSAL="${REFUSAL}${REFUSAL:+ }$line" ;;
  esac
done <<< "$OUT"
if [ -n "$REFUSAL" ]; then
  printf -v ARGV '%q ' "$@"
  "$SCRIPT_DIR/fm-status-append.sh" "$STATUS" \
    "note [key=unattended-steer]: unattended-refusal: $REFUSAL Instruction argv: $ARGV" || {
      printf 'error: unattended refusal for %s could not be handed to Firstmate in %s; original instruction argv: %s\n' "$TASK" "$STATUS" "$ARGV" >&2
      exit 1
    }
fi
exit "$RC"
